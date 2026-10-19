# Image follow-ups and Herdr previews

Validated October 19, 2026 against Loom source `47d4b54a6` and etui
`43969f88075a17044640e5e7cc43682b86a988ab`. Hosted and full-gate results belong
to the eventual PR head; the focused evidence here does not replace them.

## Dispatch finding

A read-only SQLite backup of the reported local session preserved the original
image-bearing prompt. Its first ten tool-calling assistant entries name
`gemini-flash / gemini-3.8-flash`. The run was stopped. The next text prompt
received a GLM-5.3 answer claiming the image never arrived, using the exact
historical-image placeholder produced by `client/vision`.

These records establish the original vision route and the later text route.
They are not a saved raw HTTP request. The original image remains durable;
Loom had removed it only from the follow-up's transient provider projection.
No operator transcript or image payload is checked into this report.

## Routing decision

The shared classifier now considers every image in this strand's projected
context, plus the existing immutable admitted batch. A text prompt can refer
to retained images without attaching them again. Admission, dispatch and the
live block-summary observer use the same classification. Navigation or
compaction that removes the pixels permits a return to the text route.

Historical images retain the gateway's existing per-endpoint budget. They do
not gain active-run protection. Consequently an older image beyond the image
limit may still be omitted with the existing explicit budget placeholder.
Without a usable vision route, a text-only identity retaining images refuses
admission. This costs additional vision turns while images remain in context;
it avoids a heuristic that guesses whether the wording refers to an image.

## Herdr finding

Herdr removed its bespoke pane-graphics API while retaining standard Kitty
rendering. Its [release notes](https://github.com/herdrdev/herdr/blob/master/CHANGELOG.md)
state that distinction. The pinned etui version incorrectly skipped every
`HERDR_ENV` pane, and its terminal-name allowlist also rejected `libghostty`.
The companion [etui PR #10](https://github.com/Roasbeef/etui/pull/10) fixes both.

An isolated installed Herdr 0.9.1 pane answered the one-pixel Kitty query with
`OK`, identified itself as `libghostty`, then answered primary device attributes.
With the corrected dependency, the actual Loom probe selected
`KittyPlaceholders(CellSize(5, 24))`. Herdr emitted the demo image as standard
Kitty RGBA graphics at 480 by 280 pixels. This is a native protocol capture,
not a screenshot assessment of an outer terminal's rasterization.

A negative control inheriting `NO_COLOR=1` selected `TextOnly(PlainPalette)`
and emitted no graphics. Missing and refused graphics replies remain covered
by the library regression. The smoke fixture used a private home and named
session; it did not access the operator's active Herdr session.

## Validation record

The focused client run passed 87 tests and the runtime conformance run passed
all six vision scenarios, including completed-run follow-ups, stopped-run
follow-ups, run-start injections, refusal without a vision route, and navigation
to a branch without images. The initial TUI image run passed 53 tests. Final
integration gates must use the pinned dependency.

Etui passed 1,004 Erlang tests, 950 JavaScript tests, formatting and both
documentation checkers. Its hosted test passed on the pinned commit. One fresh
independent adversarial review of both trees found no substantive findings;
the reviewer explicitly left dependency integration and runtime gates pending.

## CI repair findings

The full affected gate passed on `2a666d224` over base `ba4f1321498ff4d1544197ffdffa35a7d83ae2c4`
in 1,183 seconds, including 4,877 client tests and the skip census. Earlier
hosted advisory macOS jobs had green badges while their raw logs contained
failed test assertions; those logs remain part of the merge gate.

The remote-subagent restart failure led to a separate, deterministic finding.
A saved delegate can fail reopening while the previous writer's lease remains
live, then retain its slot while original custody drains. The resolver used to
turn that transient `Stopping` descriptor into a permanent store failure; a
second resolver could also lose the descriptor through admission's generic
`Unavailable` result. The manager now preserves existing Closing and Blocked
descriptors for the pair. Closing asks the sender to retry; a lost cleanup proof
still fails definitively, and parent release still takes precedence. Held
cleanup fixtures exercise both Closing paths and successful reuse of the same
durable identity. This reproduces a reachable product bug; the archived CI log
does not by itself prove that exact internal transition caused its missing
heartbeat.

The HTTP fixture used a one-second timeout on every header byte and another
one-second body timeout. Its functional requests now use one absolute deadline
within the existing managed fixture lifetime, read header chunks, and preserve
binary body bytes received with the header. A delayed, coalesced response failed
against the old reader and passed with the repair. Raw WebSocket upgrades keep
their exact-byte reader so a header read cannot discard the first frame.

The code-mode deadline fixture signalled admission before broker clearance
finished, so a clearance failure could settle the call before the asserted host
deadline. Its managed service now holds the admitted call until host
cancellation, with the original 200 ms wall deadline. The test also observes the
worker's death. No bootstrap or remote-background behavior was changed without
a reproducible cause.

The owner authorized repairing CI before merge and explicitly waived the
dedicated Linux signoff while obelisk is offline and no alternate host is
available. That signoff has not run. Final repair review, local validation and
hosted checks remain required; the earlier baseline does not validate the new
repairs. The repaired HTTP module passed 189 tests, the satellite module passed
39, the delegate module passed 32 and the daemon manager module passed 50.
All three deliberate delegate mutants failed the new regressions: terminal
Closing in the waiting resolver, terminal Closing at admission, and retryable
Blocked recovery. No operator installation or daemon restart is authorized.
