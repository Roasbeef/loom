# Admitted native capability provenance

This slice carries the original managed tool identity through nested native
capability calls in both satellite host modes. It builds on managed compiler
and satellite provenance in PR #789. It does not enable registered execution
in the shipped daemon.

## Admission and identity

The host derives a native child only after the trusted router accepts a call
and both the lifetime and outstanding-call ceilings pass. The child retains
the complete original ToolKey, trusted capability name, existing per-capability
admission ordinal and NativeCommand purpose. Derivation fails before tally,
worker creation or broker dispatch. There is no new counter, native UUID or
budget ledger.

The persistent host derives that child from the current invocation, not the
node's launch identity. The shared collector passes it to clear_call_from with
the original CallSpec. Owner callbacks keep their existing service custody.
Managed Build phases cannot issue native capability children; unmanaged local
calls preserve their previous behavior.

## Verification

Six new tests drive actual framed satellite peers through the single-shot and
persistent hosts into a real broker with a recording Dispatcher. They check
complete parent identity, names and ordinals, unchanged physical budget
coordinates, command data and policy, rejection before ordinal consumption,
per-invocation reset and cancellation. A controlled dispatcher refusal occurs
after dispatch. These controls do not execute a physical native command.

A temporary mutation replaced the managed collector's clearance with ordinary
clear_call. It compiled, then failed four intended assertions because the real
Dispatcher received no origin. The two derivation controls passed. The
satellite source was restored byte-for-byte before review and validation.

The full code-mode suite passed 360 tests. Root independently reran the six
focused controls with exit zero. The earlier worker client log ended after its
passing census without a recoverable command exit, so root reran that package
gate. The independent client run passed 2,749 tests and exited zero. It printed
15 existing setup skips: thirteen shipped-server fixtures, the Linux-only MCP
process check and unavailable rust-analyzer. None of the new controls skipped.
Root also reran code-mode lint and documentation checks; both exited zero.
The lint census warnings remain non-gating. The fresh full Linux signoff passed
at parent commit `4b8b57e934bd`, including all six lanes, release verification
and a clean skip census. Its 1,277-second command exited zero. That run precedes
this nested-capability slice; it does not certify this later diff or hosted CI.

## Independent review and limits

The independent adversarial review found no actionable findings after tracing
both admission paths, the shared collector, cancellation and the new controls.
It confirmed that the actor installs its updated tally before processing the
next queued call, and that no sibling native collector drops managed identity.

Remote command custody, executor resource preparation, consumption-credit
channels and shipped separate-host acceptance remain later integration work.
Provenance identifies an effect; it does not authorize it or prove native
retirement.
