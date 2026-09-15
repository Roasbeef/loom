# Update takeover: partial acceptance

The #404 takeover is based on main `fe3cfbf2`. Its drain repair is
`dde20ee8`, reviewed independently against `6f598fc0`. This record covers
that repair and the remaining installer work; it does not declare the whole
PR ready to merge.

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

## Installer work still pending

The current installer can replace or prune a physical tree without proving
that no live process uses it. A version string is insufficient installation
identity: another build can use the same version. Legacy-directory migration
also cannot rename a live path safely merely because the new wrapper uses
physical paths.

The proposed repair gives each installation a fresh immutable directory,
resolves slim launchers to physical trees, retains old trees for manual
cleanup, and refuses unsafe legacy migration. Removing automatic cleanup is
a pending owner preference under the repository's scope rules. No installer
repair has been made on that assumption. If automatic cleanup is required,
it needs an explicit ownership design before implementation.

The local branch also fixes CI artifact paths to derive the release version
from the package manifest. Those paths formerly expected 0.1.0 while the
package version was 0.2.0. Shell syntax and YAML parsing passed; the updated
workflow has not run on GitHub because the takeover is still unpushed.
