# Managed compiler and satellite provenance

This slice preserves the original managed tool identity through the existing
local builder and launcher. It implements the provenance portion of
[protocol 067](../../protocol-change/067-remote-workspace-services.md).
Registered physical execution and nested capability custody remain subsequent
components.

## Invariants and independent review

`identity.for_managed_execution` derives operation and step from the original
`ToolKey`. Phase derivation retains that parent independently of the physical
budget ledger. Builds derive `CompileCommand`; satellite launches derive
`SatelliteCommand`. Both reach the real broker through `clear_call_from`.
Build grants remain suppressed, run grants remain available, and call cancel
and step abort follow the existing handles. A split build ledger does not
change the original parent identity.

`client/codemode.execute_managed` compares operation, step and source index
before vetting or preparation. The caller supplies the actual
`tool_custody.Invocation.key`; this check does not reconstruct the argument
digest, authority or reserved result entry. Their association remains a trusted
assembly obligation.

The independent adversarial review found no functional provenance defect. Two
low-severity findings were corrected: the Unix-socket cleanup assertion now
checks actual path absence, and the package documentation names both identity
constructors. Focused re-review confirmed both repairs and unchanged production
source hashes.

## Validation

The pinned package gates pass 354 code-mode tests, 2,749 client tests and 158
core tests. Five new production-path controls exercise the real builder,
AF_UNIX launcher and broker dispatcher, including original cancellation. The
client controls construct a real runtime Invocation and prove mismatched
coordinates refuse before preparation. The new controls have no fixture skips.
Existing client environment/platform skips remain explicit; these counts do
not claim the shipped bootstrap fixtures ran locally.

A deliberate mutation replaced the managed `clear_call_from` branch with
ordinary `clear_call`. It compiled successfully and failed exactly the builder,
launcher and cancellation provenance assertions because the dispatcher saw no
origin. Two controls passed, zero skipped. The source was restored byte for
byte, and the repaired focused module passed all five tests.

Root independently reran the original tool-identity tests, all five native
provenance controls and the managed client controls, then ran the complete
157-test executor gate and documentation check. Each command exited zero.
The full executor gate includes the Linux-discovered test repair below.

These recording dispatchers deliberately stop physical execution. They prove
preparation, clearance and identity traversal, not a successful managed compiler
process, satellite boot or registered two-host execution. Full product
acceptance still requires the shipped owner and executor on disjoint hosts.

## Linux validation correction

The clean Linux run at workspace-selection commit `88117f7b873a` passed client,
mid, conformance, static and enforcement lanes, release update verification,
and the declared-skip census. Its fast lane failed one executor fault-injection
test, with 156 passing. After a failed completion commit, the worker can receive
the failure before the journal actor finishes shutting down. A subsequent
query can therefore report either `Custody(Closed)` or `Custody(Uncertain)`.

The test now accepts exactly those two results. Its reopened `Unknown`, existing
claim, real file contents and single-effect assertions remain unchanged. The
independent reviewer confirmed the race from the journal's reply/stop ordering.
All 17 workspace service tests pass in the same Linux image with this test-only
repair. The original full run remains red; that targeted rerun is not a clean
full-stack Linux signoff.
