# protocol-change/002 — add `Fault` to the Action type

**Status**: ACCEPTED 2026-08-24 · **Affects**: Part 1.3 `Action` ·
**Raised by**: WP-D · **Implemented**: machine (as raised) + spec text

## Problem

The frozen sketch lists five Action variants: `Transition`, `Dispatch`,
`AwaitEffect`, `Wait`, `Finish`. A pure, total `next_action` cannot crash,
yet corrupt inputs (an undecodable register, an impossible state/input
combination such as an aborted stop under running control) must fault the
strand rather than loop. pi handles this by throwing; a total function
needs a value.

## Proposal

```gleam
pub type Action {
  Transition(next: OperationState, tx: Tx)
  Dispatch(intent: EffectIntent, next: OperationState, tx: Tx)
  AwaitEffect(key: EffectKey)
  Wait(until: WaitReason)
  Finish(result: LastResult, tx: Tx)
  Fault(report: CorruptionReport)
}
```

The runtime treats `Fault` as pi treats a thrown invariant violation: the
strand process faults (supervisor policy applies) and the report is
surfaced. Note `Transition`/`Finish` carry a full `Tx` (writes plus
expectations) rather than the sketch's bare `expects` — writes must live
somewhere, and the `Tx.expected` field is the sketch's `expects`.

## Impact

WP-E's driver gains one case; no durable format changes. Already
implemented this way in `machine/planner`; this proposal regularizes it.

## Decision

**Accepted.** The adversarial alternative — returning
`Result(Action, CorruptionReport)` instead of a variant — was considered
and dismissed as isomorphic but worse: it forces every call site to
double-case, and a result type suggests the caller might recover, when
the correct and only response is to fault the strand and let supervision
policy decide. `Fault` is a directive exactly like the other five. The
transaction-carrying `Transition`/`Finish` shapes are ratified with it:
writes must travel with the expectations that guard them.
