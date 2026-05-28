module JRPC
  class SharedClient
    attr_reader :server

    def initialize(server, **options)
      @server = server
      @write_timeout = options.fetch(:write_timeout, 5)
      @default_ttl = options.fetch(:default_ttl, 30)
      @reap_timeout = options.fetch(:reap_timeout, nil)
      @max_queue_size = options.fetch(:max_queue_size, 10_000)
      @logger = options.fetch(:logger, nil)
      # Single monotonic clock source shared with the transport loop. The
      # :clock option is an internal test seam (deterministic TTL specs);
      # callers should not need it.
      @clock = options.fetch(:clock, nil) || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      if @write_timeout && @default_ttl && @write_timeout >= @default_ttl
        raise ArgumentError, "write_timeout (#{@write_timeout}) must be < default_ttl (#{@default_ttl})"
      end

      @transport = options.fetch(:transport) do
        Transport.build(server, **options)
      end

      @id_gen = options.fetch(:id_gen) do
        IdGenerator.new(prefix: options.fetch(:id_prefix, nil), thread_safe: true)
      end

      @registry = SharedClient::Registry.new
      @outbound_queue = SharedClient::OutboundQueue.new(capacity: @max_queue_size)
      @wake_pipe_reader, @wake_pipe_writer = IO.pipe

      @lifecycle_mutex = Mutex.new
      # :running -> :closing -> :closed   (user-initiated close)
      # :running -> :dead                 (transport thread crashed)
      @status = :running

      shutdown_check = -> { @lifecycle_mutex.synchronize { @status == :closing } }

      @transport_loop = SharedClient::TransportLoop.new(
        transport: @transport,
        registry: @registry,
        outbound_queue: @outbound_queue,
        wake_pipe_reader: @wake_pipe_reader,
        write_timeout: @write_timeout,
        reap_timeout: @reap_timeout,
        logger: @logger,
        shutdown_check: shutdown_check,
        clock: @clock
      )

      @transport_thread = Thread.new do
        @transport_loop.run do |err|
          @lifecycle_mutex.synchronize { @status = :dead }
          drain_all(err)
        end
      end
      @transport_thread.abort_on_exception = false
    end

    def request(method, params = nil, ttl: @default_ttl)
      id = @id_gen.next
      ticket = Ticket.new(
        id: id,
        payload: Message.dump(Message.build_request(method, params, id)),
        thread: Thread.current,
        expires_at: ttl ? clock_now + ttl : nil
      )

      enqueue!(ticket)
      await(ticket, ttl)
    end

    def notification(method, params = nil, ttl: @default_ttl, fire_and_forget: false)
      ticket = Ticket.new(
        id: nil,
        payload: Message.dump(Message.build_notification(method, params)),
        thread: fire_and_forget ? nil : Thread.current,
        expires_at: ttl ? clock_now + ttl : nil
      )

      enqueue!(ticket)
      return nil if fire_and_forget

      await(ticket, ttl)
      nil
    end

    def close(timeout: 5)
      @lifecycle_mutex.synchronize do
        return true if @status == :closed
        @status = :closing
      end

      wake_transport

      joined = @transport_thread.join(timeout)

      unless joined
        @transport.close rescue nil
        @transport_thread.join(1.0)
        @transport_thread.kill if @transport_thread.alive?
        @transport_thread.join
        # Forced kill: the loop never reached its graceful drain, so fail
        # whatever was still in flight. (A graceful exit drained itself; a
        # crash drained via on_crash. reject is idempotent in every case.)
        drain_all(Errors::ConnectionError.new("client force-closed"))
      end

      # Safe now that the transport thread is guaranteed dead.
      @wake_pipe_writer.close rescue nil
      @wake_pipe_reader.close rescue nil

      @lifecycle_mutex.synchronize { @status = :closed }
      !joined.nil?
    end

    def closed?
      @lifecycle_mutex.synchronize { @status == :closed }
    end

    private

    WAIT_GRACE = 1.0 # caller-side backstop beyond the loop-enforced ttl

    def clock_now
      @clock.call
    end

    def enqueue!(ticket)
      @lifecycle_mutex.synchronize do
        case @status
        when :closing, :closed
          raise Errors::ClientError, 'client closed'
        when :dead
          raise Errors::ClientError, 'client unusable: transport thread exited'
        end
        @outbound_queue.push_nonblock(ticket)
        @registry.register(ticket) if ticket.id
      end
      wake_transport
    end

    # Caller side. Blocks thread- and fiber-cooperatively until the loop
    # resolves the ticket, with a real-time backstop in case the loop dies.
    def await(ticket, ttl)
      ticket.wait(ttl ? ttl + WAIT_GRACE : nil)

      if ticket.fulfilled?
        ticket.result
      elsif ticket.rejected?
        raise ticket.error
      else
        raise Errors::Timeout, "request timed out after #{ttl}s"
      end
    ensure
      unless ticket.resolved?
        ticket.cancel
        @registry.delete(ticket)
        @outbound_queue.delete(ticket)
      end
    end

    def drain_all(err)
      @registry.drain_all_with(err)
      @outbound_queue.close_and_drain.each do |ticket|
        next if ticket.thread.nil?
        ticket.reject(err)
      end
    end

    def wake_transport
      @wake_pipe_writer.write_nonblock('.') rescue nil
    end
  end
end
