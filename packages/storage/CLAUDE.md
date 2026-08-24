# storage

## Purpose

One session's durable store behind a uniform, backend-agnostic handle:
the `Storage` behaviour of the frozen contract (spec Part 1.2) plus its two
implementations — `memory` (pure maps in an actor) and `sqlite` (one
database file per session, writer lease, private segmented branch index).
Both pass the same conformance suite; that suite is the definition of
correct. WP-B.

## Key Types

- `storage/storage.Storage(handle)` — a record of functions closed over a
  backend handle: `commit`, `get_entries`, `get_register`,
  `list_registers`, `scan_branch`, `scan_entries`, `scan_usage`, `stats`,
  `close`. `session` erases the handle type to `Storage(Nil)`.
- `storage/storage.{BranchScan, EntryScan, UsageScan}` — the three query
  shapes, built with the pipeline builders (`branch_scan`,
  `branch_stop_at_kind`, `branch_cursor`, `entry_seq_range`, ...).
- `storage/storage.StorageError` — the read-path error type, deliberately
  distinct from `core/tx.CommitError` which the commit path keeps frozen.
- `storage/memory.MemoryState` — the storage model as pure data (entries, a
  children index, registers, the usage ledger, the stats projection, next
  seq). Every mutation is a pure function over it, so the conformance suite
  can drive the model with no process involved.
- `storage/sqlite.{Config, OpenError, Segment}` — file path, lease owner,
  lease TTL, busy timeout; the segmented branch-index window type.
- `storage/internal/branch.Refine` — the shared incremental
  truncate/filter/cursor/limit pipeline, fed page by page by SQLite and
  whole by Memory.

## Relationships

- **Depends on**: `core` (ids, entries, registers, tx, codecs,
  corruption), `sqlight` (the SQLite binding, ADR-002), `gleam_erlang` +
  `gleam_otp` (both backends are actors).
- **Depended on by**: `session` (wraps one open handle), `runtime` (the
  StorageWriter owns it), `conformance` (the suite and the instrumented
  simulation store).
- **FFI**: none directly; SQLite reaches the world through `sqlight`.

## Traffic

- **Actor messages** — both backends expose an opaque `Message` and
  serialize everything through one mailbox ("one writer, one queue"):
  `Commit(tx, reply)`, `GetEntries(ids, reply)`,
  `GetRegister(ns, key, reply)`, `ListRegisters(ns, prefix, reply)`,
  `ScanBranch(q, reply)`, `ScanEntries(q, reply)`, `ScanUsage(q, reply)`,
  `Stats(reply)`, `Close(reply)`. Every variant is a call. `sqlite` adds
  lease renewal, driven from `runtime/writer`'s `RenewTick`.
- **Commits**: applies `core/tx.Write` — `InsertEntry`, `InsertUsage`,
  `SetRegister`, `DeleteRegister` — in list order, after evaluating every
  `SeqExpectation`. Assigns `seq` and `ts` at commit; `storage.stamp`
  writes them onto the entry.
- **Registers**: generic over all namespaces; stores `RegisterValue`
  payloads opaquely and returns them with their seq (`Register`). No
  history, no interpretation of `strand.*` / `op.*` payloads.
- **Wire**: the SQLite file schema — write-once `entries` and
  `usage_ledger`, mutable `registers`, `branch_entries` + `branch_meta`,
  a single-row `session` catalog, and `writer_lease`. `storage_version`
  is 1.

## Invariants

- **All-or-none commits.** Validation completes before any state is
  replaced; a failed commit applies nothing and consumes no seq. Seqs are
  strictly increasing per session; gaps are legal.
- **Every SQLite transaction opens with `BEGIN IMMEDIATE`.** Allocating the
  seq range reads `session.next_seq` before writing it, so every commit
  reads before it writes; a deferred `BEGIN` takes a read snapshot it
  cannot upgrade, and `busy_timeout` cannot rescue that.
- **The writer lease is the single-writer rule.** WAL lets two processes
  alternate writes to one file; the lease makes "one process owns one
  session" enforced rather than assumed. `open` acquires expiring fenced
  ownership and may steal an expired lease with a bumped fence; every
  commit renews it; a commit whose `(owner_id, fence)` no longer matches
  fails `Faulted` and applies nothing; `close` deletes only its own pair,
  so a stale owner cannot release its replacement.
- **Branch reads never fall back to a table scan or parent walk.**
  `scan_branch` drives from `branch_entries` via a `CROSS JOIN` that forces
  the join order and pages segment windows. `scan_branch_plan` exposes
  `EXPLAIN QUERY PLAN` so the conformance suite fails on any
  `TEMP B-TREE FOR ORDER BY` or entries-scan regression — the query plan is
  an enforced contract, not a performance note.
- **Writing an entry or usage row under an existing id is corruption**, not
  an update. Entry and usage ids share one namespace.
- **Register semantics**: set replaces, delete removes, delete-absent is a
  no-op, no history. A delete consumes a seq like any other write.
- **CAS is evaluated before anything applies.** Each `SeqExpectation` names
  the register seq the committer computed against (`None` = must not
  exist); any mismatch returns `StaleExpectation` with nothing applied.
  CAS-only commits (empty writes, non-empty expectations) are legal.
- **Parent-must-exist is enforced at commit**; in-transaction parents work
  because writes apply in order.
- **Close is idempotent** (pi §1.5): a sealed handle answers handle-closed
  on reads and faulted on commits rather than crashing.
- **Stats equal the ledger sum after every commit** — the conformance suite
  asserts it at each transaction, not just at the end.

## Deep Docs

- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the plane in full: the three stores, the segmented index, query plans as
  contract, crash behavior.
- [docs/adr/002-sqlite-binding.md](../../docs/adr/002-sqlite-binding.md) —
  why `sqlight`.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-B/T": the two
  extra indexes, actor-per-backend, close idempotence, CAS-only commits.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
