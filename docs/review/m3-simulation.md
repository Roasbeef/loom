# Adversarial review — M3 deterministic simulation runner

Scope: `packages/conformance/src/conformance/simulation/{runner, control,
vclock, script, fault, store, surface, invariant, wire, random}.gleam`,
`simulation_test.gleam`, and the claims in `docs/architecture/simulation.md`
plus the notebook entries (seam-race, crash-fired self-catch,
unfireable-schedule, orphaned-poll).

Governing question throughout: *could this check pass while the property it
names is false?*

Method note: three findings were confirmed **by construction** in a `/tmp`
copy of the tree (revert a fix / inject a violation, then observe whether the
runner still catches it). Those are marked CONFIRMED-BY-CONSTRUCTION. Others
are CONFIRMED (by reading, with the failing branch traced) or SUSPECTED.

---

## Summary

No check was found that is *structurally unable to fail* on the property it
guards for the core convergence/crash/invariant claims — the load-bearing
ones (`run/crash-fired`, `convergence/ledger`, the boundary plumbing) were
demonstrated to fire. The findings below are (a) one framing property whose
stated clause is largely vacuous, (b) two accuracy/soundness gaps that
*mislead* rather than silently pass, (c) a latent coupling that is safe only
while an unrelated invariant holds, and (d) coverage/robustness weaknesses.

Counts: 6 findings — 0 HIGH-confirmed, 2 MEDIUM, 1 LOW–MEDIUM, 2 LOW, 1
LOW-latent. Plus a "checked and sound" ledger of everything verified to
genuinely fail on violation.

The single most important item is **SIM-1** (the wire *damage* property is
substantially weaker than its stated claim), because it is the one named
check here that can essentially only fail on a decoder crash — the
"corruption is reported, not silently survived" clause is never actually
tested.

---

## Confirmations that the runner does NOT lie (the good news, established first)

These were the highest-risk "could this pass while false?" items. Each was
run to ground; the runner holds.

### Schedule does not perturb the script (convergence is not vacuous) — CONFIRMED
The central soundness premise. `surface.settlement/2` (surface.gleam:196) is
a pure function of the *projected context* and the request's model identity —
it never reads `schedule`. `surface.execute/5` uses `schedule` only through
`effect_fault` (fault injection) and `retryable`. The tool result text comes
from `script.tools`, not the schedule. So a fault can suppress/delay/kill an
effect but cannot change *what a turn settles with*. Convergence therefore
compares two runs of the same conversation, which is the whole claim.

### `convergence/ledger` has teeth — CONFIRMED-BY-CONSTRUCTION
Patched `surface.request` to add 100 tokens to every `Answer` settlement
*only when `schedule.faults != []`* (a deliberately non-transparent fault).
The sweep lit up with `convergence/ledger — fault-free N tokens but faulted
N+100/200/…` across essentially every seed. The check fires.

Worth recording as a design fact (not a defect): `convergence/projection` did
**not** fire on that token perturbation, because `fingerprint/1` excludes
token counts and timestamps by design. Usage divergence is guarded *solely*
by `convergence/ledger`. That is correct, but it means the ledger check is
load-bearing and singular — see SIM-5.

### `run/crash-fired` catches a vacuous run — CONFIRMED-BY-CONSTRUCTION
Reverted **both** halves of the crash-fired self-catch fix (removed the
`seam_quiet` wait in `pump_strand`/`settle_seam` *and* re-coupled terminal
interventions to `awaited: True`). `crash_on_the_terminal_commit_corpus_test`
then failed with:

```
run/crash-fired — a scheduled crash never fired, so the run proves nothing [crash@c6]
```

So when the runner *does* take a terminal result while the armed terminal
crash is still queued, the check reports it. The self-catch works.

`crashed` is set only by `control.note_crash`, called only on the two genuine
crash-fire paths immediately before the kill — so a hang or a dropped
`SeamDone` cannot masquerade as a crash. `seam_quiet` returning
`!seam_open || crashed` correctly treats a crash (writer killed inside the
seam) as the seam closing. Sound.

### Keying is deterministic from the seed alone — CONFIRMED
`random.gleam` is a pure SplitMix64; every draw threads `Rng`, nothing reads a
pid/timestamp/map iteration order. The phase keys (`turn_of`, `summaries_of`)
are order-insensitive counts over a deterministic projection; `newest_user_text`
folds a deterministically-ordered list. The only counter-keyed values
(`entropy` for id minting, the `effect` dispatch index for fault targeting)
never feed a script response — they are excluded from `fingerprint`. So a
synthetic settlement written during recovery cannot shift a phase, and the
seed reproduces the *decisions* exactly (BEAM interleaving aside, per the
documented limit).

