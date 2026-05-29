# frozen_string_literal: true

require 'securerandom'

module JRPC
  class IdGenerator
    def initialize(prefix: nil, thread_safe: false)
      @prefix = prefix || SecureRandom.hex(8)
      @n = 0
      @mutex = thread_safe ? Mutex.new : nil
    end

    def next
      n = if @mutex
            @mutex.synchronize { @n += 1 }
          else
            @n += 1
          end
      "#{@prefix}-#{n}"
    end
  end
end
