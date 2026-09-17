# frozen_string_literal: true

# Run each example in a child process and check that it exits cleanly rather than hanging.
RSpec.describe "examples" do
  Dir[File.expand_path("../../examples/*.rb", __dir__)].each do |path|
    name = File.basename(path)

    it "#{name} runs to completion" do
      stdout, stderr, status = run_ruby_file(path, timeout: 30)
      expect(status.exitstatus).to eq(0), "#{name} failed:\n#{stdout}\n#{stderr}"
      expect(stdout).not_to be_empty
    end
  end
end
