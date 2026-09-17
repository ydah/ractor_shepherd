# Benchmark results

| | |
|---|---|
| Date | 2026-09-17 |
| Ruby | `ruby 4.0.6 (2026-07-14 revision 03b6d3f889) +PRISM [arm64-darwin25]` |
| Machine | Apple silicon (arm64-darwin25) |

To reproduce:

```console
$ ruby bench/restart.rb 10,100,1000
$ ruby bench/call.rb
```

## Restart cost as children grow (`bench/restart.rb`)

```text
children    boot(s)    stop(s)    restart(ms)
10            0.002      0.000          0.283
100           0.006      0.005          0.349
1000          0.142      0.100          1.706
```

- `boot` is the time to wait for every child's `initialize`, in order; `stop` is the
  cooperative shutdown of all of them, in reverse.
- `restart` is the average of twenty runs of "kill a child, wait for a different
  Ractor to appear".
- Even with a thousand children a restart is around a millisecond. The watch loop
  hands every port to `Ractor.select`, so it is O(children); that is where the
  roughly fourfold increase from ten to a thousand comes from.

## Call throughput (`bench/call.rb`)

```text
cast: 1126760.6 msg/s (2000 msgs in 0.002s)
call:  27529.6 req/s (2000 reqs in 0.073s)
supervisor call:  29873.9 req/s
```

- `cast` sends and forgets, so it is orders of magnitude faster.
- `call` builds a port and a timer thread each time, which caps it around 30k req/s.
  Use `cast` or your own port when messages are frequent.
