# frozen_string_literal: true

RSpec.describe "restart intensity and backoff" do
  let(:waiter) { EventWaiter.new }

  def start_root(children, **)
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port, **))
  end

  def wait_running(id) = waiter.wait_for(type: :worker_event, child: id) { |e| e[:name] == :running }

  describe "max_restarts" do
    it "escalates after more than max_restarts failures in max_seconds" do
      with_deadline(20) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)], max_restarts: 2, max_seconds: 5)
        3.times do |i|
          wait_running(:a)
          sup.whereis(:a).send(:crash)
          waiter.wait_for(type: :child_exited, child: :a) if i < 2
        end

        event = waiter.wait_for(type: :max_restarts_exceeded, timeout: 10)
        expect([event[:max_restarts], event[:max_seconds]]).to eq([2, 5])
        expect { sup.join }.to raise_error(RactorShepherd::SupervisorCrashed) { |e|
          expect(e.cause).to be_a(RactorShepherd::MaxRestartsExceeded)
        }
      end
    end

    it "escalates on the first failure when max_restarts is 0 (E14)" do
      with_deadline(15) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)], max_restarts: 0, max_seconds: 5)
        wait_running(:a)
        sup.whereis(:a).send(:crash)
        waiter.wait_for(type: :max_restarts_exceeded, timeout: 10)
        expect { sup.join }.to raise_error(RactorShepherd::SupervisorCrashed)
      end
    end

    it "does not escalate when the failures are spread beyond max_seconds" do
      with_deadline(20) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)], max_restarts: 1, max_seconds: 0.2)
        3.times do
          wait_running(:a)
          sup.whereis(:a).send(:crash)
          waiter.wait_for(type: :child_started, child: :a, timeout: 10)
          Kernel.sleep(0.25) # step past the max_seconds window; elapsed time is the thing under test
        end
        expect(sup.alive?).to be(true)
      end
    end
  end

  describe "a child whose initialize keeps failing (E2)" do
    it "consumes the restart intensity and escalates" do
      with_deadline(20) do
        coordinator = Ractor.new(name: "coordinator") { Coordinator.run }
        sup = start_root([RactorShepherd.worker(:a, FailAfterFirstInit, args: [coordinator])],
                         max_restarts: 2, max_seconds: 30)
        wait_running(:a)
        sup.whereis(:a).send(:crash)

        expect(waiter.wait_for(type: :child_start_failed, child: :a, timeout: 10)[:error_class])
          .to eq("ArgumentError")
        waiter.wait_for(type: :max_restarts_exceeded, timeout: 10)
        expect { sup.join }.to raise_error(RactorShepherd::SupervisorCrashed)
      end
    end
  end

  describe "restart_delay" do
    it "puts the child into :restart_scheduled and then restarts it" do
      with_deadline(20) do
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart_delay: 0.5)])
        wait_running(:a)
        sup.whereis(:a).send(:crash)

        scheduled = waiter.wait_for(type: :child_restart_scheduled, child: :a)
        expect([scheduled[:delay], scheduled[:attempt]]).to eq([0.5, 1])
        expect(sup.which_children.first.status).to eq(:restart_scheduled)

        waiter.wait_for(type: :child_started, child: :a, timeout: 10) { |e| e[:attempt] == 1 }
        expect(sup.which_children.first.status).to eq(:running)
      end
    end

    it "grows the delay for consecutive failures" do
      with_deadline(20) do
        delay = { initial: 0.05, max: 0.2, factor: 2 }
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart_delay: delay)], max_restarts: 10)
        delays = 3.times.map do
          wait_running(:a)
          sup.whereis(:a).send(:crash)
          waiter.wait_for(type: :child_restart_scheduled, child: :a, timeout: 10)[:delay]
        end
        expect(delays).to eq([0.05, 0.1, 0.2])
      end
    end

    it "ignores a pending restart when the supervisor stops (E6)" do
      with_deadline(20) do
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart_delay: 5)])
        wait_running(:a)
        sup.whereis(:a).send(:crash)
        waiter.wait_for(type: :child_restart_scheduled, child: :a)

        expect(sup.stop(:shutdown, timeout: 5)).to be(true)
        events = waiter.drain
        expect(events.map { |e| e[:type] }).to include(:supervisor_stopped)
        expect(events.none? { |e| e[:type] == :child_started && e[:attempt] == 1 }).to be(true)
      end
    end
  end
end
