# Admission safety proof and differential bridge

`Admission.lean` proves a finite abstraction of the actual pure reducer in
[`executor/remote/admission.gleam`](../../../packages/executor/src/executor/remote/admission.gleam).
The bridge executes that production module through its public APIs. It does
not substitute a test reducer or compare two static expected tables.
This is a narrow proof for protocol 066's retained admission row, separate
from the ownership and remote-execution scheduling models.

## Run

From the repository root:

```sh
python3 protocol/models/admission-proof/run.py
python3 protocol/models/admission-proof/run.py --mutation reauthorize-intent
```

The ordinary run exits **0** only after Lean checks every theorem and all
**684** computed cases agree. A differential mismatch or tool failure fails
the run. The mutation command first requires that same baseline to pass,
then exits **1** for exactly one intended mismatch. Other failures exit **2**.
The mutation changes the comparator's computed **model output**, authorizing
launch from open `LaunchIntent(NativeUnconfirmed)` instead of returning
`NoLaunch`. It never edits production or proof source and is not evidence of
executing a production-source mutant. Nothing needs byte restoration.

Requirements are Python 3, existing executor package dependencies, Gleam,
OTP and the already installed Lean **4.34.0** toolchain. The local
`lean-toolchain` selects `leanprover/lean4:v4.34.0`; no Lake project, mathlib,
extra Lean library or global default change is needed. The runner invokes
`~/.elan/bin/lean` from this directory and prefixes compiler PATH with
`~/.local/lib/loom/server/bin`. It does not provision missing tools or
package dependencies; provision those separately before running it.

Each run creates a unique system temporary directory and prints its path.
`summary.json` records command arrays, working directories, exits, durations,
versions, source SHA-256 hashes, the proof axiom audit, bounds and any mismatch.
Individual stdout/stderr logs preserve both computed TSV streams. The runner
rejects changes to mapped source bytes during checking. Each subprocess has a
60-second deadline. Logs are isolated; `gleam run` uses the executor package's
normal ignored build cache. No compiler artifacts belong in this directory.
This gate is model-local and must be invoked explicitly: root `model-check`
does not discover or run Lean.

For separate checks:

```sh
(cd protocol/models/admission-proof && ~/.elan/bin/lean Admission.lean)
(cd packages/executor && gleam run -m remote_admission_bridge_test)
PATH="$HOME/.local/lib/loom/server/bin:$PATH" \
  LOOM_TEST_TIMEOUT_SECONDS=60 bash scripts/test.sh executor --match remote_admission
```

## What Lean proves

The model's `step` represents an event on one already admitted key. Request
validation precedes the event. An error retains the old phase and contributes
zero launches. A successful outcome contributes one launch only when its
actual effect is `launch`.

| Theorem | Claim |
| --- | --- |
| `only_open_admitted_launch` | Launch occurs exactly for Open + Admitted + equal request digest + AuthorizeLaunch. |
| `sealed_preserved`, `sealed_no_launch`, `launch_seals` | Intent or settlement cannot return to Admitted, authorize again, or lose its launch fence. |
| `sealed_trace` | Any subsequent finite sequence from an intent or refusal emits zero launches and remains sealed. |
| `refusal_origin_preserved`, `refusal_trace`, `refusal_never_launched_terminal` | Refusal retains its provenance through every finite sequence and cannot become a launched terminal or launched replay fence. |
| `compact_obligations`, `compact_requires_evidence` | Successful compaction requires receipt and native absence, with exact eligible phase classes. Refusal establishes native absence by construction; launched terminals require affirmative retirement. Already compacted fences retain those discharged facts. |
| `at_most_one_launch`, `fresh_scope_at_most_one` | Every finite sequence from a fresh Admitted row authorizes at most one launch. |

Trace induction has **no length bound**. Each trace input supplies its gate,
request equality class and event independently. This intentionally admits
more gate histories than production's irreversible `close`; even a hypothetical
reopened gate cannot reauthorize a sealed row. The theorem does not establish
that a fresh call to `new` recovers old evidence. Scope reuse is outside the
abstraction and forbidden by the adapter contract.

