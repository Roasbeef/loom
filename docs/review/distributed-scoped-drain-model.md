# Scoped transport-drain model review

The bounded P model checks the proposed scoped executor lifetime before its
runtime API is implemented. The focused cases and independent Astra replay pass.
This is evidence for the state transitions in the [lifetime proposal](../design-notes/distributed-scope-lifetime.md),
not an executable correspondence proof or authorization to change the native
service. The model is committed in `34653673`.

## State and properties

Six credit records are the sole allocation state. Each is Available, assigned to
an exact original scope/run, or unusable. Idle credit death loses capacity without
charging a scope; assigned credit death retains uncertainty for its original
scope. Sixteen immutable rows have permanent admission fences. An applied owner
DOWN fences its row; a reservation that won before that observation may still
consume capacity.

A fenced scope can report Drained only when it has no assigned run and no
unresolved unusable assignment. Actual answer and producer AllDelivered remain
separate facts. A completion must match the credit's original correlation. A late
handoff or completion cannot settle a later reservation, and a dead credit cannot
return to the available set.

Six new directed scenarios cover scoped fencing, both answer/drain orders,
retired uncertainty, stale completion, idle versus busy credit death, and applied
scope-owner death. The four earlier credit scenarios remain. Each scenario has
an exact reachability probe, so a normal safety pass is paired with evidence that
the intended transition can occur.

## Verification

The worker's frozen source passes ten normal cases at 1,000 schedules each and
ten exact probes. All probe witnesses occur at schedule 1. Ten mutation controls
pass against the unmodified source, then each compiling mutant reaches its
intended monitor assertion. The six earlier mutations and all unrelated harness
entries remain unchanged.

Astra independently replayed all twenty cases/probes and the four new mutation
controls. Each new mutant compiled and failed at its intended assertion. The
reviewer also inspected the worker's exact-source evidence for the six earlier
mutants and verified all six changed source hashes. No actionable model defect
was found.

| New mutation | Required failure |
| --- | --- |
| Omit the scoped admission gate | A reservation occurs after the applied scope fence. |
| Treat DOWN as drain | A credit is released without transport AllDelivered. |
| Forget retired assignment | A scope reports Drained despite unresolved original custody. |
| Accept a stale completion | An old correlation changes the current assignment. |

The integration owner completed the full model gate with command exit 0:
all 126 declared cases/probes are valid, and all 56 mutation controls pass.
Every mutant compiles and reaches its intended assertion. The run used 1,000
schedules per normal case, up to 2,000 per probe and 100 per mutation control.
These results apply to model commit `34653673`; the runtime lifecycle proposal
remains unimplemented.

Reproduce the complete gate with
`bash protocol/models/remote-execution/check.sh`. Its runner validates expected
probe and mutation assertions; an arbitrary nonzero exit is not a passing
counterexample. Source snapshots, commands, exits and schedules are retained in
ignored `protocol/models/remote-execution/PCheckerOutput/` directories. The
[model README](../../protocol/models/remote-execution/README.md) explains the
bounds and the distinction between checker exits and the gate's verdict.

## Limits and implementation obligations

The model explores directed bounded histories. Service answers, producer drain
and applied monitor observations are modeled facts. Real monitor identity,
message decoding, OTP delivery, native process retirement and SQLite durability
remain outside this proof boundary. A passing snapshot says nothing about native
descendants, Compile/workspace continuations or journal release.

The runtime must still implement exact-row fencing, canonical credit ownership,
normal idle-death handling and scope-owner monitoring. Real TLS tests must connect
these transitions to actual queued asks and joined producers. The native
close-state correction is separate: successful native retirement must survive a
later failed durable confirmation without attempting native close twice. Both
runtime changes remain pending the owner's API decision.
