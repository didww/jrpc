require 'json'
module JRPC
  class BaseClient

    def method_missing(method, *params)
      invoke_request(method, *params)
    end

    def invoke_request(method, *params)
      request = create_message(method, params)
      id = generate_id
      request['id'] = id

      response = send_request request.to_json
      response = JSON.parse response

      validate_response(response, id)
      parse_error(response['error']) if response.has_key?('error')

      response['result']
    end

    def invoke_notification(method, *params)
      send_notification create_message(method, params).to_json
      nil
    end

    private

    def validate_response(response, id)
      raise ClientError.new('Wrong response structure') unless response.is_a?(Hash)
      raise ClientError.new('Wrong version') if response['jsonrpc'] != JRPC::JSON_RPC_VERSION
      raise ClientError.new("ID response mismatch. expected #{id.inspect} got #{response['id'].inspect}") if id != response['id']
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

    def send_request(json)
      raise NotImplementedError
    end

    def send_notification(json)
      raise NotImplementedError
    end

    def generate_id
      (0...10).map { ('a'..'z').to_a[rand(26)] }.join
    end

    def create_message(method, params)
      message = {
          'jsonrpc' => JSON_RPC_VERSION,
          'method' => method
      }
      message['params'] = params unless params.empty?
      message
    end
  end
end
