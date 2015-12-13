require 'spec_helper'
require 'logger'
require 'json'

describe JRPC::TcpClient do

  describe '#invoke_request' do
    subject do
      client = JRPC::TcpClient.new('127.0.0.1:1234', client_options)
      client.invoke_request('sum', 1, 2)
    end
    let(:client_options) { {} }

    let(:expected_request) do
      {
          'jsonrpc' => JRPC::JSON_RPC_VERSION,
          'method' => 'sum',
          'params' => [1,2],
          'id' => 'rspec-generated-id'
      }.to_json
    end

    let(:expected_result) do
      {
          'jsonrpc' => JRPC::JSON_RPC_VERSION,
          'result' => 3,
          'id' => 'rspec-generated-id'
      }.to_json
    end

    let(:raw_expected_request) do
      "#{expected_request.size}:#{expected_request},"
    end

    let(:socket_stub) { instance_double(Net::TCPClient) }

    it 'does something useful' do
      expect_any_instance_of(JRPC::TcpClient).to receive(:generate_id).with(no_args).and_return('rspec-generated-id')

      expect(Net::TCPClient).to receive(:new).with(any_args).once.and_return(socket_stub)
      expect(socket_stub).to receive(:write).with(raw_expected_request).once

      expect(socket_stub).to receive(:read).with(1).exactly(expected_result.size.to_s.size).times.
          and_return(
              *(expected_result.size.to_s.split('') + [':'])
          )
      expect(socket_stub).to receive(:read).with(expected_result.size + 1).and_return(expected_result + ',')


      expect(subject).to eq JSON.parse(expected_result)['result']
    end

  end # invoke_request

end
