# frozen_string_literal: true

require 'socket'

# Helpers for exercising the TCP MD5 Signature (RFC2385) option from specs.
module TcpMd5Helpers
  # The TCP_MD5SIG option number, or nil where the platform lacks it. Read through
  # the transport so a stub_const in one example can't leak into the helpers.
  def md5sig_opt
    JRPC::Transport::Tcp::TCP_MD5SIG
  end

  # Pack a struct tcp_md5sig exactly as the transport does, so the in-test server
  # socket and the transport agree on the wire format.
  def md5sig_blob(sockaddr, key)
    sockaddr.b.ljust(128, "\x00".b) + [0, 0, key.bytesize, 0].pack('CCSL') + key.b.ljust(80, "\x00".b)
  end

  # True only when the running kernel actually accepts a TCP_MD5SIG setsockopt.
  # Both the option and CONFIG_TCP_MD5SIG must be present, so probe rather than guess.
  def tcp_md5_supported?
    return false unless md5sig_opt

    s = Socket.new(:INET, :STREAM, 0)
    s.setsockopt(Socket::IPPROTO_TCP, md5sig_opt, md5sig_blob(Socket.sockaddr_in(0, '127.0.0.1'), 'k'))
    true
  rescue StandardError
    false
  ensure
    s&.close
  end

  # A listening socket that requires the given MD5 key for any 127.0.0.1 peer.
  def md5_server(key)
    srv = Socket.new(:INET, :STREAM, 0)
    srv.setsockopt(:SOL_SOCKET, :SO_REUSEADDR, 1)
    srv.bind(Socket.sockaddr_in(0, '127.0.0.1'))
    srv.setsockopt(Socket::IPPROTO_TCP, md5sig_opt, md5sig_blob(Socket.sockaddr_in(0, '127.0.0.1'), key))
    srv.listen(1)
    srv
  end
end
