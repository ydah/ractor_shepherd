# frozen_string_literal: true

# Workers for the integration specs. They report through ctx.emit, so that
# examples can wait on events instead of sleeping for a fixed time.

# Records its start and stop, then waits.
class Recorder
  include RactorShepherd::Worker

  def run(ctx)
    @ctx = ctx
    ctx.emit(:running)
    ctx.sleep(3600) until ctx.shutdown_requested?
    ctx.emit(:stopping)
  end

  def terminate(reason)
    @ctx&.emit(:terminated, reason: reason.is_a?(Exception) ? reason.class.name : reason)
  end
end

# Crashes or returns on command.
class Commandable
  include RactorShepherd::Worker

  def run(ctx)
    ctx.emit(:running)
    while true
      case ctx.receive
      in :crash then raise ArgumentError, "boom"
      in :finish then return :done
      in [:echo, port] then port << :echo
      else nil
      end
    end
  end
end

# Crashes as soon as it starts.
class AlwaysCrashing
  include RactorShepherd::Worker

  def run(_ctx) = raise ArgumentError, "always"
end

# Always fails to initialize.
class BadInit
  include RactorShepherd::Worker

  def initialize
    super
    raise ArgumentError, "cannot init"
  end

  def run(_ctx) = nil
end

# Ignores shutdown requests.
class Deaf
  include RactorShepherd::Worker

  def run(ctx)
    ctx.emit(:running)
    Kernel.sleep(3600)
  end
end

# Takes its time to start, for the start_timeout examples.
class SlowInit
  include RactorShepherd::Worker

  def initialize(seconds)
    super()
    Kernel.sleep(seconds)
  end

  def run(ctx)
    ctx.sleep(3600) until ctx.shutdown_requested?
  end
end

# Starts once, then fails to initialize on every restart.
class FailAfterFirstInit
  include RactorShepherd::Worker

  def initialize(coordinator)
    super()
    attempt = Coordinator.next_value(coordinator)
    raise ArgumentError, "init failed on attempt #{attempt}" if attempt.positive?
  end

  def run(ctx)
    ctx.emit(:running)
    while true
      case ctx.receive
      in :crash then raise ArgumentError, "boom"
      else nil
      end
    end
  end
end

# Messages a sibling through lookup.
class SiblingCaller
  include RactorShepherd::Worker

  def initialize(sibling_id, out)
    super()
    @sibling_id = sibling_id
    @out = out
  end

  def run(ctx)
    ctx.emit(:running)
    ctx.supervisor.lookup(@sibling_id).cast([:echo, @out])
    ctx.sleep(3600) until ctx.shutdown_requested?
  end
end

# Comes up, waits a moment, then dies. For the restart storm specs.
class CrashLoop
  include RactorShepherd::Worker

  def initialize(delay)
    super()
    @delay = delay
  end

  def run(ctx)
    ctx.emit(:running)
    ctx.sleep(@delay)
    raise ArgumentError, "crash loop"
  end
end

# Takes its time finishing after a shutdown request.
class SlowStop
  include RactorShepherd::Worker

  def initialize(delay)
    super()
    @delay = delay
  end

  def run(ctx)
    ctx.emit(:running)
    ctx.sleep(3600) until ctx.shutdown_requested?
    Kernel.sleep(@delay)
  end
end

# A GenServer style counter.
class Counter
  include RactorShepherd::Server

  def initialize(start = 0)
    super()
    @count = start
  end

  def handle_call(message)
    case message
    in :get then @count
    in :crash then raise ArgumentError, "call boom"
    in [:slow, seconds]
      Kernel.sleep(seconds)
      @count
    end
  end

  def handle_cast(message)
    case message
    in [:add, n] then @count += n
    in :crash then raise ArgumentError, "cast boom"
    else nil
    end
  end
end

# A Server with no handle_cast.
class CallOnly
  include RactorShepherd::Server

  def handle_call(_message) = :pong
end

# Raises Ractor::IsolationError, for the event hint examples.
class IsolationBreaker
  include RactorShepherd::Worker

  def run(_ctx)
    outer = +"captured"
    Ractor.make_shareable(proc { outer })
  end
end
