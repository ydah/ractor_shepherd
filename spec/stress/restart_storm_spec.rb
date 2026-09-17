# frozen_string_literal: true

RSpec.describe "restart storm" do
  let(:waiter) { EventWaiter.new }
  let(:restarts) { Integer(ENV.fetch("STRESS_RESTARTS", 30)) }

  it "keeps restarting a child that crashes every 50ms" do
    with_deadline(120) do
      sup = track(RactorShepherd.start(name: :root, event_port: waiter.port,
                                       max_restarts: restarts * 2, max_seconds: 120,
                                       children: [RactorShepherd.worker(:flapper, CrashLoop, args: [0.05])]))
      waiter.wait_until(timeout: 90) do |events|
        events.count { |e| e[:type] == :child_started } > restarts
      end
      expect(sup.alive?).to be(true)
      expect(sup.which_children.first.restart_count).to be >= restarts
    end
  end

  it "survives a child crashing while another one is stopping" do
    with_deadline(60) do
      sup = track(RactorShepherd.start(name: :root, event_port: waiter.port, max_restarts: 50,
                                       children: [
                                         RactorShepherd.worker(:slow, SlowStop, args: [0.3]),
                                         RactorShepherd.worker(:flappy, Commandable)
                                       ]))
      waiter.wait_for(type: :worker_event, child: :slow, timeout: 10) { |e| e[:name] == :running }
      waiter.wait_for(type: :worker_event, child: :flappy, timeout: 10) { |e| e[:name] == :running }

      flappy = sup.whereis(:flappy)
      stopper = Thread.new { sup.stop(:shutdown, timeout: 30) }
      flappy.send(:crash)
      expect(stopper.value).to be(true)
    end
  end

  it "tolerates concurrent stop calls" do
    with_deadline(60) do
      sup = track(RactorShepherd.start(name: :root, event_port: waiter.port,
                                       children: [RactorShepherd.worker(:a, Recorder)]))
      waiter.wait_for(type: :worker_event, child: :a, timeout: 10) { |e| e[:name] == :running }
      results = 4.times.map { Thread.new { sup.stop(:shutdown, timeout: 20) } }.map(&:value)
      expect(results).to all(be(true))
    end
  end
end
