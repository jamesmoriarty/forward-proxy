module ForwardProxy
  class ThreadPool
    attr_reader :queue, :size

    def initialize(size)
      @size  = size
      @queue = Queue.new
    end

    def start
      size.times do
        Thread.new do
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
