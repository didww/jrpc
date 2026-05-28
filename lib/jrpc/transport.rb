require 'jrpc/transport/base'
require 'jrpc/transport/tcp'

module JRPC
  module Transport
    def self.build(server, **opts)
      JRPC::Transport::Tcp.new(server, **opts)
    end
  end
end
