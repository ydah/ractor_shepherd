# frozen_string_literal: true

RSpec.describe RactorShepherd::Runtime::Timer do
  let(:timer) { described_class.new }

  it "fires after the delay" do
    with_deadline(5) do
      port = Ractor::Port.new
      timer.after(0.01, port, :fired)
      expect(port.receive).to eq(:fired)
    end
  end

  it "does not fire once cancelled" do
    with_deadline(5) do
      port = Ractor::Port.new
      timer.after(0.05, port, :late).cancel
      timer.after(0.15, port, :marker)
      expect(port.receive).to eq(:marker)
    end
  end

  it "survives a closed destination port" do
    with_deadline(5) do
      port = Ractor::Port.new
      handle = timer.after(0.01, port, :fired)
      port.close
      Kernel.sleep 0.05
      expect(handle).not_to be_pending
    end
  end

  it "can send to a Ractor as well as a Port (F12)" do
    with_deadline(5) do
      port = Ractor::Port.new
      receiver = Ractor.new(port, name: "timer-target") { |pt| pt << Ractor.receive }
      timer.after(0.01, receiver, :to_ractor)
      expect(port.receive).to eq(:to_ractor)
    end
  end

  it "keeps one timer per Ractor" do
    with_deadline(5) do
      outer = described_class.for_current_ractor
      expect(described_class.for_current_ractor).to be(outer)
      inner = Ractor.new(name: "timer-local") do
        RactorShepherd::Runtime::Timer.for_current_ractor.equal?(RactorShepherd::Runtime::Timer.for_current_ractor)
      end
      expect(inner.value).to be(true)
    end
  end

  it "works inside a non-main Ractor" do
    with_deadline(5) do
      port = Ractor::Port.new
      worker = Ractor.new(port, name: "timer-in-ractor") do |pt|
        RactorShepherd::Runtime::Timer.for_current_ractor.after(0.01, pt, :from_child)
        Ractor.receive
      end
      expect(port.receive).to eq(:from_child)
      worker.send(:stop)
      worker.join
    end
  end
end
