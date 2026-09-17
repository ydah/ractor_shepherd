<div align="center">
  <h1>ractor_shepherd</h1>
  <p><strong>OTP-style supervision trees for Ruby Ractors with declarative restart strategies and graceful shutdown.</strong></p>
  <p>
    <a href="https://github.com/ydah/ractor_shepherd/actions/workflows/ci.yml"><img src="https://github.com/ydah/ractor_shepherd/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <img src="https://img.shields.io/badge/ruby-%3E%3D%204.0-CC342D.svg" alt="Ruby Version">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
  </p>
</div>

<div align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#worker-types">Worker Types</a> ·
  <a href="#restart-strategies">Restart Strategies</a> ·
  <a href="#how-it-works">How It Works</a> ·
  <a href="#development">Development</a>
</div>

---

`ractor_shepherd` brings Erlang/OTP-style supervision to Ruby's Ractor API.
Supervisors watch child Ractors, restart them according to a policy, and
escalate failures when restarting stops helping.

## Features

<a name="features"></a>

- Static and dynamic supervisors with composable supervision trees
- `:one_for_one`, `:one_for_all`, and `:rest_for_one` restart strategies
- `:permanent`, `:transient`, and `:temporary` child restart policies
- Low-level `Worker` loops or GenServer-style `Server` workers
- Restart intensity limits and configurable restart backoff
- Event ports, a built-in logger, and crash hints for common Ractor errors
- Cooperative shutdown with per-child timeouts
- Ruby 4.0 or later, with no runtime dependencies

## Installation

<a name="installation"></a>

Add to your Gemfile:

```ruby
gem "ractor_shepherd"
```

Then install:

```bash
bundle install
```

### Requirements

<a name="requirements"></a>

- Ruby 4.0+
- `Ractor::Port`

## Quick Start

<a name="quick-start"></a>

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

The block form starts the root supervisor, yields a `SupervisorRef`, and stops
the supervisor when the block exits. `lookup` returns an address that follows a
child across restarts.

## Worker Types

<a name="worker-types"></a>

### `RactorShepherd::Worker`

Use `Worker` when you need to control the receive loop yourself:

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
      ctx.sleep(@interval) # wakes as soon as shutdown is requested
    end
  end

  def terminate(reason) = nil # :normal, :shutdown, or the exception that killed the worker
end
```

The `Context` provides:

| Method | Description |
| --- | --- |
| `id` / `path` | The child's id and path, for example `root/jobs/poller` |
| `supervisor` | The parent `SupervisorRef` |
| `receive(timeout: nil)` | Receive one message; `nil` on timeout; raises `ShutdownSignal` during shutdown |
| `shutdown_requested?` | Whether shutdown has been requested |
| `sleep(seconds)` | Sleep while remaining interruptible by shutdown |
| `emit(name, **data)` | Publish an application event to the event port |

### `RactorShepherd::Server`

Use `Server` for a GenServer-style worker. Its receive loop is already written;
implement `handle_call` for synchronous requests and `handle_cast` for
fire-and-forget messages.

```ruby
class Echo
  include RactorShepherd::Server

  def handle_call(message) = message
end

sup = RactorShepherd.start(name: :root,
                           children: [RactorShepherd.worker(:echo, Echo)])
begin
  echo = sup.lookup(:echo)
  echo.call(:hello, timeout: 5) #=> :hello
  echo.cast(:ignored)
ensure
  sup.stop
end
```

## Restart Strategies

<a name="restart-strategies"></a>

With children `[a, b, c, d]`, when `b` dies:

| Strategy | Stopped, reverse start order | Started, start order |
| --- | --- | --- |
| `:one_for_one` | — | `b` |
| `:one_for_all` | `d, c, a` | `a, b, c, d` |
| `:rest_for_one` | `d, c` | `b, c, d` |

The `restart:` option decides whether a child is restarted:

| Restart kind | Exited on its own | Crashed |
| --- | --- | --- |
| `:permanent` (default) | Restart | Restart |
| `:transient` | Leave stopped | Restart |
| `:temporary` | Drop the child spec | Drop the child spec |

After more than `max_restarts` restarts within `max_seconds`, the supervisor
crashes so its parent can decide what happens next. At the root,
`SupervisorRef#join` raises `SupervisorCrashed`.

## Dynamic Supervisors

<a name="dynamic-supervisors"></a>

Use `start_dynamic` for children that come and go, such as connections or jobs:

```ruby
sup = RactorShepherd.start_dynamic(name: :jobs, max_children: 5)
begin
  id = sup.start_child(
    RactorShepherd.worker(nil, Job, args: ["job-1"], restart: :transient)
  )
  sup.terminate_child(id)
ensure
  sup.stop
end
```

Dynamic supervisors use `:one_for_one` and start with no children. `max_children`
is optional; `nil` means unlimited.

## Observability

<a name="observability"></a>

Pass an event port to `start` or `run` and either use the built-in logger or
consume the event hashes yourself:

```ruby
events = Ractor::Port.new
RactorShepherd::EventLogger.start(events)

sup = RactorShepherd.start(name: :root, event_port: events,
                           children: [RactorShepherd.worker(:counter, Counter)])
```

Events include child starts and exits, restart scheduling, unresponsive
children, and restart-intensity failures. Crash events include the exception
class, message, backtrace, and a `hint` for common Ractor errors.

For custom reporting, read from the port in the Ractor that created it. See
[`examples/crash_report.rb`](examples/crash_report.rb) for a complete example.

## How It Works

<a name="how-it-works"></a>

