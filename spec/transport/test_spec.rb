# frozen_string_literal: true

require 'timeout'
require 'jrpc/transport/test'

RSpec.describe JRPC::Transport::Test do
  subject(:transport) { described_class.new }

  after { transport.shutdown }

  describe 'with SimpleClient' do
    let(:client) { JRPC::SimpleClient.new('test', transport: transport, id_prefix: 'test') }

    it 'returns a handler result, echoing the request id' do
      transport.on('sum') { |params| params['a'] + params['b'] }

      expect(client.request('sum', { 'a' => 1, 'b' => 2 })).to eq(3)
    end

    it 'passes nil params through to the handler' do
      transport.on('ping') { |params| params.nil? ? 'pong' : 'unexpected' }

      expect(client.request('ping')).to eq('pong')
    end

    it 'allows a nil result' do
      transport.on('void') { nil }

      expect(client.request('void')).to be_nil
    end

    it 'maps a handler-raised ServerError to the matching error class' do
      transport.on('boom') { raise JRPC::Errors::InvalidParams, 'bad params' }

      expect { client.request('boom') }.to raise_error(JRPC::Errors::InvalidParams, 'bad params')
    end

    it 'defaults the error code to -32000 when the ServerError carries none' do
      transport.on('boom') { raise JRPC::Errors::ServerError, 'generic' }

      expect { client.request('boom') }.to raise_error(JRPC::Errors::InternalServerError) do |e|
        expect(e.code).to eq(-32_000)
      end
    end

    it 'raises a handler-raised transport error at read time, mapped to the client error' do
      transport.on('drop') { raise JRPC::Transport::Base::ConnectionError, 'peer reset' }

      expect { client.request('drop') }.to raise_error(JRPC::Errors::ConnectionError, 'peer reset')
    end

    it 'maps a handler-raised transport Timeout to Errors::Timeout' do
      transport.on('slow') { raise JRPC::Transport::Base::Timeout, 'too slow' }

      expect { client.request('slow') }.to raise_error(JRPC::Errors::Timeout)
    end

    it 'records requests, notifications, and raw sent payloads' do
      transport.on('sum', &:sum)
      client.request('sum', [1, 2])
      client.notification('log', { 'msg' => 'hi' })

      expect(transport.requests.map { |r| r['method'] }).to eq(['sum'])
      expect(transport.last_request).to include('method' => 'sum', 'params' => [1, 2])
      expect(transport.notifications.map { |n| n['method'] }).to eq(['log'])
      expect(transport.sent.size).to eq(2)
    end

    it 'raises UnexpectedRequest for an unstubbed method in strict mode' do
      expect { client.request('nope') }
        .to raise_error(described_class::UnexpectedRequest, /no handler for request "nope"/)
    end

    context 'with strict: false' do
      subject(:transport) { described_class.new(strict: false) }

      it 'serves a pushed raw response instead of requiring a handler' do
        transport.push_response({ 'jsonrpc' => '2.0', 'id' => 'test-1', 'result' => 42 })

        expect(client.request('anything')).to eq(42)
      end

      it 'times out when no response is queued' do
        expect { client.request('anything') }.to raise_error(JRPC::Errors::Timeout)
      end
    end

    it 'push_raise surfaces as the next read error' do
      transport.push_raise(JRPC::Transport::Base::MalformedFrame.new('garbage'))
      transport.on('x') { 'unused' }

      # The pushed raise is FIFO-first, so it wins over the handler response.
      expect { client.request('x') }.to raise_error(JRPC::Errors::MalformedResponseError)
    end

    it 'reset clears recordings and queued frames but keeps handlers' do
      transport.on('sum', &:sum)
      client.request('sum', [1, 2])
      transport.reset

      expect(transport.requests).to be_empty
      expect(transport.sent).to be_empty
      expect(client.request('sum', [3, 4])).to eq(7)
    end

    it 'fail_connect makes connect raise' do
      transport.fail_connect(JRPC::Transport::Base::ConnectionError.new('refused'))

      expect { client.request('x') }.to raise_error(JRPC::Errors::ConnectionError, 'refused')
    end
  end

  describe 'with SharedClient' do
    let(:client) { JRPC::SharedClient.new('test', transport: transport, default_ttl: 5, write_timeout: 1) }

    after { client.close }

    it 'resolves a request through a handler end-to-end' do
      transport.on('sum') { |params| params['a'] + params['b'] }

      expect(client.request('sum', { 'a' => 4, 'b' => 5 })).to eq(9)
    end

    it 'maps a handler ServerError to the matching client error' do
      transport.on('boom') { raise JRPC::Errors::MethodNotFound, 'nope' }

      expect { client.request('boom') }.to raise_error(JRPC::Errors::MethodNotFound, 'nope')
    end

    it 'records fire-and-forget notifications' do
      client.notification('log', { 'msg' => 'hi' }, fire_and_forget: true)

      # Give the transport loop a moment to flush the outbound notification.
      Timeout.timeout(2) { sleep 0.01 until transport.notifications.any? }
      expect(transport.notifications.first).to include('method' => 'log')
    end

    it 'fail_connect is drained as a connection error to callers' do
      transport.fail_connect(JRPC::Transport::Base::ConnectionError.new('refused'))

      expect { client.request('x') }.to raise_error(JRPC::Errors::ConnectionError)
    end
  end
end
