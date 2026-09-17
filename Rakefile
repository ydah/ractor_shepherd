# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

SPEC_LAYERS = %w[core runtime integration stress].freeze

RSpec::Core::RakeTask.new(:spec) do |t|
  # Stress specs only run when asked for by name.
  t.pattern = "spec/**/*_spec.rb"
  t.exclude_pattern = "spec/stress/**/*_spec.rb"
end

namespace :spec do
  SPEC_LAYERS.each do |layer|
    desc "Run #{layer} specs"
    RSpec::Core::RakeTask.new(layer) do |t|
      t.pattern = "spec/#{layer}/**/*_spec.rb"
    end
  end

  desc "Run every spec file in its own process with a timeout (hang detection)"
  task :isolated do
    limit = Integer(ENV.fetch("ISOLATED_TIMEOUT", 120))
    failed = Dir["spec/**/*_spec.rb"].reject do |file|
      puts "==> #{file}"
      pid = Process.spawn("bundle", "exec", "rspec", file)
      watchdog = Thread.new do
        sleep limit
        warn "timeout after #{limit}s: #{file}"
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      _, status = Process.waitpid2(pid)
      watchdog.kill
      status.success?
    end
    abort "isolated failures: #{failed.join(", ")}" unless failed.empty?
  end
end

desc "Fail if `loop` is used in lib (Ractor::ClosedError < StopIteration; F7)"
task :"lint:no_loop" do
  pattern = /(^|[^.\w])loop\s*(do|\{)/
  offenders = Dir["lib/**/*.rb"].flat_map do |file|
    File.readlines(file).each_with_index.filter_map do |line, i|
      code = line.sub(/#.*/, "") # a "loop do" inside a comment is not an offence
      "#{file}:#{i + 1}: #{line.strip}" if pattern.match?(code)
    end
  end
  abort "`loop do` is forbidden in lib (use `while true`):\n#{offenders.join("\n")}" unless offenders.empty?
end

desc "Validate RBS signatures"
task :"rbs:validate" do
  sh "bundle exec rbs -I sig validate" if Dir.exist?("sig") && !Dir["sig/**/*.rbs"].empty?
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

task default: %i[rubocop lint:no_loop spec rbs:validate]
