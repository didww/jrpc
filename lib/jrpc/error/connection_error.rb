module JRPC
  class ConnectionError < Error
    attr_reader :original

    def initialize(msg, original=$!)
      super(msg)
      @original = original
    end

  end
end
