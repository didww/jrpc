require 'json'

module JRPC
  module Message
    def self.build_request(method, params, id)
      validate_params!(method, params)
      envelope = { 'jsonrpc' => JRPC::JSON_RPC_VERSION, 'method' => method.to_s, 'id' => id }
      envelope['params'] = params unless params.nil?
      envelope
    end

    def self.build_notification(method, params)
      validate_params!(method, params)
      envelope = { 'jsonrpc' => JRPC::JSON_RPC_VERSION, 'method' => method.to_s }
      envelope['params'] = params unless params.nil?
      envelope
    end

    def self.dump(envelope)
      JSON.generate(envelope)
    end

    def self.parse(json_string)
      JSON.parse(json_string)
    rescue JSON::ParserError => e
      raise Errors::MalformedResponseError, "JSON parse error: #{e.message}"
    end

    def self.validate_response!(hash, expected_id)
      raise Errors::MalformedResponseError, 'response must be a Hash' unless hash.is_a?(Hash)
      raise Errors::MalformedResponseError, "jsonrpc must be #{JRPC::JSON_RPC_VERSION.inspect}" unless hash['jsonrpc'] == JRPC::JSON_RPC_VERSION
      unless hash['id'] == expected_id
        raise Errors::MalformedResponseError, "id mismatch: expected #{expected_id.inspect}, got #{hash['id'].inspect}"
      end

      has_result = hash.key?('result')
      has_error = hash.key?('error')
      unless has_result ^ has_error
        raise Errors::MalformedResponseError, "response must have exactly one of 'result' or 'error'"
      end

      if has_error
        err = hash['error']
        raise Errors::MalformedResponseError, "error must be a Hash" unless err.is_a?(Hash)
        raise Errors::MalformedResponseError, "error.code must be an Integer" unless err['code'].is_a?(Integer)
        raise Errors::MalformedResponseError, "error.message must be a String" unless err['message'].is_a?(String)
      end
    end

    def self.error_to_exception(error_hash)
      code = error_hash['code']
      message = error_hash['message']
      case code
      when -32700 then Errors::ParseError.new(message)
      when -32600 then Errors::InvalidRequest.new(message)
      when -32601 then Errors::MethodNotFound.new(message)
      when -32602 then Errors::InvalidParams.new(message)
      when -32603 then Errors::InternalError.new(message)
      when -32099..-32000 then Errors::InternalServerError.new(message, code: code)
      else Errors::UnknownError.new(message, code: code)
      end
    end

    def self.validate_params!(method, params)
      unless method.is_a?(String) || method.is_a?(Symbol)
        raise Errors::ClientError, 'method must be a String or Symbol'
      end
      raise Errors::ClientError, 'method must not be empty' if method.to_s.empty?
      unless params.nil? || params.is_a?(Array) || params.is_a?(Hash)
        raise Errors::ClientError, 'params must be nil, Array, or Hash'
      end
    end

    private_class_method :validate_params!
  end
end
