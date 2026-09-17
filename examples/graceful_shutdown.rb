# frozen_string_literal: true

# Shut down cooperatively when a signal arrives.
#
# Do not touch ports from inside a trap handler; call stop from a thread instead.
#
#   ruby examples/graceful_shutdown.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

class Poller
  include RactorShepherd::Worker

  def initialize(interval)
    super()
    @interval = interval
  end

  def run(ctx)
    ctx.emit(:polling)
    ctx.sleep(@interval) until ctx.shutdown_requested?
  end

  def terminate(reason)
    # Clean up here. reason is :normal, :shutdown, or the exception that killed the worker.
  end
end

events = Ractor::Port.new
RactorShepherd::EventLogger.start(events)

sup = RactorShepherd.start(name: :root, event_port: events,
                           children: [RactorShepherd.worker(:poller, Poller, args: [0.1])])

stopped = Thread::Queue.new
%w[INT TERM].each do |signal|
  Signal.trap(signal) do
    # Do as little as possible inside a trap handler.
    Thread.new do
      sup.stop(:shutdown, timeout: 10)
      stopped << true
    end
  end
end

puts "running; send SIGINT to stop"
Process.kill("INT", Process.pid) # send it to ourselves, so the example finishes
stopped.pop
puts "stopped cleanly; alive? = #{sup.alive?}"
