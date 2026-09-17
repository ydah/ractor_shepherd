# frozen_string_literal: true

# A dynamic supervisor, for children that come and go: one per connection, one per job.
#
#   ruby examples/dynamic.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

class Job
  include RactorShepherd::Worker

  def initialize(label)
    super()
    @label = label
  end

  def run(ctx)
    ctx.emit(:started, label: @label)
    ctx.sleep(3600) until ctx.shutdown_requested?
  end
end

events = Ractor::Port.new
RactorShepherd::EventLogger.start(events)

sup = RactorShepherd.start_dynamic(name: :jobs, max_children: 5, event_port: events)
begin
  ids = 3.times.map { |i| sup.start_child(RactorShepherd.worker(nil, Job, args: ["job-#{i}"], restart: :transient)) }
  puts "started #{ids.inspect}"
  puts "count = #{sup.count_children.inspect}"

  sup.terminate_child(ids.first)
  puts "after terminate = #{sup.which_children.map(&:id).inspect}"
ensure
  sup.stop
end
