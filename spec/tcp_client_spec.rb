require 'spec_helper'

describe JRPC::TcpClient do
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

  let(:socket_stub) { instance_double(JRPC::NetstringTcpSocket) }

  it 'does something useful' do
    expect_any_instance_of(JRPC::TcpClient).to receive(:generate_id).once.and_return('rspec-generated-id')

    expect(JRPC::NetstringTcpSocket).to receive(:new).with(any_args).once.and_return(socket_stub)
    expect(socket_stub).to receive(:set_timeout).with(5).once
    expect(socket_stub).to receive(:send_string).with(expected_request).once
    expect(socket_stub).to receive(:receive_string).and_return(expected_result).once

    client = JRPC::TcpClient.new(hostname: '127.0.0.1', port: '1234')
    result = client.invoke_request('sum', 1, 2)

    expect(result).to eq JSON.parse(expected_result)['result']
  end

end
