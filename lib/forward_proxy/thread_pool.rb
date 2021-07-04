module ForwardProxy
  class ThreadPool
    attr_reader :queue, :threads, :size

    def initialize(size)
      @size    = size
      @queue   = Queue.new
      @threads = []
    end

    def start
      size.times do
        threads << Thread.new do
          loop do
            job, args = queue.pop
            job.call(*args)
          end
        end
      end
    end

    def schedule(*args, &block)
      queue.push([block, args])
    end
  end
end
