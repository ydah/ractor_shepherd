# frozen_string_literal: true

require_relative "lib/ractor_shepherd/version"

Gem::Specification.new do |spec|
  spec.name = "ractor_shepherd"
  spec.version = RactorShepherd::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "OTP-style supervisor for Ruby Ractors."
  spec.description = "ractor_shepherd supervises Ractors the way Erlang/OTP supervisors do: " \
                     "declarative restart strategies, restart intensity, supervision trees " \
                     "and ordered graceful shutdown. No runtime dependencies."
  spec.homepage = "https://github.com/ydah/ractor_shepherd"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs"] + ["README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
end
