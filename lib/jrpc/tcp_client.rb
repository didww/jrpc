require 'net/tcp_client'
require 'netstring'
module JRPC
  class TcpClient < BaseClient
    attr_reader :namespace
    def_delegators :@socket, :logger, :logger=, :close, :alive?

    def initialize(uri, options = {})
      super
      @namespace = options.delete(:namespace).to_s
      t = @options.fetch(:timeout, 5)

      @socket = Net::TCPClient.new server: @uri,
                                   connect_retry_count: t,
                                   connect_timeout: t,
                                   read_timeout: t,
                                   # write_timeout: t,
                                   buffered: false # recommended for RPC
    end

    private

    def send_command(request)
      send_request(request)
      receive_response
    end

    def send_notification(request)
      send_request(request)
    end

    def create_message(method, params)
      super("#{namespace}#{method}", params)
    end

    def send_request(request)
      @socket.send Netstring.dump(request.to_s), 0
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