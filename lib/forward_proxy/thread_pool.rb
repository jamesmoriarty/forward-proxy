module ForwardProxy
  class ThreadPool
    attr_reader :queue, :size, :threads

    def initialize(size)
      @queue   = Queue.new
      @size    = size
      @threads = []
    end

    def start
      size.times do
        thread = Thread.new do
          loop do
            job, args = queue.pop
            job.call(*args)
          end
        end

        threads.push(thread)
      end
    end

    def schedule(*args, &block)
      raise "no threads" unless threads.any?(&:alive?)

      queue.push([block, args])
    end
  end
end
