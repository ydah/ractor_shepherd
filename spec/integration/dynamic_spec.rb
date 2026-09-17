# frozen_string_literal: true

RSpec.describe "dynamic supervisor" do
  let(:waiter) { EventWaiter.new }

  def start_dynamic(**)
    track(RactorShepherd.start_dynamic(name: :pool, event_port: waiter.port, **))
  end

  def wait_running(id) = waiter.wait_for(type: :worker_event, child: id, timeout: 10) { |e| e[:name] == :running }

  it "starts with no children" do
    with_deadline(15) do
      expect(start_dynamic.which_children).to eq([])
    end
  end

  it "numbers children automatically when the id is nil" do
    with_deadline(15) do
      sup = start_dynamic
      ids = 3.times.map { sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient)) }
      expect(ids).to eq([1, 2, 3])
      expect(sup.which_children.map(&:id)).to eq([1, 2, 3])
    end
  end

  it "accepts an explicit id and rejects a duplicate (E13)" do
    with_deadline(15) do
      sup = start_dynamic
      expect(sup.start_child(RactorShepherd.worker(:a, Commandable, restart: :transient))).to eq(:a)
      expect { sup.start_child(RactorShepherd.worker(:a, Commandable, restart: :transient)) }
        .to raise_error(RactorShepherd::InvalidSpec, /duplicated child id/)
    end
  end

  it "refuses to go past max_children" do
    with_deadline(15) do
      sup = start_dynamic(max_children: 2)
      2.times { sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient)) }
      expect { sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient)) }
        .to raise_error(RactorShepherd::MaxChildrenReached)
    end
  end

  it "reports a failed start as StartError and keeps no spec" do
    with_deadline(15) do
      sup = start_dynamic
      expect { sup.start_child(RactorShepherd.worker(:bad, BadInit, restart: :temporary)) }
        .to raise_error(RactorShepherd::StartError, /cannot init/)
      expect(sup.which_children).to eq([])
    end
  end

  it "removes a child that was terminated through the API" do
    with_deadline(15) do
      sup = start_dynamic
      id = sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient))
      wait_running(id)
      expect(sup.terminate_child(id)).to eq(:ok)
      expect(sup.which_children).to eq([])
    end
  end

  it "removes a :transient child that exited normally" do
    with_deadline(15) do
      sup = start_dynamic
      id = sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient))
      wait_running(id)
      sup.whereis(id).send(:finish)
      waiter.wait_for(type: :child_exited, child: id, timeout: 10)
      expect(sup.which_children).to eq([])
    end
  end

  it "restarts a :transient child that crashed" do
    with_deadline(15) do
      sup = start_dynamic
      id = sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient))
      wait_running(id)
      before = sup.whereis(id)
      before.send(:crash)
      waiter.wait_for(type: :child_started, child: id, timeout: 10) { |e| e[:attempt] == 1 }
      expect(sup.whereis(id)).not_to equal(before)
    end
  end

  it "does not support restart_child or delete_child" do
    with_deadline(15) do
      sup = start_dynamic
      id = sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :transient))
      expect { sup.restart_child(id) }.to raise_error(RactorShepherd::InvalidOperation, /dynamic/)
      expect { sup.delete_child(id) }.to raise_error(RactorShepherd::InvalidOperation, /dynamic/)
    end
  end

  it "raises ChildNotFound for an unknown id" do
    with_deadline(15) do
      expect { start_dynamic.terminate_child(:nope) }.to raise_error(RactorShepherd::ChildNotFound)
    end
  end

  it "stops every child on stop" do
    with_deadline(20) do
      sup = start_dynamic
      ids = 3.times.map { sup.start_child(RactorShepherd.worker(nil, Recorder, restart: :transient)) }
      ids.each { |id| wait_running(id) }
      expect(sup.stop).to be(true)
    end
  end
end
