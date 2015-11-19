module JRPC
  class ParseError < ServerError

    def initialize(message)
      super(message, -32700)
    end

  end
end