### `terminal/registers` namespace list is complete — CONFIRMED
`register.RegisterNs` has exactly five operation-owned namespaces (OpMeta,
OpState, OpToolArgs, OpPreparation, PendingEntry); `terminal_registers`
checks all five. No op-owned namespace is silently dropped, so a surviving
op register cannot escape it. The strand-scoped namespaces it omits are the
ones that legitimately survive.

### Read faults cannot mask an invariant — CONFIRMED
The boundary check `invariant.placement` is called on `inner` (the
*uninstrumented* store) inside `store.commit`, and the terminal checks in
`runner.terminal_violations` read `raw.store` (also uninstrumented). A
scheduled `ReadFault` only guards the *instrumented* store the tree runs on,
so it cannot make a violating read return "no violation". Good separation.

---

## Findings

### SIM-1 (MEDIUM, CONFIRMED) — the wire *damage* property is largely vacuous
`wire.gleam:damage_is_total`:

```gleam
case pushed.fault {
  None -> Ok(Nil)                    // any non-faulting decode passes, unconditionally
  Some(_) -> { ...check sticky... }
}
```

The architecture doc claims this property is "damage is reported, not
survived silently … it never yields a frame the encoder could not have
produced with those bytes." The code does **not** check that. When a
byte-flip produces a stream that decodes without a fault, the result is
accepted *unconditionally* — the decoded frames are never compared against
anything, never re-encoded, never validated. The only things this property
can actually catch are (a) the deframer *crashing* (totality — enforced
implicitly, a panic fails the test) and (b) a faulted deframer that keeps
decoding (stickiness). The headline clause ("could not have been produced by
the encoder") is untested, so a decoder that silently reinterpreted corrupt
bytes as a *different valid frame* — exactly the msgpack-confusion risk the
property names — would pass. `truncation_carries` is similarly totality-only:
it accepts `None | OversizedFrame` and never verifies the completed frames
were delivered or that the partial tail is retained.

*Why it matters:* this is the closest thing in scope to a named check that
cannot fail on its own stated property. Recommend the corruption case assert
that each non-faulting decoded frame re-encodes to a byte-run present in the
damaged stream (or at minimum diff decoded-vs-original and require a fault
when they differ).

### SIM-2 (MEDIUM, CONFIRMED) — shrinking can silently change the failing check
`runner.shrink`/`first_failing` keep any shrunk schedule that "still fails",
and the reported failure is the shrunk run's *re-derived* `smaller_failure`
(runner.gleam:194, 209–210). Nothing requires the minimal schedule to fail
the **same** check as the original seed. Dropping a fault or halving an
ordinal can land the run on a *different* property (e.g. an original
`convergence/ledger` failure shrinks to a schedule that instead trips
`run/crash-fired` or a different convergence line), and that different failure
is what gets reported as "the minimal case".

The report is internally consistent (the printed schedule really does produce
the printed check) and reproducible, so this is a *misdirection* risk, not a
false pass. But the doc's claim — "the worst shrinking can do is fail to
shrink" — is inaccurate: it can also relabel the defect. Recommend pinning
the shrink to `failure.check` (only accept a candidate whose failure names the
same check) and stating the guarantee honestly.

### SIM-3 (LOW–MEDIUM, SUSPECTED) — `calls_answered` blind spot on aborted/errored responses
`invariant.calls_answered` excludes tool-call blocks carried by `Aborted |
Errored` assistant messages from the *demand* set (invariant.gleam:264–273).
This is deliberate (faithful abort retention keeps un-run tool-call blocks).
But it means the check cannot detect an *unanswered* or *spuriously executed*
call that happens to be carried by an aborted/errored message — it rests
entirely on the unverified assumption that the machine never executes such a
call. If that assumption were violated by a real bug, the exactly-once count
catches only the sub-case where the stray result *collides* with an executed
call's id; a stray result under a fresh id, or a missing result, is invisible
here. The scoping is defensible; the residual risk should be named in the
check's doc rather than left implicit.

### SIM-4 (LOW, CONFIRMED-BY-CONSTRUCTION) — the seam-wait half is not exercised by its own regression test
Reverting **only** the `seam_quiet` wait in `pump_strand`/`settle_seam` (while
leaving terminal interventions detached, `awaited: False`) left the *entire*
conformance suite green — including `crash_on_the_terminal_commit_corpus_test`,
which the notebook presents as the memory of that fix. The corpus test only
fails when the *deadlock amplifier* (`awaited: True`) is also present (see the
SIM `run/crash-fired` confirmation above). So the seam-wait mechanism has no
test that fails when it alone is removed.

Severity is LOW because removing the seam-wait produces a flaky *false RED*
(the runner transiently declares "crash never fired" when the crash simply
had not fired yet), not a silent false pass — a slower machine or a GC pause
in the pump loop could surface it as an intermittent `run/crash-fired`
failure on a legitimate run. It does not let real defects through. But the
claim that the seam-wait is "validated" is not supported: its regression
coverage is entangled with the detach fix and does not isolate it.

### SIM-5 (LOW-latent, CONFIRMED) — `kill_tree` no-op still records `crashed = True`
`surface.effect_fault` for `CrashDuringEffect` calls `control.note_crash`
(setting `crashed = True`) *before* `kill_tree`, and `kill_tree` is a no-op
when the writer's named subject does not resolve (`Error(Nil) -> Nil`,
surface.gleam:567–570) — reachable if the writer is mid-restart from a prior
fault. So `crashed` can be `True` when no tree was actually killed.

