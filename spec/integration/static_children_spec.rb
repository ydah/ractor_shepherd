# frozen_string_literal: true

RSpec.describe "static supervisor child management" do
  let(:waiter) { EventWaiter.new }

  def start_root(children = [])
    track(RactorShepherd.start(name: :root, children: children, event_port: waiter.port))
  end

  def wait_running(id) = waiter.wait_for(type: :worker_event, child: id, timeout: 10) { |e| e[:name] == :running }

  it "adds a child through start_child" do
    with_deadline(15) do
      sup = start_root
      expect(sup.start_child(RactorShepherd.worker(:a, Commandable))).to eq(:a)
      expect(sup.which_children.map(&:id)).to eq([:a])
    end
  end

  it "rejects a nil id" do
    with_deadline(15) do
      sup = start_root
      expect { sup.start_child(RactorShepherd.worker(nil, Commandable)) }
        .to raise_error(RactorShepherd::InvalidSpec, /only dynamic/)
    end
  end

  it "keeps the spec after terminate_child so it can be restarted" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)])
      wait_running(:a)
      sup.terminate_child(:a)
      expect(sup.which_children.map { |c| [c.id, c.status] }).to eq([%i[a terminated]])

      expect(sup.restart_child(:a)).to eq(:ok)
      expect(sup.which_children.first.status).to eq(:running)
      expect(sup.whereis(:a)).to be_a(Ractor)
    end
  end

  it "refuses to restart a running child" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)])
      wait_running(:a)
      expect { sup.restart_child(:a) }.to raise_error(RactorShepherd::InvalidOperation, /not terminated/)
    end
  end

  it "refuses to delete a running child" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)])
      wait_running(:a)
      expect { sup.delete_child(:a) }.to raise_error(RactorShepherd::InvalidOperation, /terminate it first/)
    end
  end

  it "deletes a terminated child" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)])
      wait_running(:a)
      sup.terminate_child(:a)
      expect(sup.delete_child(:a)).to eq(:ok)
      expect(sup.which_children).to eq([])
    end
  end

  it "does not restart a child that was terminated through the API" do
    with_deadline(15) do
      sup = start_root([RactorShepherd.worker(:a, Commandable)])
      wait_running(:a)
      sup.terminate_child(:a)
      waiter.clear
      expect(sup.which_children.first.status).to eq(:terminated)
    end
  end
end
