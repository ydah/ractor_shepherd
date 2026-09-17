# frozen_string_literal: true

RSpec.describe "many dynamic children" do
  # CI turns this down with STRESS_CHILDREN=50.
  let(:count) { Integer(ENV.fetch("STRESS_CHILDREN", 200)) }
  let(:waiter) { EventWaiter.new }

  it "starts and stops #{ENV.fetch("STRESS_CHILDREN", 200)} children" do
    with_deadline(120) do
      sup = track(RactorShepherd.start_dynamic(name: :pool, event_port: waiter.port))
      ids = Array.new(count) { sup.start_child(RactorShepherd.worker(nil, Commandable, restart: :temporary)) }
      expect(ids.size).to eq(count)
      expect(sup.count_children[:active]).to eq(count)
      expect(sup.stop(:shutdown, timeout: 60)).to be(true)
    end
  end
end
