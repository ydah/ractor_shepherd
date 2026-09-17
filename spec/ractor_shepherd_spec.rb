# frozen_string_literal: true

RSpec.describe RactorShepherd do
  it "has a version number" do
    expect(RactorShepherd::VERSION).not_to be_nil
  end

  it "accepts the running Ruby" do
    expect { RactorShepherd::Runtime::Compat.check! }.not_to raise_error
  end
end
