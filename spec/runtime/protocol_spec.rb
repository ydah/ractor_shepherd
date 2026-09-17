# frozen_string_literal: true

RSpec.describe RactorShepherd::Runtime::Protocol do
  it "builds frozen messages" do
    expect(described_class.shutdown(:normal)).to eq(%i[$shutdown normal]).and(be_frozen)
  end

  describe ".reserved?" do
    it "recognises reserved arrays" do
      expect(described_class.reserved?(described_class.call(nil, :get))).to be(true)
    end

    it "recognises reserved symbols" do
      expect(described_class.reserved?(described_class::SHUTDOWN_SENTINEL)).to be(true)
    end

    [[:add, 1], :get, "string", 42, nil].each do |message|
      it "treats #{message.inspect} as a user message" do
        expect(described_class.reserved?(message)).to be(false)
      end
    end
  end
end
