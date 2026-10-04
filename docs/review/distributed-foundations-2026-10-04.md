# Distributed runtime foundation review

Date: 2026-10-04. Scope: issue #697's first implementation wave, against
`ae1a319a48aa3feed92f5f65efd09034df635675`.

This wave adds a pure executor admission reducer and two executable protocol
models. The production local executor remains unchanged. There is no remote
listener, durable remote journal, workspace service, cluster directory or
new database dependency in this change.

## Independent review

The review covered validated scope and digest identities, bounded admission,
launch uncertainty, definite refusal, separate retirement/receipt obligations,
replay fences, cross-epoch authority, model bounds and runner failure handling.
It found no material reducer safety defect and one evidence-mapping issue.

| Finding | Evidence and disposition |
| --- | --- |
| P2: the P mapping implied that every retained admission can settle after closure. | P can leave an `Admitted` row when closure or reboot precedes its queued launch. The model omits definite pre-launch refusal. Its README now states this omission and identifies the actual Gleam regressions covering refusal, durable receipt and compaction. No P liveness claim is made for that ordering. |

Before independent review, integration inspection found the corresponding gap
in the initial reducer. `RefuseBeforeLaunch` now transitions only an unlaunched
admission into a distinct refusal phase, remains usable after closure, and
requires owner receipt before compaction. Once launch intent exists, it is
permanently rejected. This keeps recovery uncertainty separate from proof that
nothing started.

## Validation

The integrating run used Gleam 1.19.0-rc2, matching the repository CI pin.
The system-default 1.18.1 formatter disagreed with an unchanged host module;
using the pinned compiler resolved that mismatch without changing the file.

```sh
PATH=/Users/roasbeef/.local/lib/loom/server/bin:$PATH \
  make check-affected BASE=ae1a319a48aa3feed92f5f65efd09034df635675
python3 protocol/models/distributed-authority/run.py
bash protocol/models/remote-execution/check.sh
```

Each command returned its own exit status **0**. The affected gate took 134
seconds and passed format, lint, documentation, prelude, client checks, the
generic model gate and all 34 executor tests. Its skip census found no
undeclared skips, and its selector did not require full signoff. Existing
lint and documentation warnings remain; this is not a claim of a warning-free
repository census.

Of the executor tests, 24 exercise the new remote foundation. The admission
suite enumerates 262,144 event sequences of length six and checks the actual
Gleam reducer. Four targeted mutation experiments were rejected by their
intended regressions: reauthorizing recovered intent, collecting before native
retirement, removing replay fences, and permitting refusal after launch intent.
The mutation experiments restored source before the passing suite.

The independent TLC run exhausted 965,376 distinct states, with 12,383,809
states generated and depth 40. Six reachability controls and three mutations
produced their exact named invariant failures, as required by the runner.
The model SHA-256 was
`642bd4d1eeb4d0ac132be19b03c520d63835a09c697e060e3a058ebfbac5b640`.
See the [model bounds](../../protocol/models/distributed-authority/README.md)
and [counterexample summaries](../../protocol/models/distributed-authority/WITNESSES.md).
TLC needed execution outside the sandbox because the JVM's local RMI bind
was denied; the model still used its configured heap and wall-clock bounds.

The independent P run passed six normal cases at 1,000 schedules each, found
all thirteen exact reachability witnesses, and rejected all five mutations.
Each mutation's unmodified control passed 100 schedules; each mutant failed
on its first schedule for the expected monitor assertion. The runner rejects
compile errors, unexpected assertions, missing evidence and resource-limit
exits. See the [P model](../../protocol/models/remote-execution/README.md) for
its seed, limits and replay commands. The checked source snapshots matched
the source prepared for commit.

The generic repository model gate discovers P projects but does not run TLC
or the stricter local mutation gates. Both local runners above are required
for this wave; hosted CI is a separate result.

## Limits and next implementation boundary

These results do not prove storage serialization, durable commit ordering,
authentication, real native retirement, filesystem behavior or production
model equivalence. The P checks are bounded schedule exploration, not
exhaustive verification. TLC is exhaustive only within its finite abstraction
and fingerprinting limits. Neither model establishes unconditional progress
during partitions or unknown native outcomes.

The next implementation must preserve the reducer's decisions in a serialized
durable journal and native adapter, with real crash-window and persistence
failure tests. Only then should authenticated transport and executor-resident
workspace operations expose remote execution. Khepri/Ra selection, placement,
planned ownership movement and a narrow Lean bridge remain later work.
