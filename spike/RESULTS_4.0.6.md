# Ractor API verification

| | |
|---|---|
| Date | 2026-09-17 |
| `ruby -v` | `ruby 4.0.6 (2026-07-14 revision 03b6d3f889) +PRISM [arm64-darwin25]` |
| Script | `spike/ractor_api_check.rb` |

## Output

```text
OK   F1 monitor exited: :exited
OK   F1 monitor aborted: :aborted
OK   F3 monitor on terminated: [false, :exited]
OK   F4 value cause: [E2, :kid]
OK   F5 value twice same ractor: [42, 42]
OK   F5 value taken by other ractor: [42, Ractor::Error]
OK   F6 send to terminated ractor: Ractor::ClosedError
OK   F6 send to port of terminated: Ractor::ClosedError
OK   F7 ClosedError ancestors: [Ractor::ClosedError, StopIteration, IndexError]
OK   F8 forced kill api: [:close]
OK   F10 Port#receive params: []
OK   F11 select identity: [true, :hi]
OK   F12 thread sends to own default port: :t
OK   F13 ractor ends while thread sleeps: [:done, true]
OK   F14 nested Ractor.new: :inner
OK   F15 shareable port/ractor: [true, true]
OK   F16 Data spec + class: [:a, 2]
OK   F17 make_shareable copy: [false, true]
OK   F18 proc isolation: Ractor::IsolationError
OK   F19 report_on_exception suppresses trace: [:aborted, MyErr]
OK   F20 ractor local: [5, nil]
OK   F21 Ractor#id: false
OK   F22 Ractor.new name: "shepherd:root"
OK   F23 select bench (500 ports x 200): "7.2ms"
OK   call pattern: reply port also monitors: [[:$reply, :hello], :aborted]
```

## Differences from what was expected

Every assumption the design relies on held, so no design change was needed.

Notes:

- `Ractor.instance_methods(false)` is
  `[:<<, :[], :[]=, :close, :default_port, :inspect, :join, :monitor, :name, :send, :to_s, :unmonitor, :value]`.
  `Ractor#close` exists but can only be called from inside the Ractor itself; from
  another one it raises `Ractor::Error: closing port by other ractors is not allowed`.
  So there is still no way to kill a Ractor from outside.
- The `Ractor.select` benchmark measures 7.1ms here, against the 17ms recorded on a
  single core miniruby build. Well within expectations.
- Ruby 4.1 (head) is not covered here. The `head` job in CI is what catches the
  change to the monitor notification format and the arrival of `receive(timeout:)`.

## A bug found while implementing (see also spike/unmonitor_id_collision.rb)

`Ractor#unmonitor(port)` looks a monitor registration up by port id alone and
ignores which Ractor created the port. Port ids are a per Ractor sequence
(`#<Ractor::Port to:#1 id:3>`), so when another Ractor is monitoring the same
target, unmonitoring drops its registration too.

Reproduce with `ruby spike/unmonitor_id_collision.rb`:

```text
collision=false watcher=#<Ractor::Port to:#3 id:2> main=#<Ractor::Port to:#1 id:1> watcher_notified=true
collision=true  watcher=#<Ractor::Port to:#5 id:3> main=#<Ractor::Port to:#1 id:3> watcher_notified=false
```

Why it matters here: a Ractor that calls a worker and then unmonitors it can wipe
out the supervisor's own monitor of that worker, leaving the child unsupervised. It
dies and nothing restarts it.

The workaround is to never call `unmonitor` anywhere in the library. Worth
reporting upstream.
