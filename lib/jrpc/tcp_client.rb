require 'net/tcp_client'
require 'netstring'
module JRPC
  class TcpClient < BaseClient
    attr_reader :namespace
    def_delegators :@client, :logger, :logger=, :close, :closed?

    def initialize(uri, options = {})
      super
      @namespace = @options.delete(:namespace).to_s
      t = @options.fetch(:timeout, 5)

      @client = Net::TCPClient.new server: @uri,
                                   connect_retry_count: t,
                                   connect_timeout: t,
                                   read_timeout: t, # write_timeout: t,
                                   buffered: false, # recommended for RPC
                                   logger: @options.delete(:logger)
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
      @client.write Netstring.dump(request.to_s)
    end

    def receive_response
      length = get_msg_length
      response = @client.read(length+1)
      raise ClientError.new('invalid response. missed comma as terminator') if response[-1] != ','
      response.chomp(',')
    end

    def get_msg_length
      length = ''
      while true do
        character = @client.read(1)
        break if character == ':'
        length += character
      end

      Integer(length)
    end

  end
end