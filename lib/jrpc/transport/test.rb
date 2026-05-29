# frozen_string_literal: true

# An in-process transport double for testing code that uses JRPC, without a real
# TCP server. NOT required by default — require it explicitly from your test setup:
#
#   require 'jrpc/transport/test'
#
# Then inject it via the `transport:` option of either client:
#
#   transport = JRPC::Transport::Test.new
#   transport.on('sum') { |params| params['a'] + params['b'] }
#   client = JRPC::SimpleClient.new('test', transport: transport)
#   client.request('sum', { 'a' => 1, 'b' => 2 }) # => 3
#   transport.last_request # => { 'jsonrpc' => '2.0', 'method' => 'sum', ... }
#
# Two scripting mechanisms, both feeding a single FIFO inbound queue:
#
#   * Handlers (`on`): the primary, high-level API. When the client writes a
#     request, the matching handler runs and its return value is encoded as a
#     JSON-RPC result response echoing the request id. A handler may instead raise:
#       - a JRPC::Errors::ServerError (or subclass) -> encoded as an error response
#         (its #code, or -32000 if nil/absent);
#       - a transport error (ConnectionError / Timeout / MalformedFrame) -> raised
#         when the client reads the response, simulating a socket-level failure.
#   * Raw frames (`push_response` / `push_raise`): the low-level escape hatch for
#     testing malformed responses, id mismatches, and orphan/unsolicited frames,
#     where you control the literal bytes the client reads.
#
# In `strict` mode (the default) a request whose method has no handler raises
# UnexpectedRequest at write time, so a missing stub fails loudly instead of
# hanging. Set `strict: false` to drive reads purely via push_response/push_raise.
require 'jrpc'
require 'socket'
require 'monitor'
require 'json'

