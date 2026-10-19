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
