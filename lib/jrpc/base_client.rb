require 'json'
module JRPC
  class BaseClient

    def method_missing(method, *params)
      invoke_request(method, *params)
    end

    def invoke_request(method, *params)
      request = create_message(method, params)
      request['id'] = generate_id

      response = send_request request.to_json
      response = JSON.parse response

      validate_response!(response, request['id'])

      response['result']
    end

    def invoke_notification(method, *params)
      send_notification create_message(method, params).to_json
      nil
    end

    private

    def validate_response!(response, id)
      raise Error.new('id mismatch') unless id && response['id'] == id
      raise Error.new('error') unless response && response['error'].nil?
    end

    def send_request(json)
      raise 'implement me'
    end

    def send_notification(json)
      raise 'implement me'
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