1. Child specs are validated and copied into shareable data.
2. A supervisor starts children in declaration order and monitors their Ractors.
3. Each child runs as either a low-level `Worker` or a message-driven `Server`.
4. When a child exits, the supervisor applies the declared strategy and restart policy.
5. When restart intensity is exceeded, the failure is escalated to the parent supervisor.

Supervisors can themselves be children, so trees compose naturally:

```ruby
RactorShepherd.run(name: :root, children: [
  RactorShepherd.worker(:cache, Cache),
  RactorShepherd.supervisor(:jobs, strategy: :rest_for_one, children: [
    RactorShepherd.worker(:fetcher, Fetcher),
    RactorShepherd.worker(:parser, Parser)
  ])
]) do |sup|
  sup.lookup(:jobs, :parser).cast(:refresh)
end
```

## Supervisor API

<a name="supervisor-api"></a>

| Entry point | Purpose |
| --- | --- |
| `RactorShepherd.start` | Start a static root supervisor |
| `RactorShepherd.start_dynamic` | Start an empty dynamic supervisor |
| `RactorShepherd.run` | Start, yield, and stop a root supervisor |
| `RactorShepherd.worker` | Describe a worker child |
| `RactorShepherd.supervisor` | Describe a nested static supervisor |
| `RactorShepherd.dynamic_supervisor` | Describe a nested dynamic supervisor |

From a `SupervisorRef`, use `lookup`, `whereis`, `which_children`, and
`count_children` to inspect the tree. Use `start_child`, `terminate_child`,
`restart_child`, and `delete_child` to manage static children at runtime.

An `Address` sends `cast` messages without waiting and uses `call` for a
synchronous reply from a `Server`. `call` does not retry automatically because
the request may not be idempotent.

## Operational Notes

<a name="operational-notes"></a>

### Ractor constraints

- **Ractors are experimental.** The first `Ractor.new` prints a warning. Silence it with `Warning[:experimental] = false`.
- **Ractors cannot be killed from outside.** Shutdown is cooperative. A child spinning on the CPU or blocked inside a C call cannot be stopped; after `shutdown_timeout` it is treated as unresponsive.
- **Worker arguments must be shareable.** `args:` and `kwargs:` are copied with `Ractor.make_shareable(copy: true)`. Procs, Threads, and Mutexes do not cross Ractors; pass plain values and put behavior in a class.
- **Some gems are not Ractor safe.** An unsafe C extension raises `Ractor::UnsafeError`; an unshareable object raises `Ractor::IsolationError`. The event log includes a hint for these errors.
- **Symbols starting with `:"$"` are reserved.** Do not start application messages with one.

### Lifecycle and delivery

- **Do not call `value` or `join` on a child.** Once another Ractor has taken a Ractor's value, the supervisor cannot read the exit reason and reports `:unknown`. Restarting still works.
- **Do not call the supervisor synchronously from `initialize`.** The supervisor is waiting for the child to finish starting, so the call deadlocks until `start_timeout` fires. Look siblings up from `run` instead.
- **Restarting resets state.** Anything that must survive belongs outside the child.
- **Delivery is at-most-once.** A message that arrived just before the child died can be lost.
- **`call` is not for hot paths.** Each call creates a port and timer thread. In the included benchmark, `cast` is roughly 1.1M messages/s while `call` is roughly 30k requests/s. Use `cast` or your own `Ractor::Port` for frequent messages; see [`bench/RESULTS.md`](bench/RESULTS.md).
- **Stopping is sequential.** It can take as long as the sum of every child's `shutdown_timeout`, because children stop one at a time in reverse order.

### Ruby 4.0 `Ractor#unmonitor` caveat

Ruby 4.0.6's `Ractor#unmonitor(port)` looks up a monitor registration by port
id alone and ignores which Ractor created the port. Since port ids are per
Ractor, unmonitoring one registration can remove another Ractor's registration.
Reproduce it with [`spike/unmonitor_id_collision.rb`](spike/unmonitor_id_collision.rb).

This gem therefore never calls `unmonitor`. If a callee dies during a call, the
caller learns about it after the timeout instead of immediately. **Do not call
`unmonitor` on a Ractor managed by this gem.**

### Stopping on a signal

Do not touch ports from inside a trap handler; call `stop` from a thread instead:

```ruby
Signal.trap("TERM") { Thread.new { sup.stop(:shutdown, timeout: 10) } }
```

When the main Ractor ends, the process ends and takes every Ractor with it.
Use the block form of `RactorShepherd.run` or stop the supervisor from `at_exit`.

## Examples

<a name="examples"></a>

Runnable examples are in [`examples/`](examples):

| File | What it shows |
| --- | --- |
| [`basic.rb`](examples/basic.rb) | `one_for_one` and automatic restarts |
| [`tree.rb`](examples/tree.rb) | A supervision tree |
| [`dynamic.rb`](examples/dynamic.rb) | Adding and removing children at runtime |
| [`graceful_shutdown.rb`](examples/graceful_shutdown.rb) | Cooperative shutdown on a signal |
| [`crash_report.rb`](examples/crash_report.rb) | Subscribing to events and reporting failures |

Run one directly:

```bash
ruby examples/basic.rb
```

## Development

<a name="development"></a>

```bash
bundle install
bundle exec rake
bundle exec rake spec:core
bundle exec rake spec:stress
bundle exec rake spec:isolated
```

The default task runs RuboCop, the no-`loop` lint, specs, and RBS validation.
Ractor compatibility is also checked with [`audition`](https://github.com/ruby/audition):

```bash
audition lib
```

## License

<a name="license"></a>

Released under the [MIT License](https://opensource.org/licenses/MIT).
