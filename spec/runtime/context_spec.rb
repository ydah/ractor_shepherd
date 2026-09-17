# frozen_string_literal: true

RSpec.describe RactorShepherd::Runtime::Context do
  include RunnerHelper

  let(:out) { Ractor::Port.new }

  describe "#receive" do
    it "returns the message that was sent" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:echo, EchoWorker, args: [out]))
        started.ractor.send([:add, 1])
        expect(out.receive).to eq([:received, [:add, 1]])
      end
    end

    it "returns nil when the timeout elapses" do
      with_deadline(5) do
        start_child!(RactorShepherd.worker(:echo, EchoWorker, args: [out], kwargs: { timeout: 0.05 }))
        expect(out.receive).to eq([:received, nil])
      end
    end

    it "ignores a stale timeout notification from an earlier receive" do
      with_deadline(10) do
        started = start_child!(RactorShepherd.worker(:echo, EchoWorker, args: [out], kwargs: { timeout: 0.05 }))
        # Time out a few times, then send a real message: no stale notification should show up.
        3.times { expect(out.receive).to eq([:received, nil]) }
        started.ractor.send(:real)
        messages = 5.times.map { out.receive }
        expect(messages).to include(%i[received real])
      end
    end

    it "raises ShutdownSignal once a shutdown was requested" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:echo, EchoWorker, args: [out]))
        started.stop_port << RactorShepherd::Runtime::Protocol.shutdown(:shutdown)
        expect(out.receive).to eq(%i[shutdown_signal shutdown])
      end
    end
  end

  describe "#sleep" do
    it "returns true when it runs to completion" do
      with_deadline(5) do
        start_child!(RactorShepherd.worker(:sleeper, SleepWorker, args: [out, 0.05]))
        expect([out.receive, out.receive]).to eq([[:slept, true], [:requested, false]])
      end
    end

    it "returns false when a shutdown interrupts it" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:sleeper, SleepWorker, args: [out, 30]))
        started.stop_port << RactorShepherd::Runtime::Protocol.shutdown(:shutdown)
        expect([out.receive, out.receive]).to eq([[:slept, false], [:requested, true]])
      end
    end

    it "returns false immediately when a shutdown was already requested" do
      ctx = described_class.new(id: :a, path: "root/a", supervisor: nil, event_port: nil)
      ctx.request_shutdown(:shutdown)
      expect(ctx.sleep(30)).to be(false)
    end
  end

  describe "#emit" do
    it "sends a :worker_event to the event port" do
      with_deadline(5) do
        events = Ractor::Port.new
        start_child!(RactorShepherd.worker(:emitter, EmittingWorker, args: ["fred"]), event_port: events)
        event = events.receive
        expect([event[:type], event[:child], event[:name], event[:data]])
          .to eq([:worker_event, :emitter, :hello, { name: "fred" }])
        expect(Ractor.shareable?(event)).to be(true)
      end
    end

    it "ignores a closed event port (E16)" do
      ctx = described_class.new(id: :a, path: "root/a", supervisor: nil, event_port: Ractor::Port.new.tap(&:close))
      expect { ctx.emit(:hello) }.not_to raise_error
    end

    it "does nothing without an event port" do
      ctx = described_class.new(id: :a, path: "root/a", supervisor: nil, event_port: nil)
      expect(ctx.emit(:hello)).to be_nil
    end
  end
end
