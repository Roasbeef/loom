# Operator diagnostics review

Baseline: 868dfedd8754e1b8a750add24227bd2b83fcd167. Scope: #363, #377 and #286.

Configuration rejection now retains a one-line reason of at most 2048 UTF-8
bytes for the exact failed opening. Authenticated operation reads check epoch
and session authority before exposing it. The memo precedes live Stopping
status, while cleanup custody still fences capacity and replacement.

Extension assembly retains at most 32 bounded refusal notices. Credited
attachment metadata reaches startup and reconnect; the total decoder rejects
malformed or oversized notices. Refused extensions remain absent from the
registry. The existing explicit remove-then-install workflow remains the
reinstall guidance; this change grants no replacement authority.

Hook refusal and enforcement details survive in bounded Outcome.stderr.
Exit 1 and empty stdout remain unchanged. Timed-out or cancelled degraded
execution discards both streams. Existing compatibility consumers may discard
exit-1 stderr; this establishes the Outcome boundary, not transcript or
debug-log delivery. Future hook CLI work remains #369.

## Independent review disposition

The adversarial pass found that a matching live Closing slot hid the failure
memo until retirement. The production terminal stops polling on Stopping,
so the initial regression's retry-any-success loop could mask the error.
The lookup now checks the exact memo first, and the production test retries
only Opening. The correction review found no remaining defect.

A deterministic storage-custody barrier keeps retirement open while the test
checks the diagnostic, stale-operation rejection, capacity and replacement
fences. It then parks the next builder before publication to prove admission
clears the old memo. Restoring the old lookup order fails that assertion.
The independent root execution of this regression passed.

## Validation boundary

Before the review correction, component gates passed client 2290 tests,
session_view 47 and TUI 946, including format and warning-free build checks.
After correction, the manager module passed 29 tests and the diagnostic
selection passed nine. Format, scoped lint, doc checks, mirrors and diff
checks passed. Existing lint and documentation warnings remain.

All three original diagnostic mutations reached regression assertions:
generic startup reason, generic hook refusal, and discarded extension notices.
Restored sources passed their targeted tests. The timeout fixture sets both
flags together; it does not independently establish each flag or captured
stderr discard.

Full make check stopped at machine dependency resolution on a Hex rate limit.
Hosted CI and exact-head Linux/shipped-server signoff must be read from the PR.
These component results are not a complete signoff. The shared wave handoff is
maintained by the documentation-cleanup PR.

## Main integration

Main advanced to 5f9df823a after the documentation-cleanup PR merged. The
topic integrates that baseline, preserving the reviewed diagnostic algorithms
and upstream UI changes. The conflicting source citation was refreshed from
the actual merged gateway. The nine diagnostic tests and deterministic cleanup
regression passed again, as did formatting and documentation checks.
