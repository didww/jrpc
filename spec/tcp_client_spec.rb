require 'spec_helper'
require 'logger'
require 'fake_transport'

describe JRPC::TcpClient do

  let(:socket_stub) { FakeTransport.new(read_timeout: 30, write_timeout: 60) }

  shared_examples :sends_request_and_receive_response do |options = {}|
    method = options.fetch(:method)
    without_params = options.fetch(:without_params, false)
    result = options.fetch(:result, 1)

    if without_params
      params = nil
    else
      params = options.fetch(:params)
    end

    let(:expected_request) do
      if without_params
        {
            jsonrpc: JRPC::JSON_RPC_VERSION,
            method: method,
            id: stubbed_generated_id
        }
      else
        {
            jsonrpc: JRPC::JSON_RPC_VERSION,
            method: method,
            params: params,
            id: stubbed_generated_id
        }
      end
    end

    let(:expected_result) do
      {
          jsonrpc: JRPC::JSON_RPC_VERSION,
          result: result,
          id: stubbed_generated_id
      }
    end

    it "sends request #{method} #{without_params ? 'without params' : params.inspect} and receives #{result.inspect}" do
      json_request = expected_request.to_json
      raw_expected_request = "#{json_request.size}:#{json_request},"
      expect(socket_stub).to receive(:write).with(raw_expected_request, 60).once

      json_result = expected_result.to_json
      socket_stub.response = json_result
      expect(socket_stub).to receive(:read).with(1, 30).exactly(json_result.size.to_s.size).times.
          and_return(
              *(json_result.size.to_s.split('') + [':'])
          )
      expect(socket_stub).to receive(:read).with(json_result.size + 1, 30).and_return(json_result + ',').and_call_original

      expect(subject).to eq JSON.parse(json_result)['result']
    end
  end

  shared_examples :sends_notification do |options = {}|
    method = options.fetch(:method)
    without_params = options.fetch(:without_params, false)

    if without_params
      params = nil
    else
      params = options.fetch(:params)
    end

    let(:expected_request) do
      if without_params
        {
            jsonrpc: JRPC::JSON_RPC_VERSION,
            method: method
        }
      else
        {
            jsonrpc: JRPC::JSON_RPC_VERSION,
            method: method,
            params: params
        }
      end
    end

    it "sends notification #{method} #{without_params ? 'without params' : params.inspect}" do
      json_request = expected_request.to_json
      raw_expected_request = "#{json_request.size}:#{json_request},"
      expect(socket_stub).to receive(:write).with(raw_expected_request, 60).once

      expect(socket_stub).to_not receive(:read)

      expect(subject).to be_nil
    end
  end

  shared_examples :raises_client_error do |msg|
    it "raises ClientError with #{msg.inspect}" do
      expect { subject }.to raise_error(JRPC::ClientError, msg)
    end
  end

  describe '#invoke_request' do
    subject do
      client.invoke_request(invoke_request_method, *invoke_request_params)
    end

    let(:client) { JRPC::TcpClient.new('127.0.0.1:1234', client_options) }
    let(:client_options) { {} }
    let(:invoke_request_method) { 'sum' }
    let(:invoke_request_params) { [1, 2] }

    before do
      allow(JRPC::Transport::SocketTcp).to receive(:new).with(any_args).once.and_return(socket_stub)
    end

    it 'calls perform_request("sum", params: [1, 2])' do
      expect(client).to receive(:perform_request).with(
          invoke_request_method,
          params: invoke_request_params
      ).once.and_return(1)
      expect(subject).to eq(1)
    end

    context 'without params' do
      let(:invoke_request_params) { [] }

      it 'calls perform_request("sum", params: nil)' do
        expect(client).to receive(:perform_request).with(
            invoke_request_method,
            params: nil
        ).once.and_return(1)
        expect(subject).to eq(1)
      end
    end

  end # invoke_request

  describe '#invoke_notification' do
    subject do
      client.invoke_notification(invoke_notification_method, *invoke_notification_params)
    end

    let(:client) { JRPC::TcpClient.new('127.0.0.1:1234', client_options) }
    let(:client_options) { {} }
    let(:invoke_notification_method) { 'sum' }
    let(:invoke_notification_params) { [1, 2] }

    before do
      allow(JRPC::Transport::SocketTcp).to receive(:new).with(any_args).once.and_return(socket_stub)
    end

    it 'calls perform_request("sum", params: [1, 2], type: :notification)' do
      expect(client).to receive(:perform_request).with(
          invoke_notification_method,
          params: invoke_notification_params,
          type: :notification
      ).once.and_return(nil)
      expect(subject).to eq(nil)
    end

    context 'without params' do
      let(:invoke_notification_params) { [] }

      it 'calls perform_request("sum", params: nil, type: :notification)' do
        expect(client).to receive(:perform_request).with(
            invoke_notification_method,
            params: nil,
            type: :notification
        ).once.and_return(1)
        expect(subject).to eq(1)
      end
    end

  end # invoke_notification

  describe '#perform_request' do
    subject do
      client.perform_request(perform_request_method, perform_request_options)
    end

    let(:client) { JRPC::TcpClient.new('127.0.0.1:1234', client_options) }
    let(:client_options) { {} }
    let(:stubbed_generated_id) { 'rspec-generated-id' }

    before do
      allow_any_instance_of(JRPC::TcpClient).to receive(:generate_id).with(no_args).and_return(stubbed_generated_id)
      allow(JRPC::Transport::SocketTcp).to receive(:new).with(any_args).once.and_return(socket_stub)
      allow(socket_stub).to receive(:closed?).and_return(false)
    end

    context 'with array params' do
      let(:perform_request_method) { 'trigger' }
      let(:perform_request_options) { { params: [1, 2] } }

      include_examples :sends_request_and_receive_response,
                       method: 'trigger',
                       params: [1, 2]

      context 'params are empty' do
        let(:perform_request_options) { { params: [] } }

        include_examples :sends_request_and_receive_response,
                         method: 'trigger',
                         params: []
      end

      context 'type notification' do
        let(:perform_request_options) { super().merge type: :notification }

        include_examples :sends_notification,
                         method: 'trigger',
                         params: [1, 2]
      end

    end

    context 'with object params' do
      let(:perform_request_method) { 'trigger' }
      let(:perform_request_options) { { params: { src: 1, dst: 2 } } }

      include_examples :sends_request_and_receive_response,
                       method: 'trigger',
                       params: { src: 1, dst: 2 }

      context 'params is an empty object' do
        let(:perform_request_options) { { params: {} } }

        include_examples :sends_request_and_receive_response,
                         method: 'trigger',
                         params: {}
      end

      context 'type notification' do
        let(:perform_request_options) { super().merge type: :notification }

        include_examples :sends_notification,
                         method: 'trigger',
                         params: { src: 1, dst: 2 }
      end

    end

    context 'without params' do
      let(:perform_request_method) { 'ping' }
      let(:perform_request_options) { {} }

      include_examples :sends_request_and_receive_response,
                       method: 'ping',
                       without_params: true

      context 'type notification' do
        let(:perform_request_options) { super().merge type: :notification }

        include_examples :sends_notification,
                         method: 'ping',
                         without_params: true
      end

    end

    context 'when params is not a hash and not and array' do
      let(:perform_request_method) { 'trigger' }
      let(:perform_request_options) { { params: 1 } }

      include_examples :raises_client_error, 'invalid params'
    end

    context 'with wrong type' do
      let(:perform_request_method) { 'trigger' }
      let(:perform_request_options) { { params: [1, 2], type: :test } }

      include_examples :raises_client_error, 'invalid type'
    end

  end # perform_request

end
