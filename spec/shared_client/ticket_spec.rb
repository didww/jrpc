# frozen_string_literal: true

RSpec.describe JRPC::SharedClient::Ticket do
  def make_ticket(id: 'x-1', payload: '{}', thread: Thread.current, expires_at: nil)
    described_class.new(id: id, payload: payload, thread: thread, expires_at: expires_at)
  end

  describe 'initial state' do
    it 'defaults to :pending' do
      expect(make_ticket.state).to eq(:pending)
    end

    it 'has nil result and error' do
      t = make_ticket
      expect(t.result).to be_nil
      expect(t.error).to be_nil
    end

    it 'exposes id, payload, thread, expires_at' do
      thread = Thread.current
      t = described_class.new(id: 'a-1', payload: 'bytes', thread: thread, expires_at: 9.9)
      expect(t.id).to eq('a-1')
      expect(t.payload).to eq('bytes')
      expect(t.thread).to eq(thread)
      expect(t.expires_at).to eq(9.9)
    end
  end

  describe '#alive?' do
    it 'returns true when thread is alive' do
      t = Thread.new { sleep }
      ticket = make_ticket(thread: t)
      expect(ticket.alive?).to be true
      t.kill
    end

    it 'returns false when thread is dead' do
      t = Thread.new { nil }
      t.join
      ticket = make_ticket(thread: t)
      expect(ticket.alive?).to be false
    end

    it 'returns false when thread is nil (fire_and_forget)' do
      expect(make_ticket(thread: nil).alive?).to be false
    end
  end

  describe '#expired?' do
    it 'returns false when expires_at is nil' do
      expect(make_ticket(expires_at: nil).expired?(1000.0)).to be false
    end

    it 'returns true when now >= expires_at' do
      t = make_ticket(expires_at: 10.0)
      expect(t.expired?(10.0)).to be true
      expect(t.expired?(11.0)).to be true
    end

    it 'returns false when now < expires_at' do
      expect(make_ticket(expires_at: 10.0).expired?(9.9)).to be false
    end
  end

  describe '#signal_done' do
    it 'sets state to :done and result' do
      t = make_ticket
      t.signal_done(result: 42)
      expect(t.state).to eq(:done)
      expect(t.result).to eq(42)
    end

    it 'works without a mutex (fire_and_forget)' do
      t = make_ticket(thread: nil)
      t.signal_done(result: 'hi')
      expect(t.state).to eq(:done)
      expect(t.result).to eq('hi')
    end
  end

  describe '#signal_error' do
    it 'sets state to :done and error' do
      t = make_ticket
      err = JRPC::Errors::ConnectionError.new('gone')
      t.signal_error(err)
      expect(t.state).to eq(:done)
      expect(t.error).to be(err)
    end

    it 'works without a mutex (fire_and_forget)' do
      t = make_ticket(thread: nil)
      err = JRPC::Errors::Timeout.new('ttl')
      t.signal_error(err)
      expect(t.state).to eq(:done)
      expect(t.error).to be(err)
    end
  end

  describe '#signal_sent' do
    it 'sets state to :done and signals waiter' do
      t = make_ticket
      t.signal_sent
      expect(t.state).to eq(:done)
    end
  end

  describe '#cancel' do
    it 'sets state to :cancelled' do
      t = make_ticket
      t.cancel
      expect(t.state).to eq(:cancelled)
    end

    it 'works without mutex (fire_and_forget)' do
      t = make_ticket(thread: nil)
      t.cancel
      expect(t.state).to eq(:cancelled)
    end
  end

  describe '#wait' do
    it 'blocks until signal_done is called from another thread' do
      t = make_ticket
      result_seen = nil
      waiter = Thread.new do
        t.wait
        result_seen = t.result
      end
      sleep 0.01
      t.signal_done(result: 99)
      waiter.join(1)
      expect(result_seen).to eq(99)
    end

    it 'blocks until signal_error is called from another thread' do
      t = make_ticket
      waiter = Thread.new { t.wait }
      sleep 0.01
      t.signal_error(JRPC::Errors::Timeout.new('x'))
      waiter.join(1)
      expect(t.state).to eq(:done)
    end

    it 'stays blocked while pending (no resolution, no timeout)' do
      t = make_ticket
      waiter = Thread.new { t.wait }
      sleep 0.01
      expect(waiter).to be_alive
      # clean up
      t.signal_done(result: nil)
      waiter.join(1)
    end

    it 'returns after the given timeout even when never resolved' do
      t = make_ticket
      returned = nil
      waiter = Thread.new do
        t.wait(0.02)
        returned = t.state
      end
      waiter.join(1)
      expect(returned).to eq(:pending)
      expect(t.resolved?).to be false
    end

    it 'cancel does not resolve the future or wake a waiter' do
      t = make_ticket
      waiter = Thread.new { t.wait }
      sleep 0.01
      t.cancel
      sleep 0.01
      expect(waiter).to be_alive
      expect(t.resolved?).to be false
      expect(t.state).to eq(:cancelled)
      # clean up
      t.signal_done(result: nil)
      waiter.join(1)
    end
  end
end
