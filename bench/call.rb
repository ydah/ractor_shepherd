# frozen_string_literal: true

# Measure call and cast throughput.
#
#   ruby bench/call.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

N = Integer(ENV.fetch("N", 2_000))

class Echo
  include RactorShepherd::Server

  def initialize
    super
    @count = 0
  end

  def handle_call(message) = message
  def handle_cast(_message) = @count += 1
end

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

RactorShepherd.run(name: :bench, children: [RactorShepherd.worker(:echo, Echo)]) do |sup|
  address = sup.lookup(:echo)

  started = clock
  N.times { address.cast([:tick]) }
  cast_elapsed = clock - started

  started = clock
  N.times { address.call(:ping, timeout: 5) }
  call_elapsed = clock - started

  puts format("cast: %8.1f msg/s (%d msgs in %.3fs)", N / cast_elapsed, N, cast_elapsed)
  puts format("call: %8.1f req/s (%d reqs in %.3fs)", N / call_elapsed, N, call_elapsed)

  started = clock
  N.times { sup.which_children }
  sup_elapsed = clock - started
  puts format("supervisor call: %8.1f req/s", N / sup_elapsed)
end
