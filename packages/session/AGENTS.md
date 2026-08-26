# session

## Purpose

The session layer over one open storage handle: opening a session against a
chosen backend with migrate-on-open, boot-seeding a strand's registers,
typed access to the machine's register payloads through the machine codecs,
and the full context projection (pi §2.5) the runtime driver reads before
every generation. `session/repo` is the repository boundary above it —
administrative operations *over* sessions rather than inside one: forks
(pi §2.7), the precise rewrite (pi §2.9), and the text-erasure transform
the rewrite exists for. WP-C plus WP-C-full.

## Key Types

- `session/session.Session` — one open `Storage(Nil)` (handle type erased)
  plus the lease-renewal capability the runtime's StorageWriter schedules,
  and `lease_interval_ms` (SQLite only; `None` for memory).
- `session/session.Cell(payload)` — a decoded register payload with the seq
  it was read at. Every typed accessor returns one, because the seq is what
  the caller's CAS expectation is built from.
- `session/session.{OpenError, SessionError}` — `SessionCorrupt(report)`
  keeps a decode failure distinct from a store failure.
- `session/session.open_memory` / `open_sqlite` — the two constructors;
  `open_sqlite` runs `migration_chain()`, the ordered migrate-on-open seam
  every schema bump extends (empty today — storage version 1 is the only
  version that has existed).
- `session/session.ensure_strand` — idempotent boot seeding. It flattens
  every commit refusal it does not already recognize into
  `StoreFailure(BackendFault(..))`, `tx.LeaseLost` included: this layer
  owns no tree to reopen, so the value it could carry has nowhere to go
  and the reason string (`tx.describe_lease_loss`) is what a caller gets.
- `session/session.Projection` — an opaque projection policy built with
  `projection()` then `with_projector(custom_type, ...)` and
  `with_transform(...)`; `CustomView` is what a custom-entry projector
  sees. `project` / `project_context` / `project_entries` / `project_scan`
  run it, the last two purely over a branch scan the caller already has.
- `session/repo.{ForkScope, ForkDestination, ForkError, fork}` — copy one
  coherent view of a source session (`ForkBranch` / `ForkTree`) into a
  fresh destination (`ForkIntoMemory` / `ForkIntoSqlite`), as one atomic
  destination transaction.
- `session/repo.{EntryRewrite, ValueRewrite, erase_text, erase_value,
  rewrite_sqlite, rewrite_memory, MemoryRewrite, RewriteError}` — the
  precise rewrite for both backends and the erase-a-string transforms it
  exists for. Every rewrite takes both an entry transform and a value
  transform (register payloads, usage details): the audit contract covers
  every store a needle can reach, not just entries.

## Relationships

- **Depends on**: `core` (ids, entries, registers, tx), `storage` (both
  backends and the handle), `machine` (register payload types and the total
  codecs). Note that the spec's DAG (§0.1) writes `C → A,B`; the machine
  edge is real and load-bearing — typed register access cannot exist
  without the payload codecs.
- **Depended on by**: `runtime` (the writer and the driver both hold a
  `Session`), `client` (the gateway holds one), `conformance` (the
  instrumented simulation store wraps one). `events` declares the
  dependency in its `gleam.toml` (the spec DAG's `K → A,B,C`) but imports
  nothing from it today.
- **FFI**: none.

## Traffic

- **Actor messages**: none of its own. Every call is a synchronous
  pass-through to the backend actor behind the `Storage` record.
- **Commits**: two paths, both outside the writer because both run where no
  supervision tree owns the store.
  - `ensure_strand`'s three-write seed (`SetRegister` on `strand.leaf`,
    `strand.config`, `strand.state`), committed **through the session
    handle, bypassing the writer**, because it runs before the tree exists
    (spec-gaps WP-E item 2). CAS-guarded with `Expect(..., seq: None)` on
    all three; a losing concurrent seeder reads `StaleExpectation` as
    success.
  - `repo.fork`'s single destination transaction: `InsertEntry` per copied
    entry (ids preserved, `seq`/`ts` re-stamped by the destination),
    `SetRegister` for the destination strands' `strand.leaf` /
    `strand.config` / `strand.state` and for the copied `fact.name` /
    `fact.label`. `repo.rewrite_memory` rebuilds a session the same way but
    retains *everything* — every register namespace verbatim plus
    `InsertUsage` for each ledger row — because a rewrite erases content,
    not history.

  Every post-boot commit goes through `runtime/writer`.
