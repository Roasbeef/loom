# machine

## Purpose

The pure operation machine: pi's harness spec Part 3 transcribed into Gleam
ADTs, with pi's "lane" renamed "strand". It owns the operation state space,
the acceptance transaction, settled-response classification, queue
admission and abort, the register payload codecs, and `next_action` — the
total function `State × Inputs → Action` the runtime drives. WP-D.
Fidelity, not invention: where this package and pi's spec differ, this
package is wrong.

## Key Types

- `machine/operation.Operation` — immutable per-operation metadata, written
  once into `op.meta` at acceptance.
- `machine/operation.OperationState` — the durable program counter, stored
  in `op.state` and replaced by every transition. It is *total*: it never
  depends on a previous state, and recovery reads exactly this value to
  decide where to resume. There is no finished variant — an ended
  operation has no state at all.
- `machine/operation.{RunPhase, Generation, ToolBatch, Inbox, Control,
  StructuralDecision, LastResult}` — the phase space: checkpoint,
  assistant, tools, compaction, deferred, failure drain; per-call
  planned/effect-pending/completed; the terminal outcome that lands in
  `strand.last_result`.
- `machine/planner.next_action` — the frozen entry point (spec §1.3).
- `machine/planner.Action` — `Transition(next, tx)`, `Dispatch(intent,
  next, tx)`, `AwaitEffect(key)`, `Wait(until)`, `Finish(result, tx)`,
  `Fault(report)`.
- `machine/planner.{PlannerInputs, Observation, EffectKey, EffectIntent}` —
  what the driver gathers, what comes back, and what the machine asks for.
- `machine/acceptance.accept_prompt` — the single acceptance transaction
  for a run, standalone compaction, or navigation.
- `machine/classification.{settle, classify}` — the normative
  first-match-wins order over a settled assistant response.
- `machine/strand.{StrandConfiguration, StrandState}` — the strand-scoped
  register payloads.
- `machine/codec` — total JSON codecs for every register payload above.

## Relationships

- **Depends on**: `core` only (ids, entries, messages, json, tx,
  corruption). Nothing else — not `storage`, not `provider`, not
  `gleam_erlang`.
- **Depended on by**: `session` (typed register access through
  `machine/codec`), `runtime` (drives the planner), `conformance` (scripts
  and invariant checks).
- **FFI**: none, and there must be none. Purity here is what makes the
  whole state space property-testable without processes.

## Traffic

- **Actor messages**: none. This package spawns nothing and waits on
  nothing; the driver in `runtime/strand_runtime` owns all process
  concerns.
- **Commits** — it *builds* transactions, never commits them. Every
  `Action` carrying a `Tx` carries all the writes that make its `next`
  state true, guarded by the seq expectations the caller must have read
  against. `machine/internal/build` holds the shared write builders.
- **Registers**:
  - writes `op.meta` (write-once at acceptance), `op.state` (every
    transition; deleted by the terminal transaction), `op.tool_args`
    (write-once, key `{op}:{step}:{index}`), `op.preparation`
    (write-once, key `{op}:{task}`), `pending.entry` (keyed by the
    reserved `EntryId`), `strand.leaf`, `strand.state`,
    `strand.last_result`, and `fact.label` (entry labels, keyed by entry
    id — Loom has no dedicated label namespace);
  - reads `strand.config` and `strand.state` seqs to build expectations.
- **Effect intents** — `ProviderRequest`, `ToolRequest`, `ToolReplay`,
  `DeferredFetch`, `SummaryProviderRequest`; their outcomes return as
  `Observation` variants (`ObservedAssistantSettled`,
  `ObservedToolOrphaned`, `ObservedStructuralDecision`, ...).
- **Wire**: none. The provider and effect wires belong to `provider` and
  `broker`.

## Invariants

- **The state is total.** Recovery reads `op.state` and nothing else to
  decide where to resume; no transition may depend on the previous state
  having been observed. `strand.last_result` is never read by the driver.
- **The effect sandwich.** Every external effect is preceded by a committed
  intent transaction and followed by a settlement transaction; `Dispatch`
  returns the intent `tx` *and* the next state, and the driver must commit
  before starting the effect.
- **Large payloads live at sibling registers, not inline.** Tool arguments,
  structural preparations, and queued entry payloads are written once under
  deterministic keys; queue lists carry only ids.
- **Acceptance must observe an idle strand** (pi invariant 14). The
  acceptance transaction expects the strand-state seq the caller read, so a
  losing concurrent accept fails `StaleExpectation` and reports `StrandBusy`
  after reload. Pre-acceptance rejections write nothing.
- **Classification order is normative and first match wins** (spec §1.3):
  cancelled control, overflow, valid deferred handle, retryable error, tool
  use, stop. Two normalizations happen at commit and both are deliberate: a
  cancelled response commits as `aborted`, an overflow-classified response
  commits as `error`. An `aborted` stop reason with running control is
  unreachable and reported as corruption.
- **A pure total planner cannot crash.** Corrupt inputs or durable state
  surface as `Fault(report)`, a sixth `Action` variant beyond the frozen
  five (`protocol-change/002`); the caller must fault, never continue.
- **The first abort wins and payloads outlive it.** `cancel_requested`
  moves steer and follow-up ids into the drained lists without deleting
  their payloads; those die only in the terminal transaction.
- **Terminal cleanup is over-approximate by construction.** The pure
  machine cannot scan, so tool-args and preparation registers are deleted
  from caller-supplied key lists; delete-absent being a no-op keeps this as
  safe as pi's defensive scan.
- **Adapter retryability travels by convention**, not by a field: the
  planner reads `raw_stop_reason == "retryable"`, and the runtime bridges
  `provider/retry.classify` into it (spec-gaps WP-D item 3).
- **Faithful-but-surprising transcriptions are kept deliberately** — a
  completed tool batch sets skip-inbox-once; the threshold check also runs
  at may-finish checkpoints; backoff saturates at exponent twenty;
  overflow during a deferred poll drains as failure; summary usage rows
  carry no entry id.

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the durable program counter, the effect sandwich, the state space, the
  drive loop.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-D (`machine`)":
  the `Fault` variant, the absent list store, prefix scans, entry labels.
- [protocol-change/](../../protocol-change/) — amendments to the frozen
  interfaces this package implements.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
