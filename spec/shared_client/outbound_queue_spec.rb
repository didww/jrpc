RSpec.describe JRPC::SharedClient::OutboundQueue do
  let(:queue) { described_class.new }

  def ticket(id = 'x-1', expires_at: nil)
    JRPC::SharedClient::Ticket.new(id: id, payload: '{}', thread: Thread.current, expires_at: expires_at)
  end

  describe '#push_nonblock / #pop_nonblock' do
    it 'enqueues and dequeues in FIFO order' do
      t1 = ticket('a')
      t2 = ticket('b')
      queue.push_nonblock(t1)
      queue.push_nonblock(t2)
      expect(queue.pop_nonblock).to be(t1)
      expect(queue.pop_nonblock).to be(t2)
    end

    it 'returns nil when empty' do
      expect(queue.pop_nonblock).to be_nil
    end
  end

  describe 'capacity enforcement' do
    it 'raises ClientError when queue is full' do
      q = described_class.new(capacity: 2)
      q.push_nonblock(ticket('a'))
      q.push_nonblock(ticket('b'))
      expect { q.push_nonblock(ticket('c')) }.to raise_error(JRPC::Errors::ClientError, /queue full/)
    end

    it 'allows push after pop frees a slot' do
      q = described_class.new(capacity: 1)
      t = ticket('a')
      q.push_nonblock(t)
      q.pop_nonblock
      expect { q.push_nonblock(ticket('b')) }.not_to raise_error
    end
  end

  describe '#empty? and #size' do
    it 'is empty initially' do
      expect(queue.empty?).to be true
      expect(queue.size).to eq(0)
    end

    it 'reflects contents' do
      queue.push_nonblock(ticket)
      expect(queue.empty?).to be false
      expect(queue.size).to eq(1)
    end
  end

  describe '#delete' do
    it 'removes by object identity and returns true' do
      t = ticket
      queue.push_nonblock(t)
      expect(queue.delete(t)).to be true
      expect(queue.empty?).to be true
    end

    it 'returns false if ticket not present' do
      expect(queue.delete(ticket)).to be false
    end

    it 'only removes the matching object when two tickets compare equal' do
      t1 = ticket('same')
      t2 = ticket('same')
      queue.push_nonblock(t1)
      queue.push_nonblock(t2)
      queue.delete(t1)
      expect(queue.size).to eq(1)
      expect(queue.pop_nonblock).to be(t2)
    end
  end

  describe '#each_snapshot' do
    it 'yields each ticket without holding the mutex during the block' do
      t1 = ticket('a')
      t2 = ticket('b')
      queue.push_nonblock(t1)
      queue.push_nonblock(t2)
      seen = []
      queue.each_snapshot { |t| seen << t }
      expect(seen).to eq([t1, t2])
    end

    it 'works on an empty queue' do
      expect { queue.each_snapshot { } }.not_to raise_error
    end

    it 'snapshot is independent of later deletions' do
      t1 = ticket('a')
      t2 = ticket('b')
      queue.push_nonblock(t1)
      queue.push_nonblock(t2)
      seen = []
      queue.each_snapshot do |t|
        seen << t
        queue.delete(t) if t.equal?(t1)
      end
      expect(seen).to eq([t1, t2])
      expect(queue.size).to eq(1)
    end
  end

  describe '#earliest_deadline' do
    it 'returns nil when queue is empty' do
      expect(queue.earliest_deadline).to be_nil
    end

    it 'returns nil when no ticket has an expires_at' do
      queue.push_nonblock(ticket('a', expires_at: nil))
      expect(queue.earliest_deadline).to be_nil
    end

    it 'returns the minimum expires_at' do
      queue.push_nonblock(ticket('a', expires_at: 100.0))
      queue.push_nonblock(ticket('b', expires_at: 50.0))
      queue.push_nonblock(ticket('c', expires_at: nil))
      expect(queue.earliest_deadline).to eq(50.0)
    end
  end

  describe '#close_and_drain' do
    it 'returns all queued tickets and clears the queue' do
      t1 = ticket('a')
      t2 = ticket('b')
      queue.push_nonblock(t1)
      queue.push_nonblock(t2)
      drained = queue.close_and_drain
      expect(drained).to contain_exactly(t1, t2)
      expect(queue.empty?).to be true
    end

    it 'prevents further pushes after close' do
      queue.close_and_drain
      expect { queue.push_nonblock(ticket) }.to raise_error(JRPC::Errors::ClientError, /queue closed/)
    end

    it 'is idempotent — second call returns []' do
      queue.push_nonblock(ticket)
      queue.close_and_drain
      expect(queue.close_and_drain).to eq([])
    end
  end
end
