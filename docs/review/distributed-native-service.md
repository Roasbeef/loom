# Remote native service review

This slice implements finite remote command execution over pinned mTLS, exact
SQLite payload custody and the existing native executor. It follows the owner
recovery component. Product registration, daemon selection and complete remote
workspace/code-mode/LSP assembly remain separate acceptance gates.

## Findings and corrections

Independent adversarial review found three reachable failures in the first native
adapter. A lost stdin acknowledgement could be ignored before accepting a clean
terminal result; replay of the last accepted input could incorrectly charge its
quota again; and cancellation before Submit could leave no durable admission
fence. The adapter now records input uncertainty instead of acknowledging success,
checks exact accepted ordinals before quota, and reserves a permanent cancellation
fence without inventing a prepared command.

A subsequent pass examined the correction paths, registration and listener.
It found a per-request process leak: completed native calls left their unlinked
output persistence actors alive. The publication factory now runs inside native
control initialization. Its linked child follows that parent's normal or abnormal
exit, and the final serialized End acknowledgement stops it directly. This uses
weft's existing parent lifetime rather than a new reaper or process ledger.
Only the journal handle and bounded request state remain in the sink.

The follow-up review closed the leak finding. No actionable finding remains in
the reviewed registration, listener or finite native adapter. A separate review
of the owner dispatch binding found no defect in original-child reservation,
full-scope immutable envelopes, exact receipt matching or cancellation fencing.

## Executed evidence

The executor package gate passed 105 tests, including 23 real native integrations,
21 TLS tests and seven administrative registration tests. Executor lint reported
zero errors. The complete executor suite also passed with four-way parallel
scheduling and serialized native census tests. There were no prerequisite skips
in the native suite.

The 33-command regression checks active-slot reuse and retained retirement
inventory, then compares VM process identities after scoped drain. An isolated
mutation restoring unlinked, non-stopping sinks fails this assertion while the
other 22 native tests pass. The corrected suite passes all 23. The module is
serialized in the parallel runner because the process census is VM-wide.

A second lifecycle regression kills actual native control and separately fails
initialization after publication-child creation; neither leaves the child alive.
Paused TLS writers do not block local cancellation. A failed journal still permits
local cancellation and attempted native drain, while durable evidence remains
uncertain. Lost admission, terminal and receipt replies retain exactly one native
filesystem mutation under the original request identity.

The owner binding's 13 SQLite tests cover full scope/physical coordinates, stable
request identity, forged receipts, exact ordered binary evidence, cancellation
before reservation and mandatory fence notification when custody is unavailable.
They invoke the real callbacks but do not exercise a TLS socket. The next gate
must join that owner adapter to the native service, then test the shipped system
on distinct hosts with no owner copy of the executor checkout.
