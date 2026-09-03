# frozen_string_literal: true

module JRPC
  module Errors
    class Error < RuntimeError; end

    class ClientError < Error; end

    class ConnectionError < Error
    end

    class Timeout < Error; end

    # A JSON-RPC error object the peer sent back, carrying its `code` and its optional
    # `data` member verbatim. Per the spec `data` is "a primitive or structured value"
    # defined by the server, so it arrives as whatever JSON.parse produced — String,
    # Hash, Array, Numeric — or nil when the peer omitted it.
    class ServerError < Error
      attr_reader :code, :data

      def initialize(message, code: nil, data: nil)
        @code = code
        @data = data
        super(message)
      end
    end

    # Raised locally when a frame is unparseable or violates the envelope rules, so it
    # never corresponds to a peer error object: no code, no data.
    class MalformedResponseError < ServerError
      def initialize(message)
        super(message, code: nil)
      end
    end

    class ParseError < ServerError
      def initialize(message, data: nil)
        super(message, code: -32_700, data: data)
      end
    end

    class InvalidRequest < ServerError
      def initialize(message, data: nil)
        super(message, code: -32_600, data: data)
      end
    end

    class MethodNotFound < ServerError
      def initialize(message, data: nil)
        super(message, code: -32_601, data: data)
      end
    end

    class InvalidParams < ServerError
      def initialize(message, data: nil)
        super(message, code: -32_602, data: data)
      end
    end

    class InternalError < ServerError
      def initialize(message, data: nil)
        super(message, code: -32_603, data: data)
      end
    end

    class InternalServerError < ServerError
    end

    class UnknownError < ServerError
    end
  end
end
