RSpec.describe JRPC::Message do
  describe '.build_request' do
    it 'builds a request envelope with array params' do
      env = JRPC::Message.build_request('sum', [1, 2], 'req-1')
      expect(env).to eq('jsonrpc' => '2.0', 'method' => 'sum', 'params' => [1, 2], 'id' => 'req-1')
    end

    it 'builds a request envelope with hash params' do
      env = JRPC::Message.build_request('ping', { timeout: 5 }, 'req-2')
      expect(env).to eq('jsonrpc' => '2.0', 'method' => 'ping', 'params' => { timeout: 5 }, 'id' => 'req-2')
    end

    it 'omits params key when params is nil' do
      env = JRPC::Message.build_request('ping', nil, 'req-3')
      expect(env).to eq('jsonrpc' => '2.0', 'method' => 'ping', 'id' => 'req-3')
      expect(env).not_to have_key('params')
    end

    it 'accepts symbol method name and stringifies it' do
      env = JRPC::Message.build_request(:sum, nil, 'x')
      expect(env['method']).to eq('sum')
    end

    it 'raises ClientError for non-string/symbol method' do
      expect { JRPC::Message.build_request(42, nil, 'x') }
        .to raise_error(JRPC::Errors::ClientError, /method must be a String or Symbol/)
    end

    it 'raises ClientError for empty method' do
      expect { JRPC::Message.build_request('', nil, 'x') }
        .to raise_error(JRPC::Errors::ClientError, /must not be empty/)
    end

    it 'raises ClientError for invalid params type' do
      expect { JRPC::Message.build_request('foo', 42, 'x') }
        .to raise_error(JRPC::Errors::ClientError, /params must be nil, Array, or Hash/)
    end
  end

  describe '.build_notification' do
    it 'builds notification without id' do
      env = JRPC::Message.build_notification('log', ['msg'])
      expect(env).to eq('jsonrpc' => '2.0', 'method' => 'log', 'params' => ['msg'])
      expect(env).not_to have_key('id')
    end

    it 'omits params when nil' do
      env = JRPC::Message.build_notification('ping', nil)
      expect(env).not_to have_key('params')
    end

    it 'raises ClientError for invalid method' do
      expect { JRPC::Message.build_notification(nil, nil) }
        .to raise_error(JRPC::Errors::ClientError)
    end
  end

  describe '.dump' do
    it 'serializes to JSON' do
      env  = { 'jsonrpc' => '2.0', 'method' => 'ping', 'id' => '1' }
      json = JRPC::Message.dump(env)
      expect(JSON.parse(json)).to eq(env)
    end
  end

  describe '.parse' do
    it 'parses valid JSON' do
      json = '{"jsonrpc":"2.0","result":1,"id":"1"}'
      expect(JRPC::Message.parse(json)).to eq('jsonrpc' => '2.0', 'result' => 1, 'id' => '1')
    end

    it 'raises MalformedResponseError on invalid JSON' do
      expect { JRPC::Message.parse('{bad json') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /JSON parse error/)
    end
  end

  describe '.validate_response!' do
    def valid_response(overrides = {})
      { 'jsonrpc' => '2.0', 'result' => 42, 'id' => 'req-1' }.merge(overrides)
    end

    it 'passes on a valid success response' do
      expect { JRPC::Message.validate_response!(valid_response, 'req-1') }.not_to raise_error
    end

    it 'passes on a valid error response' do
      resp = { 'jsonrpc' => '2.0', 'error' => { 'code' => -32601, 'message' => 'not found' }, 'id' => 'req-1' }
      expect { JRPC::Message.validate_response!(resp, 'req-1') }.not_to raise_error
    end

    it 'raises when not a Hash' do
      expect { JRPC::Message.validate_response!('string', 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /must be a Hash/)
    end

    it 'raises when jsonrpc is wrong' do
      expect { JRPC::Message.validate_response!(valid_response('jsonrpc' => '1.0'), 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /jsonrpc/)
    end

    it 'raises on id mismatch' do
      expect { JRPC::Message.validate_response!(valid_response, 'other-id') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /id mismatch/)
    end

    it 'raises when both result and error present' do
      resp = valid_response('error' => { 'code' => -1, 'message' => 'e' })
      expect { JRPC::Message.validate_response!(resp, 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /exactly one/)
    end

    it 'raises when neither result nor error present' do
      resp = { 'jsonrpc' => '2.0', 'id' => 'req-1' }
      expect { JRPC::Message.validate_response!(resp, 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /exactly one/)
    end

    it 'raises when error is not a Hash' do
      resp = { 'jsonrpc' => '2.0', 'error' => 'bad', 'id' => 'req-1' }
      expect { JRPC::Message.validate_response!(resp, 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /must be a Hash/)
    end

    it 'raises when error.code is not an Integer' do
      resp = { 'jsonrpc' => '2.0', 'error' => { 'code' => '-32601', 'message' => 'e' }, 'id' => 'req-1' }
      expect { JRPC::Message.validate_response!(resp, 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /code must be an Integer/)
    end

    it 'raises when error.message is not a String' do
      resp = { 'jsonrpc' => '2.0', 'error' => { 'code' => -32601, 'message' => 42 }, 'id' => 'req-1' }
      expect { JRPC::Message.validate_response!(resp, 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /message must be a String/)
    end

    it 'does not coerce id types (string != integer)' do
      resp = valid_response('id' => 1)   # integer id, but expected_id is string 'req-1'
      expect { JRPC::Message.validate_response!(resp, 'req-1') }
        .to raise_error(JRPC::Errors::MalformedResponseError, /id mismatch/)
    end
  end

  describe '.error_to_exception' do
    {
      -32700 => JRPC::Errors::ParseError,
      -32600 => JRPC::Errors::InvalidRequest,
      -32601 => JRPC::Errors::MethodNotFound,
      -32602 => JRPC::Errors::InvalidParams,
      -32603 => JRPC::Errors::InternalError,
      -32099 => JRPC::Errors::InternalServerError,
      -32050 => JRPC::Errors::InternalServerError,
      -32000 => JRPC::Errors::InternalServerError,
      -31999 => JRPC::Errors::UnknownError,
      0      => JRPC::Errors::UnknownError,
      99     => JRPC::Errors::UnknownError,
    }.each do |code, expected_class|
      it "maps code #{code} to #{expected_class.name.split('::').last}" do
        err = JRPC::Message.error_to_exception('code' => code, 'message' => 'msg')
        expect(err).to be_a(expected_class)
        expect(err.code).to eq(code)
        expect(err.message).to eq('msg')
      end
    end
  end
end
