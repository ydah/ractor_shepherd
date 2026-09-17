# frozen_string_literal: true

RSpec.describe RactorShepherd::Server do
  let(:waiter) { EventWaiter.new }

  def start_root(children, **)
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port, **))
  end

  def counter(**)
    sup = start_root([RactorShepherd.worker(:counter, Counter, args: [0], **)])
    [sup, sup.lookup(:counter)]
  end

  it "answers a call with the return value of handle_call" do
    with_deadline(15) do
      _sup, address = counter
      expect(address.call(:get, timeout: 5)).to eq(0)
    end
  end

  it "keeps the order of casts" do
    with_deadline(15) do
      _sup, address = counter
      5.times { |i| address.cast([:add, i]) }
      expect(address.call(:get, timeout: 5)).to eq(0 + 1 + 2 + 3 + 4)
    end
  end

  it "treats a plain array message as a cast" do
    with_deadline(15) do
      _sup, address = counter
      address.ractor.send([:add, 3])
      expect(address.call(:get, timeout: 5)).to eq(3)
    end
  end

  it "raises WorkerDown and restarts the child when handle_call raises (E9)" do
    with_deadline(15) do
      sup, address = counter
      # Since unmonitor is unusable, a dead callee is only noticed after the timeout.
      expect { address.call(:crash, timeout: 0.2) }.to raise_error(RactorShepherd::WorkerDown)
      waiter.wait_for(type: :child_started, child: :counter, timeout: 10) { |e| e[:attempt] == 1 }
      expect(sup.which_children.first.restart_count).to eq(1)
    end
  end

  it "restarts the child when handle_cast raises" do
    with_deadline(15) do
      sup, address = counter
      address.cast(:crash)
      waiter.wait_for(type: :child_started, child: :counter, timeout: 10) { |e| e[:attempt] == 1 }
      expect(sup.which_children.first.status).to eq(:running)
    end
  end

  it "loses the state on restart" do
    with_deadline(15) do
      _sup, address = counter
      address.cast([:add, 7])
      expect(address.call(:get, timeout: 5)).to eq(7)
      address.cast(:crash)
      waiter.wait_for(type: :child_started, child: :counter, timeout: 10) { |e| e[:attempt] == 1 }
      expect(address.resolve! && address.call(:get, timeout: 5)).to eq(0)
    end
  end

  it "survives a caller that timed out before the reply (E10)" do
    with_deadline(15) do
      _sup, address = counter
      expect { address.call([:slow, 0.3], timeout: 0.05) }.to raise_error(RactorShepherd::CallTimeout)
      expect(address.call(:get, timeout: 5)).to eq(0)
    end
  end

  it "emits :unhandled_message when handle_cast is not implemented" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:quiet, CallOnly)])
      sup.lookup(:quiet).cast([:whatever])
      event = waiter.wait_for(type: :unhandled_message, child: :quiet, timeout: 10)
      expect(event[:message_class]).to eq("Array")
      expect(sup.which_children.first.status).to eq(:running)
    end
  end

  it "stops cleanly on a shutdown request" do
    with_deadline(15) do
      sup, = counter
      expect(sup.stop).to be(true)
    end
  end
end
