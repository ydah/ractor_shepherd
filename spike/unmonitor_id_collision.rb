# frozen_string_literal: true
# spike/unmonitor_id_collision.rb
#
# Ruby 4.0.6's Ractor#unmonitor looks a monitor registration up by port id alone
# and ignores which Ractor created the port. Port ids are a per Ractor sequence, so
# when another Ractor is monitoring the same target, unmonitor drops its
# registration too.
#
# Expected output:
#   collision=false ... watcher_notified=true
#   collision=true  ... watcher_notified=false   <- the bug
#
# Because of this, ractor_shepherd never calls unmonitor.
Warning[:experimental] = false
require "timeout"

def probe(force_collision)
  reply = Ractor::Port.new              # create the caller's port first, to fix its id
  target_id = Integer(reply.inspect[/id:(\d+)/, 1])
  wanted = force_collision ? target_id : target_id + 1

  result = Ractor::Port.new
  child = Ractor.new(name: "child") do
    Thread.current.report_on_exception = false
    Ractor.receive
    raise "x"
  end

  Ractor.new(child, result, wanted, name: "watcher") do |c, out, want|
    port = Ractor::Port.new
    port = Ractor::Port.new while Integer(port.inspect[/id:(\d+)/, 1]) < want
    c.monitor(port)
    out << port.inspect
    _p, msg = Ractor.select(port)
    out << [:saw, msg]
  end
  watcher_port = result.receive

  child.monitor(reply)
  child.unmonitor(reply)
  child.send(:go)

  notified = begin
    Timeout.timeout(2) { result.receive; true }
  rescue Timeout::Error
    false
  end
  puts format("collision=%-5s watcher=%-26s main=%-26s watcher_notified=%s",
              force_collision, watcher_port, reply.inspect, notified)
end

probe(false)
probe(true)
