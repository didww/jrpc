RSpec.describe JRPC::Errors do
  describe 'hierarchy' do
    it 'Error is a RuntimeError' do
      expect(JRPC::Errors::Error.ancestors).to include(RuntimeError)
    end

    it 'ClientError < Error' do
      expect(JRPC::Errors::ClientError.ancestors).to include(JRPC::Errors::Error)
    end

    it 'ConnectionError < Error' do
      expect(JRPC::Errors::ConnectionError.ancestors).to include(JRPC::Errors::Error)
    end

    it 'Timeout < Error' do
      expect(JRPC::Errors::Timeout.ancestors).to include(JRPC::Errors::Error)
    end

    it 'ServerError < Error' do
      expect(JRPC::Errors::ServerError.ancestors).to include(JRPC::Errors::Error)
    end

    it 'MalformedResponseError < ServerError' do
      expect(JRPC::Errors::MalformedResponseError.ancestors).to include(JRPC::Errors::ServerError)
    end

    %w[ParseError InvalidRequest MethodNotFound InvalidParams InternalError
       InternalServerError UnknownError].each do |name|
      it "#{name} < ServerError" do
        klass = JRPC::Errors.const_get(name)
        expect(klass.ancestors).to include(JRPC::Errors::ServerError)
      end
    end

    it 'ClientError, ConnectionError, Timeout, ServerError are siblings (no cross-inheritance)' do
      tops = [JRPC::Errors::ClientError, JRPC::Errors::ConnectionError,
              JRPC::Errors::Timeout, JRPC::Errors::ServerError]
      tops.combination(2).each do |a, b|
        expect(a.ancestors).not_to include(b)
        expect(b.ancestors).not_to include(a)
      end
    end
  end

  describe JRPC::Errors::ConnectionError do
    it 'stores cause' do
      original = RuntimeError.new('boom')
      begin
        begin
          raise original
        rescue => _
          raise JRPC::Errors::ConnectionError.new('connection lost')
        end
      rescue => e
        err = e
      end
      expect(err.message).to eq('connection lost')
      expect(err.cause).to equal(original)
    end

    it 'cause defaults to nil' do
      err = JRPC::Errors::ConnectionError.new('oops')
      expect(err.cause).to be_nil
    end
  end

  describe JRPC::Errors::ServerError do
    it 'stores code' do
      err = JRPC::Errors::ServerError.new('bad', code: -99)
      expect(err.code).to eq(-99)
    end

    it 'code defaults to nil' do
      err = JRPC::Errors::ServerError.new('bad')
      expect(err.code).to be_nil
    end
  end

  describe 'fixed-code server errors' do
    {
      ParseError: -32700,
      InvalidRequest: -32600,
      MethodNotFound: -32601,
      InvalidParams: -32602,
      InternalError: -32603,
    }.each do |name, expected_code|
      it "#{name} has code #{expected_code}" do
        err = JRPC::Errors.const_get(name).new('msg')
        expect(err.code).to eq(expected_code)
      end
    end
  end

  describe JRPC::Errors::InternalServerError do
    it 'stores the provided code' do
      err = JRPC::Errors::InternalServerError.new('oops', code: -32050)
      expect(err.code).to eq(-32050)
    end
  end

  describe JRPC::Errors::UnknownError do
    it 'stores the provided code' do
      err = JRPC::Errors::UnknownError.new('what', code: 42)
      expect(err.code).to eq(42)
    end
  end

  describe JRPC::Errors::MalformedResponseError do
    it 'code is nil' do
      err = JRPC::Errors::MalformedResponseError.new('bad frame')
      expect(err.code).to be_nil
    end
  end
end
