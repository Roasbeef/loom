# executor

## Purpose

The executor service as a process of its own (issue #696, phase S4). The
service, pool and `Dispatcher` live in `packages/broker`
(`broker/executor`, `broker/dispatch`); this package is the thin
entrypoint that boots them without the harness. It exists as a package
for one reason: its dependency list is the compile-time proof that the
service needs no session, provider, web view or daemon. It depends on
`broker` and `core` (plus `argv`, `envoy`, `gleam_json`, `gleam_time`,
`simplifile`) and never on `client`.

It defines no socket, listener, frame, registration or trust model. A
standalone executor has no caller until the distributed-runtime epic
(#697) supplies a transport, and that work implements
`broker/dispatch.Dispatcher`, which is the whole adapter: a remote
transport is a `Dispatcher` whose `start` forwards a `Dispatch` to a peer.
No second type names it.

## Key Types

- `executor.main()` — the entrypoint (`gleam run`). Helper path from
  argv[0], else `LOOM_EXEC_HELPER`, else `bin/loom-exec`. Boots, prints the
  census as one JSON line, runs `true` jailed through the broker and
  service, drains, prints `drain: ok`, and exits 0 only if every step
  succeeded. Failure exits 1 by the entry process killing itself, which
  adds no `@external`.
- `executor.{Config, Standalone}` — `Config(helper, scratch, pool_size)`;
  `Standalone` is opaque (pool, service, broker, incarnation).
- `executor.{boot, census, smoke, drain, incarnation, service_of}` — the
  steps. `drain` is `broker.stop` then `broker/executor.close`, and its
  answer is the pool's native-exit verdict unchanged.
- `executor.{choose_helper, base_policy, census_line, mint_incarnation}` —
  the pure parts: argv, env, default; scratch writable with network off;
  the JSON line; wall-clock microseconds.

## Relationships

Depends on `broker` (`broker`, `census`, `exec`, `executor`, `policy`,
`token`) and `core` (`clock`, `ids`). Nothing depends on it.
`make executor-smoke` builds the helper and runs the entrypoint.

## Invariants

- No `client` dependency. A change that adds one defeats the package.
- No `@external`, no socket, no wire. Remote trust and transport are #697.
- Helper locality: the helper is spawned by `exec.prepare_helper` on the
  machine running this process, as the harness spawns it.
- An incarnation is minted per boot from the wall clock in microseconds, so
  two boots in one VM never share one and an `ExecutionId` of one boot
  never equals one of the other. A restart is a fresh boot; nothing resumes.
- Versions are compared with `broker/census.skew`; features are never
  refused.
- Tests skip with a `SKIP` line on stderr when the helper is absent or the
  platform cannot jail; the incarnation and drain tests need no helper
  because the pool spawns lazily.
