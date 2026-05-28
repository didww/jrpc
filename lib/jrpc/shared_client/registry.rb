module JRPC
  class SharedClient
    class Registry
      def initialize
        @mutex = Mutex.new
        @tickets = {}
      end

      def register(ticket)
        @mutex.synchronize { @tickets[ticket.id] = ticket }
      end

      def fetch_and_delete(id)
        @mutex.synchronize { @tickets.delete(id) }
      end

      def delete(ticket)
        @mutex.synchronize { @tickets.delete(ticket.id) }
      end

      # Yields each ticket while holding the registry mutex. Block must be quick — no I/O.
      def each_ticket(&blk)
        @mutex.synchronize { @tickets.each_value(&blk) }
      end

      # Signals every ticket with error and clears the registry atomically.
      # Idempotent: tickets already in :done/:cancelled are skipped.
      def drain_all_with(error)
        tickets = @mutex.synchronize { @tickets.values.tap { @tickets.clear } }
        tickets.each do |ticket|
          next if ticket.state == :done || ticket.state == :cancelled
          ticket.signal_error(error)
        end
      end

      def empty?
        @mutex.synchronize { @tickets.empty? }
      end
    end
  end
end
