# frozen_string_literal: true

RSpec.describe RactorShepherd::Core::RestartPolicy do
  # One example per cell of the restart policy table.
  {
    %i[permanent exited] => :restart,
    %i[permanent aborted] => :restart,
    %i[transient exited] => :keep_terminated,
    %i[transient aborted] => :restart,
    %i[temporary exited] => :remove,
    %i[temporary aborted] => :remove
  }.each do |(restart, status), expected|
    it "decides #{expected.inspect} for restart: #{restart.inspect}, status: #{status.inspect}" do
      expect(described_class.decide(restart: restart, status: status)).to eq(expected)
    end
  end

  describe "dynamic supervisors" do
    it "turns :keep_terminated into :remove" do
      expect(described_class.decide(restart: :transient, status: :exited, dynamic: true)).to eq(:remove)
    end

    it "leaves :restart untouched" do
      expect(described_class.decide(restart: :transient, status: :aborted, dynamic: true)).to eq(:restart)
    end
  end

  it "rejects an unknown restart kind" do
    expect { described_class.decide(restart: :forever, status: :exited) }.to raise_error(ArgumentError, /restart/)
  end

  it "rejects an unknown status" do
    expect { described_class.decide(restart: :permanent, status: :vanished) }.to raise_error(ArgumentError, /status/)
  end
end
