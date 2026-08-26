# core

## Purpose

The vocabulary every other package shares: opaque ids, the write-once
durable rows, the closed register-namespace set, the transaction types, and
the two total codecs (JSON and msgpack) that guard every durability and
wire boundary. WP-A, and the root of the dependency DAG — `core` depends on
`gleam_stdlib` and nothing else, not even `gleam_erlang`.

## Key Types

- `core/ids.{EntryId, UsageId, OpId}` — distinct opaque UUIDv7 wrappers, so
  an `EntryId` can never be passed where an `OpId` belongs. `Generator`
  mints them purely from an injected `Clock` plus a seeded SplitMix64
  state; `mint_follower` reuses a parent's 48-bit time prefix with a fresh
  random tail.
- `core/entry.Entry` — the four write-once row shapes (`MessageEntry`,
  `CompactionEntry`, `BranchSummaryEntry`, `CustomEntry`), placement fields
  and payload together. `UsageRow` is the ledger row.
- `core/register.{RegisterNs, RegisterValue}` — the closed namespace enum
  and the thin tagged JSON wrapper storage persists. The rich payload types
  each namespace forces live in `machine`; `core` understands only
  `StrandLeaf`'s `Option(EntryId)`.
- `core/tx.{Write, Tx, SeqExpectation, CommitResult, CommitError}` — the
  unit of durability: an ordered write list applied all-or-none under
  optimistic seq expectations. `CommitError` carries four refusals, and
  the fourth is newer than the frozen sketch: `LeaseLost(held_by:)` says
  the committer is no longer the session's writer, which is the one
  refusal no reload and no retry can get past
  (`protocol-change/005`). `tx.describe_lease_loss` is the single place
  it is worded for humans, so every layer that has to flatten one into
  prose says the same thing.
- `core/json.JsonValue` — a pattern-matchable JSON ADT with a total parser,
  defined here rather than borrowed so pure code can inspect the `Json`
  named in the frozen contracts.
- `core/msgpack.MsgPackValue` — the canonical msgpack subset the
  effect-plane framing protocol uses (ADR-003).
- `core/corruption.CorruptionReport` — the single error type every total
  decoder returns.
- `core/clock.Clock` — the injected time capability; reading returns
  `#(now_ms, successor_clock)`.

## Relationships

- **Depends on**: `gleam_stdlib` only. No `gleam_erlang`, no `gleam_otp`,
  no `simplifile` — the purity of this package is structural, not a
  convention.
- **Depended on by**: every other Gleam package (`storage`, `session`,
  `machine`, `runtime`, `provider`, `broker`, `tools`, `conformance`).
- **FFI**: none. There is no `internal/ffi_*` module here and there must
  not be one; `Clock` and `Generator` take injected functions instead, so
  impurity belongs to whoever constructed them.

## Traffic

- **Actor messages**: none. `core` spawns nothing and imports no process
  primitives.
- **Commits**: defines the `Write` vocabulary (`InsertEntry`,
  `InsertUsage`, `SetRegister`, `DeleteRegister`) and `SeqExpectation`;
  performs none.
- **Registers**: defines the closed set — `strand.leaf`, `strand.config`,
  `strand.state`, `strand.last_result`, `op.meta`, `op.state`,
  `op.tool_args`, `op.preparation`, `pending.entry`, `fact.name`,
  `fact.label`, `fact.custom` — and their string forms via
  `ns_to_string` / `parse_ns`.
- **Wire**: `core/codec` is the JSON durability codec for every durable
  core type, using pi's exact field vocabulary (`parentId`, `cacheRead`,
  `stopReason`, `retainedTail`) per ADR-001 so a format-4 import is a
  mechanical decode-and-re-mint. `core/msgpack` is the effect-plane
  framing codec, golden-pinned under `protocol/msgpack-fixtures/`.

## Invariants

- **Decoding is total everywhere.** Every decoder returns
  `Result(t, CorruptionReport)`; wrong shapes and wrong types are reports,
  never crashes. Partial decoding is a bug class, not a style choice
  (spec §0.2).
- **Adversarial input is bounded at both codecs.** JSON and msgpack
  containers nest at most `max_depth` (256) levels; `CorruptionReport`
  truncates its context excerpt to `max_context_length` (256) graphemes;
  msgpack rejects non-byte-aligned bit arrays and trailing bytes.
- **Duplicate keys are corruption, in both codecs.** Decoders disagree on
  first- versus last-occurrence precedence, so a document or frame
  carrying duplicates has no single meaning; rejecting is the only rule
  with one interpretation.
- **msgpack encoding is canonical** — smallest encoding that fits — so
  equal values always produce identical bytes. The Go helper's strict
  decoder and the golden fixtures both depend on this.
- **Non-finite floats are corruption**, in JSON and msgpack alike: the
  BEAM cannot represent NaN or infinity. JSON ints are arbitrary
  precision; msgpack ints outside `[-2^63, 2^64-1]` are encode errors.
- **Minting is pure and reproducible.** The same `Generator` value always
  mints the same ids; the runtime seeds it from real entropy, tests from a
  constant. Production wiring must supply seeds that never repeat within a
  session lifetime or re-minted ids could collide with committed ones
  (spec-gaps WP-E item 6).
- **Tool-result ids inherit the assistant id's time prefix**
  (`mint_follower`), so a call-and-results group stays time-cohesive under
  id order even across a midnight boundary (pi §1.2 rule 2).
- **Entries are write-once.** The types carry no update path; writing under
  an existing id is corruption at the storage layer, not an update.

## Deep Docs

- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the durability plane: stores, identity, transactions, expectations.
- [docs/adr/001-agent-message-fidelity.md](../../docs/adr/001-agent-message-fidelity.md)
  — why the message family mirrors pi's shapes field for field.
- [docs/adr/003-msgpack.md](../../docs/adr/003-msgpack.md) — why the
  msgpack codec is self-contained pure Gleam.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-A (`core`)":
  the mint signature, `RegisterValue` representation, numeric edges.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