module JRPC
  module Transport
    class Test < Base
      # Resolve `raise ConnectionError`-style names to the transport hierarchy the
      # clients rescue, mirroring Tcp (otherwise constant lookup finds JRPC::* v1).
      ConnectionError = Base::ConnectionError
      Timeout = Base::Timeout
      MalformedFrame = Base::MalformedFrame

      # Raised at write time when a request arrives for a method with no registered
      # handler and strict mode is on. A test-harness assertion, not a transport
      # condition, so it is deliberately outside the Base::Error hierarchy: it
      # propagates raw to your test (via SimpleClient) instead of being swallowed
      # and remapped to a generic ConnectionError.
      class UnexpectedRequest < StandardError; end

      # GC backstop: release the socketpair FDs if a transport is dropped without an
      # explicit #shutdown. Returns a proc that captures only the two IOs, never self.
      def self.finalizer(io, signal)
        proc do
          [io, signal].each do |sock|
            sock.close
          rescue StandardError
            nil
          end
        end
      end

      def initialize(server = 'test', **options)
        super
        @strict = options.fetch(:strict, true)
        @mon = Monitor.new
        @handlers = {}
        @inbound = []       # FIFO of [:frame, String] | [:raise, Exception]
        @sent = []          # raw payload strings exactly as the client wrote them
        @requests = []      # parsed request envelopes (Hash) in write order
        @notifications = [] # parsed notification envelopes (Hash) in write order
        @open = false
        @io = nil
        @signal = nil
        @fail_connect = nil
      end

      # --- Scripting API (called from your test thread) ---------------------------

      # Register a handler for +method+. The block receives the request params
      # (Array, Hash, or nil) and its return value becomes the JSON-RPC result.
      def on(method, &block)
        raise ArgumentError, 'on requires a block' unless block

        @mon.synchronize { @handlers[method.to_s] = block }
        self
      end

      # Enqueue a literal inbound frame. Accepts a JSON String (used verbatim, so it
      # may be intentionally malformed) or a Hash (serialized with JSON.generate).
      def push_response(frame)
        payload = frame.is_a?(String) ? frame : JSON.generate(frame)
        enqueue([:frame, payload])
        self
      end

      # Enqueue an error to be raised on the client's next read, simulating a
      # socket-level failure mid-stream. Pass a transport error for realistic
      # behavior (e.g. JRPC::Transport::Base::ConnectionError.new('reset')).
      def push_raise(error)
        enqueue([:raise, error])
        self
      end

      # Arm #connect to raise +error+ on every attempt until cleared by #reset.
      # Defaults to a ConnectionError so SharedClient's loop treats it as a normal
      # connect failure (drained), rather than a crash.
      def fail_connect(error = ConnectionError.new('connect failed'))
        @mon.synchronize { @fail_connect = error }
        self
      end

      # Clear recordings, the inbound queue, and any armed connect failure. Keeps
      # registered handlers so a transport can be reused across examples.
      def reset
        @mon.synchronize do
          @inbound.clear
          @sent.clear
          @requests.clear
          @notifications.clear
          @fail_connect = nil
          drain_signal
        end
        self
      end

      def sent          = @mon.synchronize { @sent.dup }
      def requests      = @mon.synchronize { @requests.dup }
      def notifications = @mon.synchronize { @notifications.dup }
      def last_request  = @mon.synchronize { @requests.last }

      # Close the socketpair FDs. Idempotent. Call from an after-hook for
      # deterministic FD cleanup; otherwise the GC finalizer reclaims them.
      def shutdown
        @mon.synchronize do
          @open = false
          [@io, @signal].each do |sock|
            sock&.close
          rescue StandardError
            nil
          end
          @io = nil
          @signal = nil
        end
      end

      # --- Transport interface (called from the client / SharedClient loop) -------

      def connect
        @mon.synchronize do
          raise @fail_connect if @fail_connect

          open_socketpair if @io.nil?
          @open = true
        end
      end

      # closed? tracks the logical open flag, not the FD: #close keeps the socketpair
      # alive (so a concurrent IO.select in SharedClient's loop is never yanked) and
      # only flips the flag, mirroring the proven spec helper.
      def closed?
        @mon.synchronize { !@open }
      end

      def socket
        @mon.synchronize { @open ? @io : nil }
      end

      def write_frame(bytes, **)
        @mon.synchronize do
          raise ConnectionError, 'transport closed' if closed_unlocked?

          @sent << bytes
          envelope = JSON.parse(bytes)
          if envelope.key?('id')
            handle_request(envelope)
          else
            handle_notification(envelope)
          end
        end
      end

      def read_frame(**)
        @mon.synchronize do
          raise ConnectionError, 'transport closed' if closed_unlocked?

          entry = pop_inbound
          raise Timeout, 'read_frame: no scripted response available' if entry.nil?

          deliver(entry)
        end
      end

      def try_read_frame
        @mon.synchronize do
          raise ConnectionError, 'transport closed' if closed_unlocked?

          entry = pop_inbound
          if entry.nil?
            drain_signal
            return :wait
          end

          deliver(entry)
        end
      end

      def close
        @mon.synchronize do
          @open = false
          @inbound.clear
          # Wake a loop blocked in IO.select so it re-checks closed? promptly.
          signal_readable
          true
        end
      end

      private

      def closed_unlocked?
        !@open
      end

      def open_socketpair
        # A bidirectional UNIX socketpair: @io (returned by #socket) stays writable
        # while its send buffer has room, and becomes readable when we write a wake
        # byte to @signal. SharedClient's loop selects on it for both directions;
        # IO.pipe would not work (its read end is never writable, so the loop would
        # never flush). Linux/macOS only.
        @io, @signal = ::Socket.socketpair(:UNIX, :STREAM, 0)
        # Drop any prior finalizer (from an earlier connect/shutdown cycle) before
        # registering the new one, so they don't accumulate on a reused instance.
        ObjectSpace.undefine_finalizer(self)
        ObjectSpace.define_finalizer(self, self.class.finalizer(@io, @signal))
      end

      def handle_request(envelope)
        @requests << envelope
        method = envelope['method']
        handler = @handlers[method]
        if handler
          run_request_handler(envelope['id'], envelope['params'], handler)
        elsif @strict
          raise UnexpectedRequest,
                "JRPC::Transport::Test: no handler for request #{method.inspect}; " \
                "register one with `transport.on(#{method.inspect}) { ... }`, " \
                'queue a frame with push_response, or set strict: false'
        end
        # non-strict + no handler: reads are driven entirely by push_response/push_raise.
      end

      def run_request_handler(id, params, handler)
        result = handler.call(params)
        enqueue([:frame, result_response(id, result)])
      rescue Errors::ServerError => e
        enqueue([:frame, error_response(id, e)])
      rescue Base::Error => e
        # Transport-level failure (ConnectionError/Timeout/MalformedFrame): surface it
        # when the client reads the response, simulating a mid-stream socket error.
        enqueue([:raise, e])
      end

      def handle_notification(envelope)
        @notifications << envelope
        handler = @handlers[envelope['method']]
        return unless handler

        begin
          handler.call(envelope['params'])
        rescue Base::Error
          # Simulate a send-time socket failure; surfaces through write_frame.
          raise
        rescue Errors::ServerError
          # Notifications have no response channel, so a server error is meaningless.
          nil
        end
      end

      def result_response(id, result)
        JSON.generate({ 'jsonrpc' => JRPC::JSON_RPC_VERSION, 'id' => id, 'result' => result })
      end

      def error_response(id, error)
        code = error.respond_to?(:code) && error.code.is_a?(Integer) ? error.code : -32_000
        JSON.generate(
          { 'jsonrpc' => JRPC::JSON_RPC_VERSION, 'id' => id,
            'error' => { 'code' => code, 'message' => error.message } }
        )
      end

      def enqueue(entry)
        @mon.synchronize do
          @inbound << entry
          signal_readable
        end
      end

      def pop_inbound
        @inbound.shift
      end

      def deliver(entry)
        type, value = entry
        case type
        when :raise then raise value
        when :frame then value
        end
      end

      # Make @io readable so a loop blocked in IO.select wakes. Best-effort: a full
      # buffer just means the socket is already readable, so swallow any error.
      def signal_readable
        return if @signal.nil?

        @signal.write_nonblock('.')
      rescue StandardError
        nil
      end

      # Drain accumulated wake bytes so @io stops selecting readable once the inbound
      # queue is empty, preventing the loop from spinning.
      def drain_signal
        return if @io.nil?

        loop { @io.read_nonblock(4096) }
      rescue IO::WaitReadable, IOError
        nil
      end
    end
  end
end
