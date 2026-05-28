RSpec.describe JRPC::SimpleClient do
  # Minimal transport double that records activity and lets tests configure outcomes.
  class TransportDouble
    attr_reader :connects, :closes, :frames_written

    def initialize
      @closed         = true
      @connects       = 0
      @closes         = 0
      @frames_written = []
      @read_queue     = []
      @connect_error  = nil
      @write_error    = nil
      @read_error     = nil
    end

    def closed?
      @closed
    end

    def connect
      raise @connect_error if @connect_error
      @connects += 1
      @closed = false
    end

    def write_frame(bytes, timeout:)
      raise @write_error if @write_error
      @frames_written << bytes
    end

    def read_frame(timeout:)
      raise @read_error if @read_error
      @read_queue.shift
    end

    def close
      @closes += 1
      @closed = true
    end

    # helpers for test setup
    def queue_response(json)  = @read_queue << json
    def fail_on_connect(err)  = (@connect_error = err)
    def fail_on_write(err)    = (@write_error = err)
    def fail_on_read(err)     = (@read_error = err)
  end

  let(:transport) { TransportDouble.new }

  # id_prefix: 'test' gives predictable ids: 'test-1', 'test-2', …
  let(:client) { JRPC::SimpleClient.new("127.0.0.1:1234", transport: transport, id_prefix: 'test') }

  def ok_response(id, result)
    JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'result' => result })
  end

  def error_response(id, code, message)
    JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } })
  end

  # ── lazy connect ───────────────────────────────────────────────────────────

  describe 'lazy connect' do
    it 'does not connect on construction' do
      expect(transport.connects).to eq(0)
      expect(transport.closed?).to be true
    end

    it 'connects on first request' do
      transport.queue_response(ok_response('test-1', 42))
      client.request('ping')
      expect(transport.connects).to eq(1)
    end

    it 'connects on first notification' do
      client.notification('log')
      expect(transport.connects).to eq(1)
    end

    it 'does not reconnect when already connected' do
      transport.queue_response(ok_response('test-1', 1))
      transport.queue_response(ok_response('test-2', 2))
      client.request('a')
      client.request('b')
      expect(transport.connects).to eq(1)
    end
  end

  # ── #request ──────────────────────────────────────────────────────────────

  describe '#request' do
    it 'returns the result' do
      transport.queue_response(ok_response('test-1', 99))
      expect(client.request('sum')).to eq(99)
    end

    it 'sends the correct JSON-RPC frame' do
      transport.queue_response(ok_response('test-1', nil))
      client.request('sum', [1, 2])
      sent = JSON.parse(transport.frames_written.last)
      expect(sent).to eq('jsonrpc' => '2.0', 'method' => 'sum', 'params' => [1, 2], 'id' => 'test-1')
    end

    it 'works with hash params' do
      transport.queue_response(ok_response('test-1', 'ok'))
      client.request('foo', { a: 1 })
      sent = JSON.parse(transport.frames_written.last)
      expect(sent['params']).to eq('a' => 1)
    end

    it 'omits params key when params is nil' do
      transport.queue_response(ok_response('test-1', true))
      client.request('ping')
      sent = JSON.parse(transport.frames_written.last)
      expect(sent).not_to have_key('params')
    end

    it 'accepts symbol method name' do
      transport.queue_response(ok_response('test-1', 0))
      client.request(:sum, [1])
      sent = JSON.parse(transport.frames_written.last)
      expect(sent['method']).to eq('sum')
    end

    it 'increments the id on each call' do
      transport.queue_response(ok_response('test-1', 1))
      transport.queue_response(ok_response('test-2', 2))
      client.request('a')
      client.request('b')
      ids = transport.frames_written.map { |f| JSON.parse(f)['id'] }
      expect(ids).to eq(['test-1', 'test-2'])
    end

    it 'raises ClientError for non-string/symbol method' do
      expect { client.request(42) }.to raise_error(JRPC::Errors::ClientError)
    end

    it 'raises ClientError for empty method' do
      expect { client.request('') }.to raise_error(JRPC::Errors::ClientError)
    end

    it 'raises ClientError for invalid params type' do
      expect { client.request('foo', 42) }.to raise_error(JRPC::Errors::ClientError)
    end

    it 'raises ClientError when client is closed' do
      client.close
      expect { client.request('ping') }.to raise_error(JRPC::Errors::ClientError, /client closed/)
    end
  end

  # ── #notification ──────────────────────────────────────────────────────────

  describe '#notification' do
    it 'returns nil' do
      expect(client.notification('log')).to be_nil
    end

    it 'sends the correct JSON-RPC frame without id' do
      client.notification('log', ['msg'])
      sent = JSON.parse(transport.frames_written.last)
      expect(sent).to eq('jsonrpc' => '2.0', 'method' => 'log', 'params' => ['msg'])
      expect(sent).not_to have_key('id')
    end

    it 'omits params when nil' do
      client.notification('ping')
      sent = JSON.parse(transport.frames_written.last)
      expect(sent).not_to have_key('params')
    end

    it 'raises ClientError for bad method' do
      expect { client.notification(nil) }.to raise_error(JRPC::Errors::ClientError)
    end

    it 'raises ClientError when client is closed' do
      client.close
      expect { client.notification('log') }.to raise_error(JRPC::Errors::ClientError, /client closed/)
    end
  end

  # ── autoclose ──────────────────────────────────────────────────────────────

  describe 'autoclose: true' do
    let(:client) { JRPC::SimpleClient.new("127.0.0.1:1234", transport: transport, id_prefix: 'test', autoclose: true) }

    it 'closes the transport after each request' do
      transport.queue_response(ok_response('test-1', 1))
      client.request('ping')
      expect(transport.closes).to eq(1)
      expect(transport.closed?).to be true
    end

    it 'closes the transport after each notification' do
      client.notification('log')
      expect(transport.closes).to eq(1)
      expect(transport.closed?).to be true
    end

    it 'client is still usable (reconnects on next call)' do
      transport.queue_response(ok_response('test-1', 1))
      transport.queue_response(ok_response('test-2', 2))
      client.request('a')
      client.request('b')
      expect(transport.connects).to eq(2)
      expect(transport.closes).to eq(2)
    end

    it 'closes the transport even when request raises' do
      transport.fail_on_read(JRPC::Transport::Base::ConnectionError.new('gone'))
      expect { client.request('ping') }.to raise_error(JRPC::Errors::ConnectionError)
      expect(transport.closes).to eq(1)
    end
  end

  describe 'autoclose: false (default)' do
    it 'does not close the transport after a request' do
      transport.queue_response(ok_response('test-1', 1))
      client.request('ping')
      expect(transport.closes).to eq(0)
    end

    it 'does not close the transport after a notification' do
      client.notification('log')
      expect(transport.closes).to eq(0)
    end
  end

  # ── #close and #closed? ────────────────────────────────────────────────────

  describe '#close' do
    it 'returns true' do
      expect(client.close).to be true
    end

    it 'sets closed? to true' do
      client.close
      expect(client.closed?).to be true
    end

    it 'is idempotent — second call returns true without error' do
      client.close
      expect(client.close).to be true
    end

    it 'closes the transport' do
      client.close
      expect(transport.closes).to eq(1)
    end

    it 'does not close the transport a second time on second call' do
      client.close
      client.close
      expect(transport.closes).to eq(1)
    end
  end

  describe '#closed?' do
    it 'is false before close' do
      expect(client.closed?).to be false
    end

    it 'is true after close' do
      client.close
      expect(client.closed?).to be true
    end
  end

  # ── per-call timeout overrides ─────────────────────────────────────────────

  describe 'per-call timeout overrides' do
    it 'passes read_timeout override to transport.read_frame' do
      allow(transport).to receive(:read_frame).with(timeout: 99).and_return(ok_response('test-1', 1))
      client.request('ping', nil, read_timeout: 99)
    end

    it 'passes write_timeout override to transport.write_frame' do
      transport.queue_response(ok_response('test-1', 1))
      allow(transport).to receive(:write_frame).with(anything, timeout: 77)
      client.request('ping', nil, write_timeout: 77)
    end

    it 'passes write_timeout override to transport.write_frame for notifications' do
      allow(transport).to receive(:write_frame).with(anything, timeout: 55)
      client.notification('log', nil, write_timeout: 55)
    end
  end

  # ── error translation ──────────────────────────────────────────────────────

  describe 'error translation' do
    context 'connect failure' do
      it 'translates Transport::Base::ConnectionError to Errors::ConnectionError' do
        transport.fail_on_connect(JRPC::Transport::Base::ConnectionError.new('refused'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::ConnectionError, /refused/)
      end

      it 'translates Transport::Base::Timeout to Errors::Timeout' do
        transport.fail_on_connect(JRPC::Transport::Base::Timeout.new('timed out'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::Timeout, /timed out/)
      end
    end

    context 'write failure' do
      it 'translates Transport::Base::ConnectionError to Errors::ConnectionError' do
        transport.fail_on_write(JRPC::Transport::Base::ConnectionError.new('broken pipe'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::ConnectionError, /broken pipe/)
      end

      it 'translates Transport::Base::Timeout to Errors::Timeout' do
        transport.fail_on_write(JRPC::Transport::Base::Timeout.new('write timeout'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::Timeout, /write timeout/)
      end

      it 'translates write Timeout for notifications' do
        transport.fail_on_write(JRPC::Transport::Base::Timeout.new('write timeout'))
        expect { client.notification('log') }.to raise_error(JRPC::Errors::Timeout)
      end
    end

    context 'read failure' do
      it 'translates Transport::Base::ConnectionError to Errors::ConnectionError' do
        transport.fail_on_read(JRPC::Transport::Base::ConnectionError.new('eof'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::ConnectionError, /eof/)
      end

      it 'translates Transport::Base::Timeout to Errors::Timeout' do
        transport.fail_on_read(JRPC::Transport::Base::Timeout.new('read timeout'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::Timeout, /read timeout/)
      end

      it 'translates Transport::Base::MalformedFrame to Errors::MalformedResponseError' do
        transport.fail_on_read(JRPC::Transport::Base::MalformedFrame.new('bad frame'))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::MalformedResponseError)
      end
    end

    context 'Errors::ConnectionError wraps cause' do
      it 'sets cause on the translated error' do
        orig = JRPC::Transport::Base::ConnectionError.new('refused')
        transport.fail_on_connect(orig)
        err = nil
        begin
          client.request('ping')
        rescue JRPC::Errors::ConnectionError => e
          err = e
        end
        expect(err.cause).to be(orig)
      end
    end

    context 'server-returned errors' do
      {
        -32700 => JRPC::Errors::ParseError,
        -32601 => JRPC::Errors::MethodNotFound,
        -32602 => JRPC::Errors::InvalidParams,
        0      => JRPC::Errors::UnknownError
      }.each do |code, klass|
        it "raises #{klass.name.split('::').last} for error code #{code}" do
          transport.queue_response(error_response('test-1', code, 'err'))
          expect { client.request('ping') }.to raise_error(klass)
        end
      end
    end

    context 'malformed server response' do
      it 'raises MalformedResponseError for invalid JSON' do
        transport.queue_response('not json{{{')
        expect { client.request('ping') }.to raise_error(JRPC::Errors::MalformedResponseError)
      end

      it 'raises MalformedResponseError for wrong jsonrpc version' do
        transport.queue_response(JSON.generate({ 'jsonrpc' => '1.0', 'result' => 1, 'id' => 'test-1' }))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::MalformedResponseError)
      end

      it 'raises MalformedResponseError for id mismatch' do
        transport.queue_response(ok_response('wrong-id', 1))
        expect { client.request('ping') }.to raise_error(JRPC::Errors::MalformedResponseError, /id mismatch/)
      end
    end
  end
end
