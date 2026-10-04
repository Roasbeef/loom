# Live compiler association model review

The P model now separates committed native admission from permission to launch
the compiler. The original live preparation claim must obtain a committed
resource association before its continuation receives a launch permit. Recovered
Ready data, a lost permit reply and a later process incarnation grant no new
permission.

The [model guide](../../protocol/models/remote-execution/README.md) describes the
executable cases. Its [implementation correspondence](../../protocol/models/remote-execution/PRODUCT.md)
maps the modeled boundaries to the resource journal, native service and owner
custody. This is a bounded state-machine model, not an end-to-end refinement proof.

## Independent review and execution

The independent Astra high review found no actionable defect in the frozen model
and its retained gate evidence. Manifest
`34c509b354d7f4acd22e886a5490937e38ff8ecabf855be0fac953de5166ba0a`
covered 28 files. The model adds four normal scenarios, seven reachability probes
and seven mutations while preserving the earlier controls.

The full safety run passed 39 normal scenarios at 1000 schedules each and 51
probes with a 2000-schedule budget. It exited zero in 355.805 seconds. All 37
mutations compiled and failed their intended assertions; the mutation run exited
zero in 610.279 seconds. Step, timeout and memory bounds remained unchanged, and
there were no skips. A probe can stop after its witness is reached, so its budget
is not a claim that all 2000 schedules ran.

The root independently ran all 90 scenarios and probes at 100 schedules on a
private source copy. After removing one trailing space from a model comment, the
root repeated that gate on the exact final bytes: exit zero in 79.327 seconds.
All 28 final source hashes matched the integrated tree. The whitespace edit did
not alter a mutation target or behavior; it is recorded here because the earlier
review manifest and final source manifest are different.

## What the model establishes

The model holds native Admit before association, retains the original claim's
issuer and incarnation separately from durable preparation facts, and permits
launch only after association commits. Cancellation before association prevents
the permit. Cancellation afterward follows the retained native identity and can
race process startup. Every historical control retains the full command reference.

The model treats initial insertion and claim as one abstract action. The
[atomic first-admission tests](distributed-compile-first-admission.md) separately
exercise the actual SQLite transaction. Nonce freshness remains an implementation
obligation. Stdin is modeled as forwarding permission, not arbitrary byte contents.
Illustrative startup budgets in the model do not measure production latency.

These checks do not establish OS process retirement, authenticated transport,
filesystem preparation, artifact finalization or registered separate-host
execution. Those require the original service assembly and its real-host tests.
