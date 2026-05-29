# frozen_string_literal: true

require 'jrpc/transport/base'
require 'jrpc/transport/tcp'

module JRPC
  module Transport
    def self.build(server, **)
      JRPC::Transport::Tcp.new(server, **)
    end
  end
end
