# frozen_string_literal: true

module JRPC
  # Debug-level wire-payload logging shared by the clients. When a `logger` is
  # configured, every request/response payload (the raw JSON netstring body,
  # exactly as written/read) is emitted at DEBUG. Without a logger it is a no-op.
  module PayloadLogging
    SEND_MARK = '>>'
    RECV_MARK = '<<'

    def log_sent(payload)
      @logger&.debug("[#{log_tag}] #{SEND_MARK} #{payload}")
    end

    def log_received(payload)
      @logger&.debug("[#{log_tag}] #{RECV_MARK} #{payload}")
    end
  end
end
