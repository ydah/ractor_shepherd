# frozen_string_literal: true

require "rbconfig"
require "tempfile"

module ExampleRunner
  # Run a script in a child process. A hang is killed so that it fails the test.
  def run_ruby_file(path, timeout: 30)
    out = Tempfile.new("shepherd-out")
    err = Tempfile.new("shepherd-err")
    pid = Process.spawn(RbConfig.ruby, path, out: out.path, err: err.path)
    killer = Thread.new do
      sleep timeout
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    _, status = Process.waitpid2(pid)
    killer.kill
    [File.read(out.path), File.read(err.path), status]
  ensure
    [out, err].each do |file|
      file&.close
      file&.unlink
    end
  end
end
