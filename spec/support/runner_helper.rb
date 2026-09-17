# frozen_string_literal: true

# Drives ChildRunner directly, with no supervisor in the picture.
module RunnerHelper
  Started = Struct.new(:ractor, :id, :stop_port, :ref, :start_port, :event_port)

  def start_child(spec, path: "root/#{spec.id}", event_port: nil, name: "spec:#{spec.id}")
    start_port = Ractor::Port.new
    ractor = Ractor.new(spec, start_port, nil, event_port, path.freeze, name: name) do |sp, stp, pr, ep, pa|
      RactorShepherd::Runtime::ChildRunner.run(sp, stp, pr, ep, pa)
    end
    # Like a real supervisor: watch the start port so a crash during startup is caught.
    ractor.monitor(start_port)
    [ractor, start_port]
  end

  # Wait for child_ready and return a Started.
  def start_child!(spec, **options)
    ractor, start_port = start_child(spec, **options)
    message = start_port.receive
    raise "unexpected start message: #{message.inspect}" unless message[0] == :"$child_ready"

    _tag, id, stop_port, ref = message
    Started.new(ractor, id, stop_port, ref, start_port, options[:event_port])
  end

  # Always normalise a monitor notification: Ruby 4.0 sends a Symbol and
  # Ruby 4.1 sends [ractor, status].
  def exit_status(ractor)
    port = Ractor::Port.new
    ractor.monitor(port) # false means it has already finished, and the notification is waiting
    RactorShepherd::Runtime::Compat.monitor_status(port.receive)
  ensure
    # Never call Ractor#unmonitor (see Runtime::Call).
    port.close
  end

  # Pull the reason out of a Ractor that aborted.
  def exit_reason(ractor)
    ractor.value
    :normal
  rescue Ractor::RemoteError => e
    e.cause
  rescue Ractor::Error
    :unknown
  end
end
