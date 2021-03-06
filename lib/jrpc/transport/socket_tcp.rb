module JRPC
  module Transport
    class SocketTcp < SocketBase

      # @raise [JRPC::ConnectionClosedError] if socket was closed during data read.
      def read(length, timeout = @read_timeout)
        received = ''
        length_to_read = length
        while length_to_read > 0
          io_read, = IO.select([socket], [], [], timeout)
          raise ReadTimeoutError unless io_read
          check_socket_state!
          chunk = io_read[0].read_nonblock(length_to_read)
          received += chunk
          length_to_read -= chunk.bytesize
        end
        received
      rescue Errno::EPIPE, EOFError => e
        # EPIPE, in this case, means that the data connection was unexpectedly terminated.
        close
        raise ReadFailedError, "#{e.class} #{e.message}"
      rescue => e
        close
        raise e
      end

      # @raise [JRPC::ConnectionClosedError] if socket was closed during data write.
      def write(data, timeout = @write_timeout)
        length_written = 0
        data_to_write = data
        while data_to_write.bytesize > 0
          _, io_write, = IO.select([], [socket], [], timeout)
          raise WriteTimeoutError unless io_write
          check_socket_state!
          chunk_length = io_write[0].write_nonblock(data_to_write)
          length_written += chunk_length
          data_to_write = data.byteslice(length_written, data.length)
        end
        length_written
      rescue Errno::EPIPE => e
        # EPIPE, in this case, means that the data connection was unexpectedly terminated.
        close
        raise WriteFailedError, "#{e.class} #{e.message}"
      rescue => e
        close
        raise e
      end

      # Socket implementation allows client to send data to server after FIN event,
      # but server will never receive this data.
      # So we consider socket closed when it have FIN event
      # and close it correctly from client side.
      def closed?
        return true if @socket.nil?

        if socket.closed? || fin_signal?
          close
          return true
        end

        false
      end

      # @raise [JRPC::ConnectionClosedError] if socket is closed or FIN event received.
      def check_socket_state!
        raise JRPC::ConnectionClosedError if closed?
      end

      def socket
        @socket ||= build_socket
      end

      # When socket is closed we need to cleanup internal @socket object,
      # because we will receive "IOError closed stream" if we try to reconnect via same socket.
      def close
        return if @socket.nil?
        @socket.close unless @socket.closed?
        @socket = nil
      end

      private

      # when recv_nonblock(1) responds with empty string means that FIN event was received.
      # in other cases it will return 1 byte string or raise EAGAINWaitReadable.
      # MSG_PEEK means we do not move pointer when reading data.
      # see https://apidock.com/ruby/BasicSocket/recv_nonblock
      def fin_signal?
        begin
          resp = socket.recv_nonblock(1, Socket::MSG_PEEK)
        rescue IO::EAGAINWaitReadable => _
          resp = nil
        end
        resp == ''
      end

      def set_timeout_to(socket, type, value)
        secs = Integer(value)
        u_secs = Integer((value - secs) * 1_000_000)
        opt_val = [secs, u_secs].pack('l_2')
        socket.setsockopt Socket::SOL_SOCKET, type, opt_val
      end

      def build_socket
        host = @server.split(':').first
        addr = Socket.getaddrinfo(host, nil)
        Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)
      end

      def connect_socket
        host, port = @server.split(':')
        addr = Socket.getaddrinfo(host, nil)
        full_addr = Socket.pack_sockaddr_in(port, addr[0][3])

        begin
          socket.connect_nonblock(full_addr)
        rescue IO::WaitWritable => _
          if IO.select(nil, [socket], nil, @connect_timeout)
            socket.connect_nonblock(full_addr)
          else
            close
            raise ConnectionFailedError, "Can't connect during #{@connect_timeout}"
          end
        end

      rescue Errno::EISCONN => _
        # already connected
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::EPIPE => e
        close
        raise ConnectionFailedError, "#{e.class} #{e.message}"
      rescue => e
        close
        raise e
      end

    end
  end
end
