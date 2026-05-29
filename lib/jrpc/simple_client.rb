# frozen_string_literal: true

module JRPC
  # NOT thread-safe: a SimpleClient instance must not be shared across threads or
  # fibers. It owns a single transport/socket plus an unsynchronized id counter, so
  # concurrent calls would interleave socket reads/writes and corrupt the framing
  # buffer. Use one instance per thread/fiber (or a pool of instances).
  class SimpleClient
    attr_reader :server

    def initialize(server, **options)
      @closed = false
      @server = server
      @read_timeout = options.fetch(:read_timeout, 60)
      @write_timeout = options.fetch(:write_timeout, 60)
      @autoclose = options.fetch(:autoclose, false)
      @logger = options[:logger]
      @transport = options.fetch(:transport) do
        Transport.build(server, **options)
      end
      @id_gen = options.fetch(:id_gen) do
        IdGenerator.new(prefix: options[:id_prefix], thread_safe: false)
      end
    end

    def request(method, params = nil, read_timeout: @read_timeout, write_timeout: @write_timeout)
      raise Errors::ClientError, 'client closed' if @closed

      id = @id_gen.next
      json = Message.dump(Message.build_request(method, params, id))

      with_transport_error_handling do
        connect_if_needed!
        @transport.write_frame(json, timeout: write_timeout)
        raw = @transport.read_frame(timeout: read_timeout)
        response = Message.parse(raw)
        Message.validate_response!(response, id)
        raise Message.error_to_exception(response['error']) if response.key?('error')

        response['result']
      end
    end

    def notification(method, params = nil, write_timeout: @write_timeout)
      raise Errors::ClientError, 'client closed' if @closed

      json = Message.dump(Message.build_notification(method, params))

      with_transport_error_handling do
        connect_if_needed!
        @transport.write_frame(json, timeout: write_timeout)
        nil
      end
    end

    def close
      return true if @closed

      @transport.close
      @closed = true
      true
    end

    def closed?
      @closed
    end

    private

    def connect_if_needed!
      @transport.connect if @transport.closed?
    end

    # Translate transport-level errors into the client's public Errors:: hierarchy and
    # apply the autoclose policy. Shared by request and notification so the mapping and
    # the close-after-each-call rule live in exactly one place.
    def with_transport_error_handling
      yield
    rescue Transport::Base::Timeout => e
      raise Errors::Timeout, e.message
    rescue Transport::Base::ConnectionError => e
      raise Errors::ConnectionError, e.message
    rescue Transport::Base::MalformedFrame => e
      raise Errors::MalformedResponseError, e.message
    ensure
      @transport.close if @autoclose
    end
  end
end
