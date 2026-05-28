module JRPC
  class SharedClient
    class TransportLoop
      SELECT_FLOOR = 60.0

      def initialize(
        transport:, registry:, outbound_queue:, wake_pipe_reader:,
        write_timeout:, reap_timeout:, logger:,
        shutdown_check:,
        clock: nil
      )
        @transport = transport
        @registry = registry
        @outbound_queue = outbound_queue
        @wake_pipe_reader = wake_pipe_reader
        @write_timeout = write_timeout
        @reap_timeout = reap_timeout
        @logger = logger
        @shutdown_check = shutdown_check
        @clock = clock || method(:default_clock)
        @last_rx_at = nil
      end

      # Runs the transport loop. Calls on_crash.(err) on unexpected exception, then returns.
      def run(&on_crash)
        main_loop
      rescue => e
        log_error("transport thread crashed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        err = Errors::ConnectionError.new("transport thread crashed: #{e.class}: #{e.message}")
        on_crash.call(err)
      end

      private

      def clock_now
        @clock.call
      end

      def default_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def shutting_down?
        @shutdown_check.call
      end

      def main_loop
        loop do
          break if shutting_down? && @outbound_queue.empty? && @registry.empty?

          ensure_connected

          ios_read = [@wake_pipe_reader]
          ios_read << @transport.socket unless @transport.closed?
          ios_write = []
          ios_write << @transport.socket if !@transport.closed? && !@outbound_queue.empty?

          timeout = compute_select_timeout
          readable, writable, = IO.select(ios_read, ios_write, [], timeout)

          drain_wake_pipe if readable&.include?(@wake_pipe_reader)
          flush_one_outbound if writable&.include?(@transport.socket)
          consume_inbound if readable&.include?(@transport.socket)

          expire_due_tickets
          sweep_dead_threads
          reap_if_idle
        end
      end

      def ensure_connected
        return unless @transport.closed?
        return if @outbound_queue.empty? && @registry.empty?

        begin
          @transport.connect
          @last_rx_at = clock_now
        rescue Transport::Base::ConnectionError, Transport::Base::Timeout => e
          drain_connection_error("connect failed: #{e.message}")
        end
      end

      def compute_select_timeout
        now = clock_now
        candidates = [SELECT_FLOOR]

        registry_min = nil
        @registry.each_ticket { |t| registry_min = [registry_min || t.expires_at, t.expires_at].min if t.expires_at }
        queue_min = @outbound_queue.earliest_deadline

        [registry_min, queue_min].each do |deadline|
          candidates << [deadline - now, 0].max if deadline
        end

        if @reap_timeout && !@transport.closed? && @outbound_queue.empty? && @registry.empty? && @last_rx_at
          reap_remaining = (@last_rx_at + @reap_timeout) - now
          candidates << [reap_remaining, 0].max
        end

        candidates.min
      end

      def drain_wake_pipe
        loop do
          @wake_pipe_reader.read_nonblock(1024)
        end
      rescue IO::EAGAINWaitReadable, IO::WaitReadable
        # drained
      end

      def flush_one_outbound
        ticket = @outbound_queue.pop_nonblock
        return unless ticket

        return if ticket.cancelled?

        now = clock_now
        if ticket.expired?(now)
          @registry.delete(ticket) if ticket.id
          if ticket.thread.nil?
            log_error("fire_and_forget notification expired before send")
          elsif ticket.alive?
            ticket.reject(Errors::Timeout.new("ttl expired before send"))
          else
            log_error("ticket expired before send; owner gone: #{ticket.id.inspect}")
          end
          return
        end

        begin
          @transport.write_frame(ticket.payload, timeout: @write_timeout)
        rescue Transport::Base::Timeout => e
          err = Errors::Timeout.new("write timeout: #{e.message}")
          signal_or_log(ticket, err)
          drain_connection_error("write timeout; partial frame may have been sent")
          return
        rescue Transport::Base::ConnectionError, Transport::Base::Error => e
          err = Errors::ConnectionError.new(e.message)
          signal_or_log(ticket, err)
          drain_connection_error(e.message)
          return
        end

        # Fire-and-forget notification: nothing more to do.
        return if ticket.thread.nil?

        # Blocking notification (no id): the caller only waits for the send.
        # Request (has id): leave it registered; the response will resolve it.
        ticket.fulfill(nil) if ticket.id.nil?
      end

      def consume_inbound
        loop do
          frame = begin
            @transport.try_read_frame
          rescue Transport::Base::MalformedFrame => e
            log_error("framing error: #{e.message}")
            drain_connection_error("framing corruption; stream resynchronized")
            return
          rescue Transport::Base::ConnectionError, Transport::Base::Error => e
            drain_connection_error(e.message)
            return
          end

          break if frame == :wait

          @last_rx_at = clock_now

          begin
            parsed = Message.parse(frame)
          rescue Errors::MalformedResponseError => e
            log_error("JSON parse error on inbound frame: #{e.message}")
            drain_connection_error("framing corruption; stream resynchronized")
            return
          end

          id = parsed['id']
          if id.nil?
            log_error("server-initiated message received (no id), dropping")
            next
          end

          ticket = @registry.fetch_and_delete(id)
          if ticket.nil?
            log_error("orphan response: id=#{id.inspect}")
            next
          end

          if ticket.cancelled? || !ticket.alive?
            log_error("orphan response: ticket #{id.inspect} cancelled or owner dead")
            next
          end

          begin
            Message.validate_response!(parsed, id)
          rescue Errors::MalformedResponseError => e
            ticket.reject(e)
            next
          end

          if parsed.key?('error')
            ticket.reject(Message.error_to_exception(parsed['error']))
          else
            ticket.fulfill(parsed['result'])
          end
        end
      end

      def expire_due_tickets
        now = clock_now
        expired_ids = []
        @registry.each_ticket { |t| expired_ids << t.id if t.expired?(now) }
        expired_ids.each do |id|
          ticket = @registry.fetch_and_delete(id)
          next unless ticket

          if ticket.alive?
            ticket.reject(Errors::Timeout.new("ttl expired"))
          else
            log_error("expired ticket #{id.inspect} owner thread dead; dropping")
          end
        end

        @outbound_queue.each_snapshot do |ticket|
          next unless ticket.expired?(now)
          @outbound_queue.delete(ticket)
          if ticket.thread.nil?
            log_error("fire_and_forget notification expired in queue")
          elsif ticket.alive?
            ticket.reject(Errors::Timeout.new("ttl expired"))
          else
            log_error("expired queued ticket #{ticket.id.inspect} owner thread dead; dropping")
          end
        end
      end

      def sweep_dead_threads
        dead = []
        @registry.each_ticket { |t| dead << t unless t.alive? }
        dead.each do |ticket|
          @registry.delete(ticket)
          log_error("owner thread dead; dropping in-flight ticket #{ticket.id.inspect}")
        end
      end

      def reap_if_idle
        return unless @reap_timeout
        return if @transport.closed?
        return unless @outbound_queue.empty? && @registry.empty?
        return unless @last_rx_at && (clock_now - @last_rx_at) >= @reap_timeout

        @transport.close
        @last_rx_at = nil
      end

      def drain_connection_error(message)
        @transport.close rescue nil
        err = Errors::ConnectionError.new(message)
        @registry.drain_all_with(err)
        @outbound_queue.each_snapshot do |ticket|
          @outbound_queue.delete(ticket)
          signal_or_log(ticket, err)
        end
        @last_rx_at = nil
      end

      def signal_or_log(ticket, err)
        if ticket.thread
          ticket.reject(err)
        else
          log_error("fire_and_forget send failed: #{err.message}")
        end
      end

      def log_error(msg)
        @logger&.error("[JRPC::SharedClient] #{msg}")
      end
    end
  end
end
