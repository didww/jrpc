RSpec.describe JRPC::IdGenerator do
  describe 'single-threaded (thread_safe: false)' do
    subject(:gen) { JRPC::IdGenerator.new(thread_safe: false) }

    it 'generates sequential ids' do
      id1 = gen.next
      id2 = gen.next
      prefix1, _, n1 = id1.rpartition('-')
      prefix2, _, n2 = id2.rpartition('-')
      expect(n1.to_i).to eq(1)
      expect(n2.to_i).to eq(2)
      expect(prefix1).to eq(prefix2)
    end

    it 'uses the provided prefix' do
      g = JRPC::IdGenerator.new(prefix: 'myprefix', thread_safe: false)
      expect(g.next).to eq('myprefix-1')
      expect(g.next).to eq('myprefix-2')
    end

    it 'auto-generates a 16-hex-char prefix' do
      prefix, = gen.next.rpartition('-')
      expect(prefix).to match(/\A[0-9a-f]{16}\z/)
    end

    it 'two generators have different prefixes by default' do
      g1 = JRPC::IdGenerator.new
      g2 = JRPC::IdGenerator.new
      p1, = g1.next.rpartition('-')
      p2, = g2.next.rpartition('-')
      expect(p1).not_to eq(p2)
    end
  end

  describe 'thread-safe (thread_safe: true)' do
    subject(:gen) { JRPC::IdGenerator.new(thread_safe: true) }

    it 'generates monotonically increasing ids in a single thread' do
      ids = 100.times.map { gen.next }
      counters = ids.map { |id| id.split('-').last.to_i }
      expect(counters).to eq((1..100).to_a)
    end

    # This test verifies both uniqueness and correct value capture under the lock.
    # On MRI the GIL makes races invisible — run this suite on JRuby/TruffleRuby too
    # (see §6 of the plan) to exercise true parallelism.
    it 'produces distinct ids across concurrent threads' do
      threads_n    = 50
      per_thread   = 200
      collected    = Mutex.new
      all_ids      = []

      threads = threads_n.times.map do
        Thread.new do
          local = per_thread.times.map { gen.next }
          collected.synchronize { all_ids.concat(local) }
        end
      end
      threads.each(&:join)

      expect(all_ids.size).to eq(threads_n * per_thread)
      expect(all_ids.uniq.size).to eq(all_ids.size), 'duplicate ids detected'
    end
  end
end
