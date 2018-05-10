module JRPC
  module Transport
    class SocketTcp < SocketBase

      attr_reader :socket

      def initialize(options)
        super
        @socket = build_socket
      end

      def read(length, timeout = @read_timeout)
        received = ''
        length_to_read = length
        while length_to_read > 0
          io_read, = IO.select([@socket], [], [], timeout)
          raise ReadTimeoutError unless io_read
          chunk = io_read[0].read_nonblock(length_to_read)
          received += chunk
          length_to_read -= chunk.bytesize
        end
        received
      end

      def write(data, timeout = @write_timeout)
        length_written = 0
        data_to_write = data
        while data_to_write.bytesize > 0
          _, io_write, = IO.select([], [@socket], [], timeout)
          raise WriteTimeoutError unless io_write
          chunk_length = io_write[0].write_nonblock(data_to_write)
          length_written += chunk_length
          data_to_write = data.byteslice(length_written, data.length)
        end
        length_written
      end

      def close
        @socket.close
      end

      def closed?
        @socket.closed?
      end

      private

      def set_timeout_to(socket, type, value)
        secs = Integer(value)
        u_secs = Integer((value - secs) * 1_000_000)
        opt_val = [secs, u_secs].pack('l_2')
        socket.setsockopt Socket::SOL_SOCKET, type, opt_val
      end

      def build_socket
        host = @server.split(':').first
        addr = Socket.getaddrinfo(host, nil)
        sock = Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)
        set_timeout_to(sock, Socket::SO_RCVTIMEO, @connect_timeout) if @connect_timeout
        sock
      end

      def connect_socket
        host, port = @server.split(':')
        addr = Socket.getaddrinfo(host, nil)
        full_addr = Socket.pack_sockaddr_in(port, addr[0][3])
        @socket.connect(full_addr)
      rescue Errno::EISCONN => _
        # already connected
      rescue Errno::ETIMEDOUT => _
        raise ConnectionTimeoutError
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT => e
        raise ConnectionFailedError, "#{e.class} #{e.message}"
      end

    end
  end
end
