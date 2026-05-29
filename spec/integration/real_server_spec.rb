# frozen_string_literal: true

# End-to-end specs that run the real Tcp transport (and, for SharedClient, the
# real TransportLoop on its own thread) against a live JSON-RPC server in a
# separate process (spec/test_server.rb). Unlike the fake-transport unit specs,
# these drive actual socket I/O and netstring framing.
RSpec.describe 'real server integration' do
  let(:server) { "127.0.0.1:#{TestServerProcess.port}" }

  describe JRPC::SimpleClient do
    subject(:client) { described_class.new(server, connect_timeout: 5, read_timeout: 5, write_timeout: 5) }

    after { client.close }

    it 'performs a request/response round trip' do
      expect(client.request('echo', %w[hello world])).to eq(%w[hello world])
    end

    it 'reuses the connection across multiple sequential requests' do
      expect(client.request('add', [1, 2, 3])).to eq(6)
      expect(client.request('add', [10, 20])).to eq(30)
      expect(client.request('echo', { 'a' => 1 })).to eq('a' => 1)
    end

    it 'raises a server error for a JSON-RPC error response' do
      expect { client.request('boom') }
        .to raise_error(JRPC::Errors::InternalServerError) { |e| expect(e.code).to eq(-32_000) }
    end

    it 'maps method-not-found to the typed error' do
      expect { client.request('does_not_exist') }
        .to raise_error(JRPC::Errors::MethodNotFound) { |e| expect(e.code).to eq(-32_601) }
    end

    it 'sends a notification with no response' do
      expect(client.notification('echo', %w[ignored])).to be_nil
      # The connection is still usable for a subsequent request.
      expect(client.request('add', [4, 5])).to eq(9)
    end

    it 'times out a read when the server is too slow' do
      expect { client.request('slow', { 'ms' => 400 }, read_timeout: 0.1) }
        .to raise_error(JRPC::Errors::Timeout)
    end
  end

  describe JRPC::SharedClient do
    subject(:client) { described_class.new(server, write_timeout: 2, default_ttl: 5) }

    after { client.close }

    it 'performs a request/response round trip' do
      expect(client.request('echo', %w[hi])).to eq(%w[hi])
    end

    it 'multiplexes concurrent requests from many threads over one connection' do
      results = Array.new(20)
      threads = (0...20).map do |i|
        Thread.new { results[i] = client.request('add', [i, i]) }
      end
      threads.each(&:join)
      expect(results).to eq((0...20).map { |i| i * 2 })
    end

    it 'raises a server error for a JSON-RPC error response' do
      expect { client.request('boom') }
        .to raise_error(JRPC::Errors::InternalServerError) { |e| expect(e.code).to eq(-32_000) }
    end

    it 'performs a request with an unbounded ttl' do
      expect(client.request('add', [2, 3], ttl: nil)).to eq(5)
    end

    it 'delivers an unbounded-ttl notification' do
      expect(client.notification('echo', %w[k], ttl: nil)).to be_nil
    end

    it 'delivers a blocking notification' do
      expect(client.notification('echo', %w[x])).to be_nil
    end

    it 'accepts a fire-and-forget notification' do
      expect(client.notification('echo', %w[x], fire_and_forget: true)).to be_nil
      # Connection still works afterwards.
      expect(client.request('add', [7, 8])).to eq(15)
    end
  end
end
