module JRPC
  module Transport
    class SocketBase

      class Error < ::JRPC::Error
      end

      class TimeoutError < Error
        def initialize
          super(self.class.to_s.split('::').last)
        end
      end

      class ReadTimeoutError < TimeoutError
      end

      class WriteTimeoutError < TimeoutError
      end

      class ConnectionTimeoutError < TimeoutError
      end

      class ConnectionFailedError < Error
      end

      class WriteFailedError < Error
      end

      class ReadFailedError < Error
      end

      attr_reader :options, :read_timeout, :write_timeout

      def self.connect(options)
        connection = new(options)
        yield(connection)
      ensure
        connection.close if connection
      end

      def initialize(options)
        @server = options.fetch(:server)
        @read_timeout = options.fetch(:read_timeout, nil)
        @write_timeout = options.fetch(:write_timeout, nil)
        @connect_timeout = options.fetch(:connect_timeout, nil)
        @connect_retry_count = options.fetch(:connect_retry_count, 0)
        @options = options
      end

      def connect
        retries = @connect_retry_count

        while retries >= 0
          begin
            connect_socket
            break
          rescue Error => e
            retries -= 1
            raise e if retries < 0
          end
        end
      end

      def read(_length, _timeout = @read_timeout)
        raise NotImplementedError
      end

      def write(_data, _timeout = @write_timeout)
        raise NotImplementedError
      end

      def close
        raise NotImplementedError
      end

      def closed?
        raise NotImplementedError
      end

      private

      def connect_socket
        raise NotImplementedError
      end

    end
  end
end
