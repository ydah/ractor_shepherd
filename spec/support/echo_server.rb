# frozen_string_literal: true

# A tiny server for the Runtime::Call specs. Runs inside its own Ractor.
module EchoServer
  def self.run
    Thread.current.report_on_exception = false
    while true # `loop do` would swallow Ractor::ClosedError, which is a StopIteration
      case Ractor.receive
      in [:"$call", _reply, :crash] then raise ArgumentError, "boom"
      in [:"$call", reply, [:slow, seconds]]
        Kernel.sleep(seconds)
        send_reply(reply)
      in [:"$call", reply, request] then reply << [:"$reply", request]
      in :stop then return :stopped
      end
    end
  end

  # The caller may have timed out and closed its reply port; that is fine.
  def self.send_reply(reply)
    reply << %i[$reply late]
  rescue Ractor::ClosedError
    nil
  end
end
