# Checked run and mutation witnesses

Checked on 2026-10-04 with `/usr/bin/java` (Java 8u152), the pinned official
TLA tools v1.7.1 jar, and the bounds in [README.md](README.md). This records
abstract protocol evidence only. These traces have not been replayed against
a production distributed authority implementation.

From the repository root:

```sh
python3 protocol/models/distributed-authority/run.py
```

Runner exit: **0**. Translation exit: **0**. All ten cases passed their
expected verdict. TLC ran with execution permission outside the sandbox
because its local RMI bind was denied inside the sandbox.
Full argument arrays, configuration hashes, exits and logs are in
`.runs/1791103449588606000/summary.json`. That evidence directory is ignored,
so independent verification regenerates it rather than relying on a vendored
log or binary. The checked model SHA-256 is:

```text
642bd4d1eeb4d0ac132be19b03c520d63835a09c697e060e3a058ebfbac5b640
```

| Case | TLC exit | Generated states | Distinct states | Witness states |
| --- | --- | --- | --- | --- |
| Safety | 0 | 12,383,809 | 965,376 | none |
| ReachHandoff | 12 | 1,497,984 | 160,655 | 18 |
| ReachRecovery | 12 | 2,649,303 | 258,114 | 20 |
| ReachActivationReply | 12 | 2,642,925 | 257,731 | 20 |
| ReachDelayed | 12 | 2,800,619 | 275,662 | 20 |
| ReachStaleRoute | 12 | 472,803 | 55,991 | 15 |
| ReachAbortRetry | 12 | 20,796 | 3,120 | 8 |
| MutantDirectory | 12 | 1,609,585 | 182,290 | 15 |
| MutantAdmission | 12 | 2,526,661 | 246,617 | 20 |
| MutantCut | 12 | 477,597 | 56,448 | 15 |

Safety exhausted its queue at depth **40**. TLC reported fingerprint collision
estimates of `6.0E-7` (calculated optimistic) and `7.6E-8` (actual fingerprints).
The nine controls stop at their first intended invariant counterexample;
their counts describe partial exploration, not exhausted state graphs.

## M1: directory publication substituted for local freeze

Command: `python3 protocol/models/distributed-authority/run.py --case MutantDirectory`.
The control requires `OneEffectiveWriter`, which Safety also checks. This
mutation weakens Frozen publication so that a directory commit fabricates a
consistent cut without A closing its local writer.

```text
State 1:  Active(A,1); writers = {A/1}; source seal = Open.
State 2:  Source journals handoff 1.
State 3:  Directory commits Draining(A,1,1,B).
State 4:  Mutant publishes Frozen and a cut; seal remains Open, writer A/1 remains.
State 5:  B journals handoff 1 and observes Frozen.
State 6:  B records target verification of the published cut.
States 7..8:   E1, then E2 durably close admission.
States 9..10:  E1, then E2 acknowledge retirement.
State 11: Directory commits Prepared(B,2,1).
State 12: B reconciles Prepared for handoff 1.
State 13: Directory commits Active(B,2,1).
State 14: B reconciles Active for handoff 1.
State 15: B opens; writers = {A/1, B/2}.
```

TLC exit **12**, `Invariant OneEffectiveWriter is violated.` Both writers
coexist in different epochs. Checking one writer per epoch would miss this
witness. The fake publication's earlier evidence violations are deliberately
not selected in this control, so the observed failure is physical exclusivity.

## M2: delayed admission after durable closure

Command: `python3 protocol/models/distributed-authority/run.py --case MutantAdmission`.
The control requires `NoOverlappingAuthority`, which counts native work even
if its executor is unreachable. The mutation skips the durable admission
fence when a Pending epoch-1 request is finally delivered.

```text
State 1:  Active(A,1); requests on both executors are Unsent.
State 2:  Source journals handoff 1.
State 3:  A sends to E1; the request stays Pending in transport.
State 4:  Directory commits Draining(A,1,1,B).
State 5:  A reconciles Draining for handoff 1.
State 6:  A freezes durably and closes its writer.
State 7:  A forms its consistent cut.
State 8:  Directory commits Frozen.
State 9:  B journals handoff 1.
State 10: B verifies the cut.
States 11..12: E1, then E2 durably close admission.
States 13..14: E1, then E2 acknowledge retirement; E1's request is still Pending.
State 15: Directory commits Prepared(B,2,1).
State 16: B reconciles Prepared.
State 17: Directory commits Active(B,2,1).
State 18: B reconciles Active.
State 19: B opens its epoch-2 writer.
State 20: Mutant E1 admits the delayed request; requests[E1] = Running.
```

TLC exit **12**, `Invariant NoOverlappingAuthority is violated.` Effective
authorities are `{A/1, B/2}`, although A's local writer is correctly closed.
The unmutated `ReachDelayed` witness follows this same delayed-send shape and
finishes with E1's request **Rejected**, while all safety invariants hold.

## M3: preparation skips target cut verification

Command: `python3 protocol/models/distributed-authority/run.py --case MutantCut`.
The control requires `ActivationHasEvidence`, which Safety also checks.
Only the target-verification prerequisite of Prepared is removed.

```text
States 1..7:   A journals handoff 1, drains, freezes, forms the cut, and publishes Frozen.
State 8:      B journals handoff 1 but has not verified the cut.
States 9..10: E1, then E2 durably close admission.
States 11..12: E1, then E2 acknowledge retirement.
State 13:     Mutant commits Prepared(B,2,1), with targetVerified = FALSE.
State 14:     B reconciles Prepared.
State 15:     Directory commits Active(B,2,1), still with targetVerified = FALSE.
```

TLC exit **12**, `Invariant ActivationHasEvidence is violated.` Correct source
freeze and executor retirement do not substitute for B's independent
verification. The violation occurs at the activation authority commit before
B opens a local writer.

## Crash and lost-reply controls

`ReachRecovery` closes A's writer and forms the cut, then crashes A while the
directory is still Draining. A restarts without reopening epoch 1, publishes
the retained freeze evidence under handoff 1, and B eventually opens epoch 2.
The final witness has `recoveredFreeze = TRUE` and `writers = {B/2}`.

`ReachActivationReply` commits Active(B,2,1) at state 16 while B's observation
is still Prepared. B crashes at state 17, leaving its journaled `targetIntent`
unchanged and losing its volatile observation. B restarts at state 18, reads
back Active for handoff 1 at state 19, and opens its writer at state 20.
No second handoff identity or source fallback is allocated.

`ReachAbortRetry` cancels locally before freeze, commits and reconciles the
abort receipt for ID 1, then allocates ID 2. `ReachStaleRoute` demonstrates
refusal through the old A route. These are existential controls under no
fairness assumption; they are not universal eventual-completion proofs.
