# frozen_string_literal: true

# A supervision tree: supervisors can be children too.
#
#   ruby examples/tree.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
Warning[:experimental] = false
require "ractor_shepherd"

class Echo
  include RactorShepherd::Server

  def handle_call(message) = message
end

events = Ractor::Port.new
RactorShepherd::EventLogger.start(events)

RactorShepherd.run(name: :root, event_port: events, children: [
                     RactorShepherd.worker(:cache, Echo),
                     RactorShepherd.supervisor(:jobs, strategy: :rest_for_one, children: [
                                                 RactorShepherd.worker(:fetcher, Echo),
                                                 RactorShepherd.worker(:parser, Echo)
                                               ])
                   ]) do |sup|
  puts "root children = #{sup.which_children.map { |c| [c.id, c.type] }.inspect}"

  jobs = sup.whereis(:jobs)
  puts "jobs path = #{jobs.path}"
  puts "jobs children = #{jobs.which_children.map(&:id).inspect}"

  puts "parser says #{sup.lookup(:jobs, :parser).call(:hello, timeout: 5).inspect}"
end
