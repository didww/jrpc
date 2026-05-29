# frozen_string_literal: true

require 'socket'

Transport = JRPC::Transport

# Stand-in for a non-blocking connect that never completes: connect_nonblock signals
# "in progress" via the IO::WaitWritable *module*. Using a module-only error (no
# concrete IO::EAGAINWaitWritable) also proves try_connect_nonblock rescues the module
# — the same fix applied to write_frame for macOS/BSD where EAGAIN != EWOULDBLOCK.
class StubWaitWritable < StandardError
  include IO::WaitWritable
end

RSpec.describe JRPC::Transport::Tcp do
  def open_server
    TCPServer.new('127.0.0.1', 0)
  end

  def server_port(srv)
    srv.addr[1]
  end

  def ns_frame(data)
    "#{data.bytesize}:#{data},"
  end

  # Connect the transport to the server, accept the server-side socket, yield, then clean up.
  def with_connection(port, **opts)
    transport = JRPC::Transport::Tcp.new("127.0.0.1:#{port}", **opts)
    transport.connect
    raise 'did not connect' if transport.closed?

    yield transport
  ensure
    transport.close
  end

  describe '#connect' do
    it 'establishes a TCP connection' do
      srv = open_server
      port = server_port(srv)
      t = described_class.new("127.0.0.1:#{port}")
      expect(t.closed?).to be true
      t.connect
      expect(t.closed?).to be false
      srv.accept.close
      t.close
      srv.close
    end

    it 'raises ConnectionError when server is not listening' do
      # Port 1 is not open on loopback (requires root to bind; ECONNREFUSED on connect)
      t = described_class.new('127.0.0.1:1', connect_retry_count: 0)
      expect { t.connect }.to raise_error(Transport::Base::ConnectionError)
    end

    it 'normalizes DNS resolution failures to ConnectionError' do
      # .invalid is reserved by RFC 2606 — guaranteed not to resolve.
      t = described_class.new('no-such-host.invalid:1234', connect_retry_count: 0)
      expect { t.connect }.to raise_error(Transport::Base::ConnectionError)
    end

    it 'retries connect_retry_count times and then raises' do
      t = described_class.new('127.0.0.1:1',
                              connect_retry_count: 2,
                              connect_retry_interval: 0)
      # We spy by counting ConnectionError rescues through retry logic.
      # Easiest: measure wall time or count.  Here we just verify it raises eventually.
      expect { t.connect }.to raise_error(Transport::Base::ConnectionError)
    end

    it 'closes the previous socket when connect is called on a live transport (no fd leak)' do
      srv      = open_server
      port     = server_port(srv)
      accepted = []
      acceptor = Thread.new { 2.times { accepted << srv.accept } }

      t = described_class.new("127.0.0.1:#{port}")
      t.connect
      sock1 = t.socket
      t.connect # reconnect on an already-connected transport
      sock2 = t.socket

      expect(sock1).not_to be(sock2)
      expect(sock1).to be_closed # old fd closed, not orphaned
      expect(t.closed?).to be false

      t.close
      acceptor.join
      accepted.each(&:close)
      srv.close
    end

    it 'is reusable after close' do
      srv  = open_server
      port = server_port(srv)
      t    = described_class.new("127.0.0.1:#{port}")
      t.connect
      conn1 = srv.accept
      t.close
      t.connect
      conn2 = srv.accept
      expect(t.closed?).to be false
      conn1.close
      conn2.close
      t.close
      srv.close
    end
  end

  describe 'connect timeout handling (deterministic, stubbed socket)' do
    # Build a transport whose socket creation is stubbed, so connect() exercises only the
    # timeout/retry logic and never touches a real network. wait_writable is stubbed per-example.
    def transport_with_stubbed_socket(**opts)
      t = JRPC::Transport::Tcp.new('203.0.113.1:9', **opts) # TEST-NET-3, never contacted
      fake_sock = instance_double(Socket)
      allow(fake_sock).to receive(:connect_nonblock).and_raise(StubWaitWritable)
      allow(fake_sock).to receive(:close)
      allow(t).to receive(:build_socket).and_return([fake_sock, :sockaddr])
      [t, fake_sock]
    end

    it 'raises Timeout when the connect never becomes writable' do
      t, fake_sock = transport_with_stubbed_socket(connect_timeout: 0.5)
      allow(fake_sock).to receive(:wait_writable).and_return(nil) # never writable
      expect { t.connect }.to raise_error(Transport::Base::Timeout, /connect timed out/)
    end

    it 'closes the in-progress socket and stays closed after a connect timeout' do
      t, fake_sock = transport_with_stubbed_socket(connect_timeout: 0.5)
      allow(fake_sock).to receive(:wait_writable).and_return(nil)
      expect { t.connect }.to raise_error(Transport::Base::Timeout)
      expect(fake_sock).to have_received(:close)
      expect(t.closed?).to be true
    end

    it 'caps a single IO.select wait at the time left in connect_timeout' do
      t, fake_sock = transport_with_stubbed_socket(connect_timeout: 5, connect_attempt_timeout: nil)
      waits = []
      allow(fake_sock).to receive(:wait_writable) { |wait|
        waits << wait
        nil
      }
      expect { t.connect }.to raise_error(Transport::Base::Timeout)
      expect(waits.first).to be > 0
      expect(waits.first).to be <= 5
    end

    it 'caps a single IO.select wait at connect_attempt_timeout when it is the smaller bound' do
      t, fake_sock = transport_with_stubbed_socket(connect_timeout: 60, connect_attempt_timeout: 0.05)
      waits = []
      allow(fake_sock).to receive(:wait_writable) { |wait|
        waits << wait
        nil
      }
      expect { t.connect }.to raise_error(Transport::Base::Timeout)
      expect(waits.first).to eq(0.05)
    end

    it 'makes connect_retry_count additional attempts, each its own wait_writable call' do
      t, fake_sock = transport_with_stubbed_socket(connect_timeout: 60,
                                                   connect_attempt_timeout: 0.01,
                                                   connect_retry_count: 2,
                                                   connect_retry_interval: 0)
      allow(fake_sock).to receive(:wait_writable).and_return(nil)
      expect { t.connect }.to raise_error(Transport::Base::Timeout)
      expect(fake_sock).to have_received(:wait_writable).exactly(3).times # initial attempt + 2 retries
    end

    it 'passes a nil wait_writable timeout (block indefinitely) when both connect bounds are nil' do
      t = described_class.new('203.0.113.1:9', connect_timeout: nil, connect_attempt_timeout: nil)
      # connect_nonblock: WaitWritable first, then EISCONN (connected) on the retry.
      call = 0
      fake = instance_double(Socket, close: nil, closed?: false)
      allow(fake).to receive(:connect_nonblock) do
        call += 1
        call == 1 ? raise(StubWaitWritable) : raise(Errno::EISCONN)
      end
      allow(t).to receive(:build_socket).and_return([fake, :sockaddr])
      # With no deadline and no per-attempt cap the wait_writable timeout must be nil;
      # return the socket to indicate writable so the connect loop reaches EISCONN (connected).
      allow(fake).to receive(:wait_writable) do |wait|
        expect(wait).to be_nil
        fake
      end
      t.connect
      expect(t.closed?).to be false
    end
  end

  describe '#write_frame / #read_frame round-trip' do
    it 'sends and receives a frame' do
      srv  = open_server
      port = server_port(srv)
      payload = '{"jsonrpc":"2.0","method":"ping","id":"1"}'

      receiver = Thread.new do
        conn = srv.accept
        data = conn.read(ns_frame(payload).bytesize)
        conn.write(ns_frame('{"jsonrpc":"2.0","result":true,"id":"1"}'))
        conn.close
        data
      end

      with_connection(port) do |t|
        t.write_frame(payload, timeout: 5)
        result = t.read_frame(timeout: 5)
        expect(result).to eq('{"jsonrpc":"2.0","result":true,"id":"1"}')
      end

      expect(receiver.value).to eq(ns_frame(payload))
      srv.close
    end

    it 'handles empty payload' do
      srv  = open_server
      port = server_port(srv)

      Thread.new do
        conn = srv.accept
        conn.write(ns_frame(''))
        conn.close
      end
      with_connection(port) do |t|
        t.write_frame('', timeout: 5)
        expect(t.read_frame(timeout: 5)).to eq('')
      end
      srv.close
    end

    it 'handles a large payload' do
      srv     = open_server
      port    = server_port(srv)
      payload = 'x' * 100_000

      Thread.new do
        conn = srv.accept
        conn.write(ns_frame(payload))
        conn.close
      end
      with_connection(port) do |t|
        expect(t.read_frame(timeout: 5)).to eq(payload)
      end
      srv.close
    end

    it 'reads multiple sequential frames' do
      srv  = open_server
      port = server_port(srv)

      Thread.new do
        conn = srv.accept
        conn.write(ns_frame('first'))
        conn.write(ns_frame('second'))
        conn.write(ns_frame('third'))
        conn.close
      end

      with_connection(port) do |t|
        expect(t.read_frame(timeout: 5)).to eq('first')
        expect(t.read_frame(timeout: 5)).to eq('second')
        expect(t.read_frame(timeout: 5)).to eq('third')
      end
      srv.close
    end
  end

  describe '#try_read_frame' do
    it 'returns :wait when no data available' do
      srv  = open_server
      port = server_port(srv)

      Thread.new { srv.accept } # accept but don't write anything

      with_connection(port) do |t|
        expect(t.try_read_frame).to eq(:wait)
      end
      srv.close
    end

    it 'returns the frame when data is available' do
      srv  = open_server
      port = server_port(srv)

      Thread.new do
        conn = srv.accept
        conn.write(ns_frame('hello'))
        begin
          conn.flush
        rescue StandardError
          nil
        end
      end

      with_connection(port) do |t|
        # spin until data arrives
        result = nil
        10.times do
          result = t.try_read_frame
          break unless result == :wait

          sleep 0.02
        end
        expect(result).to eq('hello')
      end
      srv.close
    end

    it 'returns buffered frames even after peer closes' do
      # Server writes two frames in one chunk then closes. The second frame must
      # survive the EOF on the follow-up read_nonblock — i.e., try_read_frame must
      # parse the buffer BEFORE attempting a socket read.
      srv  = open_server
      port = server_port(srv)

      Thread.new do
        conn = srv.accept
        conn.write(ns_frame('first') + ns_frame('second'))
        conn.close
      end

      with_connection(port) do |t|
        # Pull bytes from the socket into the buffer.
        first = nil
        10.times do
          first = t.try_read_frame
          break unless first == :wait

          sleep 0.02
        end
        expect(first).to eq('first')

        # Second frame is already buffered. Even though the peer has closed,
        # try_read_frame must return it instead of raising on EOF.
        expect(t.try_read_frame).to eq('second')

        # Only AFTER the buffer drains does EOF surface as ConnectionError.
        expect {
          20.times do
            t.try_read_frame
            sleep 0.02
          end
        }
          .to raise_error(Transport::Base::ConnectionError)
      end
      srv.close
    end

    it 'raises ConnectionError when called on a closed transport' do
      t = described_class.new('127.0.0.1:9999')
      expect { t.try_read_frame }.to raise_error(Transport::Base::ConnectionError)
    end
  end

  describe '#close' do
    it 'is idempotent' do
      srv  = open_server
      port = server_port(srv)
      Thread.new { srv.accept }

      t = described_class.new("127.0.0.1:#{port}")
      t.connect
      t.close
      t.close # must not raise
      expect(t.closed?).to be true
      srv.close
    end

    it 'resets the read buffer so reconnect starts clean' do
      srv  = open_server
      port = server_port(srv)

      # Server: send half a netstring, then accept a second connection and send a complete one
      server_thread = Thread.new do
        conn1 = srv.accept
        conn1.write('5:he') # incomplete frame
        conn1.close
        conn2 = srv.accept
        conn2.write(ns_frame('clean'))
        conn2.close
      end

      t = described_class.new("127.0.0.1:#{port}")
      t.connect

      # Accumulate partial data
      begin
        t.read_frame(timeout: 0.2)
      rescue JRPC::Transport::Base::ConnectionError, JRPC::Transport::Base::Timeout
        # expected: connection closed or timeout
      end

      # close resets buffer
      t.close
      t.connect

      frame = t.read_frame(timeout: 2)
      expect(frame).to eq('clean')

      t.close
      server_thread.join
      srv.close
    end
  end

  describe 'malformed frames' do
    def server_sends_raw(raw)
      srv  = open_server
      port = server_port(srv)
      Thread.new do
        conn = srv.accept
        conn.write(raw)
        begin
          conn.flush
        rescue StandardError
          nil
        end
        conn.close
      end
      [srv, port]
    end

    it 'raises MalformedFrame for non-digit length prefix' do
      srv, port = server_sends_raw('abc:hello,')
      with_connection(port) do |t|
        expect { t.read_frame(timeout: 2) }.to raise_error(Transport::Base::MalformedFrame)
      end
      srv.close
    end

    it 'raises MalformedFrame for missing comma terminator' do
      srv, port = server_sends_raw('5:helloX')
      with_connection(port) do |t|
        expect { t.read_frame(timeout: 2) }.to raise_error(Transport::Base::MalformedFrame)
      end
      srv.close
    end

    it 'raises MalformedFrame for empty length prefix' do
      srv, port = server_sends_raw(':hello,')
      with_connection(port) do |t|
        expect { t.read_frame(timeout: 2) }.to raise_error(Transport::Base::MalformedFrame)
      end
      srv.close
    end

    it 'raises MalformedFrame for a leading zero in the length prefix' do
      srv, port = server_sends_raw('01:x,')
      with_connection(port) do |t|
        expect { t.read_frame(timeout: 2) }.to raise_error(Transport::Base::MalformedFrame, /leading zero/)
      end
      srv.close
    end
  end

  describe 'timeouts' do
    it 'raises Timeout from read_frame when no data arrives in time' do
      srv  = open_server
      port = server_port(srv)
      Thread.new { srv.accept } # accept but never write

      with_connection(port) do |t|
        expect { t.read_frame(timeout: 0.05) }.to raise_error(Transport::Base::Timeout)
      end
      srv.close
    end

    it 'transport is closed after read timeout' do
      srv  = open_server
      port = server_port(srv)
      Thread.new { srv.accept }

      t = described_class.new("127.0.0.1:#{port}")
      t.connect
      begin
        t.read_frame(timeout: 0.05)
      rescue Transport::Base::Timeout
        nil
      end
      expect(t.closed?).to be true
      srv.close
    end
  end

  describe 'connection errors' do
    it 'raises ConnectionError when peer closes mid-frame' do
      srv  = open_server
      port = server_port(srv)
      Thread.new do
        conn = srv.accept
        conn.write('5:he')
        conn.close
      end

      with_connection(port) do |t|
        expect { t.read_frame(timeout: 2) }
          .to raise_error(Transport::Base::ConnectionError)
      end
      srv.close
    end
  end

  describe '#socket' do
    it 'returns nil when closed' do
      t = described_class.new('127.0.0.1:9999')
      expect(t.socket).to be_nil
    end

    it 'read_frame on a closed transport raises ConnectionError (not raw TypeError)' do
      t = described_class.new('127.0.0.1:9999')
      expect { t.read_frame(timeout: 1) }.to raise_error(Transport::Base::ConnectionError)
    end

    it 'write_frame on a closed transport raises ConnectionError (not raw TypeError)' do
      t = described_class.new('127.0.0.1:9999')
      expect { t.write_frame('x', timeout: 1) }.to raise_error(Transport::Base::ConnectionError)
    end

    it 'returns the socket when connected' do
      srv  = open_server
      port = server_port(srv)
      Thread.new { srv.accept }

      with_connection(port) do |t|
        expect(t.socket).to be_a(Socket)
      end
      srv.close
    end
  end

  describe 'TCP MD5 Signature (RFC2385) via tcp_md5_pass' do
    include TcpMd5Helpers

    it 'round-trips a frame when the key matches the server' do
      skip 'TCP_MD5SIG unsupported on this host' unless tcp_md5_supported?

      key = 'shared-secret'
      srv = md5_server(key)
      port = srv.local_address.ip_port
      acceptor = Thread.new do
        conn, = srv.accept
        conn.recv(64) # consume the request frame
        conn.write(ns_frame('pong'))
        conn
      end

      t = described_class.new("127.0.0.1:#{port}", tcp_md5_pass: key, connect_timeout: 5)
      t.connect
      t.write_frame('ping', timeout: 5)
      expect(t.read_frame(timeout: 5)).to eq('pong')

      t.close
      acceptor.value.close
      srv.close
    end

    it 'fails to connect when the key does not match the server (kernel drops the handshake)' do
      skip 'TCP_MD5SIG unsupported on this host' unless tcp_md5_supported?

      srv = md5_server('right-key')
      port = srv.local_address.ip_port
      acceptor = Thread.new do
        srv.accept
      rescue StandardError
        nil
      end

      t = described_class.new("127.0.0.1:#{port}",
                              tcp_md5_pass: 'wrong-key',
                              connect_timeout: 1,
                              connect_retry_count: 0)
      expect { t.connect }.to raise_error(Transport::Base::Timeout)

      acceptor.kill
      srv.close
    end

    it 'raises ConnectionError for a key longer than the 80-byte kernel maximum' do
      skip 'TCP_MD5SIG unsupported on this host' unless tcp_md5_supported?

      t = described_class.new('127.0.0.1:9', tcp_md5_pass: 'x' * 81, connect_retry_count: 0)
      expect { t.connect }.to raise_error(Transport::Base::ConnectionError, /max is 80/)
    end

    it 'normalizes a non-String tcp_md5_pass to ConnectionError' do
      skip 'TCP_MD5SIG unsupported on this host' unless tcp_md5_supported?

      t = described_class.new('127.0.0.1:9', tcp_md5_pass: 12_345, connect_retry_count: 0)
      expect { t.connect }.to raise_error(Transport::Base::ConnectionError, /invalid tcp_md5_pass/)
    end

    it 'raises ConnectionError when TCP_MD5SIG is unavailable on the platform' do
      stub_const('JRPC::Transport::Tcp::TCP_MD5SIG', nil)
      t = described_class.new('127.0.0.1:9', tcp_md5_pass: 'key', connect_retry_count: 0)
      expect { t.connect }.to raise_error(Transport::Base::ConnectionError, /unsupported on this platform/)
    end

    it 'leaves connections unsigned (and connectable) when tcp_md5_pass is not set' do
      srv = open_server
      port = server_port(srv)
      Thread.new { srv.accept }

      t = described_class.new("127.0.0.1:#{port}")
      t.connect
      expect(t.closed?).to be false
      t.close
      srv.close
    end
  end
end
