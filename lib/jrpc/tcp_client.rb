require 'net/tcp_client'
require 'netstring'
module JRPC
  class TcpClient < BaseClient
    attr_reader :namespace
    def_delegators :@socket, :logger, :logger=

    def initialize(uri, options = {})
      super
      @namespace = options.delete(:namespace).to_s
      connect if options.fetch(:connect_on_initialize, true)
    end

    def connect
      close if alive?
      @socket = Net::TCPClient.new(connection_params)
    end

    def close
      unless @socket.nil?
        @socket.close
        @socket = nil
      end
    end

    def alive?
      if @socket.nil?
        false
      else
        @socket.alive?
      end
    end

    private

    def connection_params
      t = options.fetch(:timeout, 5)
      {server: uri, connect_retry_count: t, connect_timeout: t, read_timeout: t, buffered: false}
    end

    def send_command(request)
      connect unless alive?
      send_request(request)
      receive_response
    end

    def send_notification(request)
      connect unless alive?
      send_request(request)
    end

    def create_message(method, params)
      super("#{namespace}#{method}", params)
    end

    def send_request(request)
      @socket.write Netstring.dump(request.to_s)
    end

    def receive_response
      length = get_msg_length
      response = @socket.read(length+1)
      raise ClientError.new('invalid response. missed comma as terminator') if response[-1] != ','
      response.chomp(',')
    end

    def get_msg_length
      length = ''
      while true do
        character = @socket.read(1)
        break if character == ':'
        length += character
      end

      Integer(length)
    end

  end
end
