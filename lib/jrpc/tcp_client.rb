module JRPC
  class TcpClient < BaseClient
    attr_reader :hostname, :port, :namespace, :options

    def initialize(options = {})
      @hostname = options.delete(:hostname)
      @port = options.delete(:port)
      @namespace = options.delete(:namespace).to_s
      @options = options
      @socket = NetstringTcpSocket.new(@hostname, @port)
      @socket.set_timeout @options.fetch(:timeout, 5)
    end

    def close
      @socket.close
    end


    private

    def create_message(method, params)
      super("#{namespace}#{method}", params)
    end

    def send_request(request)
      @socket.send_string(request)
      @socket.receive_string
    end

    def send_notification(request)
      @socket.send_string(request)
    end

  end
end