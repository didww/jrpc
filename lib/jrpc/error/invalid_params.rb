module JRPC
  class InvalidParams < ServerError

    def initialize(message)
      super(message, -32602)
    end

  end
end
