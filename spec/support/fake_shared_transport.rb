# frozen_string_literal: true

require 'socket'

# Fake transport backed by a UNIXSocket pair.
# socket_a is exposed as transport.socket — it is BOTH readable (when socket_b writes)
# AND writable (send buffer not full), so IO.select works correctly for both read and write.
# try_read_frame pulls from an in-memory queue; inject_response writes one byte to socket_b
# to wake IO.select, then try_read_frame pops the frame and drains the wakeup byte.
class FakeSharedTransport
  # Track live instances so the suite can close their UNIXSocket pairs after each
  # example. Without this the FDs leak (a new instance is created per example and
  # nothing closes the sockets), eventually hitting ulimit -n on some environments.
  @instances_mutex = Mutex.new
  @instances = []

  class << self
    attr_reader :instances_mutex, :instances

    def close_all
      instances_mutex.synchronize do
        instances.each(&:shutdown)
        instances.clear
      end
    end
  end

  attr_reader :frames_written, :connects, :closes

  def initialize
    @closed = true
    @frames_written = []
    @connects = 0
    @closes = 0
    @response_mutex = Mutex.new
    @response_queue = []
    @socket_a, @socket_b = UNIXSocket.pair
    @connect_error = nil
    @write_error = nil
    @read_error = nil
    self.class.instances_mutex.synchronize { self.class.instances << self }
  end

  # Close the underlying socket pair. Idempotent; safe to call more than once.
  def shutdown
    [@socket_a, @socket_b].each do |s|
      s.close unless s.closed?
    rescue StandardError
      nil
    end
  end

  def connect
    raise @connect_error if @connect_error

    @connects += 1
    @closed = false
  end

  def closed? = @closed

  def socket
    @closed ? nil : @socket_a
  end

  def write_frame(bytes, **)
    raise @write_error if @write_error

    @frames_written << bytes
  end

  def try_read_frame
    err = @response_mutex.synchronize do
      e = @read_error
      @read_error = nil
      e
    end
    raise err if err

    result = @response_mutex.synchronize { @response_queue.shift }
    if result
      result
    else
      # drain wakeup bytes written by inject_response / close
      begin
        loop { @socket_a.read_nonblock(1024) }
      rescue IO::WaitReadable, IOError
        nil
      end
      :wait
    end
  end

  def close
    @closes += 1
    @closed = true
    # write a byte to socket_b to make socket_a readable, waking IO.select
    begin
      @socket_b.write_nonblock('.')
    rescue StandardError
      nil
    end
  end

  def inject_response(json)
    @response_mutex.synchronize { @response_queue << json }
    begin
      @socket_b.write_nonblock('.')
    rescue StandardError
      nil
    end
  end

  def fail_on_connect(err) = @connect_error = err
  def fail_on_write(err) = @write_error = err

  # Arm the next try_read_frame to raise `err` (then clear), and wake IO.select
  # by making socket_a readable so consume_inbound runs promptly.
  def fail_on_read(err)
    @response_mutex.synchronize { @read_error = err }
    begin
      @socket_b.write_nonblock('.')
    rescue StandardError
      nil
    end
  end
end

RSpec.configure do |config|
  config.after { FakeSharedTransport.close_all }
end
