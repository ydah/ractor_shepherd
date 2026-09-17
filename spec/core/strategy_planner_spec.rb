# frozen_string_literal: true

RSpec.describe RactorShepherd::Core::StrategyPlanner do
  def view(...) = RactorShepherd::Core::StrategyPlanner::ChildView.new(...)

  def views(*ids, restarts: {}, dead: [])
    ids.map { |id| view(id: id, restart: restarts.fetch(id, :permanent), alive: !dead.include?(id)) }
  end

  describe "the worked example from the design notes ([a, b, c, d], b fails)" do
    let(:children) { views(:a, :b, :c, :d) }

    it "one_for_one terminates nothing and starts [b]" do
      plan = described_class.plan(children: children, failed_id: :b, strategy: :one_for_one)
      expect([plan.terminate, plan.start, plan.remove]).to eq([[], [:b], []])
    end

    it "one_for_all terminates [d, c, a] and starts [a, b, c, d]" do
      plan = described_class.plan(children: children, failed_id: :b, strategy: :one_for_all)
      expect([plan.terminate, plan.start, plan.remove]).to eq([%i[d c a], %i[a b c d], []])
    end

    it "rest_for_one terminates [d, c] and starts [b, c, d]" do
      plan = described_class.plan(children: children, failed_id: :b, strategy: :rest_for_one)
      expect([plan.terminate, plan.start, plan.remove]).to eq([%i[d c], %i[b c d], []])
    end
  end

  describe "when the first child fails" do
    it "rest_for_one covers every child" do
      plan = described_class.plan(children: views(:a, :b, :c), failed_id: :a, strategy: :rest_for_one)
      expect([plan.terminate, plan.start]).to eq([%i[c b], %i[a b c]])
    end
  end

  describe "when the last child fails" do
    it "rest_for_one only restarts that child" do
      plan = described_class.plan(children: views(:a, :b, :c), failed_id: :c, strategy: :rest_for_one)
      expect([plan.terminate, plan.start]).to eq([[], [:c]])
    end
  end

  describe "with temporary children in the group" do
    let(:children) { views(:a, :b, :c, :d, restarts: { c: :temporary }) }

    it "terminates them but does not start them, and removes them" do
      plan = described_class.plan(children: children, failed_id: :b, strategy: :one_for_all)
      expect([plan.terminate, plan.start, plan.remove]).to eq([%i[d c a], %i[a b d], [:c]])
    end

    it "does not remove a temporary child that was already dead" do
      children = views(:a, :b, :c, restarts: { c: :temporary }, dead: [:c])
      plan = described_class.plan(children: children, failed_id: :b, strategy: :one_for_all)
      expect([plan.terminate, plan.remove]).to eq([[:a], []])
    end
  end

  describe "with children that are not alive" do
    it "does not terminate them but still starts them" do
      children = views(:a, :b, :c, :d, dead: %i[a d])
      plan = described_class.plan(children: children, failed_id: :b, strategy: :one_for_all)
      expect([plan.terminate, plan.start]).to eq([[:c], %i[a b c d]])
    end
  end

  it "rejects an unknown strategy" do
    expect { described_class.plan(children: views(:a), failed_id: :a, strategy: :all_for_one) }
      .to raise_error(ArgumentError, /strategy/)
  end

  it "rejects an unknown child" do
    expect { described_class.plan(children: views(:a), failed_id: :z, strategy: :one_for_one) }
      .to raise_error(ArgumentError, /unknown child/)
  end
end
