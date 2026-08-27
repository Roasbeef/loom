# ADR-005 — the pooled budget bounds the batch, not the call

**Status**: accepted · **Date**: 2026-08-26 · **Supersedes**: nothing ·
**Relates to**: issue #50, #22 (identity threading through this keying),
#23 (per-execution spawn ceiling), #87 (two programs in one batch — see
the addendum)

## The question

`broker.reserve_budget` keys ledgers by `#(op_id, step_id)` and opens each
one with the first caller's `spec.budget`. `step_id` is `batch.turn_id` —
shared by every tool call in one batch. `grep` declares
`max_outstanding: 1` and `execution_mode: Concurrent`; under
`tool_execution: Parallel`, two genuinely concurrent `grep` calls in one
batch share the ledger the first one opens, and the second is refused
`OutstandingCapReached`. Every test of concurrency on this path used
`bash`, which is `Exclusive` and cannot produce the interleaving, so this
went unnoticed until an adversarial review of the escalation path
(unrelated) tripped over it.

Two readings, and they disagree about where the bug is:

1. The cap bounds **one call's own fan-out** — so it should key on
   something finer than the turn (per-call, or per-tool-within-the-turn).
2. The cap bounds **the whole batch's concurrent effects** — so the
   keying is correct as designed, and `grep`'s `max_outstanding: 1` is
   simply the wrong declaration for a tool marked `Concurrent`.

## Decision

**Reading 2.** The pooled budget keys stay `#(op_id, step_id)`, unchanged.
The fix is in the tool: `grep.max_concurrent_searches` (was
`max_outstanding: 1`, now `16`) —
`packages/tools/src/tools/grep.gleam`.

## Why

This is not a judgment call between two equally plausible designs — the
design already answers it, on the record, twice over:

- **`broker/budget.gleam`'s own module doc** states the pooling model
  before this issue existed: *"Broker-side limits are pooled per
  execution, not per call: one token backs many in-flight effects, so the
  budget is aggregate — a cap on outstanding effects and one wall-clock
  deadline for everything under the token. This closes the amplification
  hole: 10,000 polite parallel reads or 50 spawned test runs share one
  ledger and are refused past the cap, however politely they ask."* A
  cap that instead bounded one call's fan-out could not close that hole —
  10,000 *separate* calls, each within its own per-call cap, would sail
  straight through it.
