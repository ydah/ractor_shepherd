# frozen_string_literal: true

RSpec.describe RactorShepherd::Core::Backoff do
  def backoff(spec, reset_after: 5.0) = described_class.new(spec, reset_after: reset_after)

  it "has no delay before the first failure" do
    expect(backoff(1.0).delay).to eq(0)
  end

  it "restarts immediately when restart_delay is nil" do
    b = backoff(nil)
    b.record_failure(0.0)
    expect(b.delay).to eq(0)
  end

  it "restarts immediately when restart_delay is 0" do
    b = backoff(0)
    b.record_failure(0.0)
    expect(b.delay).to eq(0)
  end

  it "uses a fixed delay for a Numeric restart_delay" do
    b = backoff(0.25)
    3.times { |i| b.record_failure(i.to_f) }
    expect(b.delay).to eq(0.25)
  end

  describe "with an exponential BackoffSpec" do
    let(:spec) { RactorShepherd::BackoffSpec.new(initial: 0.1, max: 0.5, factor: 2.0) }

    it "grows by factor per consecutive failure and caps at max" do
      b = backoff(spec)
      delays = 5.times.map do |i|
        b.record_failure(i.to_f)
        b.delay.round(4)
      end
      expect(delays).to eq([0.1, 0.2, 0.4, 0.5, 0.5])
    end
  end

  it "resets the attempt count when the child survived reset_after seconds" do
    b = backoff(0.25, reset_after: 5.0)
    b.record_failure(0.0)
    b.record_failure(1.0)
    expect(b.attempt).to eq(2)

    b.record_start(10.0)
    b.record_failure(15.0)
    expect(b.attempt).to eq(1)
  end

  it "keeps counting when the child died before reset_after" do
    b = backoff(0.25, reset_after: 5.0)
    b.record_failure(0.0)
    b.record_start(1.0)
    b.record_failure(2.0)
    expect(b.attempt).to eq(2)
  end

  it "can be reset explicitly" do
    b = backoff(0.25)
    b.record_failure(0.0)
    b.reset
    expect([b.attempt, b.delay]).to eq([0, 0])
  end

  it "rejects an unknown restart_delay shape" do
    b = backoff("soon")
    b.record_failure(0.0)
    expect { b.delay }.to raise_error(ArgumentError, /restart_delay/)
  end
end
