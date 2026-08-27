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
- `machine/planner` is a big module on purpose: one public function over
  a closed vocabulary, then a section per phase of pi's spec. Read its
  module doc first — it enumerates the sections and what each *decides*,
  which is the map. Two conventions hold throughout: every type the
  module has is declared before the first function body (the private ones
  included), and a phase's entry function is a dispatch table whose arms
  name the decision rather than making it. The corruption path has its
  own `use` forms — `or_fault` and `or_fault_unless` — because Gleam has
  no early return and `result.try` cannot serve where the continuation
  returns an `Action`; reach for them rather than nesting a `case` whose
  error arm is `Fault(report:)`.
- `machine/acceptance.accept_prompt` — the single acceptance transaction
  for a run, standalone compaction, or navigation.
- `machine/classification.{settle, classify}` — the normative
  first-match-wins order over a settled assistant response.
  `ClassifyCtx.expected_api` is the *captured* request api, not the
  response's self-report.
- `machine/operation.ToolExecution` — `Sequential` or `Parallel`, the
  batch's scheduling mode; it decides which call `next_action` works next.
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
- **FFI**: none, and there must be none — no `@external` of any target,
  and no `gleam_erlang` or `gleam_otp` in `gleam.toml`, by rule rather
  than by coincidence.
  Two properties rest on that, and one `@external` closes both: purity is
  what makes the state space property-testable without spawning processes,
  and the same discipline is what keeps this package compiling to the
  **JavaScript target**. Lint R6 gates on it at error level and its census
  must stay zero. Portable here means *decide but not act* — replay a
  conversation tree, validate a transcript with the server's own total
  decoders, run `next_action` over fetched state — and never the harness in
  a browser: `gleam_otp` has no JavaScript target, Rule Zero is
  kernel-enforced (in a browser the harness VM and the untrusted-code VM
  would be the same VM), and the two-channel doctrine needs processes on
  both sides. `docs/gleam-style.md` Part IV §5 argues it in full.

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
    `strand.last_result`, `fact.custom` under the reserved
    `operation-result/{op}` prefix (the operation-keyed copy of the
    terminal result, written atomically beside `strand.last_result` so a
    waiter keyed on the operation survives a later run's overwrite —
    `operation.result_fact_key`), and `fact.label` (entry labels, keyed
    by entry id — Loom has no dedicated label namespace);
  - reads `strand.config`, `strand.state`, and `strand.leaf` seqs to build
    expectations (`build.expect_leaf` takes `Option(Seq)` — `None` when the
    leaf register does not exist yet).
- **Effect intents** — `ProviderRequest`, `ToolRequest`, `ToolReplay`,
  `DeferredFetch`, `SummaryProviderRequest`; their outcomes return as
  `Observation` variants (`ObservedAssistantSettled`,
  `ObservedToolOrphaned`, `ObservedStructuralDecision`, ...).
- **Wire**: none. The provider and effect wires belong to `provider` and
  `broker`.

## Invariants

- **The state is total.** Recovery reads `op.state` and nothing else to
  decide where to resume; no transition may depend on the previous state
  having been observed. `strand.last_result` is never read by the driver;
  it is latest-wins per strand, which is why the terminal transaction
  also records the same result operation-keyed (`operation-result/{op}`
  in `fact.custom`) for waiters that must observe a *specific*
  operation's outcome after later runs.
- **The effect sandwich.** Every external effect is preceded by a committed
  intent transaction and followed by a settlement transaction; `Dispatch`
  returns the intent `tx` *and* the next state, and the driver must commit
  before starting the effect.
- **Large payloads live at sibling registers, not inline.** Tool arguments,
  structural preparations, and queued entry payloads are written once under
  deterministic keys; queue lists carry only ids.
- **Acceptance must observe an idle strand *and* an unmoved leaf** (pi
  invariant 14; review finding ORCH-L6). The acceptance transaction expects
  the strand-state seq **and** the `strand.leaf` seq the caller read, so a
  losing concurrent accept fails `StaleExpectation` and reports
  `StrandBusy` after reload, and a concurrent idle tree-write moving the
  leaf between the read and the commit refuses the acceptance instead of
  mis-parenting its entries. Pre-acceptance rejections write nothing.
- **Deferred handles are validated against the captured request api**, not
  the response's claim (ORCH-L4). Admission resolves the api, the intent
  transaction persists it as `Generation.request_api`, and classification
  compares `{provider, model_id, api}` against that stored value — so a
  routing change between dispatch and settlement cannot smuggle a handle in.
- **Batch scheduling mode decides which call is worked next** (pi §3.8,
  ORCH-M2). `Sequential` works the frontier's head only, so one call
  clears, executes, and settles at a time; `Parallel` works the first
  still-*planned* call even while earlier calls are effect-pending, and
  parks on the first pending call only once nothing is left to plan. Tree
  materialization stays source-ordered in both modes.
- **A really-settled response under cancelled control keeps its content and
  its reported usage** (pi §4.6, ORCH-M3), committed normalized to
  `aborted`. Only an *unknown-outcome* orphan gets the synthetic
  zero-usage settlement — abort must not fabricate a cost of zero for work
  the provider actually did.
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
- **A failed in-run compaction is judged by its `CompactionReason`**, the
  same way a declined one already was (issue #34). A *threshold*
  compaction is the harness's own clamp: failing it against an
  unavailable summarizer restores the resume checkpoint and the run
  carries on, with `enabled` cleared in the run's captured
  `CompactionSettings` so the threshold cannot re-fire into the same dead
  route at every later boundary — settings are per-operation, so the next
  run tries again. An *overflow* compaction still drains, and so does a
  threshold one whose error is about the context rather than the
  summarizer (`fatal_to_the_context`). Corruption never reaches this
  decision; it is a `Fault` at its own site.
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
  "From the M3 runtime wave": the additive admission api field, the leaf
  expectation on acceptance, and parallel dispatch adding per-tool
  exclusivity only (the broker's pooled budget stays the ceiling).
- [protocol-change/](../../protocol-change/) — amendments to the frozen
  interfaces this package implements.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
