# frozen_string_literal: true

RSpec.describe "supervision trees" do
  let(:waiter) { EventWaiter.new }

  def start_root(children, **)
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port, **))
  end

  def wait_running(id) = waiter.wait_for(type: :worker_event, child: id, timeout: 10) { |e| e[:name] == :running }

  # Three levels: root / mid / inner / leaf.
  def three_levels(**leaf_options)
    start_root([
                 RactorShepherd.supervisor(:mid, children: [
                                             RactorShepherd.supervisor(:inner, children: [
                                                                         RactorShepherd.worker(:leaf, Commandable)
                                                                       ], **leaf_options)
                                           ])
               ])
  end

  it "reports a nested supervisor as a SupervisorRef child" do
    with_deadline(15) do
      sup = three_levels
      info = sup.which_children.first
      expect([info.id, info.type, info.status]).to eq(%i[mid supervisor running])
      expect(info.ref).to be_a(RactorShepherd::SupervisorRef)
      expect(info.ref.path).to eq("root/mid")
    end
  end

  it "counts supervisors separately from workers" do
    with_deadline(15) do
      sup = three_levels
      expect(sup.count_children).to eq({ specs: 1, active: 1, workers: 0, supervisors: 1 })
    end
  end

  it "handles a leaf crash at the innermost supervisor only" do
    with_deadline(20) do
      sup = three_levels
      wait_running(:leaf)
      mid = sup.whereis(:mid)
      inner = mid.whereis(:inner)
      leaf = inner.whereis(:leaf)

      leaf.send(:crash)
      waiter.wait_for(type: :child_started, child: :leaf, timeout: 10) { |e| e[:attempt] == 1 }

      expect(sup.whereis(:mid)).to eq(mid)
      expect(mid.whereis(:inner)).to eq(inner)
      expect(inner.whereis(:leaf)).not_to equal(leaf)
    end
  end

  it "tags events with the path of the supervisor that produced them" do
    with_deadline(15) do
      three_levels
      wait_running(:leaf)
      event = waiter.wait_until(timeout: 10) { |es| es.any? { |e| e[:type] == :child_started && e[:child] == :leaf } }
                    .find { |e| e[:type] == :child_started && e[:child] == :leaf }
      expect(event[:supervisor]).to eq("root/mid/inner")
    end
  end

  it "rebuilds the whole subtree when an inner supervisor escalates (E11)" do
    with_deadline(30) do
      sup = three_levels(max_restarts: 0, max_seconds: 5)
      wait_running(:leaf)
      mid = sup.whereis(:mid)
      inner = mid.whereis(:inner)

      inner.whereis(:leaf).send(:crash)
      # inner exceeds its restart budget and dies; mid rebuilds the whole subtree.
      waiter.wait_for(type: :max_restarts_exceeded, timeout: 15)
      waiter.wait_for(type: :child_started, child: :inner, timeout: 15) { |e| e[:attempt] == 1 }

      new_inner = sup.whereis(:mid).whereis(:inner)
      expect(new_inner).not_to eq(inner)
      expect(new_inner.whereis(:leaf)).to be_a(Ractor)
    end
  end

  it "stops the tree from the leaves up" do
    with_deadline(20) do
      sup = three_levels
      wait_running(:leaf)
      waiter.clear
      expect(sup.stop).to be(true)

      events = waiter.wait_until(timeout: 10) do |es|
        es.any? do |e|
          e[:type] == :supervisor_stopped && e[:supervisor] == "root"
        end
      end
      stopped = events.select { |e| e[:type] == :supervisor_stopped }.map { |e| e[:supervisor] }
      expect(stopped).to eq(["root/mid/inner", "root/mid", "root"])
    end
  end

  describe "Address" do
    it "reaches a nested worker" do
      with_deadline(20) do
        sup = three_levels
        wait_running(:leaf)
        out = Ractor::Port.new
        sup.lookup(:mid, :inner, :leaf).cast([:echo, out])
        expect(out.receive).to eq(:echo)
      end
    end

    it "re-resolves across a restart of the target" do
      with_deadline(20) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)])
        wait_running(:a)
        address = sup.lookup(:a)
        out = Ractor::Port.new
        address.cast([:echo, out])
        expect(out.receive).to eq(:echo)

        old = address.ractor
        old.send(:crash)
        waiter.wait_for(type: :child_started, child: :a, timeout: 10) { |e| e[:attempt] == 1 }

        address.cast([:echo, out])
        expect(out.receive).to eq(:echo)
        expect(address.ractor).not_to equal(old)
      end
    end

    it "raises ChildUnavailable when the target is waiting for a delayed restart" do
      with_deadline(20) do
        sup = start_root([RactorShepherd.worker(:a, Commandable, restart_delay: 5)])
        wait_running(:a)
        sup.whereis(:a).send(:crash)
        waiter.wait_for(type: :child_restart_scheduled, child: :a, timeout: 10)

        address = sup.lookup(:a, resolve_timeout: 0.2)
        expect { address.cast([:echo, Ractor::Port.new]) }
          .to raise_error(RactorShepherd::ChildUnavailable, %r{root/a})
      end
    end

    it "refuses to cast to a supervisor" do
      with_deadline(15) do
        sup = three_levels
        expect { sup.lookup(:mid).cast(:hello) }
          .to raise_error(RactorShepherd::InvalidOperation, /supervisor/)
      end
    end

    it "rejects an empty path" do
      with_deadline(15) do
        sup = start_root([RactorShepherd.worker(:a, Commandable)])
        expect { sup.lookup }.to raise_error(RactorShepherd::InvalidSpec, /at least one id/)
      end
    end
  end

  describe "Context#supervisor" do
    it "lets a worker reach a sibling by name" do
      with_deadline(20) do
        out = Ractor::Port.new
        start_root([RactorShepherd.worker(:other, Commandable),
                    RactorShepherd.worker(:caller, SiblingCaller, args: [:other, out])])
        expect(out.receive).to eq(:echo)
      end
    end
  end
end
