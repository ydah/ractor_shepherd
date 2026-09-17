# frozen_string_literal: true

# one_for_one: only the child that died is replaced.
#
#   ruby examples/basic.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

class Counter
  include RactorShepherd::Server

  def initialize(start = 0)
    super()
    @count = start
  end

  def handle_call(message)
    case message
    in :get then @count
    end
  end

  def handle_cast(message)
    case message
    in [:add, n] then @count += n
    in :crash then raise "boom"
    end
  end
end

events = Ractor::Port.new
RactorShepherd::EventLogger.start(events)

RactorShepherd.run(name: :root, strategy: :one_for_one, max_restarts: 3, max_seconds: 5,
                   event_port: events,
                   children: [RactorShepherd.worker(:counter, Counter, args: [0])]) do |sup|
  counter = sup.lookup(:counter)
  counter.cast([:add, 2])
  puts "count = #{counter.call(:get, timeout: 5)}"

  crashed = counter.ractor
  counter.cast(:crash) # it dies, and is restarted with its state back at zero

  # Wait for the restart to finish, which is when a different Ractor shows up.
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  while sup.whereis(:counter).equal?(crashed)
    raise "restart did not happen" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.05
  end

  puts "count after restart = #{counter.resolve! && counter.call(:get, timeout: 5)}"
  puts "children = #{sup.which_children.map { |c| [c.id, c.status, c.restart_count] }.inspect}"
end
