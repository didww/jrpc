require 'oj'
require 'forwardable'
module JRPC
  class BaseClient
    extend Forwardable

    attr_reader :uri, :options

    ID_CHARACTERS = (('a'..'z').to_a + ('0'..'9').to_a + ('A'..'Z').to_a).freeze
    REQUEST_TYPES = [:request, :notification].freeze

    def self.connect(uri, options)
      client = new(uri, options)
      yield(client)
    ensure
      client.close if client
    end

    def initialize(uri, options)
      @uri = uri
      @options = options
    end

    def method_missing(method, *params)
      invoke_request(method, *params)
    end

    def perform_request(method, params: nil, type: :request, read_timeout: nil, write_timeout: nil)
      validate_request(params, type)
      request = create_message(method.to_s, params)
      if type == :request
        id = generate_id
        request['id'] = id
        response = send_command serialize_request(request), read_timeout: read_timeout, write_timeout: write_timeout
        response = deserialize_response(response)

        validate_response(response, id)
        parse_error(response['error']) if response.has_key?('error')

        response['result']
      else
        send_notification serialize_request(request), write_timeout: write_timeout
        nil
      end
    end

    def invoke_request(method, *params)
      warn '[DEPRECATION] `invoke_request` is deprecated. Please use `perform_request` instead.'
      params = nil if params.empty?
      perform_request(method, params: params)
    end

    def invoke_notification(method, *params)
      warn '[DEPRECATION] `invoke_request` is deprecated. Please use `perform_request` instead.'
      params = nil if params.empty?
      perform_request(method, params: params, type: :notification)
    end

    private

    def serialize_request(request)
      Oj.dump(request, mode: :compat)
    end

    def deserialize_response(response)
      Oj.load(response)
    end

    def validate_response(response, id)
      raise ClientError, 'Wrong response structure' unless response.is_a?(Hash)
      raise ClientError, 'Wrong version' if response['jsonrpc'] != JRPC::JSON_RPC_VERSION
      if id != response['id']
        raise ClientError, "ID response mismatch. expected #{id.inspect} got #{response['id'].inspect}"
      end
    end

    def validate_request(params, type)
      raise ClientError, 'invalid type' unless REQUEST_TYPES.include?(type)
      raise ClientError, 'invalid params' if !params.nil? && !params.is_a?(Array) && !params.is_a?(Hash)
    end

    def parse_error(error)
      case error['code']
        when -32700
          raise ParseError.new(error['message'])
        when -32600
          raise InvalidRequest.new(error['message'])
        when -32601
          raise MethodNotFound.new(error['message'])
        when -32602
          raise InvalidParams.new(error['message'])
        when -32603
          raise InternalError.new(error['message'])
        when -32099..-32000
          raise InternalServerError.new(error['message'], error['code'])
        else
          raise UnknownError.new(error['message'], error['code'])
      end
    end

    def send_command(json, options={})
      raise NotImplementedError
    end

    def send_notification(json, options={})
      raise NotImplementedError
    end

    def generate_id
      size = ID_CHARACTERS.size
      (0...32).map { ID_CHARACTERS.to_a[rand(size)] }.join
    end

    def create_message(method, params)
      message = {
          'jsonrpc' => JSON_RPC_VERSION,
          'method' => method
      }
      message['params'] = params unless params.nil?
      message
    end
  end
end
