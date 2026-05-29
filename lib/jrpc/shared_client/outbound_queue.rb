# frozen_string_literal: true

module JRPC
  class SharedClient
    class OutboundQueue
      def initialize(capacity: nil)
        @mutex = Mutex.new
        @arr = []
        @capacity = capacity
        @closed = false
      end

      # Raises ClientError("queue full") or ClientError("queue closed") on failure.
      def push_nonblock(ticket)
        @mutex.synchronize do
          raise Errors::ClientError, 'queue closed' if @closed
          raise Errors::ClientError, 'queue full' if @capacity && @arr.size >= @capacity

          @arr << ticket
        end
      end

      # Returns next Ticket or nil if empty.
      def pop_nonblock
        @mutex.synchronize { @arr.shift }
      end

      # Yields each ticket from a snapshot; does not hold the mutex during the block.
      def each_snapshot(&)
        snapshot = @mutex.synchronize { @arr.dup }
        snapshot.each(&)
      end

      # Removes by object identity. Returns true if removed, false if not found.
      def delete(ticket)
        @mutex.synchronize do
          idx = @arr.index { |t| t.equal?(ticket) }
          return false unless idx

          @arr.delete_at(idx)
          true
        end
      end

      # Returns the earliest expires_at across all queued tickets, or nil.
      def earliest_deadline
        @mutex.synchronize do
          deadlines = @arr.filter_map(&:expires_at)
          deadlines.min
        end
      end

      def empty?
        @mutex.synchronize { @arr.empty? }
      end

      def size
        @mutex.synchronize { @arr.size }
      end

      # Sets closed = true, returns and clears all remaining tickets.
      # Idempotent: returns [] on second call.
      def close_and_drain
        @mutex.synchronize do
          @closed = true
          @arr.slice!(0..)
        end
      end
    end
  end
end
