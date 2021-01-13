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
        catch(:exit) do
          loop do
            job, args = queue.pop
            job.call(*args)
          end
        end
      end
    end
  end

  def schedule(*args, &block)
    queue.push([block, args])
  end

  def shutdown
    threads.each do
      schedule { throw :exit }
    end

    threads.each(&:join)
  end
end