The proof uses ordinary kernel-checked reduction and induction, with no
`sorry`, custom axiom, unsafe declaration or native-decision escape. The runner
audits all twelve theorems. Their current dependencies are Lean's foundational
`propext` and, for some simplification proofs, `Quot.sound`. These are reported
explicitly; a project axiom or `sorryAx` causes the runner to fail.

## Model-to-code mapping and finite cases

The fixture creates opaque Books using `capacity`, `new`, `admit` and successful
`reduce` witnesses. It never injects Phase values into a Book. Both result
digests are reached independently through the real functions.

| Model phase text | Actual reachable class | Count |
| --- | --- | --- |
| `a` | Admitted. | 1 |
| `i0`, `i1` | LaunchIntent with unconfirmed or retired native custody. | 2 |
| `fap`, `fad`, `fbp`, `fbd` | Refused with digest a/b and pending/durable receipt. | 4 |
| `ta0p` through `tb1d` | Terminal with digest a/b, unconfirmed/retired custody and pending/durable receipt. | 8 |
| `ra`, `rb` | Retired launched work with digest a/b. | 2 |
| `xa`, `xb` | RetiredRefusal with digest a/b. | 2 |

Here a/b result digests are 256-bit integer representatives **9/8**; equal and
conflicting request digests are representatives **1/2**. `0/1` mean
unconfirmed/retired custody; `p/d` mean pending/durable receipt. Result-bearing
events each enumerate both a and b. Together with AuthorizeLaunch,
ConfirmRetirement and Compact this gives **nine event representatives**.
Every combination of 19 phases, two gates, two request classes and nine events
is executed: **684 reducer calls**, plus fixture and inspection calls.

`step` maps the production `apply_event`, `authorize_launch`,
`refuse_before_launch`, `observe_terminal`, `confirm_retirement`,
`confirm_owner_receipt` and `compact` paths. Request conflict maps `inspect`'s
request-digest validation. The private production Gate is exercised through
`close`, not reconstructed. A new-key admission probe on the full one-row Book
distinguishes open Saturated from closed EpochClosed, checking successor gate
preservation too. Every row also checks retained count, duplicate admission's
unchanged Book and NoLaunch, returned evidence against successor inspection,
and the exact Launch key.

The TSV has six columns: `BRIDGE`, gate, input phase, request class, event and
outcome. Outcomes encode named errors or successor phase, effect and gate.
The Lean output is computed from the **same `step` whose invariants are proved**.
The Gleam output is computed by
[`remote_admission_bridge_test.gleam`](../../../packages/executor/test/remote_admission_bridge_test.gleam).
The comparator rejects missing, duplicate or differing cases. Gleam's phase,
event, custody, receipt, effect and AdmissionError projections match all
constructors exhaustively. Adding a constructor requires updating the bridge
before compilation succeeds. A semantic change requires deliberate model and
proof maintenance; there is no static golden table to silently retain.

## Limits

Lean proves **this abstract transition function**. The differential finite-case
checks are **not a theorem of full Gleam/OTP runtime equivalence**, arbitrary
256-bit digest universality, persistence, authentication, OS cleanup or native
execution. They check two concrete result and request representatives under
one valid scope and one retained key. ScopeMismatch, UnknownRequest, capacity
construction ranges, multi-key interactions and identity parsing are outside
this Lean function and remain covered by existing Gleam tests.

Custody and receipts are trustworthy abstract evidence, not observations of
real processes or durable owner storage. Compaction retains a fence in the
model; it does not prove a database persists it. Transition values can still
be duplicated by a caller, and the adapter must commit before effect, serialize
against the latest state and apply a launch effect once. Arbitrary network
traffic, host crashes, disk corruption, native descendant retirement and the
ongoing distributed executor E2E work remain separate obligations.
