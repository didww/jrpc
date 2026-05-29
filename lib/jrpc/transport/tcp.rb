# frozen_string_literal: true

require 'socket'

module JRPC
  module Transport
    class Tcp < Base
      # Pull error classes into this scope so `raise ConnectionError` resolves correctly.
      # Without this, Ruby's constant lookup would find JRPC::ConnectionError (v1) instead.
      ConnectionError = Base::ConnectionError
      Timeout = Base::Timeout
      MalformedFrame = Base::MalformedFrame

      # RFC2385 TCP MD5 Signature. TCP_MD5SIG is a Linux socket option (IPPROTO_TCP
      # level); it is absent on platforms that don't support it, in which case the
      # transport raises ConnectionError when a key is requested. The kernel caps the
      # key at 80 bytes (TCP_MD5SIG_MAXKEYLEN, not exported as a Ruby constant).
      TCP_MD5SIG = defined?(::Socket::TCP_MD5SIG) ? ::Socket::TCP_MD5SIG : nil
      TCP_MD5SIG_MAXKEYLEN = 80

      def initialize(server, **options)
        super
        @socket = nil
        @read_buffer = ''.b
      end

      def connect
        deadline = @connect_timeout ? monotonic_now + @connect_timeout : nil
        attempts_remaining = @connect_retry_count + 1
        begin
          connect_once(deadline)
        rescue ConnectionError, Timeout
          attempts_remaining -= 1
          raise if attempts_remaining <= 0
          raise if deadline && remaining_time(deadline) <= 0 # total budget spent

          sleep @connect_retry_interval
          retry
        end
      end

      def write_frame(bytes, timeout:)
        raise ConnectionError, 'transport closed' if @socket.nil?

        frame = "#{bytes.bytesize}:#{bytes},"
        written = 0
        deadline = timeout ? monotonic_now + timeout : nil

        while written < frame.bytesize
          remaining = remaining_time(deadline)
          close_and_raise_timeout!('write') if remaining && remaining <= 0

          writable = @socket.wait_writable(remaining)
          close_and_raise_timeout!('write') unless writable

          begin
            n = @socket.write_nonblock(frame.byteslice(written..))
            written += n
          rescue IO::WaitWritable
            # socket not ready yet; loop back to IO.select. Rescue the module (not the
            # concrete IO::EAGAINWaitWritable) so IO::EWOULDBLOCKWaitWritable is also
            # caught on platforms where EAGAIN != EWOULDBLOCK (macOS/BSD).
          rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
            close
            raise ConnectionError, "write failed: #{e.class}: #{e.message}"
          end
        end
      end

      def read_frame(timeout:)
        raise ConnectionError, 'transport closed' if @socket.nil?

        deadline = timeout ? monotonic_now + timeout : nil

        loop do
          result = try_parse_frame
          return result unless result == :wait

          remaining = remaining_time(deadline)
          close_and_raise_timeout!('read') if remaining && remaining <= 0

          readable = @socket.wait_readable(remaining)
          close_and_raise_timeout!('read') unless readable

          fill_buffer
        end
      end

      def try_read_frame
        raise ConnectionError, 'transport closed' if @socket.nil?

        # Parse first so already-buffered frames survive an EOF on the next read.
        result = try_parse_frame
        return result unless result == :wait

        # fill_buffer swallows EAGAIN (no data yet); the re-parse then returns :wait.
        fill_buffer
        try_parse_frame
      end

      def close
        begin
          @socket&.close
        rescue StandardError
          nil
        end
        @socket = nil
        @read_buffer = ''.b
      end

      def closed?
        @socket.nil? || @socket.closed?
      end

      attr_reader :socket

      private

      # Attempt a single TCP connect.  All errors are normalised to ConnectionError or Timeout.
      def connect_once(deadline)
        # Close any existing socket first so connecting on an already-connected
        # transport replaces it cleanly instead of orphaning the old file descriptor.
        begin
          @socket&.close
        rescue StandardError
          nil
        end
        @socket = nil

        sock, sockaddr = build_socket
        apply_tcp_md5sig!(sock, sockaddr) if @tcp_md5_pass

        loop do
          break if try_connect_nonblock(sock, sockaddr, deadline)
        end

        @socket = sock
        @read_buffer = ''.b
      end

      def fill_buffer
        chunk = @socket.read_nonblock(65_536)
        @read_buffer << chunk.b
      rescue IO::WaitReadable
        # no data right now; caller already confirmed readable via IO.select
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError => e
        close
        raise ConnectionError, "read failed: #{e.class}: #{e.message}"
      end

      def build_socket
        host, port_str = @server.split(':', 2)
        addr_info = ::Socket.getaddrinfo(host, nil, nil, ::Socket::SOCK_STREAM)
        family = ::Socket.const_get(addr_info[0][0])
        sockaddr = ::Socket.pack_sockaddr_in(port_str.to_i, addr_info[0][3])
        sock = ::Socket.new(family, ::Socket::SOCK_STREAM, 0)
        [sock, sockaddr]
      rescue StandardError => e
        raise ConnectionError, "#{e.class}: #{e.message}"
      end

      # Install the RFC2385 TCP MD5 Signature key on the socket *before* connect, keyed
      # to the peer at +peer_sockaddr+. The kernel then signs and verifies every segment
      # of the connection; a peer with a mismatched (or absent) key has its segments
      # silently dropped, so the handshake never completes. Linux-only. Any failure
      # — unsupported platform, oversized key, or a setsockopt error — closes the
      # just-built socket (no fd leak) and raises ConnectionError, since a security
      # option that silently fails to apply is worse than a refused connection.
      def apply_tcp_md5sig!(sock, peer_sockaddr)
        raise ConnectionError, 'tcp_md5_pass set but TCP_MD5SIG is unsupported on this platform' if TCP_MD5SIG.nil?

        key = @tcp_md5_pass.b
        if key.bytesize > TCP_MD5SIG_MAXKEYLEN
          raise ConnectionError, "tcp_md5_pass is #{key.bytesize} bytes; max is #{TCP_MD5SIG_MAXKEYLEN}"
        end

        # struct tcp_md5sig: sockaddr_storage(128) + flags(u8) + prefixlen(u8) +
        # keylen(u16) + ifindex(u32) + key[80]. Basic per-peer mode leaves
        # flags/prefixlen/ifindex zero; keylen/ifindex are native byte order.
        addr = peer_sockaddr.b.ljust(128, "\x00".b)
        meta = [0, 0, key.bytesize, 0].pack('CCSL')
        keybuf = key.ljust(TCP_MD5SIG_MAXKEYLEN, "\x00".b)
        sock.setsockopt(::Socket::IPPROTO_TCP, TCP_MD5SIG, addr + meta + keybuf)
      rescue ConnectionError
        close_socket(sock)
        raise
      rescue SystemCallError => e
        close_socket(sock)
        raise ConnectionError, "failed to set TCP MD5 signature (RFC2385): #{e.class}: #{e.message}"
      rescue StandardError => e
        # Any other failure (e.g. a non-String tcp_md5_pass that doesn't respond
        # to #b) still closes the socket and normalises to ConnectionError.
        close_socket(sock)
        raise ConnectionError, "invalid tcp_md5_pass: #{e.class}: #{e.message}"
      end

      def close_socket(sock)
        sock&.close
      rescue StandardError
        nil
      end

      def try_connect_nonblock(sock, sockaddr, deadline)
        sock.connect_nonblock(sockaddr)
        true # connected
      rescue Errno::EISCONN
        true # already connected
      rescue IO::WaitWritable
        writable = sock.wait_writable(connect_wait_timeout(deadline))
        unless writable
          begin
            sock.close
          rescue StandardError
            nil
          end
          raise Timeout, "connect timed out to #{@server}"
        end
        false
        # loop again → next connect_nonblock call will return EISCONN or error
      rescue StandardError => e
        begin
          sock.close
        rescue StandardError
          nil
        end
        raise ConnectionError, "#{e.class}: #{e.message}"
      end

      # Wait passed to a single IO.select while connecting: the smaller of the per-attempt
      # cap and the time left in the overall connect deadline. nil (block forever) only when
      # neither bound is set.
      def connect_wait_timeout(deadline)
        bounds = [@connect_attempt_timeout, remaining_time(deadline)].compact
        return nil if bounds.empty?

        wait = bounds.min
        wait.negative? ? 0 : wait
      end

      def try_parse_frame
        return :wait if @read_buffer.empty?

        colon_idx = @read_buffer.index(':'.b)

        if colon_idx.nil?
          unless @read_buffer.match?(/\A\d+\z/)
            raise MalformedFrame, "non-digit in length prefix: #{@read_buffer.byteslice(0, 32).inspect}"
          end

          return :wait
        end

        raise MalformedFrame, 'empty length prefix' if colon_idx.zero?

        length_str = @read_buffer.byteslice(0, colon_idx)
        raise MalformedFrame, "non-digit in length prefix: #{length_str.inspect}" unless length_str.match?(/\A\d+\z/)
        if length_str.bytesize > 1 && length_str.getbyte(0) == 48 # ord('0'): leading zero
          raise MalformedFrame, "leading zero in length prefix: #{length_str.inspect}"
        end

        length = Integer(length_str, 10)
        frame_end = colon_idx + 1 + length # index of the expected comma

        return :wait if @read_buffer.bytesize <= frame_end

        unless @read_buffer.getbyte(frame_end) == 44 # ord(',')
          raise MalformedFrame, "missing comma terminator at position #{frame_end}"
        end

        data = @read_buffer.byteslice(colon_idx + 1, length).force_encoding(Encoding::UTF_8)
        # The line-194 guard guarantees bytesize > frame_end, so this byteslice is never nil.
        @read_buffer = @read_buffer.byteslice((frame_end + 1)..)
        data
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def remaining_time(deadline)
        return nil unless deadline

        deadline - monotonic_now
      end

      def close_and_raise_timeout!(operation)
        close
        raise Timeout, "#{operation} timed out on #{@server}"
      end
    end
  end
end