This is currently harmless *only* because `fault.dedupe` caps a schedule at
one crash total, so a spurious `crashed` from a `CrashDuringEffect` can never
coexist with an armed `CrashAtCommit` (the only crash `crash_fired` requires).
The coupling is load-bearing and undocumented: **if the one-crash cap were
ever relaxed, `crash_fired` could be silently satisfied by an unrelated
effect-crash that did nothing, masking a genuinely unfired commit crash** —
that would be a HIGH-severity false pass. Recommend moving `note_crash` to
*after* a confirmed kill (or having `kill_tree` return success/failure and
gating `note_crash` on it), so `crashed` means "a tree was actually killed".

### SIM-6 (LOW, SUSPECTED) — coverage marks report *entry*, not *exercise*; asserted one-directionally
Two sub-issues in the coverage assertion:

1. `required_paths` (simulation_test.gleam:71) is a hardcoded list, checked
   only in the direction "every required path was reached". A path that
   *should* be exercised but was never added to the list is silently
   unchecked. The protective direction (a listed path becoming unreachable
   fails loudly) does hold.
2. Several marks fire on *entry* rather than on the interesting recovery
   actually running: `deferred-poll` is marked the moment a `PollRequest`
   reaches the surface (`mark_request`, surface.gleam:167), and
   `overflow-compaction` on settlement send — before the machine has
   classified or recovered anything. So "the sweep reached deferred-poll" is
   a weaker statement than it reads. Mitigated for the specific ORCH-H1
   orphaned-poll defect by the pinned machine-level regression test, but the
   coverage line itself over-claims.

---

## Checked and sound (verified to genuinely fail on violation)

- **`run/crash-fired`** — fires on a vacuous run (construction). `crashed`
  provably reflects a real kill on the required (`CrashAtCommit`) path; the
  one-crash cap keeps its accounting clean (see SIM-5 for the latent edge).
- **`convergence/ledger`** — fires on token divergence (construction).
- **`convergence/outcome` / `convergence/projection`** — list-equality checks
  with an explicit, bounded allowance (`interrupted_variant` for
  `ReplayNever`); clearly can fail; the allowance is keyed on matching
  tool+id, not a blanket skip.
- **`invariant/boundary` plumbing** — `placement` Error → `control.note` →
  `report.violations` → `sound` returns `invariant/boundary`. Path intact;
  reads the uninstrumented store.
- **`placement/queued-id`** — errors precisely on the both-held case; queued
  set derived from durable strand/op state; empty-set early return is correct
  scoping, not a swallow.
- **`terminal/registers`** — complete namespace coverage; fails on any
  non-empty op namespace or a strand still naming an open operation.
- **`replay/never-once`** — counter-backed; fails on count > 1; key
  construction matches between execution and check.
- **`terminal/last-result-once`** — independent cross-count
  (`terminal_writes` vs `#outcomes`); fails on double-write or missing write.
- **Fault injection reality** — `RefuseCommitStale` returns before applying
  and claims once; `ReadFault` returns the error at `ordinal == landed` once;
  `StealLease` fails the renewal once at `ordinal <= landed`; each marks
  coverage only inside the branch that truly fires. No "armed but no-op
  counted as fired" for the checks that *require* firing.
- **vclock quiescence/advance** — `advance` fires the earliest deadline only,
  moves `now` monotonically forward (`int_max`), and every deadline is a
  hint the driver re-reads; a `SlowEffect` park is honored as a logical-time
  lower bound because its deadline only fires once `now` has reached it. No
  real timing bug is collapsed *within the documented "clock is not
  adversarial" limit* (backward jumps / skew are out of scope by construction,
  as the doc states).

---

## Scratch experiments (for reproduction)

All in a `/tmp/loom-scratch` copy; the real tree was never modified and no
commit was made.

1. Baseline: `gleam test` in `packages/conformance` → 38 passed.
2. SIM-4: neutered `seam_quiet` in `pump_strand`+`settle_seam` → still 38
   passed. Then additionally re-coupled terminal interventions to
   `awaited: True` → `run/crash-fired` fired on the terminal-commit corpus
   case (`crash@c6`).
3. `convergence/ledger`: `+100` tokens on `Answer` when `schedule.faults != []`
   → ledger check fired across the sweep. Restored.
