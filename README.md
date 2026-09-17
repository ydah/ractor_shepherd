# ractor_shepherd

Supervise Ruby Ractors the way Erlang/OTP supervisors do. When a child Ractor dies
with an exception, it is restarted according to a policy you declare; when
restarting stops helping, the failure is escalated to the supervisor above.
Supervisors can themselves be children, so a supervision tree is just supervisors
all the way down.

- Ruby 4.0 or later, and ready for the Ractor API changes in 4.1
- No runtime dependencies: standard library only
- The decision logic lives in a layer that never touches Ractors, so it is covered by ordinary unit tests

## Installation

```ruby
gem "ractor_shepherd"
```

## A minimal example

```ruby
require "ractor_shepherd"

class Counter
  include RactorShepherd::Server

  def initialize(start = 0)
    super()
    @count = start
  end

  def handle_call(message)
    case message
    in :get then @count
    end
  end

  def handle_cast(message)
    case message
    in [:add, n] then @count += n
    in :crash then raise "boom"
    end
  end
end

events = Ractor::Port.new
RactorShepherd::EventLogger.start(events) # one line per event on stderr

RactorShepherd.run(name: :root, strategy: :one_for_one, max_restarts: 3, max_seconds: 5,
                   event_port: events,
                   children: [RactorShepherd.worker(:counter, Counter, args: [0])]) do |sup|
  counter = sup.lookup(:counter)
  counter.cast([:add, 2])
  counter.call(:get, timeout: 5) #=> 2

  counter.cast(:crash) # it dies, and is restarted with its state back at zero
end
```

Runnable examples live in [`examples/`](examples).

| File | What it shows |
|---|---|
| `examples/basic.rb` | one_for_one and automatic restarts |
| `examples/tree.rb` | a supervision tree |
| `examples/dynamic.rb` | adding and removing children at runtime |
| `examples/graceful_shutdown.rb` | shutting down cleanly on a signal |
| `examples/crash_report.rb` | subscribing to events to report why a child died |

## Two kinds of worker

### `RactorShepherd::Worker`, the low level one

You write the loop yourself. `initialize` plays the role of OTP's `init`.

```ruby
class Poller
  include RactorShepherd::Worker

  def initialize(url, interval)
    super()
    @url = url
    @interval = interval
  end

  def run(ctx)
    until ctx.shutdown_requested?
      fetch(@url)
      ctx.sleep(@interval) # returns as soon as a shutdown is requested
    end
  end

  def terminate(reason) = nil # optional; reason is :normal, :shutdown, or an exception
end
```

What `ctx` (a `Context`) gives you:

| Method | Description |
|---|---|
| `id` / `path` | this child's id and path, e.g. `"root/jobs/poller"` |
| `supervisor` | the parent `SupervisorRef`, which is how you reach siblings |
| `receive(timeout: nil)` | receive one message; nil on timeout; raises `ShutdownSignal` after a shutdown request |
| `shutdown_requested?` | has a shutdown been requested? |
| `sleep(seconds)` | sleep, but wake on shutdown; true if it slept the whole time, false if cut short |
| `emit(name, **data)` | publish an application event to the event port |

### `RactorShepherd::Server`, the GenServer style one

`run` is already written; you fill in `handle_call` and `handle_cast`. Whatever
`handle_call` returns becomes the reply.

## Restart strategies

With children `[a, b, c, d]`, when `b` dies:

| Strategy | Stopped (reverse start order) | Started (start order) |
|---|---|---|
| `:one_for_one` | nothing | `[b]` |
| `:one_for_all` | `[d, c, a]` | `[a, b, c, d]` |
| `:rest_for_one` | `[d, c]` | `[b, c, d]` |

The restart kind (`restart:`) decides whether that child is restarted at all.

| | Exited on its own | Crashed |
|---|---|---|
| `:permanent` (default) | restart | restart |
| `:transient` | leave it stopped | restart |
| `:temporary` | drop the spec | drop the spec |

