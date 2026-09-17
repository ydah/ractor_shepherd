# frozen_string_literal: true

# Subscribe to events yourself and report why a child died.
#
#   ruby examples/crash_report.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

class Flaky
  include RactorShepherd::Worker

  def run(ctx)
    ctx.emit(:started)
    ctx.receive
    raise ArgumentError, "something went wrong"
  end
end

events = Ractor::Port.new
sup = RactorShepherd.start(name: :root, event_port: events, max_restarts: 1, max_seconds: 60,
                           children: [RactorShepherd.worker(:flaky, Flaky)])

# Poke it again after each crash. Once the supervisor gives up, this raises SupervisorDown.
def poke(sup)
  sup.whereis(:flaky)&.send(:go)
rescue RactorShepherd::SupervisorDown, Ractor::ClosedError
  nil
end

poke(sup)

# With max_restarts: 1, the second crash takes the supervisor down with it.
while (event = events.receive)
  case event[:type]
  when :child_exited
    puts "#{event[:child]} exited: #{event[:error_class]}: #{event[:error_message]}"
    puts "  hint: #{event[:hint]}" if event[:hint]
    puts "  at:   #{event[:backtrace]&.first}"
    poke(sup)
  when :max_restarts_exceeded
    puts "giving up: #{event[:restarts]} restarts in #{event[:max_seconds]}s"
  when :supervisor_stopped
    puts "supervisor stopped: #{event[:reason]}"
    break
  end
end

begin
  sup.join
rescue RactorShepherd::SupervisorCrashed => e
  puts "root crashed: #{e.cause.class}"
  # A real application would log this and exit(1), leaving systemd or Kubernetes
  # to restart the process.
end
