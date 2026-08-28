# storage

## Purpose

One session's durable store behind a uniform, backend-agnostic handle:
the `Storage` behaviour of the frozen contract (spec Part 1.2) plus its two
implementations — `memory` (pure maps in an actor) and `sqlite` (one
database file per session, writer lease, private segmented branch index,
migrate-on-open, and the offline precise rewrite). Both pass the same
conformance suite; that suite is the definition of correct. WP-B, extended
by WP-C-full.

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
  `OpenError.UnsupportedVersion(found, supported)` is the fail-closed
  answer to a file this build cannot read.
- `storage/sqlite.Migration(from_version, statements)` — one migrate-on-open
  step, run by `open_with_migrations`; the chain itself is owned by
  `session.migration_chain`. `sqlite.storage_version` is 1, so the chain is
  empty today.
- `storage/sqlite.{record_identity, identity}` — the catalog row's
  identity projection (`protocol-change/008`): `record_identity` writes
  the session's canonical id into the metadata blob and its parent's into
  the long-reserved `parent_session_id` column, and `identity(path:)`
  reads both back without taking the writer lease, the way
  `generation(path:)` does. Both are a **projection** — the session's
  `session/id` / `session/parent` register cells are the truth — so it
  needs no schema version bump and a failed write costs only a repair on
  the next open.
- `storage/sqlite.{Rewrite, RewriteError, rewrite_into, generation}` — the
  offline precise rewrite (pi §2.9) over a **closed** file, and the
  rewrite-generation counter external indexes key their cursors on.
  `rewrite_into` takes two transforms: an entry rewrite for `entries`
  payloads and a value rewrite for register payloads and usage-ledger
  details, because the audit contract covers every store a needle can
  reach.
- `storage/internal/branch.Refine` — the shared incremental
  truncate/filter/cursor/limit pipeline, fed page by page by SQLite and
  whole by Memory.

## Relationships

- **Depends on**: `core` (ids, entries, registers, tx, codecs,
  corruption), `sqlight` (the SQLite binding, ADR-002), `simplifile` (the
  rewrite's copy/rename/unlink), `gleam_erlang` + `gleam_otp` (both
  backends are actors).
- **Depended on by**: `session` (wraps one open handle; owns the migration
  chain and drives the rewrite), `runtime` (the StorageWriter owns it),
  `events` (projections and the search service scan sessions through the
  `Storage` record), `client` (the gateway's catch-up scans), `conformance`
  (the suite and the instrumented simulation store).
- **FFI**: none directly; SQLite reaches the world through `sqlight`.

## Traffic

- **Actor messages** — both backends expose an opaque `Message` and
  serialize everything through one mailbox ("one writer, one queue"):
  `Commit(tx, reply)`, `GetEntries(ids, reply)`,
  `GetRegister(ns, key, reply)`, `ListRegisters(ns, prefix, reply)`,
  `ScanBranch(q, reply)`, `ScanEntries(q, reply)`, `ScanUsage(q, reply)`,
  `Stats(reply)`, `Close(reply)`. Every variant is a call. `sqlite` adds
  lease renewal, driven from `runtime/writer`'s `RenewTick`, and
  `Segments(reply)` for the branch-index diagnostics the conformance suite
  asserts on. `rewrite_into` and `generation` take a **path**, not a
  handle: they are offline operations with no actor involved.
- **Commits**: applies `core/tx.Write` — `InsertEntry`, `InsertUsage`,
  `SetRegister`, `DeleteRegister` — in list order, after evaluating every
  `SeqExpectation`. Assigns `seq` and `ts` at commit; `storage.stamp`
  writes them onto the entry.
- **Registers**: generic over all namespaces; stores `RegisterValue`
  payloads opaquely and returns them with their seq (`Register`). No
  history, no interpretation of `strand.*` / `op.*` payloads.
- **Wire**: the SQLite file schema — write-once `entries` and
  `usage_ledger`, mutable `registers`, `branch_entries` + `branch_meta`,
  a single-row `session` catalog (carrying `storage_version`, the rewrite
  `generation` and the projected `session_id` in its metadata blob, and
  the projected `parent_session_id` in its column), and `writer_lease`.
  `storage_version` is 1.

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
  fails `tx.LeaseLost(held_by:)` — naming the thief when the row names
  one, `None` when the row was cleared — and applies nothing; `close`
  deletes only its own pair, so a stale owner cannot release its
  replacement. The condition is a value rather than a `Faulted` reason
  string precisely because its remedy is opposite to every other commit
  failure's: reopen, never retry (`protocol-change/005`). The read path
  still flattens it, since `StorageError` has no lease vocabulary —
  `renew_lease` reports `BackendFault(tx.describe_lease_loss(..))`, which
  is what stops the runtime's writer.
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
- **A version is migrated or refused, never misread — and a refusal writes
  nothing.** Open runs in refuse-before-write order: one `BEGIN IMMEDIATE`
  admission transaction reads the stored version, refuses a newer file or
  an uncovered older one (`UnsupportedVersion(found, supported)`) or a held
  lease with the file byte-untouched, and otherwise claims the lease;
  schema DDL, the migration chain, and the WAL journal switch run only
  after that, under the lease (pi §2.8). A step's `statements` and its
  version bump commit in one transaction. The same admission transaction
  serializes racing creators, so N concurrent opens of a fresh path write
  exactly one catalog row and every loser gets an in-band `OpenError`.
- **The precise rewrite is the sole sanctioned exception to "entries are
  never modified"** (pi §2.9), and it is offline: an unexpired writer lease
  refuses it with `RewriteLeaseHeld`. The rewrite then *claims and holds*
  the lease in the original under the reserved owner `"rewrite"` for its
  whole duration — a concurrent open is refused `LeaseHeld` instead of
  committing into a file the swap would discard — and re-verifies the
  claim immediately before the rename, aborting if it was stolen. It works
  on a `VACUUM INTO` copy and only an atomic rename replaces the original,
  so every failure path leaves the original file's content untouched (and
  releases the lease).
- **A rewrite must leave no erased bytes behind.** The source's WAL is
  retired *before* the copy is taken (a verified TRUNCATE checkpoint —
  SQLite would replay any matching WAL into the swapped-in file on the
  next open, resurrecting the erased text), the copy is vacuumed so
  replaced content does not survive in free pages, and the leftover
  `-wal`/`-shm` siblings are unlinked after the swap with failures
  *propagated*, never discarded. The transforms reach entries, register
  payloads, and usage details alike — the audit contract is that the
  erased string appears nowhere in the new file's raw bytes.
- **A rewrite preserves each entry's id, parent, and kind**; a transform
  that moves an entry, or reports corruption, aborts the whole rewrite with
  nothing swapped. Every rewrite bumps the `generation` counter, which is
  how an external index (WP-K search) learns its cursors are invalid;
  `generation` reads it without taking the lease, and never conjures a file
  that does not exist.

## Deep Docs

- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the plane in full: the three stores, the segmented index, query plans as
  contract, crash behavior.
- [docs/adr/002-sqlite-binding.md](../../docs/adr/002-sqlite-binding.md) —
  why `sqlight`.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-B/T": the two
  extra indexes, actor-per-backend, close idempotence, CAS-only commits.
  "From WP-C-full": rewrite scope, the memory backend's absent
  generation counter.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
