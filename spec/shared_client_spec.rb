require 'socket'

RSpec.describe JRPC::SharedClient do
  # Fake transport backed by a UNIXSocket pair.
  # socket_a is exposed as transport.socket — it is BOTH readable (when socket_b writes)
  # AND writable (send buffer not full), so IO.select works correctly for both read and write.
  # try_read_frame pulls from an in-memory queue; inject_response writes one byte to socket_b
  # to wake IO.select, then try_read_frame pops the frame and drains the wakeup byte.
  class FakeSharedTransport
    attr_reader :frames_written, :connects, :closes

    def initialize
      @closed = true
      @frames_written = []
      @connects = 0
      @closes = 0
      @response_mutex = Mutex.new
      @response_queue = []
      @socket_a, @socket_b = UNIXSocket.pair
      @connect_error = nil
      @write_error = nil
    end

    def connect
      raise @connect_error if @connect_error
      @connects += 1
      @closed = false
    end

    def closed?; @closed; end

    def socket; @closed ? nil : @socket_a; end

    def write_frame(bytes, timeout:)
      raise @write_error if @write_error
      @frames_written << bytes
    end

    def try_read_frame
      result = @response_mutex.synchronize { @response_queue.shift }
      if result
        result
      else
        # drain wakeup bytes written by inject_response / close
        begin
          loop { @socket_a.read_nonblock(1024) }
        rescue IO::EAGAINWaitReadable, IO::WaitReadable, IOError
        end
        :wait
      end
    end

    def close
      @closes += 1
      @closed = true
      # write a byte to socket_b to make socket_a readable, waking IO.select
      @socket_b.write_nonblock('.') rescue nil
    end

    # ── test helpers ──────────────────────────────────────────────────────────
    def inject_response(json)
      @response_mutex.synchronize { @response_queue << json }
      @socket_b.write_nonblock('.') rescue nil
    end

    def fail_on_connect(err); @connect_error = err; end
    def fail_on_write(err);   @write_error   = err; end
  end

  def ok_response(id, result)
    JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'result' => result })
  end

  def error_response(id, code, message)
    JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } })
  end

  # Polls until block returns truthy or timeout expires.
  def wait_for(timeout: 1.0, interval: 0.005)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      raise "wait_for timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep interval
    end
  end

  let(:transport) { FakeSharedTransport.new }

  def build_client(**opts)
    defaults = { transport: transport, id_prefix: 'test', write_timeout: 1, default_ttl: 30 }
    JRPC::SharedClient.new("127.0.0.1:1234", **defaults.merge(opts))
  end

  let(:client) { build_client }

  after { client.close(timeout: 0.2) rescue nil }

  # ── constructor validation ─────────────────────────────────────────────────

  describe 'constructor' do
    it 'raises ArgumentError when write_timeout >= default_ttl' do
      expect {
        JRPC::SharedClient.new("127.0.0.1:1234", transport: transport,
                               write_timeout: 30, default_ttl: 30)
      }.to raise_error(ArgumentError, /write_timeout/)
    end

    it 'allows write_timeout < default_ttl' do
      c = JRPC::SharedClient.new("127.0.0.1:1234", transport: transport,
                                 write_timeout: 1, default_ttl: 30)
      expect { c.close }.not_to raise_error
    end
  end

  # ── basic request / response ──────────────────────────────────────────────

  describe '#request' do
    it 'returns the result when server responds' do
      result = nil
      caller = Thread.new { result = client.request(:sum, [1, 2]) }
      wait_for { transport.frames_written.size >= 1 }
      transport.inject_response(ok_response('test-1', 42))
      caller.join(2)
      expect(result).to eq(42)
    end

    it 'sends the correct JSON-RPC frame' do
      t = Thread.new do
        begin
          client.request(:sum, [1, 2])
        rescue; end
      end
      wait_for { transport.frames_written.size >= 1 }
      sent = JSON.parse(transport.frames_written.first)
      expect(sent).to include('jsonrpc' => '2.0', 'method' => 'sum', 'params' => [1, 2])
      expect(sent['id']).to eq('test-1')
      client.close(timeout: 0.2)
      t.join(1)
    end

    it 'omits params key when params is nil' do
      t = Thread.new do
        begin
          client.request(:ping)
        rescue; end
      end
      wait_for { transport.frames_written.size >= 1 }
      sent = JSON.parse(transport.frames_written.first)
      expect(sent).not_to have_key('params')
      client.close(timeout: 0.2)
      t.join(1)
    end

    it 'handles multiple concurrent requests with out-of-order responses' do
      results = {}
      caller1 = Thread.new { results[:a] = client.request(:a) }
      caller2 = Thread.new { results[:b] = client.request(:b) }
      wait_for { transport.frames_written.size >= 2 }

      id_a = JSON.parse(transport.frames_written.find { |f| JSON.parse(f)['method'] == 'a' })['id']
      id_b = JSON.parse(transport.frames_written.find { |f| JSON.parse(f)['method'] == 'b' })['id']

      transport.inject_response(ok_response(id_b, 'B'))
      transport.inject_response(ok_response(id_a, 'A'))

      caller1.join(2)
      caller2.join(2)
      expect(results[:a]).to eq('A')
      expect(results[:b]).to eq('B')
    end

    it 'raises ClientError for invalid method type' do
      expect { client.request(42) }.to raise_error(JRPC::Errors::ClientError)
    end

    it 'raises ClientError when client is closed' do
      client.close
      expect { client.request(:ping) }.to raise_error(JRPC::Errors::ClientError, /client closed/)
    end

    it 'raises ServerError subclass for server-returned error envelope' do
      err = nil
      caller = Thread.new do
        begin
          client.request(:x)
        rescue => e
          err = e
        end
      end
      wait_for { transport.frames_written.size >= 1 }
      transport.inject_response(error_response('test-1', -32601, 'not found'))
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::MethodNotFound)
    end

    it 'raises MalformedResponseError for bad jsonrpc version' do
      err = nil
      caller = Thread.new do
        begin
          client.request(:x)
        rescue => e
          err = e
        end
      end
      wait_for { transport.frames_written.size >= 1 }
      transport.inject_response(JSON.generate({ 'jsonrpc' => '1.0', 'result' => 1, 'id' => 'test-1' }))
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::MalformedResponseError)
    end
  end

  # ── notifications ──────────────────────────────────────────────────────────

  describe '#notification' do
    it 'blocking notification returns nil after send' do
      result = nil
      caller = Thread.new { result = client.notification(:log, ['msg']) }
      wait_for { transport.frames_written.size >= 1 }
      caller.join(2)
      expect(result).to be_nil
    end

    it 'sends correct JSON-RPC frame without id' do
      t = Thread.new do
        begin
          client.notification(:log, ['msg'])
        rescue; end
      end
      wait_for { transport.frames_written.size >= 1 }
      sent = JSON.parse(transport.frames_written.first)
      expect(sent).to eq('jsonrpc' => '2.0', 'method' => 'log', 'params' => ['msg'])
      expect(sent).not_to have_key('id')
      client.close(timeout: 0.2)
      t.join(1)
    end

    it 'fire_and_forget returns nil immediately without waiting for send' do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.notification(:metric, [1], fire_and_forget: true)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be < 0.5
    end

    it 'raises ClientError when client is closed' do
      client.close
      expect { client.notification(:log) }.to raise_error(JRPC::Errors::ClientError, /client closed/)
    end
  end

  # ── TTL / timeout ──────────────────────────────────────────────────────────

  describe 'TTL expiry' do
    let(:fake_clock) { [0.0] }
    let(:client) { build_client(clock: -> { fake_clock[0] }, default_ttl: 10, write_timeout: 1) }

    it 'raises Timeout when TTL fires while ticket is in flight' do
      err = nil
      caller = Thread.new do
        begin
          client.request(:slow)
        rescue => e
          err = e
        end
      end
      wait_for { transport.frames_written.size >= 1 }

      # Advance clock past TTL and wake the transport loop.
      fake_clock[0] = 20.0
      # inject a well-formed JSON but unknown id to poke the loop without disrupting state.
      transport.inject_response(ok_response('no-such-id', nil))

      caller.join(2)
      expect(err).to be_a(JRPC::Errors::Timeout)
    end
  end

  # ── connection errors ──────────────────────────────────────────────────────

  describe 'connection handling' do
    it 'raises ConnectionError when connect fails' do
      transport.fail_on_connect(JRPC::Transport::Base::ConnectionError.new('refused'))
      err = nil
      caller = Thread.new do
        begin
          client.request(:x)
        rescue => e
          err = e
        end
      end
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::ConnectionError)
    end

    it 'raises ConnectionError when write fails' do
      transport.fail_on_write(JRPC::Transport::Base::ConnectionError.new('broken pipe'))
      err = nil
      caller = Thread.new do
        begin
          client.request(:x)
        rescue => e
          err = e
        end
      end
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::ConnectionError)
    end
  end

  # ── queue full ────────────────────────────────────────────────────────────

  describe 'max_queue_size' do
    it 'raises ClientError("queue full") immediately when capacity is zero' do
      c = JRPC::SharedClient.new("127.0.0.1:1234", transport: transport,
                                 id_prefix: 'q', write_timeout: 1, default_ttl: 30,
                                 max_queue_size: 0)
      expect {
        c.request(:x)
      }.to raise_error(JRPC::Errors::ClientError, /queue full/)
      c.close(timeout: 0.1)
    end
  end

  # ── #close and #closed? ───────────────────────────────────────────────────

  describe '#close' do
    it 'returns true on graceful close (nothing in flight)' do
      expect(client.close).to be true
    end

    it 'is idempotent' do
      client.close
      expect(client.close).to be true
    end

    it 'sets closed? to true' do
      client.close
      expect(client.closed?).to be true
    end

    it 'unblocks an in-flight request with ConnectionError (hard close path)' do
      err = nil
      caller = Thread.new do
        begin
          client.request(:slow)
        rescue => e
          err = e
        end
      end
      wait_for { transport.frames_written.size >= 1 }

      # Use a short timeout to trigger the hard-close path quickly.
      client.close(timeout: 0.1)
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::ConnectionError)
    end

    it 'prevents new enqueues after close' do
      client.close
      expect { client.request(:x) }.to raise_error(JRPC::Errors::ClientError, /client closed/)
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

  # ── orphan / server-initiated ─────────────────────────────────────────────

  describe 'orphan and server-initiated messages' do
    it 'logs and drops a response for an unknown id without crashing' do
      logger = double('logger', error: nil)
      c = build_client(logger: logger)
      transport.inject_response(ok_response('unknown-99', 42))
      sleep 0.05
      expect(c.closed?).to be false
      c.close(timeout: 0.2)
    end

    it 'drops a server-initiated notification (no id) without crashing' do
      logger = double('logger', error: nil)
      c = build_client(logger: logger)
      transport.inject_response(JSON.generate({ 'jsonrpc' => '2.0', 'method' => 'ping' }))
      sleep 0.05
      expect(c.closed?).to be false
      c.close(timeout: 0.2)
    end
  end

  # ── write_timeout invariant ────────────────────────────────────────────────

  describe 'write_timeout invariant' do
    it 'raises ArgumentError when write_timeout == default_ttl' do
      expect {
        JRPC::SharedClient.new("127.0.0.1:1234", transport: transport,
                               write_timeout: 30, default_ttl: 30)
      }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError when write_timeout > default_ttl' do
      expect {
        JRPC::SharedClient.new("127.0.0.1:1234", transport: transport,
                               write_timeout: 60, default_ttl: 30)
      }.to raise_error(ArgumentError)
    end
  end
end
