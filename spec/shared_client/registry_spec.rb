# frozen_string_literal: true

RSpec.describe JRPC::SharedClient::Registry do
  let(:registry) { described_class.new }

  def ticket(id)
    JRPC::SharedClient::Ticket.new(id: id, payload: '{}', thread: Thread.current)
  end

  describe '#register and #fetch_and_delete' do
    it 'returns the ticket by id and removes it' do
      t = ticket('a-1')
      registry.register(t)
      expect(registry.fetch_and_delete('a-1')).to be(t)
      expect(registry.fetch_and_delete('a-1')).to be_nil
    end

    it 'returns nil for unknown id' do
      expect(registry.fetch_and_delete('nope')).to be_nil
    end
  end

  describe '#delete' do
    it 'removes the ticket by id' do
      t = ticket('b-1')
      registry.register(t)
      registry.delete(t)
      expect(registry.fetch_and_delete('b-1')).to be_nil
    end

    it 'is a no-op for unregistered ticket' do
      t = ticket('b-2')
      expect { registry.delete(t) }.not_to raise_error
    end
  end

  describe '#empty?' do
    it 'is true initially' do
      expect(registry.empty?).to be true
    end

    it 'is false after registering a ticket' do
      registry.register(ticket('c-1'))
      expect(registry.empty?).to be false
    end

    it 'is true after removing all tickets' do
      t = ticket('c-2')
      registry.register(t)
      registry.fetch_and_delete('c-2')
      expect(registry.empty?).to be true
    end
  end

  describe '#each_ticket' do
    it 'yields all registered tickets' do
      t1 = ticket('d-1')
      t2 = ticket('d-2')
      registry.register(t1)
      registry.register(t2)
      seen = []
      registry.each_ticket { |t| seen << t }
      expect(seen).to contain_exactly(t1, t2)
    end

    it 'yields nothing for empty registry' do
      seen = []
      registry.each_ticket { |t| seen << t }
      expect(seen).to be_empty
    end
  end

  describe '#drain_all_with' do
    it 'signals all tickets with the error and clears the registry' do
      t1 = ticket('e-1')
      t2 = ticket('e-2')
      registry.register(t1)
      registry.register(t2)
      err = JRPC::Errors::ConnectionError.new('gone')
      registry.drain_all_with(err)
      expect(registry.empty?).to be true
      expect(t1.state).to eq(:done)
      expect(t1.error).to be(err)
      expect(t2.state).to eq(:done)
      expect(t2.error).to be(err)
    end

    it 'skips tickets already in :done' do
      t = ticket('e-3')
      registry.register(t)
      t.signal_done(result: 1)
      err = JRPC::Errors::ConnectionError.new('gone')
      expect { registry.drain_all_with(err) }.not_to raise_error
      expect(t.error).to be_nil
    end

    it 'skips tickets already in :cancelled' do
      t = ticket('e-4')
      registry.register(t)
      t.cancel
      err = JRPC::Errors::ConnectionError.new('gone')
      expect { registry.drain_all_with(err) }.not_to raise_error
    end

    it 'is idempotent on second call' do
      t = ticket('e-5')
      registry.register(t)
      err = JRPC::Errors::ConnectionError.new('x')
      registry.drain_all_with(err)
      expect { registry.drain_all_with(err) }.not_to raise_error
    end
  end
end
