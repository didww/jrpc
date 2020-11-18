module JRPC
  class ConnectionClosedError < Error
    def initialize
      super('socket was closed unexpectedly')
    end
  end
end
