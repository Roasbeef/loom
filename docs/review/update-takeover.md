# Update takeover: review and acceptance

The #404 takeover is based on main `fe3cfbf2`. Its drain repair is
`dde20ee8`, reviewed independently against `6f598fc0`. This record covers
that repair, the installer, and reconnect fixes through `76030114`. The owner
retains the final merge decision; hosted CI and Linux signoff must be checked
at the pushed head.

## Drain review

The production path is `main.prepare` through `serve.drain_instance`.
Registry snapshots retain each resident instance's drain capability, then a
bounded root-owned task invokes those capabilities outside both actors.
The root remains responsive in `Stopping`. Each gateway permanently refuses
mutations before returning held input and requesting runtime cancellation.

The gateway sends return pushes and a flush marker to each transport from the
same process. The socket acknowledges the marker after preceding writes.
Waiting occurs outside the gateway, allowing an in-flight socket request to
finish. An acknowledgement confirms socket writes, not remote receipt or
persistence. Expired budgets and disconnected clients cannot confirm return.

The independent adversarial pass found no actionable defects. It checked
production wiring, exhaustive command admission, callback instance identity,
Push/Flush ordering, shared deadline accounting, and original custody witness
retention. Starting the task before returning the new root state cannot admit
a mutation: the root processes no other message during that turn. Worker
completion never establishes lifetime retirement or authorizes lock release.

## Validation

`make check-client` passed all 1,807 tests with an empty HOME and its own
exit status captured as zero. Focused modules passed 17 daemon-root tests,
93 gateway tests, and 9 real socket tests. The regressions exercise paused
drain control reads, real registry authority checks, lock retention, late
mutation refusal, no successor after abort, a withheld transport flush
acknowledgement, and complete held text written before daemon teardown.

Format, client lint, and documentation checks passed. Client lint reported
181 warnings and zero errors. The review inspected the regressions but did
not independently rerun them or establish mutation sensitivity. Full final
PR, release, hosted CI, and Linux signoff remain separate acceptance gates.

## Immutable installation

Commit `9d664731` gives each installation a fresh immutable directory and
retains old trees for manual cleanup. It refuses legacy paths before copying
or publishing; moving a live legacy directory would break later path-based
loads. Complete wrapper files and release links are renamed individually.
The slim shipment carries its own launcher, build metadata, and profiling
behavior. Switching client shapes retains old links and trees.

All 17 Python script tests passed, including four installer regressions:
repeated installs retain every older tree, a delayed read uses the original
tree, shape changes and rollback select the expected artifacts, and failed
copies or legacy paths preserve the installation. A separate check of the
actual built slim launcher verified physical ebin paths, artifact identity,
profiling argument handling, and installed sibling discovery.

## Final review findings and disposition

The independent pass over the remaining update path found four defects:

| Finding | Disposition |
|---|---|
| Reconnect could spend its only attempt on a draining VM before native retirement. | `e5423bc9` polls read-only endpoint/status observations under one deadline. Healthy accepting VMs can be reused; only native vacancy reaches one launch-capable resolver. |
| Adoption and later captures erased the build mismatch notice. | `e5423bc9` projects authenticated identity on every coherent capture. |
| Server shipment inherited the client's build identity. | `41fe733a` stamps the generated server launcher and runs the lifecycle fixture with conflicting inherited client values. |
| Stopping a newer daemon did not make an old-schema rollback startable. | `76030114` documents the additional offline recovery prerequisite; neither deleting the endpoint alone nor a stop permits silently discarding its fence. |

The reviewer checked those fixes at `76030114` and closed all four findings
without another actionable ordering defect. The six daemon-bootstrap tests
passed, including a real native process held after its serving socket is gone.
The real daemon lifecycle fixture passed through the shipped reconnect event
and successful session adoption. It checks draft retention and exactly one
mismatch notice after adoption and a subsequent capture. It also verifies that
a healthy VM can be reused. Reconnect obtains a fresh coherent capture;
standalone resume-codec tests are not evidence of a resumed-subscription path.

The CI artifact fix in `34ea0895` derives release filenames from the manifest
instead of expecting 0.1.0 for a 0.2.0 build. Shell syntax and YAML parsing
passed. The full local `make check` gate passed at implementation `76030114` with its
own exit code captured as zero: 17 script tests, every Gleam package including
1,807 client and 510 TUI tests, Go sandbox checks, and house lint with zero
errors. The isolated test HOME uses a separate short `LOOM_TEST_SCRATCH` path
for code-mode sockets. Release, hosted CI, and Linux signoff remain separate
from review; consult the PR checks for the exact pushed head.
