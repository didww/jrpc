require 'net/tcp_client'
require 'netstring'
module JRPC
  class SafeTcpClient < TcpClient

    def initialize(uri, options = {})
      super uri, options.merge(connect_on_initialize: false)
    end

    private

    def send_command(request)
      super
    ensure
      close
    end

    def send_notification(request)
      super
    ensure
      close
    end

  end
end
