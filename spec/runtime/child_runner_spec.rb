# frozen_string_literal: true

RSpec.describe RactorShepherd::Runtime::ChildRunner do
  include RunnerHelper

  let(:out) { Ractor::Port.new }

  describe "the start handshake" do
    it "sends child_ready with the id, a stop port and its own Ractor" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:echo, EchoWorker, args: [out]))
        expect(started.id).to eq(:echo)
        expect(started.stop_port).to be_a(Ractor::Port)
        expect(started.ref).to be_a(Ractor)
      end
    end

    it "aborts without child_ready when initialize raises (E1)" do
      with_deadline(5) do
        ractor, start_port = start_child(RactorShepherd.worker(:bad, BadInitWorker))
        expect(RactorShepherd::Runtime::Compat.monitor_status(start_port.receive)).to eq(:aborted)
        expect(exit_reason(ractor)).to be_a(ArgumentError)
      end
    end

    it "does not print the backtrace of an abnormal exit (F19)" do
      script = <<~RUBY
        $LOAD_PATH.unshift("lib")
        Warning[:experimental] = false
        require "ractor_shepherd"
        require "./spec/support/runtime_workers"
        port = Ractor::Port.new
        spec = RactorShepherd.worker(:crash, CrashingWorker, args: [port])
        r = Ractor.new(spec, port, nil, nil, "root/crash", name: "quiet") do |sp, stp, pr, ep, pa|
          RactorShepherd::Runtime::ChildRunner.run(sp, stp, pr, ep, pa)
        end
        m = Ractor::Port.new
        r.monitor(m)
        m.receive
      RUBY
      stdout, stderr, status = run_ruby(script)
      expect(stderr).not_to include("boom")
      expect([stdout, status.success?]).to eq(["", true])
    end
  end

  describe "the terminate reason" do
    it "is :normal when run returns" do
      with_deadline(5) do
        start_child!(RactorShepherd.worker(:done, FinishingWorker, args: [out]))
        expect([out.receive, out.receive]).to eq([[:ran], %i[terminate normal]])
      end
    end

    it "is the exception when run raises" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:crash, CrashingWorker, args: [out]))
        expect(out.receive).to eq([:terminate, "ArgumentError"])
        expect(exit_status(started.ractor)).to eq(:aborted)
      end
    end

    it "is :shutdown when a shutdown is requested" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:echo, EchoWorker, args: [out]))
        started.stop_port << RactorShepherd::Runtime::Protocol.shutdown(:shutdown)
        expect(out.receive).to eq(%i[shutdown_signal shutdown])
        expect(out.receive).to eq(%i[terminate shutdown])
      end
    end
  end

  describe "when terminate raises" do
    it "turns a normal exit into an abnormal one" do
      with_deadline(5) do
        started = start_child!(RactorShepherd.worker(:bad_term, BadTerminateWorker, args: [out, false]))
        expect(out.receive).to eq([:ran])
        expect(exit_status(started.ractor)).to eq(:aborted)
        expect(exit_reason(started.ractor)).to be_a(TypeError)
      end
    end

    it "keeps the original exception when the exit was already abnormal" do
      with_deadline(5) do
        events = Ractor::Port.new
        started = start_child!(RactorShepherd.worker(:bad_term, BadTerminateWorker, args: [out, true]),
                               event_port: events)
        expect(exit_reason(started.ractor)).to be_a(ArgumentError)
        event = events.receive
        expect([event[:type], event[:name], event[:data][:error_class]])
          .to eq([:worker_event, :terminate_failed, "TypeError"])
      end
    end
  end
end
