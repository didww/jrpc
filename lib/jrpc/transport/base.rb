# frozen_string_literal: true

module JRPC
  module Transport
    class Base
      class Error < StandardError; end

      class ConnectionError < Error; end

      class Timeout < Error; end

      class MalformedFrame < Error; end

      def initialize(server, **options)
        @server = server
        # connect_timeout: total wall-clock budget for the whole connect (across retries).
        # connect_attempt_timeout: cap on a single connect attempt; nil means a single
        # attempt is bounded only by whatever is left of connect_timeout.
        @connect_timeout = options.fetch(:connect_timeout, 60)
        @connect_attempt_timeout = options.fetch(:connect_attempt_timeout, nil)
        @connect_retry_count = options.fetch(:connect_retry_count, 0)
        @connect_retry_interval = options.fetch(:connect_retry_interval, 0.5)
        @write_timeout = options.fetch(:write_timeout, nil)
        # Optional RFC2385 TCP MD5 Signature key. nil disables it. When set, the
        # transport installs it on the socket before connect (Linux-only). See Tcp.
        @tcp_md5_pass = options.fetch(:tcp_md5_pass, nil)
      end

      # Abstract interface. Subclasses must implement every method below; the bodies
      # only exist to fail loudly if one is forgotten, so they carry no logic worth
      # covering and are excluded from coverage via :nocov:.
      # :nocov:
      def connect
        raise NotImplementedError
      end

      def write_frame(bytes, timeout:)
        raise NotImplementedError
      end

      def read_frame(timeout:)
        raise NotImplementedError
      end

      def try_read_frame
        raise NotImplementedError
      end

      def close
        raise NotImplementedError
      end

      def closed?
        raise NotImplementedError
      end

      def socket
        raise NotImplementedError
      end
      # :nocov:
    end
  end
end
