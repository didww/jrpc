# frozen_string_literal: true

require 'logger'
require 'json'
require 'async'

# Fiber-caller matrix for SharedClient (plan §9.8 / §11).
#
# These exercise the load-bearing assumption that a caller blocking in
# ticket.wait under a live Fiber.scheduler YIELDS its OS thread, and that the
# transport thread (a real Thread, NOT on the reactor) can resolve that future
# cross-thread and wake the right fiber. Responses are injected from a plain
# background Thread on purpose: that is the cross-thread unblock under test.
RSpec.describe 'JRPC::SharedClient fiber callers' do
  let(:transport) { FakeSharedTransport.new }

  def build_client(**opts)
    defaults = { transport: transport, id_prefix: 'fiber', write_timeout: 1, default_ttl: 30 }
    JRPC::SharedClient.new('127.0.0.1:1234', **defaults, **opts)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def ok_response(id, result)
    JSON.generate({ 'jsonrpc' => '2.0', 'id' => id, 'result' => result })
  end

  # Background (real) thread that watches the outbound frames and answers each
  # one exactly once, with result = result_for.(parsed_request). Returns the
  # thread so the caller can join it.
  def auto_responder(count:, timeout: 3.0)
    Thread.new do
      seen = {}
      deadline = monotonic + timeout
      until seen.size >= count || monotonic > deadline
        transport.frames_written.dup.each do |frame|
          parsed = JSON.parse(frame)
          id = parsed['id']
          next if id.nil? || seen[id]

          seen[id] = true
          transport.inject_response(ok_response(id, yield(parsed)))
        end
        sleep 0.005
      end
    end
  end

  it 'resolves a request issued from a fiber via cross-thread unblock' do
    client = build_client
    responder = auto_responder(count: 1) { 42 }
    result = nil

    Async do |task|
      task.async { result = client.request(:sum, [1, 2]) }.wait
    end

    responder.join
    expect(result).to eq(42)
    client.close(timeout: 0.5)
  end

  it 'yields the OS thread while a fiber waits, letting other fibers run' do
    client = build_client
    events = []

    Async do |task|
      requester = task.async do
        events << :request_start
        client.request(:slow)
        events << :request_done
      end

      task.async { events << :other_ran }

      # Let the sibling fiber run and the requester park in ticket.wait.
      task.sleep 0.05
      expect(events).to include(:other_ran)
      expect(events).not_to include(:request_done)

      # Now answer it from a real thread and confirm the fiber resumes.
      responder = auto_responder(count: 1) { 1 }
      requester.wait
      responder.join
      expect(events).to include(:request_done)
    end

    client.close(timeout: 0.5)
  end

  it 'serves a thread caller and a fiber caller on one client concurrently' do
    client = build_client
    responder = auto_responder(count: 2) { |req| req['method'] }

    thread_result = nil
    fiber_result = nil

    t = Thread.new { thread_result = client.request(:from_thread) }
    Async do |task|
      task.async { fiber_result = client.request(:from_fiber) }.wait
    end
    t.join(3)
    responder.join

    expect(fiber_result).to eq('from_fiber')
    expect(thread_result).to eq('from_thread')
    client.close(timeout: 0.5)
  end

  it 'handles many concurrent fibers on one reactor without drift or starvation' do
    client = build_client
    n = 100
    responder = auto_responder(count: n) { |req| req['method'] }
    results = {}

    Async do |task|
      tasks = Array.new(n) do |i|
        task.async { results[i] = client.request("m#{i}") }
      end
      tasks.each(&:wait)
    end
    responder.join

    expect(results.size).to eq(n)
    expect(results).to eq((0...n).to_h { |i| [i, "m#{i}"] })
    client.close(timeout: 0.5)
  end

  describe 'cancellation' do
    let(:logger) { instance_double(Logger, error: nil) }

    it 'cancels the ticket and orphans a late response when the fiber is stopped (Task#stop)' do
      client = build_client(logger: logger)

      Async do |task|
        requester = task.async do
          client.request(:slow)
        rescue Async::Stop
          nil # stop unwinds through ticket.wait; await's ensure cleans up
        end

        # Wait until the request is in flight, then stop the fiber mid-wait.
        loop do
          break if transport.frames_written.size >= 1

          task.sleep 0.005
        end
        requester.stop
        requester.wait

        # The ticket must be gone from the registry: a late response is an orphan.
        transport.inject_response(ok_response('fiber-1', 99))
        task.sleep 0.05
      end

      expect(logger).to have_received(:error).with(/orphan response: id=/)
      client.close(timeout: 0.5)
    end

    it 'cancels the ticket when Async with_timeout fires mid-wait' do
      client = build_client(logger: logger)
      raised = nil

      Async do |task|
        child = task.async do |t|
          t.with_timeout(0.05) { client.request(:slow) }
        rescue Async::TimeoutError => e
          raised = e
        end
        child.wait

        transport.inject_response(ok_response('fiber-1', 99))
        task.sleep 0.05
      end

      expect(raised).to be_a(Async::TimeoutError)
      expect(logger).to have_received(:error).with(/orphan response: id=/)
      client.close(timeout: 0.5)
    end
  end
end
