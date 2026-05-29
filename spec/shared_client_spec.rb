# frozen_string_literal: true

require 'logger'
require 'socket'

# FakeSharedTransport lives in spec/support/fake_shared_transport.rb so the
# fiber-caller spec can reuse it without load-order coupling.

RSpec.describe JRPC::SharedClient do
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
      raise 'wait_for timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep interval
    end
  end

  let(:transport) { FakeSharedTransport.new }
  let(:client) { build_client }

  def build_client(**opts)
    defaults = { transport: transport, id_prefix: 'test', write_timeout: 1, default_ttl: 30 }
    JRPC::SharedClient.new('127.0.0.1:1234', **defaults, **opts)
  end

  after do
    client.close(timeout: 0.2)
  rescue StandardError
    nil
  end

  # ── constructor validation ─────────────────────────────────────────────────

  describe 'constructor' do
    it 'raises ArgumentError when write_timeout >= default_ttl' do
      expect {
        described_class.new('127.0.0.1:1234', transport: transport,
                                              write_timeout: 30, default_ttl: 30)
      }.to raise_error(ArgumentError, /write_timeout/)
    end

    it 'allows write_timeout < default_ttl' do
      c = described_class.new('127.0.0.1:1234', transport: transport,
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
        client.request(:sum, [1, 2])
      rescue StandardError
        nil
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
        client.request(:ping)
      rescue StandardError
        nil
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
        client.request(:x)
      rescue StandardError => e
        err = e
      end
      wait_for { transport.frames_written.size >= 1 }
      transport.inject_response(error_response('test-1', -32_601, 'not found'))
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::MethodNotFound)
    end

    it 'raises MalformedResponseError for bad jsonrpc version' do
      err = nil
      caller = Thread.new do
        client.request(:x)
      rescue StandardError => e
        err = e
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
        client.notification(:log, ['msg'])
      rescue StandardError
        nil
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
        client.request(:slow)
      rescue StandardError => e
        err = e
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
        client.request(:x)
      rescue StandardError => e
        err = e
      end
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::ConnectionError)
    end

    it 'raises ConnectionError when write fails' do
      transport.fail_on_write(JRPC::Transport::Base::ConnectionError.new('broken pipe'))
      err = nil
      caller = Thread.new do
        client.request(:x)
      rescue StandardError => e
        err = e
      end
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::ConnectionError)
    end
  end

  # ── queue full ────────────────────────────────────────────────────────────

  describe 'max_queue_size' do
    it 'raises ClientError("queue full") immediately when capacity is zero' do
      c = described_class.new('127.0.0.1:1234', transport: transport,
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
        client.request(:slow)
      rescue StandardError => e
        err = e
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
      logger = instance_double(Logger, error: nil, debug: nil)
      c = build_client(logger: logger)
      transport.inject_response(ok_response('unknown-99', 42))
      sleep 0.05
      expect(c.closed?).to be false
      c.close(timeout: 0.2)
    end

    it 'drops a server-initiated notification (no id) without crashing' do
      logger = instance_double(Logger, error: nil, debug: nil)
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
        described_class.new('127.0.0.1:1234', transport: transport,
                                              write_timeout: 30, default_ttl: 30)
      }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError when write_timeout > default_ttl' do
      expect {
        described_class.new('127.0.0.1:1234', transport: transport,
                                              write_timeout: 60, default_ttl: 30)
      }.to raise_error(ArgumentError)
    end
  end

  # ── debug payload logging ──────────────────────────────────────────────────

  describe 'debug payload logging' do
    let(:logger) { instance_double(Logger, error: nil, debug: nil) }
    let(:client) { build_client(logger: logger) }

    it 'logs the sent and received raw payloads at debug' do
      result = nil
      caller = Thread.new { result = client.request(:sum, [1, 2]) }
      wait_for { transport.frames_written.size >= 1 }
      transport.inject_response(ok_response('test-1', 42))
      caller.join(2)

      expect(result).to eq(42)
      expect(logger).to have_received(:debug)
        .with('[JRPC::SharedClient] >> {"jsonrpc":"2.0","method":"sum","id":"test-1","params":[1,2]}')
      expect(logger).to have_received(:debug)
        .with("[JRPC::SharedClient] << #{ok_response('test-1', 42)}")
    end
  end

  # ── caller-thread interruption (Thread#raise mid-wait) ─────────────────────

  describe 'caller interrupted while waiting' do
    let(:logger) { instance_double(Logger, error: nil, debug: nil) }
    let(:client) { build_client(logger: logger) }

    it 'cancels the ticket, cleans up the registry, and treats a late response as orphan' do
      caller = Thread.new do
        client.request(:slow)
      rescue StandardError
        nil # swallow the injected interrupt
      end
      # Wait until the request is in flight (sent), so the caller is parked in #wait.
      wait_for { transport.frames_written.size >= 1 }

      caller.raise(StandardError, 'interrupted')
      caller.join(2)

      # The caller's ensure block must have removed the ticket from the registry,
      # so the matching late response is now an orphan (logged, dropped, no crash).
      transport.inject_response(ok_response('test-1', 99))
      wait_for { transport.frames_written.size >= 0 } # let the loop spin once
      sleep 0.05

      expect(logger).to have_received(:error).with(/orphan response: id=/)
      expect(client.closed?).to be false
    end

    it 'does not leave a leaked entry that would block a graceful close' do
      caller = Thread.new do
        client.request(:slow)
      rescue StandardError
        nil
      end
      wait_for { transport.frames_written.size >= 1 }

      caller.raise(StandardError, 'interrupted')
      caller.join(2)

      # Registry was cleaned up by the caller; nothing in flight blocks the loop,
      # so a graceful close joins cleanly (returns true) rather than force-killing.
      expect(client.close(timeout: 1)).to be true
    end
  end

  # ── connection drop mid-session ────────────────────────────────────────────

  describe 'connection drop with in-flight requests' do
    it 'drains every in-flight request with ConnectionError and keeps the thread running' do
      errors = {}
      callers = Array.new(3) do |i|
        Thread.new do
          client.request("m#{i}")
        rescue StandardError => e
          errors[i] = e
        end
      end
      wait_for { transport.frames_written.size >= 3 }

      transport.fail_on_read(JRPC::Transport::Base::ConnectionError.new('peer closed'))

      callers.each { |t| t.join(2) }
      expect(errors.values).to contain_exactly(
        an_instance_of(JRPC::Errors::ConnectionError),
        an_instance_of(JRPC::Errors::ConnectionError),
        an_instance_of(JRPC::Errors::ConnectionError)
      )
      expect(client.closed?).to be false
    end

    it 'reconnects on the next request after a drop' do
      caller = Thread.new do
        client.request(:first)
      rescue StandardError
        nil
      end
      wait_for { transport.frames_written.size >= 1 }
      transport.fail_on_read(JRPC::Transport::Base::ConnectionError.new('peer closed'))
      caller.join(2)

      expect(transport.connects).to be >= 1
      before = transport.connects

      result = nil
      caller2 = Thread.new { result = client.request(:second) }
      wait_for { transport.frames_written.size >= 2 }
      id = JSON.parse(transport.frames_written.last)['id']
      transport.inject_response(ok_response(id, 'ok'))
      caller2.join(2)

      expect(result).to eq('ok')
      expect(transport.connects).to be > before
    end
  end

  # ── framing corruption mid-stream ──────────────────────────────────────────

  describe 'framing corruption' do
    it 'tears down with ConnectionError("framing corruption...") then resynchronizes on reconnect' do
      err = nil
      caller = Thread.new do
        client.request(:x)
      rescue StandardError => e
        err = e
      end
      wait_for { transport.frames_written.size >= 1 }

      transport.fail_on_read(JRPC::Transport::Base::MalformedFrame.new('bad netstring length prefix'))
      caller.join(2)

      expect(err).to be_a(JRPC::Errors::ConnectionError)
      expect(err.message).to match(/framing corruption/)

      # Stream is resynchronized on the next connect: a fresh request resolves normally.
      result = nil
      caller2 = Thread.new { result = client.request(:y) }
      wait_for { transport.frames_written.size >= 2 }
      id = JSON.parse(transport.frames_written.last)['id']
      transport.inject_response(ok_response(id, 7))
      caller2.join(2)
      expect(result).to eq(7)
    end
  end

  # ── transport-thread crash ─────────────────────────────────────────────────

  describe 'transport-thread crash' do
    let(:logger) { instance_double(Logger, error: nil, debug: nil) }
    let(:client) { build_client(logger: logger) }

    # A non-transport StandardError from write_frame is not caught by the loop's
    # transport-error rescues, so it escapes to TransportLoop#run's crash handler.
    it 'drains in-flight requests with ConnectionError when the loop crashes' do
      transport.fail_on_write(RuntimeError.new('boom'))
      err = nil
      caller = Thread.new do
        client.request(:x)
      rescue StandardError => e
        err = e
      end
      caller.join(2)
      expect(err).to be_a(JRPC::Errors::ConnectionError)
    end

    it 'marks the client unusable so later calls raise ClientError' do
      transport.fail_on_write(RuntimeError.new('boom'))
      caller = Thread.new do
        client.request(:x)
      rescue StandardError
        nil
      end
      caller.join(2)

      expect { client.request(:y) }
        .to raise_error(JRPC::Errors::ClientError, /unusable/)
    end

    it 'still closes cleanly after a crash' do
      transport.fail_on_write(RuntimeError.new('boom'))
      caller = Thread.new do
        client.request(:x)
      rescue StandardError
        nil
      end
      caller.join(2)

      expect(client.close(timeout: 1)).to be true
      expect(client.closed?).to be true
    end
  end
end