Once there have been more than `max_restarts` restarts within `max_seconds`, the
supervisor gives up: it crashes itself so that its parent decides what happens
next. At the root, `SupervisorRef#join` raises `SupervisorCrashed`, which is your
cue to log and `exit(1)` and let systemd or Kubernetes restart the process.

## Things to watch out for

- **Ractors are experimental.** The first `Ractor.new` prints a warning. Silence it
  with `Warning[:experimental] = false`.
- **Ractors cannot be killed from outside.** Shutdown is cooperative only. A child
  spinning on the CPU without looking at `ctx`, or blocked inside a C call, cannot
  be stopped; after `shutdown_timeout` it is treated as unresponsive.
- **Symbols starting with `:"$"` are reserved.** Do not start your own messages with one.
- **Do not call `value` or `join` on a child.** Once another Ractor has taken a
  Ractor's value, the supervisor can no longer read the exit reason and reports
  `:unknown`. Restarting still works.
- **Do not call the supervisor synchronously from `initialize`.** The supervisor is
  waiting for this child to finish starting, so the call deadlocks until
  `start_timeout` fires. Look siblings up from `run` instead.
- **Restarting resets a child's state**, exactly as in Erlang. Anything that must
  survive belongs outside the child.
- **Delivery is at-most-once.** A message that arrived just before the child died is lost.
- **`call` is not for hot paths.** Each one builds a port and a timer thread:
  roughly 30k req/s against 1.1M msg/s for `cast` (see [bench/RESULTS.md](bench/RESULTS.md)).
  Use `cast`, or your own `Ractor::Port`, when messages are frequent.
- **Stopping can take as long as the sum of every child's `shutdown_timeout`**,
  because children are stopped one at a time in reverse order.

### Gems that are not Ractor safe

Calling a C extension that is not Ractor safe raises `Ractor::UnsafeError`, and
referencing something unshareable raises `Ractor::IsolationError`. Either way the
child keeps crashing until the supervisor escalates. This gem attaches a `hint` to
the event for the exceptions it recognises, so start from the event log.

```text
ERROR -- [ractor_shepherd] root child_exited child=:a status=:aborted reason=:error
  error_class="Ractor::IsolationError" hint="the child may be referencing something unshareable, such as a Proc or an IO"
```

`args:` and `kwargs:` accept only values that survive
`Ractor.make_shareable(copy: true)`. Procs, Threads and Mutexes do not. Pass plain
values and hand the behaviour over as a class.

### A note on `Ractor#unmonitor` in Ruby 4.0

Ruby 4.0.6's `Ractor#unmonitor(port)` looks a monitor registration up by port id
alone and ignores which Ractor created the port. Port ids are a per Ractor
sequence, so when another Ractor is monitoring the same target, unmonitoring drops
its registration too. Reproduce it with `ruby spike/unmonitor_id_collision.rb`.

This gem therefore never calls `unmonitor`. One consequence: when a callee dies
mid-call, the caller finds out after the timeout rather than immediately.
**Do not call `unmonitor` on a Ractor this gem manages, either.**

## Stopping on a signal

Do not touch ports from inside a trap handler; call `stop` from a thread instead.

```ruby
Signal.trap("TERM") { Thread.new { sup.stop(:shutdown, timeout: 10) } }
```

When the main Ractor ends, the process ends and takes every Ractor with it, so
either use the block form of `RactorShepherd.run` or stop the supervisor from `at_exit`.

## Development

```console
$ bundle install
$ bundle exec rake             # rubocop + lint:no_loop + spec + rbs validate
$ bundle exec rake spec:core   # the unit tests, which use no Ractors
$ bundle exec rake spec:stress # the stress tests
$ bundle exec rake spec:isolated # one file per process, to catch hangs
```

Ractor compatibility is checked with [audition](https://github.com/ruby/audition).

```console
$ audition lib
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
