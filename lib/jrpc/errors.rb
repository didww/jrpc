# frozen_string_literal: true

module JRPC
  module Errors
    class Error < RuntimeError; end

    class ClientError < Error; end

    class ConnectionError < Error
    end

    class Timeout < Error; end

    class ServerError < Error
      attr_reader :code

      def initialize(message, code: nil)
        @code = code
        super(message)
      end
    end

    class MalformedResponseError < ServerError
      def initialize(message)
        super(message, code: nil)
      end
    end

    class ParseError < ServerError
      def initialize(message)
        super(message, code: -32_700)
      end
    end

    class InvalidRequest < ServerError
      def initialize(message)
        super(message, code: -32_600)
      end
    end

    class MethodNotFound < ServerError
      def initialize(message)
        super(message, code: -32_601)
      end
    end

    class InvalidParams < ServerError
      def initialize(message)
        super(message, code: -32_602)
      end
    end

    class InternalError < ServerError
      def initialize(message)
        super(message, code: -32_603)
      end
    end

    class InternalServerError < ServerError
    end

    class UnknownError < ServerError
    end
  end
end
