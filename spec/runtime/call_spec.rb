# frozen_string_literal: true

RSpec.describe RactorShepherd::Runtime::Call do
  def start_server(name)
    Ractor.new(name: name) { EchoServer.run }
  end

  it "returns the reply" do
    with_deadline(5) do
      server = start_server("call-ok")
      expect(described_class.perform(server, server, :hello, timeout: 2)).to eq(:hello)
      server.send(:stop)
      server.join
    end
  end

  it "raises CallTimeout when no reply arrives in time" do
    with_deadline(5) do
      server = start_server("call-timeout")
      expect { described_class.perform(server, server, [:slow, 5], timeout: 0.05) }
        .to raise_error(RactorShepherd::CallTimeout)
    end
  end

  it "does not crash the responder when the caller already timed out (E10)" do
    with_deadline(10) do
      server = start_server("call-late-reply")
      expect { described_class.perform(server, server, [:slow, 0.2], timeout: 0.05) }
        .to raise_error(RactorShepherd::CallTimeout)
      # Having replied late, it can still answer the next call.
      expect(described_class.perform(server, server, :still_here, timeout: 2)).to eq(:still_here)
      server.send(:stop)
      server.join
    end
  end

  # Because Ractor#unmonitor is unusable, a call with a finite timeout does not
  # monitor; a dead callee is told apart from a slow one after the timeout.
  it "raises the down error when the target crashes while handling the call" do
    with_deadline(10) do
      server = start_server("call-crash")
      expect { described_class.perform(server, server, :crash, timeout: 0.2) }
        .to raise_error(RactorShepherd::SupervisorDown, /terminated while handling/)
    end
  end

  it "raises the down error without waiting when the timeout is :infinity" do
    with_deadline(10) do
      server = start_server("call-crash-infinity")
      expect { described_class.perform(server, server, :crash, timeout: :infinity) }
        .to raise_error(RactorShepherd::SupervisorDown, /terminated while handling/)
    end
  end

  # Regression test: this used to call unmonitor in an ensure block, which
  # dropped another Ractor's monitor whenever the two ports shared an id.
  it "does not clobber another Ractor's monitor of the same target" do
    with_deadline(10) do
      target = start_server("call-monitor-safety")
      result = Ractor::Port.new
      Ractor.new(target, result, name: "call-watcher") do |ractor, out|
        port = Ractor::Port.new
        # Uses port id 1, which is what the caller's reply port is likely to get too.
        ractor.monitor(port)
        out << :ready
        _p, message = Ractor.select(port)
        out << [:saw, RactorShepherd::Runtime::Compat.monitor_status(message)]
      end
      result.receive

      expect(described_class.perform(target, target, :hello, timeout: 2)).to eq(:hello)
      target.send(:stop)

      expect(result.receive).to eq(%i[saw exited])
    end
  end

  it "raises the down error for an already terminated target (F3)" do
    with_deadline(5) do
      server = start_server("call-dead")
      server.send(:stop)
      server.join
      expect { described_class.perform(server, server, :hello, timeout: 5) }
        .to raise_error(RactorShepherd::SupervisorDown, /is not running/)
    end
  end

  it "uses the caller supplied down error class" do
    with_deadline(5) do
      server = start_server("call-worker-down")
      server.send(:stop)
      server.join
      expect { described_class.perform(server, server, :hello, timeout: 5, down_error: RactorShepherd::WorkerDown) }
        .to raise_error(RactorShepherd::WorkerDown)
    end
  end

  it "waits forever with timeout: :infinity" do
    with_deadline(5) do
      server = start_server("call-infinity")
      expect(described_class.perform(server, server, [:slow, 0.1], timeout: :infinity)).to eq(:late)
      server.send(:stop)
      server.join
    end
  end
end
