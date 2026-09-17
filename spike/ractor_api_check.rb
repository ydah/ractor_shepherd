# frozen_string_literal: true
# spike/ractor_api_check.rb
Warning[:experimental] = false

def check(name)
  result = yield
  puts "OK   #{name}: #{result.inspect}"
rescue Exception => e
  puts "FAIL #{name}: #{e.class}: #{e.message}"
end

class MyErr < StandardError; end
class E2 < StandardError
  attr_reader :id
  def initialize(id) = (@id = id; super("x #{id}"))
end
Spec = Data.define(:id, :klass, :args)
class W; def run(x) = x * 2; end

check("F1 monitor exited") { r = Ractor.new { 1 }; p = Ractor::Port.new; r.monitor(p); p.receive }
check("F1 monitor aborted") do
  r = Ractor.new { Thread.current.report_on_exception = false; raise MyErr, "boom" }
  p = Ractor::Port.new; r.monitor(p); p.receive
end
check("F3 monitor on terminated") { r = Ractor.new { 1 }; r.join; pt = Ractor::Port.new; [r.monitor(pt), pt.receive] }
check("F4 value cause") do
  r = Ractor.new { Thread.current.report_on_exception = false; raise E2.new(:kid) }
  begin; r.value; rescue Ractor::RemoteError => e; [e.cause.class, e.cause.id]; end
end
check("F5 value twice same ractor") { r = Ractor.new { 42 }; [r.value, r.value] }
check("F5 value taken by other ractor") do
  r = Ractor.new { sleep 0.1; 42 }
  o = Ractor.new(r) { |t| t.value }
  sleep 0.3
  [o.value, (r.value rescue $!.class)]
end
check("F6 send to terminated ractor") { r = Ractor.new { 1 }; r.join; begin; r.send(1); :no_error; rescue => e; e.class; end }
check("F6 send to port of terminated") { pt = Ractor.new { Ractor::Port.new }.value; begin; pt << 1; :no_error; rescue => e; e.class; end }
check("F7 ClosedError ancestors") { Ractor::ClosedError.ancestors.take(3) }
check("F8 forced kill api") { Ractor.instance_methods.grep(/kill|close|take/) }
check("F10 Port#receive params") { Ractor::Port.instance_method(:receive).parameters }
check("F11 select identity") do
  a = Ractor::Port.new; b = Ractor::Port.new
  Ractor.new(b) { |bb| bb << :hi }
  pt, m = Ractor.select(a, b); [pt.equal?(b), m]
end
check("F12 thread sends to own default port") { Ractor.new { Thread.new { sleep 0.05; Ractor.current.send(:t) }; Ractor.receive }.value }
check("F13 ractor ends while thread sleeps") { r = Ractor.new { Thread.new { sleep 100 }; :done }; t = Time.now; [r.value, (Time.now - t) < 1] }
check("F14 nested Ractor.new") { Ractor.new { Ractor.new { :inner }.value }.value }
check("F15 shareable port/ractor") { [Ractor.shareable?(Ractor::Port.new), Ractor.shareable?(Ractor.current)] }
check("F16 Data spec + class") do
  s = Ractor.make_shareable(Spec.new(id: :a, klass: W, args: [1]))
  Ractor.new(s) { |sp| [sp.id, sp.klass.new.run(sp.args[0])] }.value
end
check("F17 make_shareable copy") { a = [+"x"]; s = Ractor.make_shareable(a, copy: true); [a.frozen?, Ractor.shareable?(s)] }
check("F18 proc isolation") { x = 1; begin; Ractor.make_shareable(proc { x }); :ok; rescue => e; e.class; end }
check("F19 report_on_exception suppresses trace") do
  r = Ractor.new { Thread.current.report_on_exception = false; raise MyErr, "quiet" }
  pt = Ractor::Port.new; r.monitor(pt)
  [pt.receive, (r.value rescue $!.cause.class)]
end
check("F20 ractor local") { Ractor[:t] = 5; [Ractor[:t], Ractor.new { Ractor[:t] }.value] }
check("F21 Ractor#id") { Ractor.current.respond_to?(:id) }
check("F22 Ractor.new name") { Ractor.new(name: "shepherd:root") { Ractor.current.name }.value }
check("F23 select bench (500 ports x 200)") do
  ports = Array.new(500) { Ractor::Port.new }
  feeder = Ractor.new(Ractor.make_shareable(ports)) do |ps|
    200.times { |i| ps[i % ps.size] << i }
  end
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  200.times { Ractor.select(*ports) }
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
  feeder.value
  "#{ms}ms"
end
check("call pattern: reply port also monitors") do
  srv = Ractor.new do
    Thread.current.report_on_exception = false
    while true
      case Ractor.receive
      in [:"$call", reply, :crash] then raise "crash"
      in [:"$call", reply, req] then reply << [:"$reply", req]
      end
    end
  end
  call = lambda do |req|
    rp = Ractor::Port.new
    srv.monitor(rp)
    srv << [:"$call", rp, req]
    rp.receive
  ensure
    srv.unmonitor(rp) rescue nil
    rp.close
  end
  [call.(:hello), call.(:crash)]
end
