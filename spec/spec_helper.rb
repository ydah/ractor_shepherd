# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    add_group "Core", "lib/ractor_shepherd/core"
    add_group "Runtime", "lib/ractor_shepherd/runtime"
  end
end

require "stringio"

Warning[:experimental] = false

require "ractor_shepherd"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.include DeadlineHelper
  config.include ExampleRunner
  config.include RunnerHelper
  config.include SubprocessHelper
  config.include SupervisorTracking

  config.after { stop_tracked_supervisors }
end
