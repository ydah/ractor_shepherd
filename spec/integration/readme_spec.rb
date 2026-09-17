# frozen_string_literal: true

require "tempfile"

RSpec.describe "README" do
  let(:readme) { File.read(File.expand_path("../../README.md", __dir__)) }

  it "has a minimal example that actually runs" do
    source = readme[/## A minimal example\n\n```ruby\n(.*?)```/m, 1]
    expect(source).not_to be_nil

    Tempfile.create(["readme", ".rb"]) do |file|
      file.write("$LOAD_PATH.unshift(File.expand_path(\"lib\"))\nWarning[:experimental] = false\n#{source}")
      file.flush
      _stdout, stderr, status = run_ruby_file(file.path, timeout: 30)
      expect(status.exitstatus).to eq(0), stderr
    end
  end

  it "warns about every pitfall a user needs to know" do
    ["experimental", "cannot be killed", "value", "initialize", "at-most-once", "unmonitor"].each do |topic|
      expect(readme).to include(topic)
    end
  end
end
