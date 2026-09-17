# frozen_string_literal: true

require "open3"
require "tempfile"
require "rbconfig"

module SubprocessHelper
  # Run a Ruby script in a child process and return [stdout, stderr, status].
  def run_ruby(source)
    Tempfile.create(["shepherd", ".rb"]) do |file|
      file.write(source)
      file.flush
      Open3.capture3(RbConfig.ruby, file.path, chdir: Dir.pwd, stdin_data: "")
    end
  end
end
