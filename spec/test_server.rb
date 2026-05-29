# frozen_string_literal: true

# A real JSON-RPC 2.0 server over TCP, spawned as a separate process by the
# integration specs (spec/integration/real_server_spec.rb). It speaks the same
# netstring framing as JRPC::Transport::Tcp ("<bytesize>:<bytes>,") so the specs
# exercise the actual client transport + transport loop against a live socket
# instead of a fake transport double.
#
# Usage: ruby spec/test_server.rb
#   Binds 127.0.0.1 on an ephemeral port, prints "PORT=<port>" to stdout (flushed),
#   then serves until killed (SIGTERM/SIGINT). One thread per connection.
#
# Methods:
#   echo(params)      -> returns params verbatim
#   add([a, b, ...])  -> returns the sum
#   slow({ms:})       -> sleeps ms milliseconds, then returns "ok" (for timeout specs)
#   boom              -> returns a JSON-RPC error { code: -32000, message: "boom" }
#   <anything else>   -> returns method-not-found { code: -32601 }
# Notifications (no "id") produce no response.

require 'socket'
require 'json'

JSON_RPC_VERSION = '2.0'

# Read one netstring frame ("<len>:<payload>,") from +io+. Returns the payload
# String, or nil on EOF / malformed frame (connection is then dropped).
def read_frame(io)
  len_str = +''
  loop do
    ch = io.read(1)
    return nil if ch.nil?
    break if ch == ':'
    return nil unless ch.match?(/\d/)

    len_str << ch
    return nil if len_str.bytesize > 20 # absurd length prefix; bail
  end
  return nil if len_str.empty?

  payload = io.read(len_str.to_i)
  return nil if payload.nil? || payload.bytesize < len_str.to_i

  comma = io.read(1)
  return nil unless comma == ','

  payload
end

def write_frame(io, bytes)
  io.write("#{bytes.bytesize}:#{bytes},")
end

def build_result(id, result)
  JSON.generate('jsonrpc' => JSON_RPC_VERSION, 'id' => id, 'result' => result)
end

def build_error(id, code, message)
  JSON.generate('jsonrpc' => JSON_RPC_VERSION, 'id' => id,
                'error' => { 'code' => code, 'message' => message })
end

# Returns the response String, or nil when no response should be sent
# (notifications, i.e. requests without an "id").
def handle(request)
  id = request['id']
  method = request['method']
  params = request['params']
  return nil if id.nil? # notification: no reply

  case method
  when 'echo'
    build_result(id, params)
  when 'add'
    build_result(id, Array(params).sum)
  when 'slow'
    ms = params.is_a?(Hash) ? params['ms'].to_i : 0
    sleep(ms / 1000.0)
    build_result(id, 'ok')
  when 'boom'
    build_error(id, -32_000, 'boom')
  else
    build_error(id, -32_601, "method not found: #{method}")
  end
end

def serve(conn)
  loop do
    raw = read_frame(conn)
    break if raw.nil?

    request = JSON.parse(raw)
    response = handle(request)
    write_frame(conn, response) if response
  end
rescue IOError, Errno::ECONNRESET, Errno::EPIPE
  # client went away
ensure
  begin
    conn.close
  rescue StandardError
    nil
  end
end

server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
$stdout.puts("PORT=#{port}")
$stdout.flush

%w[TERM INT].each { |sig| trap(sig) { exit(0) } }

loop do
  conn = server.accept
  Thread.new(conn) { |c| serve(c) }
end
