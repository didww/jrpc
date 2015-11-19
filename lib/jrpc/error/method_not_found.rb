module JRPC
  class MethodNotFound < ServerError

    def initialize(message)
      super(message, -32601)
    end

  end
end
