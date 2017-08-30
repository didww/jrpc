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

      timeout = @options.fetch(:timeout, 5)
      connect_timeout = @options.fetch(:connect_timeout, timeout)
      read_timeout = @options.fetch(:read_timeout, timeout)
      write_timeout = @options.fetch(:write_timeout, nil) # default 60
      connect_retry_count = @options.fetch(:connect_retry_count, nil) # default 10

      @transport = Net::TCPClient.new server: @uri,
                                   connect_retry_count: connect_retry_count,
                                   connect_timeout: connect_timeout,
                                   read_timeout: read_timeout,
                                   write_timeout: write_timeout,
                                   buffered: false # recommended for RPC
    rescue ::SocketError
      raise ConnectionError, "Can't connect to #{@uri}"
    end

    private

    def send_command(request, options={})
      read_timeout = options.fetch(:read_timeout)
      write_timeout = options.fetch(:write_timeout)
      response = nil
      t = Benchmark.realtime do
        logger.debug { "Request address: #{uri}" }
        logger.debug { "Request message: #{Utils.truncate(request, MAX_LOGGED_MESSAGE_LENGTH)}" }
        logger.debug { "Request read_timeout: #{read_timeout}" }
        logger.debug { "Request write_timeout: #{write_timeout}" }
        send_request(request, write_timeout)
        response = receive_response(read_timeout)
      end
      logger.debug do
        "(#{'%.2f' % (t * 1000)}ms) Response message: #{Utils.truncate(response, MAX_LOGGED_MESSAGE_LENGTH)}"
      end
      response
    end

    def send_notification(request, options={})
      write_timeout = options.fetch(:write_timeout)
      logger.debug { "Request address: #{uri}" }
      logger.debug { "Request message: #{Utils.truncate(request, MAX_LOGGED_MESSAGE_LENGTH)}" }
      logger.debug { "Request write_timeout: #{write_timeout}" }
      send_request(request, write_timeout)
      logger.debug { 'No response required' }
    end

    def create_message(method, params)
      super("#{namespace}#{method}", params)
    end

    def send_request(request, timeout)
      timeout ||= @transport.write_timeout
      @transport.write Netstring.dump(request.to_s), timeout
    rescue ::SocketError
      raise ConnectionError, "Can't send request to #{uri}"
    end

    def receive_response(timeout)
      timeout ||= @transport.read_timeout
      length = get_msg_length(timeout)
      response = @transport.read(length+1, nil, timeout)
      raise ClientError.new('invalid response. missed comma as terminator') if response[-1] != ','
      response.chomp(',')
    rescue ::SocketError
      raise ConnectionError, "Can't receive response from #{uri}"
    end

    def get_msg_length(timeout)
      length = ''
      while true do
        character = @transport.read(1, nil, timeout)
        break if character == ':'
        length += character
      end

      Integer(length)
    end

  end
end
