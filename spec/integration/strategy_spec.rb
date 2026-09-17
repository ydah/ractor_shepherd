# frozen_string_literal: true

RSpec.describe "restart strategies" do
  let(:waiter) { EventWaiter.new }

  def start_root(children, **)
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port, **))
  end

  def three_commandables
    %i[a b c].map { |id| RactorShepherd.worker(id, Commandable) }
  end

  def wait_until_running(*ids)
    ids.each { |id| waiter.wait_for(type: :worker_event, child: id) { |e| e[:name] == :running } }
  end

  describe ":one_for_one" do
    it "only replaces the failed child" do
      with_deadline(15) do
        sup = start_root(three_commandables, strategy: :one_for_one)
        wait_until_running(:a, :b, :c)
        before = %i[a b c].to_h { |id| [id, sup.whereis(id)] }

        before[:b].send(:crash)
        waiter.wait_for(type: :child_started, child: :b) { |e| e[:attempt] == 1 }

        expect(sup.whereis(:a)).to equal(before[:a])
        expect(sup.whereis(:b)).not_to equal(before[:b])
        expect(sup.whereis(:c)).to equal(before[:c])
      end
    end
  end

  describe ":one_for_all" do
    it "replaces every child" do
      with_deadline(15) do
        sup = start_root(three_commandables, strategy: :one_for_all)
        wait_until_running(:a, :b, :c)
        before = %i[a b c].to_h { |id| [id, sup.whereis(id)] }

        before[:b].send(:crash)
        wait_until_running(:a, :b, :c)

        %i[a b c].each { |id| expect(sup.whereis(id)).not_to equal(before[id]) }
      end
    end

    it "terminates in reverse order and starts in start order" do
      with_deadline(15) do
        sup = start_root(three_commandables, strategy: :one_for_all)
        wait_until_running(:a, :b, :c)
        waiter.clear
        sup.whereis(:b).send(:crash)
        events = waiter.wait_until(timeout: 10) { |evts| evts.count { |e| e[:type] == :child_started } == 3 }

        terminated = events.select { |e| e[:type] == :child_terminated }.map { |e| e[:child] }
        started = events.select { |e| e[:type] == :child_started }.map { |e| e[:child] }
        expect(terminated).to eq(%i[c a])
        expect(started).to eq(%i[a b c])
      end
    end
  end

  describe ":rest_for_one" do
    it "keeps the children before the failed one" do
      with_deadline(15) do
        sup = start_root(three_commandables, strategy: :rest_for_one)
        wait_until_running(:a, :b, :c)
        before = %i[a b c].to_h { |id| [id, sup.whereis(id)] }

        before[:b].send(:crash)
        wait_until_running(:b, :c)

        expect(sup.whereis(:a)).to equal(before[:a])
        expect(sup.whereis(:b)).not_to equal(before[:b])
        expect(sup.whereis(:c)).not_to equal(before[:c])
      end
    end

    it "terminates only the children after the failed one" do
      with_deadline(15) do
        sup = start_root(three_commandables, strategy: :rest_for_one)
        wait_until_running(:a, :b, :c)
        waiter.clear
        sup.whereis(:b).send(:crash)
        events = waiter.wait_until(timeout: 10) { |evts| evts.count { |e| e[:type] == :child_started } == 2 }

        terminated = events.select { |e| e[:type] == :child_terminated }.map { |e| e[:child] }
        started = events.select { |e| e[:type] == :child_started }.map { |e| e[:child] }
        expect(terminated).to eq([:c])
        expect(started).to eq(%i[b c])
      end
    end
  end
end
