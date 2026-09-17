# frozen_string_literal: true

# Every event type this gem publishes, and the example that proves it happens.
#
# | type                     | example                                                  |
# |--------------------------|----------------------------------------------------------|
# | :supervisor_started      | "emits :supervisor_started when the boot finishes"       |
# | :child_started           | "emits :child_started for each child"                    |
# | :child_start_failed      | "emits :child_start_failed when initialize raises"       |
# | :child_exited            | "emits :child_exited with the reason and backtrace"      |
# | :child_restart_scheduled | "emits :child_restart_scheduled for a delayed restart"   |
# | :child_terminated        | "emits :child_terminated on a cooperative stop"          |
# | :child_unresponsive      | "emits :child_unresponsive when a child ignores stop"    |
# | :max_restarts_exceeded   | "emits :max_restarts_exceeded before escalating"         |
# | :supervisor_stopping     | "emits :supervisor_stopping and :supervisor_stopped"     |
# | :supervisor_stopped      | "emits :supervisor_stopping and :supervisor_stopped"     |
# | :unhandled_message       | spec/integration/server_spec.rb                          |
# | :worker_event            | "emits :worker_event for ctx.emit"                       |
RSpec.describe "events" do
  let(:waiter) { EventWaiter.new }

  def start_root(children, **)
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port, **))
  end

  def wait_running(id) = waiter.wait_for(type: :worker_event, child: id, timeout: 10) { |e| e[:name] == :running }

  it "emits :supervisor_started when the boot finishes" do
    with_deadline(15) do
      start_root([RactorShepherd.worker(:a, Commandable)])
      event = waiter.wait_for(type: :supervisor_started)
      expect([event[:supervisor], event[:children]]).to eq(["root", [:a]])
      expect(event[:at]).to be_a(Float)
    end
  end

  it "emits :child_started for each child" do
    with_deadline(15) do
      start_root([RactorShepherd.worker(:a, Commandable)])
      event = waiter.wait_for(type: :child_started, child: :a)
      expect([event[:attempt], event[:ractor_name]]).to eq([0, "shepherd:root/a"])
    end
  end

  it "emits :child_exited with the reason and backtrace" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)])
      wait_running(:a)
      sup.whereis(:a).send(:crash)
      event = waiter.wait_for(type: :child_exited, child: :a, timeout: 10)
      expect([event[:status], event[:reason], event[:error_class]]).to eq([:aborted, :error, "ArgumentError"])
      expect(event[:backtrace].size).to be_between(1, 10)
    end
  end

  it "emits :child_start_failed when initialize raises" do
    with_deadline(15) do
      sup = track(RactorShepherd.start_dynamic(name: :root, event_port: waiter.port))
      begin
        sup.start_child(RactorShepherd.worker(:bad, BadInit, restart: :temporary))
      rescue RactorShepherd::StartError
        nil
      end
      event = waiter.wait_for(type: :child_start_failed, child: :bad, timeout: 10)
      expect([event[:error_class], event[:error_message]]).to eq(["ArgumentError", "cannot init"])
    end
  end

  it "adds a hint for Ractor::IsolationError" do
    with_deadline(15) do
      start_root([RactorShepherd.worker(:a, IsolationBreaker, restart: :temporary)])
      event = waiter.wait_for(type: :child_exited, child: :a, timeout: 10)
      expect(event[:error_class]).to eq("Ractor::IsolationError")
      expect(event[:hint]).to match(/unshareable/)
    end
  end

  it "emits :child_restart_scheduled for a delayed restart" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable, restart_delay: 0.2)])
      wait_running(:a)
      sup.whereis(:a).send(:crash)
      event = waiter.wait_for(type: :child_restart_scheduled, child: :a, timeout: 10)
      expect([event[:delay], event[:attempt]]).to eq([0.2, 1])
    end
  end

  it "emits :child_terminated on a cooperative stop" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Recorder)])
      wait_running(:a)
      sup.terminate_child(:a)
      expect(waiter.wait_for(type: :child_terminated, child: :a, timeout: 10)[:requested_by]).to eq(:api)
    end
  end

  it "emits :supervisor_stopping and :supervisor_stopped" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Recorder)])
      wait_running(:a)
      sup.stop(:shutdown)
      expect(waiter.wait_for(type: :supervisor_stopping, timeout: 10)[:reason]).to eq(:shutdown)
      expect(waiter.wait_for(type: :supervisor_stopped, timeout: 10)[:reason]).to eq(:shutdown)
    end
  end

  it "emits :child_unresponsive when a child ignores stop" do
    with_deadline(20) do
      sup = start_root([RactorShepherd.worker(:deaf, Deaf, shutdown_timeout: 0.2)], on_unresponsive: :abandon)
      wait_running(:deaf)
      sup.stop(:shutdown, timeout: 10)
      event = waiter.wait_for(type: :child_unresponsive, child: :deaf, timeout: 10)
      expect([event[:phase], event[:action], event[:timeout]]).to eq([:stop, :abandon, 0.2])
    end
  end

  it "emits :max_restarts_exceeded before escalating" do
    with_deadline(20) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)], max_restarts: 0)
      wait_running(:a)
      sup.whereis(:a).send(:crash)
      event = waiter.wait_for(type: :max_restarts_exceeded, timeout: 10)
      expect([event[:max_restarts], event[:restarts]]).to eq([0, 1])
      expect(waiter.wait_for(type: :supervisor_stopped, timeout: 10)[:reason])
        .to eq("RactorShepherd::MaxRestartsExceeded")
    end
  end

  it "emits :worker_event for ctx.emit" do
    with_deadline(15) do
      start_root([RactorShepherd.worker(:a, Recorder)])
      event = wait_running(:a)
      expect([event[:child], event[:name], event[:data]]).to eq([:a, :running, {}])
    end
  end

  it "keeps running when the event port owner is gone (E16)" do
    with_deadline(15) do
      # A port closes when the Ractor that created it finishes.
      dead_port = Ractor.new(name: "event-owner") { Ractor::Port.new }.value
      sup = track(RactorShepherd.start(name: :root, event_port: dead_port,
                                       children: [RactorShepherd.worker(:a, Commandable)]))
      expect(sup.which_children.map(&:id)).to eq([:a])
      sup.whereis(:a).send(:crash)
      expect(sup.alive?).to be(true)
    end
  end
end
