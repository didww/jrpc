module JRPC
  class InternalError < ServerError

    def initialize(message)
      super(message, -32603)
    end

  end
end
