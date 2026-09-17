# frozen_string_literal: true

RSpec.describe RactorShepherd::Core::Event do
  describe ".build" do
    it "always carries type, supervisor and at" do
      event = described_class.build(:child_started, supervisor: "root/jobs", at: 1.5, child: :poller)
      expect(event).to eq({ type: :child_started, supervisor: "root/jobs", at: 1.5, child: :poller })
    end

    it "produces a shareable, deeply frozen Hash" do
      event = described_class.build(:child_exited, supervisor: "root", at: 1.0,
                                                   child: :a, backtrace: [+"line 1"])
      expect(Ractor.shareable?(event)).to be(true)
      expect(event[:backtrace].first).to be_frozen
    end

    it "does not freeze the caller's data" do
      backtrace = [+"line 1"]
      described_class.build(:child_exited, supervisor: "root", at: 1.0, backtrace: backtrace)
      expect(backtrace.first).not_to be_frozen
    end
  end

  describe ".error_info" do
    it "returns nothing for a non-exception reason" do
      expect(described_class.error_info(:normal)).to eq({})
    end

    it "extracts class, message and backtrace" do
      error = raise ArgumentError, "boom" rescue $! # rubocop:disable Style/RescueModifier,Style/SpecialGlobalVars
      info = described_class.error_info(error)
      expect(info[:error_class]).to eq("ArgumentError")
      expect(info[:error_message]).to eq("boom")
      expect(info[:backtrace].size).to be_between(1, 10)
    end

    it "caps the backtrace at 10 lines" do
      error = ArgumentError.new("deep")
      error.set_backtrace(Array.new(50) { |i| "line #{i}" })
      expect(described_class.error_info(error)[:backtrace].size).to eq(10)
    end

    it "omits hint for an ordinary exception" do
      expect(described_class.error_info(ArgumentError.new("x"))).not_to have_key(:hint)
    end
  end

  describe ".hint_for" do
    it "explains Ractor::UnsafeError" do
      expect(described_class.hint_for(Ractor::UnsafeError.new("x"))).to match(/C extension/)
    end

    it "explains Ractor::IsolationError" do
      expect(described_class.hint_for(Ractor::IsolationError.new("x"))).to match(/unshareable/)
    end

    it "returns nil for an unknown exception" do
      expect(described_class.hint_for(ArgumentError.new("x"))).to be_nil
    end
  end

  describe ".reason_kind" do
    {
      normal: :normal,
      shutdown: :shutdown
    }.each do |reason, expected|
      it "maps #{reason.inspect} to #{expected.inspect}" do
        expect(described_class.reason_kind(reason)).to eq(expected)
      end
    end

    it "maps an exception to :error" do
      expect(described_class.reason_kind(ArgumentError.new("x"))).to eq(:error)
    end

    it "maps anything else to :unknown" do
      expect(described_class.reason_kind(:unknown)).to eq(:unknown)
    end
  end
end