- **Registers** — reads and decodes, one accessor per namespace:
  `strand_configuration` (`strand.config`), `strand_state`
  (`strand.state`), `strand_leaf` (`strand.leaf`), `last_result`
  (`strand.last_result`), `op_meta` (`op.meta`), `op_state` (`op.state`),
  `tool_arguments` (`op.tool_args`), `preparation` (`op.preparation`),
  `pending_payloads` (`pending.entry`). `register_keys` lists a namespace's
  keys for the machine's terminal cleanup. Writes the three seed registers
  above; `repo.fork` additionally writes the destination's `strand.*`,
  `fact.name`, and `fact.label`, and never copies `op.*`, `pending.entry`,
  `strand.last_result`, or `fact.custom`.
- **Wire**: none in-process. `repo.rewrite_sqlite` reaches the file system
  through `storage/sqlite.rewrite_into` (copy, rewrite, vacuum, rename).

## Invariants

- **One writer commits through a session.** Reads may come from anywhere —
  both backends serialize through their own actor mailbox — but exactly one
  StorageWriter process should hold the commit path.
- **Every register read is a total decode.** A payload that does not decode
  is `SessionCorrupt(report)`, never a partial value and never a crash; the
  caller faults rather than continuing on a guess.
- **Every typed read carries its seq.** The `Cell` seq is the input to the
  caller's `SeqExpectation`; dropping it and re-reading later is how
  lost-update bugs enter.
- **Strand seeding is idempotent and race-safe.** An existing
  `strand.config` short-circuits; a concurrent seeder's `StaleExpectation`
  is success, not an error.
- **The projection stops at the first compaction entry** and maps the
  branch, oldest first, through pi §2.5's five rules in order: reverse to
  oldest-first (a heading compaction opens the context with its summary and
  retained tail); drop assistant responses whose stop reason is `error`,
  `aborted`, or `deferred` while retaining genuine output-limit `length`;
  run custom entries through the registered projectors; heal orphaned tool
  calls; apply the `transform_context` hook.
- **An unregistered custom entry never enters context.** Projectors are
  pure per-entry computation keyed by `custom_type`; registering a type
  again replaces the earlier projector.
- **Healing happens at request construction, not at the fork** (pi §2.7,
  spec-gaps WP-C-full item 5). A retained tool call whose result exists
  nowhere later in the projected context gets a synthetic unknown-outcome
  error result directly after its assistant message, before the transform
  hook. On a settled history this is a no-op, which is what keeps
  successive projections append-only.
- **`transform_context` is request-local and applied last.** It is never
  persisted, and the harness trusts it to preserve conversation
  well-formedness — a violating transform is an application defect, not a
  storage validation case.
- **Compaction and branch-summary entries project as user messages** — pi
  §2.5 leaves the provider mapping open, and this is the recorded
  interpretation (spec-gaps WP-E item 7).
- **Fork never mutates the source, and the destination starts idle.** It
  copies entries (ids preserved), strand configuration and leaves, and
  semantic facts; it copies no operation, pending, or terminal-result
  register and no usage row, so the destination's cost ledger starts at
  zero. Forking into a destination that already holds entries is refused.
- **Fork and rewrite are defined over a quiescent source.** Reads serialize
  through the storage actor, but successive reads interleaved with live
  commits could observe two half-states, so the caller — an admin surface,
  never the harness hot path — must ensure no writer is committing. The
  SQLite rewrite enforces this by holding the writer lease for its whole
  duration (a concurrent open is refused `LeaseHeld`); the in-process
  operations trust their caller.
- **Erasure is total at the boundary.** `erase_text` rewrites string values
  in an entry's canonical JSON and leaves object keys alone; the result is
  decoded back through the entry codec, so a needle colliding with
  structural vocabulary aborts the rewrite as corruption rather than
  producing an unreadable store. `erase_value` does the same over the
  free-form register and usage-details JSON, where there is no codec to
  collide with (an id collision inside a register surfaces at the machine
  codecs instead).

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — where the projection sits in the drive loop.
- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the tree, branches, and strands the projection walks.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-E (`runtime`,
  `session`)": boot seeding bypassing the writer, the projection mapping.
  "From WP-C-full (`session`, `storage`)": branch-fork configuration
  source, fork re-stamping placement, the absent parent-session record,
  fact semantics across forks, healing placement, rewrite scope, and what
  erasure leaves alone.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
