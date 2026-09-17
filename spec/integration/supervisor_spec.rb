# frozen_string_literal: true

RSpec.describe "one_for_one supervisor" do
  let(:waiter) { EventWaiter.new }

  def start_root(children, **)
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port, **))
  end

  def worker_event(child, name, timeout: 5)
    waiter.wait_for(type: :worker_event, child: child, timeout: timeout) { |e| e[:name] == name }
  end

  describe "booting" do
    it "starts children in order" do
      with_deadline(10) do
        start_root([RactorShepherd.worker(:a, Recorder), RactorShepherd.worker(:b, Recorder)])
        waiter.wait_for(type: :supervisor_started)
        started = waiter.buffer.select { |e| e[:type] == :child_started }.map { |e| e[:child] }
        expect(started).to eq(%i[a b])
      end
    end

    it "reports every child through which_children" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Recorder)])
        info = sup.which_children.first
        expect([info.id, info.type, info.status, info.restart_count]).to eq([:a, :worker, :running, 0])
        expect(info.ref).to be_a(Ractor)
      end
    end

    it "counts children" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Recorder), RactorShepherd.worker(:b, Recorder)])
        expect(sup.count_children).to eq({ specs: 2, active: 2, workers: 2, supervisors: 0 })
      end
    end

    it "raises StartError with the original cause when a child fails to initialize (E1)" do
      with_deadline(10) do
        error = begin
          RactorShepherd.start(name: :root, event_port: waiter.port,
                               children: [RactorShepherd.worker(:a, Recorder),
                                          RactorShepherd.worker(:b, BadInit)])
          nil
        rescue RactorShepherd::StartError => e
          e
        end

        expect(error.message).to include(":b")
        expect(error.cause).to be_a(ArgumentError)
        expect(error.cause.message).to eq("cannot init")
      end
    end

    it "stops the already started children before raising (E1)" do
      with_deadline(10) do
        RactorShepherd.start(name: :root, event_port: waiter.port,
                             children: [RactorShepherd.worker(:a, Recorder),
                                        RactorShepherd.worker(:b, BadInit)])
      rescue RactorShepherd::StartError
        expect(worker_event(:a, :terminated)[:data][:reason]).to eq(:shutdown)
      end
    end

    it "fails the boot when a child does not finish initializing in time" do
      with_deadline(15) do
        expect do
          RactorShepherd.start(name: :root, event_port: waiter.port,
                               children: [RactorShepherd.worker(:slow, SlowInit, args: [5], start_timeout: 0.2)])
        end.to raise_error(RactorShepherd::StartError)
        expect(waiter.wait_for(type: :child_unresponsive, child: :slow)[:phase]).to eq(:start)
      end
    end
  end

  describe "restarting" do
    it "restarts an abnormally exited child with a new Ractor" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable), RactorShepherd.worker(:b, Commandable)])
        worker_event(:a, :running)
        worker_event(:b, :running)
        before_a = sup.whereis(:a)
        before_b = sup.whereis(:b)

        before_a.send(:crash)
        waiter.wait_for(type: :child_started, child: :a) { |e| e[:attempt] == 1 }

        expect(sup.whereis(:a)).not_to equal(before_a)
        expect(sup.whereis(:b)).to equal(before_b)
        expect(sup.which_children.find { |c| c.id == :a }.restart_count).to eq(1)
      end
    end

    it "reports the crash reason in the child_exited event" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)])
        worker_event(:a, :running)
        sup.whereis(:a).send(:crash)
        event = waiter.wait_for(type: :child_exited, child: :a)
        expect([event[:status], event[:reason], event[:error_class], event[:error_message]])
          .to eq([:aborted, :error, "ArgumentError", "boom"])
      end
    end

    it "does not restart a :transient child that exited normally" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart: :transient)])
        worker_event(:a, :running)
        sup.whereis(:a).send(:finish)
        waiter.wait_for(type: :child_exited, child: :a)
        expect(sup.which_children.first.status).to eq(:terminated)
      end
    end

    it "drops a :temporary child from which_children when it exits" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart: :temporary)])
        worker_event(:a, :running)
        sup.whereis(:a).send(:crash)
        waiter.wait_for(type: :child_exited, child: :a)
        expect(sup.which_children).to eq([])
      end
    end

    it "still restarts when another Ractor already took the child's value (E8)" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)])
        worker_event(:a, :running)
        child = sup.whereis(:a)
        child.send(:crash)
        # The example takes the value before the supervisor gets a chance to.
        begin
          child.value
        rescue Ractor::Error
          nil
        end
        waiter.wait_for(type: :child_started, child: :a) { |e| e[:attempt] == 1 }
        expect(sup.whereis(:a)).not_to equal(child)
      end
    end

    it "answers a call that arrived during a restart (E7)" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)])
        worker_event(:a, :running)
        sup.whereis(:a).send(:crash)
        expect(sup.which_children.map(&:id)).to eq([:a])
      end
    end
  end

  describe "stopping" do
    it "stops children in reverse order" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Recorder), RactorShepherd.worker(:b, Recorder)])
        worker_event(:a, :running)
        worker_event(:b, :running)
        expect(sup.stop).to be(true)

        order = waiter.drain.select { |e| e[:type] == :child_terminated }.map { |e| e[:child] }
        expect(order).to eq(%i[b a])
      end
    end

    it "is idempotent (E12)" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Recorder)])
        expect([sup.stop, sup.stop]).to eq([true, true])
      end
    end

    it "flips alive? from true to false" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Recorder)])
        expect(sup.alive?).to be(true)
        sup.stop
        expect(sup.alive?).to be(false)
      end
    end

    it "escalates when a child ignores the shutdown request (E5)" do
      with_deadline(15) do
        sup = start_root([RactorShepherd.worker(:deaf, Deaf, shutdown_timeout: 0.2)])
        worker_event(:deaf, :running)
        sup.stop(:shutdown, timeout: 5)
        expect { sup.join }.to raise_error(RactorShepherd::SupervisorCrashed, /ChildUnresponsive/)
      end
    end

    it "completes the stop when on_unresponsive is :abandon (E5)" do
      with_deadline(15) do
        sup = start_root([RactorShepherd.worker(:deaf, Deaf, shutdown_timeout: 0.2)], on_unresponsive: :abandon)
        worker_event(:deaf, :running)
        expect(sup.stop(:shutdown, timeout: 5)).to be(true)
        expect(waiter.wait_for(type: :child_unresponsive, child: :deaf)[:action]).to eq(:abandon)
      end
    end

    it "treats a child that exited just before the stop request as terminated (E4)" do
      with_deadline(10) do
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart: :temporary)])
        worker_event(:a, :running)
        sup.whereis(:a).send(:crash)
        waiter.wait_for(type: :child_exited, child: :a)
        expect(sup.stop).to be(true)
      end
    end
  end

  describe "RactorShepherd.run" do
    it "stops the supervisor when the block returns" do
      with_deadline(10) do
        captured = nil
        RactorShepherd.run(name: :root, event_port: waiter.port,
                           children: [RactorShepherd.worker(:a, Recorder)]) do |sup|
          captured = sup
          expect(sup.alive?).to be(true)
        end
        expect(captured.alive?).to be(false)
      end
    end
  end
end
