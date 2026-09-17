# frozen_string_literal: true

# A counter that several Ractors can share, for tests that need to know how
# many times something has happened across restarts.
#
# The child side creates its own reply port, because only the Ractor that
# created a port may receive from it.
module Coordinator
  def self.run
    Thread.current.report_on_exception = false
    count = 0
    while true
      case Ractor.receive
      in [:"$call", reply, :next]
        reply << [:"$reply", count]
        count += 1
      in :stop then return count
      end
    end
  end

  # Call this from inside a child Ractor.
  def self.next_value(coordinator)
    reply = Ractor::Port.new
    coordinator << [:"$call", reply, :next]
    _tag, value = reply.receive
    value
  ensure
    reply&.close
  end
end
