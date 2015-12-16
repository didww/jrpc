require 'net/tcp_client'
require 'netstring'
require 'logger'
require 'benchmark'
module JRPC
  class TcpClient < BaseClient
    attr_reader :namespace, :transport
    attr_accessor :logger
    def_delegators :@transport, :close, :closed?, :connect

    MAX_LOGGED_MESSAGE_LENGTH = 255

    def initialize(uri, options = {})
      super
      @logger = @options.delete(:logger) || Logger.new($null)
      @namespace = @options.delete(:namespace).to_s
      t = @options.fetch(:timeout, 5)

      @transport = Net::TCPClient.new server: @uri,
                                   connect_retry_count: t,
                                   connect_timeout: t,
                                   read_timeout: t, # write_timeout: t,
                                   buffered: false # recommended for RPC
    rescue ::SocketError
      raise ConnectionError, "Can't connect to #{@uri}"
    end

    private

    def send_command(request)
      response = nil
      t = Benchmark.realtime do
        logger.debug "Request address: #{uri}"
        logger.debug "Request message: #{Utils.truncate(request, MAX_LOGGED_MESSAGE_LENGTH)}"
        send_request(request)
        response = receive_response
      end
      logger.debug "(#{'%.2f' % (t * 1000)}ms) Response message: #{Utils.truncate(response, MAX_LOGGED_MESSAGE_LENGTH)}"
      response
    end

    def send_notification(request)
      logger.debug "Request address: #{uri}"
      logger.debug "Request message: #{Utils.truncate(request, MAX_LOGGED_MESSAGE_LENGTH)}"
      send_request(request)
      logger.debug 'No response required'
    end

    def create_message(method, params)
      super("#{namespace}#{method}", params)
    end

    def send_request(request)
      @transport.write Netstring.dump(request.to_s)
    rescue ::SocketError
      raise ConnectionError, "Can't send request to #{uri}"
    end

    def receive_response
      length = get_msg_length
      response = @transport.read(length+1)
      raise ClientError.new('invalid response. missed comma as terminator') if response[-1] != ','
      response.chomp(',')
    rescue ::SocketError
      raise ConnectionError, "Can't receive response from #{uri}"
    end

    def get_msg_length
      length = ''
      while true do
        character = @transport.read(1)
        break if character == ':'
        length += character
      end

      Integer(length)
    end

  end
end