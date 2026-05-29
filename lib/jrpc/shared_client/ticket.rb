# frozen_string_literal: true

require 'concurrent'

module JRPC
  class SharedClient
    # One in-flight request or notification together with its result future.
    #
    # The result is backed by a write-once Concurrent::Promises.resolvable_future.
    # That single primitive replaces the old hand-rolled Mutex+ConditionVariable
    # state machine and gives us three things for free:
    #
    #   * idempotent resolution  - fulfill/reject never raise on a second call,
    #     so the transport loop and the close path can both resolve a ticket
    #     without racing (fixes the old :cancelled -> :done overwrite).
    #   * a caller-side timeout   - #wait takes a timeout, so a caller is no
    #     longer at the mercy of the loop thread to be woken (fixes the
    #     "loop dies, callers hang forever" hole).
    #   * fiber cooperation       - the future's wait bottoms out in a
    #     scheduler-aware ConditionVariable, so blocking a fiber under Falcon /
    #     rage-rb yields to the reactor instead of stalling the thread.
    #
    # `cancelled` is a separate monotonic flag (the caller gave up); it is
    # deliberately NOT part of the future, so cancellation can never race or
    # overwrite a real result.
    class Ticket
      attr_reader :id, :payload, :thread, :expires_at

      def initialize(id:, payload:, thread:, expires_at: nil)
        @id = id
        @payload = payload
        @thread = thread
        @expires_at = expires_at
        @future = Concurrent::Promises.resolvable_future
        @cancelled = Concurrent::AtomicBoolean.new(false)
      end

      # --- caller side -------------------------------------------------------

      # Block until resolved or `timeout` seconds elapse (nil waits forever).
      # Cooperates with the fiber scheduler. Returns self; inspect afterwards.
      def wait(timeout = nil)
        @future.wait(timeout)
        self
      end

      def resolved? = @future.resolved?
      def fulfilled? = @future.fulfilled?
      def rejected? = @future.rejected?
      def result = @future.fulfilled? ? @future.value : nil
      def error = @future.rejected? ? @future.reason : nil

      def cancel = @cancelled.make_true
      def cancelled? = @cancelled.true?

      # --- worker (transport loop / close) side ------------------------------
      # All idempotent: the first resolution wins, later ones are no-ops.

      def fulfill(value) = @future.fulfill(value, false)
      def reject(err) = @future.reject(err, false)

      # Resolution aliases used by Registry/OutboundQueue and the transport loop.
      def signal_done(result:) = fulfill(result)
      def signal_error(err) = reject(err)
      # blocking notification: caller waits only for the send
      def signal_sent = fulfill(nil)

      # Coarse state view kept for Registry, which skips already-settled tickets.
      def state
        return :cancelled if cancelled?
        return :done if resolved?

        :pending
      end

      # --- misc --------------------------------------------------------------

      # fire_and_forget tickets (thread: nil) are never "alive".
      def alive? = @thread.nil? ? false : @thread.alive?

      def expired?(now) = @expires_at ? now >= @expires_at : false
    end
  end
end