- **`broker/broker.gleam`'s module doc** restates the same thing at the
  keying site itself: *"a token is valid for exactly one `{op_id,
  step_id}`... so that pair *is* the execution identity, and the broker
  holds one `budget.Ledger` per live `{op_id, step_id}`... so 10,000
  polite parallel reads under one execution share one `max_outstanding`
  cap and one aggregate wall deadline."* (That doc now says *batch*
  identity where it said *execution* identity; the addendum below is why,
  and the pooling claim it makes is unchanged.)
- **`code_mode` already builds to this reading and nothing else does.**
  Its budget (`client/codemode.pooled_budget`) is deliberately configurable
  (`default_outstanding = 6`, not a literal `1` or `2`) precisely because
  one execution's build, satellite node, and every capability call the
  running program makes all share **one** ledger under the strand's own
  `{op_id, step_id}` (`tools/CLAUDE.md`: *"the broker pools budget per
  `{op_id, step_id}`... a concurrent call in the same step would open that
  ledger with *its* budget — and a satellite needs two outstanding effects
  to exist at all"*). `code_mode` is the one tool that was already written
  correctly against reading 2; `grep` is the one that was not.

So `grep`'s `max_outstanding: 1` was never a considered per-call limit —
it was `bash`'s constant, copied. `bash` is `Exclusive` and never shares
its ledger with a concurrent sibling, so `1` was invisible there. Marking
`grep` `Concurrent` and leaving its budget at `bash`'s value is the actual
bug: the two declarations on the same tool contradicted each other, and
the fix is making them agree, not changing what the ledger key means.

`16` is a real ceiling chosen to be comfortably above the handful of
searches one batch plausibly asks for and nowhere near the "10,000"
amplification case the pooling exists to refuse — a working number, not
a value derived from first principles. Getting that number right for
every `Concurrent` tool in general is a harder problem than this decision
answers; see below.

## What this settles for #22 and #23

**#22** threads a new identity through this same `{op_id, step_id}`
keying. This decision is the constraint that identity must preserve:
whatever #22 adds, it must still resolve to **one ledger per batch**, not
one per call. A per-call identity would quietly re-open reading 1 by
construction — every call getting its own ledger is functionally "the cap
bounds one call's fan-out" again, just via a different mechanism than
changing the `dict` key by hand. If #22's identity needs to distinguish
calls *within* a batch for some other reason (attribution, cancellation
scoping), it must do so without becoming a second axis of the budget key.

**#23**'s per-execution spawn ceiling is an **additional**, narrower
constraint layered on top of this pooled cap, not a replacement for it.
The pooled `max_outstanding` answers "how many effects may this batch
have outstanding at once, across every tool in it" — a broker-wide,
tool-agnostic anti-amplification limit. A spawn ceiling answers a
different, tool-specific question: how many *processes* (satellite
nodes, subagent strands, whatever #23 is scoped to) one execution may
create over its whole lifetime, which `max_outstanding` cannot express
(it counts what is outstanding *right now*, not a lifetime total). Both
should exist; neither substitutes for the other; and #23 should key its
own accounting the same way this ADR keys the ledger — per `{op_id,
step_id}` — for the identical reason: a spawn ceiling keyed finer than
the execution has the same amplification hole this issue found, one
level up. *(That last recommendation is the one thing here the build
departs from; the addendum says why.)*

## What is not settled here

Whether `16` (or `code_mode`'s `6`) is the *right* number for any given
tool, and whether tools should keep hand-picking their own
`max_outstanding` at all versus the broker deriving a default from
`execution_mode` (a `Concurrent` tool with no considered value could
default to something well above `1` rather than silently inheriting
whatever an `Exclusive` neighbor used). That is a policy question worth
its own pass once more `Concurrent` tools exist to generalize from —
today `grep` is the only one clearing through the broker, so there is
one data point, not a pattern.

## Addendum — two programs in one batch (issue #87)

*Added 2026-08-27. The decision above is unchanged; this records what it
answers for a case it did not name.*

Issue #87 found a second reading of "one ledger per batch". `code_mode`
is `tool.Exclusive`, which forbids a concurrent *start* and nothing more,
so one batch may hold two `code_mode` calls at different source indices
that run back to back under one `op_id` and one `step_id`. They share a
ledger. Is that the pooling working, or the keying being too coarse?

**It is the pooling working, and the key does not move.** Two programs in
one batch *are* one batch, and a pooled cap bounding that batch's
concurrent effects is this ADR verbatim. The alternative — a ledger per
`code_mode` call — is reading 1 arriving by a different door: K calls in
one batch would buy K × `max_outstanding` and K wall deadlines, and the
model authors the batch, so the amplification factor would be the model's
to choose. That is the hole the pooling exists to refuse.

The sharing is also close to vacuous in practice, and it is worth saying
why rather than resting on the principle alone. `broker.release_slot`
deletes a ledger whose outstanding count reaches zero, so **a ledger with
nothing outstanding leaves the table**. `Exclusive` means the first
execution's effects have settled before the second starts, so the second
opens a *fresh* ledger under the same key, with its own budget and its own
deadline. The only window in which the two genuinely share one is a
straggling settlement from the first, and releases are generation-checked
already, so a stale settlement cannot free a successor's budget. The
shared key is a transient overlap, not a standing condition.

What #87 *did* need was a per-execution coordinate, and it got one — in
paths, not here. `client/codemode.exec_root` digests
`{op_id, step_id, source_index}`, so each execution's build root, cap
socket and token file are its own; two hermetic builds sharing a directory
and two satellites reachable at one socket path were the real defects.
`{op_id, step_id}` is the batch identity the broker pools on;
`{op_id, step_id, source_index}` is the execution identity; the root
digests the latter and the ledger keys on the former, deliberately.

**On #23's unit, where this ADR guessed and the build differs.** The
"What this settles" section above suggested the spawn ceiling key itself
per `{op_id, step_id}` for the same anti-amplification reason the ledger
does. What shipped is per *execution*, and the difference is deliberate
rather than an oversight (issue #88). The ledger's argument does not carry
across: what the turn cost throttled was zero-marginal-cost **iteration**,
not turns, and inside one execution a program's loop is free — that is the
whole defect a ceiling answers. A *second* `code_mode` call is not free.
It costs an authored program, a hermetic build, a node launch and its own
wall deadline, so its marginal cost is spawn-shaped and the economics that
bound a model's own `agent_spawn` are back. Nor would per-batch be a
security boundary on its own: a model that can put K executions in one
message can put K in K messages, and nothing bounds messages. If a
per-batch lifetime spawn count is ever wanted anyway, it is a fold over
the durable lineage ledger — which already records
`minted_by: CallSite(operation, step_id, source_index)` per child and is
already read on the spawn path — rather than a coordinate threaded through
this key.

**The constraint this puts on future work** is the one already stated for
#22, now with a name: the source index must not reach the budget key. It
is deliberately absent from `codemode/identity.ExecIdentity`, whose
exports feed exactly two things — ledger keys and `broker.CallSpec`s —
because `identity.ledger_key` is one field-read away from whatever that
value carries, and a refactor that "completes" the key with an
obviously-available third field would mint one ledger per call without
anyone intending it. A per-call coordinate that names paths lives where
the paths are named.
