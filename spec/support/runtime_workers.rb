# frozen_string_literal: true

# Workers for the Runtime layer specs. They report what happened by sending to
# a Ractor::Port handed in through their arguments.

# Observes what ctx.receive does.
class EchoWorker
  include RactorShepherd::Worker

  def initialize(out, timeout: nil)
    @out = out
    @timeout = timeout
  end

  def run(ctx)
    while true
      message = ctx.receive(timeout: @timeout)
      @out << [:received, message]
    end
  rescue RactorShepherd::ShutdownSignal
    @out << [:shutdown_signal, ctx.shutdown_reason]
    raise
  end

  def terminate(reason)
    @out << [:terminate, reason.is_a?(Exception) ? reason.class.name : reason]
  end
end

# Observes what ctx.sleep returns.
class SleepWorker
  include RactorShepherd::Worker

  def initialize(out, seconds)
    @out = out
    @seconds = seconds
  end

  def run(ctx)
    @out << [:slept, ctx.sleep(@seconds)]
    @out << [:requested, ctx.shutdown_requested?]
  end

  def terminate(reason)
    @out << [:terminate, reason.is_a?(Exception) ? reason.class.name : reason]
  end
end

# Returns from run straight away.
class FinishingWorker
  include RactorShepherd::Worker

  def initialize(out) = @out = out
  def run(_ctx) = @out << [:ran]
  def terminate(reason) = @out << [:terminate, reason.is_a?(Exception) ? reason.class.name : reason]
end

# Raises from run.
class CrashingWorker
  include RactorShepherd::Worker

  def initialize(out) = @out = out
  def run(_ctx) = raise ArgumentError, "boom"
  def terminate(reason) = @out << [:terminate, reason.is_a?(Exception) ? reason.class.name : reason]
end

# Raises from initialize.
class BadInitWorker
  include RactorShepherd::Worker

  def initialize(*)
    super()
    raise ArgumentError, "cannot initialize"
  end

  def run(_ctx) = nil
end

# Raises from terminate.
class BadTerminateWorker
  include RactorShepherd::Worker

  def initialize(out, crash_in_run)
    @out = out
    @crash_in_run = crash_in_run
  end

  def run(_ctx)
    raise ArgumentError, "run failed" if @crash_in_run

    @out << [:ran]
  end

  def terminate(_reason) = raise TypeError, "terminate failed"
end

# Publishes an application event.
class EmittingWorker
  include RactorShepherd::Worker

  def initialize(name) = @name = name

  def run(ctx)
    ctx.emit(:hello, name: @name)
    ctx.sleep(3600) until ctx.shutdown_requested?
  end
end
