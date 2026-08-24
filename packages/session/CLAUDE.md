# session

## Purpose

The session layer over one open storage handle: opening a session against a
chosen backend, boot-seeding a strand's registers, typed access to the
machine's register payloads through the machine codecs, and the context
projection the runtime driver reads before every generation. A WP-C slice —
forks, the full compaction projection, custom-entry projectors, the
`transform_context` hook seam, and precise rewrite are WP-C-full (M3).

## Key Types

- `session/session.Session` — one open `Storage(Nil)` (handle type erased)
  plus the lease-renewal capability the runtime's StorageWriter schedules,
  and `lease_interval_ms` (SQLite only; `None` for memory).
- `session/session.Cell(payload)` — a decoded register payload with the seq
  it was read at. Every typed accessor returns one, because the seq is what
  the caller's CAS expectation is built from.
- `session/session.{OpenError, SessionError}` — `SessionCorrupt(report)`
  keeps a decode failure distinct from a store failure.
- `session/session.open_memory` / `open_sqlite` — the two constructors.
- `session/session.ensure_strand` — idempotent boot seeding.
- `session/session.project_context` / `project_scan` — the branch scan to
  provider messages.

## Relationships

- **Depends on**: `core` (ids, entries, registers, tx), `storage` (both
  backends and the handle), `machine` (register payload types and the total
  codecs). Note that the spec's DAG (§0.1) writes `C → A,B`; the machine
  edge is real and load-bearing — typed register access cannot exist
  without the payload codecs.
- **Depended on by**: `runtime` (the writer and the driver both hold a
  `Session`), `conformance` (the instrumented simulation store wraps one).
- **FFI**: none.

## Traffic

- **Actor messages**: none of its own. Every call is a synchronous
  pass-through to the backend actor behind the `Storage` record.
- **Commits**: exactly one path — `ensure_strand`'s three-write seed,
  committed **through the session handle, bypassing the writer**, because
  it runs before the supervision tree exists (spec-gaps WP-E item 2). It is
  CAS-guarded with `Expect(..., seq: None)` on all three registers, and a
  losing concurrent seeder reads `StaleExpectation` as success. Every
  post-boot commit goes through `runtime/writer`.
- **Registers** — reads and decodes, one accessor per namespace:
  `strand_configuration` (`strand.config`), `strand_state`
  (`strand.state`), `strand_leaf` (`strand.leaf`), `last_result`
  (`strand.last_result`), `op_meta` (`op.meta`), `op_state` (`op.state`),
  `tool_arguments` (`op.tool_args`), `preparation` (`op.preparation`),
  `pending_payloads` (`pending.entry`). `register_keys` lists a namespace's
  keys for the machine's terminal cleanup. Writes only the three seed
  registers above.
- **Wire**: none.

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
  branch, oldest first, to provider messages (pi §2.5 steps 1-3 and 5's
  provider mapping). Step 4 is deliberately absent: no custom entry enters
  context.
- **Compaction and branch-summary entries project as user messages** — pi
  §2.5 leaves the provider mapping open, and this is the recorded
  interpretation (spec-gaps WP-E item 7).

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — where the projection sits in the drive loop.
- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the tree, branches, and strands the projection walks.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-E (`runtime`,
  `session`)": boot seeding bypassing the writer, the projection mapping.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
