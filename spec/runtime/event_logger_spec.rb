# frozen_string_literal: true

RSpec.describe RactorShepherd::EventLogger do
  def event(type, **data)
    RactorShepherd::Core::Event.build(type, supervisor: "root", at: 1.0, **data)
  end

  describe ".level_for" do
    {
      supervisor_started: :info,
      supervisor_stopping: :info,
      supervisor_stopped: :info,
      child_terminated: :info,
      worker_event: :info,
      unhandled_message: :info,
      child_start_failed: :warn,
      child_restart_scheduled: :warn,
      child_unresponsive: :error,
      max_restarts_exceeded: :error
    }.each do |type, level|
      it "logs #{type} at #{level}" do
        expect(described_class.level_for(event(type))).to eq(level)
      end
    end

    it "logs a crash exit at error" do
      expect(described_class.level_for(event(:child_exited, reason: :error))).to eq(:error)
    end

    it "logs a normal exit at info" do
      expect(described_class.level_for(event(:child_exited, reason: :normal))).to eq(:info)
    end

    it "logs the first start at info and a restart at warn" do
      expect(described_class.level_for(event(:child_started, attempt: 0))).to eq(:info)
      expect(described_class.level_for(event(:child_started, attempt: 2))).to eq(:warn)
    end
  end

  describe ".format_event" do
    it "puts the supervisor path and type first" do
      line = described_class.format_event(event(:child_started, child: :a, attempt: 0))
      expect(line).to eq("[ractor_shepherd] root child_started child=:a attempt=0")
    end
  end

  describe ".start" do
    it "writes each event to the logger with its level" do
      with_deadline(5) do
        port = Ractor::Port.new
        logger = RecordingLogger.new
        described_class.start(port, logger: logger)

        port << event(:supervisor_started, children: [:a])
        port << event(:max_restarts_exceeded, restarts: 4)

        expect(logger.lines.pop.first).to eq(:info)
        expect(logger.lines.pop.first).to eq(:error)
      end
    end

    it "ends when the port closes" do
      with_deadline(5) do
        port = Ractor::Port.new
        thread = described_class.start(port, logger: RecordingLogger.new)
        port.close
        expect(thread.join(3)).to eq(thread)
      end
    end

    it "writes to stderr by default" do
      with_deadline(5) do
        port = Ractor::Port.new
        captured = StringIO.new
        original = $stderr
        $stderr = captured
        begin
          described_class.start(port)
          port << event(:supervisor_started, children: [])
          wait_until(3) { captured.string.include?("supervisor_started") }
        ensure
          $stderr = original
        end
        expect(captured.string).to start_with("INFO -- [ractor_shepherd] root supervisor_started")
      end
    end
  end

  # Poll for the condition instead of sleeping for a fixed time.
  def wait_until(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise Timeout::Error, "condition not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end
end
