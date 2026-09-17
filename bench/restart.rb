# frozen_string_literal: true

# Measure boot, stop and per-restart time as the number of children grows.
#
#   ruby bench/restart.rb [10,100,1000]

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

SIZES = (ARGV[0] || "10,100,1000").split(",").map { |s| Integer(s) }
RESTARTS = Integer(ENV.fetch("RESTARTS", 20))

class Idle
  include RactorShepherd::Worker

  def run(ctx)
    while true
      case ctx.receive
      in :crash then raise "boom"
      else nil
      end
    end
  end
end

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def measure
  started = clock
  yield
  clock - started
end

puts format("%-8s %10s %10s %14s", "children", "boot(s)", "stop(s)", "restart(ms)")
SIZES.each do |size|
  children = Array.new(size) { |i| RactorShepherd.worker(i, Idle) }
  events = Ractor::Port.new
  sup = nil
  boot = measure do
    sup = RactorShepherd.start(name: :bench, children: children,
                               max_restarts: RESTARTS * 2, max_seconds: 600, event_port: events)
  end

  # Kill one child and time how long it takes for a different Ractor to show up.
  total = measure do
    RESTARTS.times do
      target = sup.whereis(0)
      target.send(:crash)
      sleep 0 while sup.whereis(0).equal?(target)
    end
  end

  stop = measure { sup.stop(:shutdown, timeout: 120) }
  puts format("%-8d %10.3f %10.3f %14.3f", size, boot, stop, (total / RESTARTS) * 1000)
end
