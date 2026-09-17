# frozen_string_literal: true

RSpec.describe RactorShepherd::Runtime::Compat do
  describe ".monitor_status" do
    it "passes through the Ruby 4.0 Symbol form" do
      expect([described_class.monitor_status(:exited), described_class.monitor_status(:aborted)])
        .to eq(%i[exited aborted])
    end

    it "unwraps the Ruby 4.1 [ractor, status] form" do
      ractor = Ractor.new { :done }
      ractor.join
      expect(described_class.monitor_status([ractor, :exited])).to eq(:exited)
    end

    [:running, [1, :exited], nil, "exited", []].each do |message|
      it "raises ProtocolError for #{message.inspect}" do
        expect { described_class.monitor_status(message) }
          .to raise_error(RactorShepherd::ProtocolError, /unexpected monitor message/)
      end
    end
  end

  describe ".check!" do
    it "accepts the running Ruby" do
      expect { described_class.check! }.not_to raise_error
    end
  end

  describe ".native_receive_timeout?" do
    it "answers from the actual method signature, not the version number" do
      has_timeout = Ractor::Port.instance_method(:receive).parameters.any? { |k, n| k == :key && n == :timeout }
      expect(described_class.native_receive_timeout?).to be(has_timeout)
    end
  end
end
