# frozen_string_literal: true

RSpec.describe RactorShepherd::Core::RestartIntensity do
  it "allows up to max_restarts within the window" do
    intensity = described_class.new(max_restarts: 3, max_seconds: 5.0)
    expect([intensity.record(0.0), intensity.record(1.0), intensity.record(2.0)]).to eq(%i[ok ok ok])
  end

  it "reports :exceeded on the restart after max_restarts" do
    intensity = described_class.new(max_restarts: 3, max_seconds: 5.0)
    3.times { |i| intensity.record(i.to_f) }
    expect(intensity.record(3.0)).to eq(:exceeded)
  end

  it "never restarts when max_restarts is 0" do
    intensity = described_class.new(max_restarts: 0, max_seconds: 5.0)
    expect(intensity.record(0.0)).to eq(:exceeded)
  end

  it "keeps a record that is exactly max_seconds old" do
    intensity = described_class.new(max_restarts: 1, max_seconds: 5.0)
    intensity.record(0.0)
    expect(intensity.record(5.0)).to eq(:exceeded)
  end

  it "drops a record that is older than max_seconds" do
    intensity = described_class.new(max_restarts: 1, max_seconds: 5.0)
    intensity.record(0.0)
    expect(intensity.record(5.001)).to eq(:ok)
  end

  it "exposes the number of restarts still in the window" do
    intensity = described_class.new(max_restarts: 5, max_seconds: 1.0)
    intensity.record(0.0)
    intensity.record(0.5)
    intensity.record(2.0)
    expect(intensity.count).to eq(1)
  end
end
