module JRPC
  class InvalidRequest < ServerError

    def initialize(message)
      super(message, -32600)
    end

  end
end
