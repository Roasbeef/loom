# Web Mermaid rendering: validation and review

**Status**: browser-validated in Chrome · **Date**: 2026-10-18, browser drive 2026-10-19 · **Base**: `dd43362c86b43000e69e291550a41c21f5ffc13b`, rebased onto `490792538` · **Branch**: `feature/web-mermaid`

The web implementation follows
[protocol-change/091](../../protocol-change/091-isolated-mermaid-diagrams.md).
The source stays in the session page as text, and a separate opaque frame owns
Mermaid's DOM generation. The TUI remains unchanged. These results describe the
local implementation, not an installed release or a completed end-to-end signoff.

## Initial implementation: local gates

| Gate | Observed result |
| --- | --- |
| `web_view` package suite | All 1,131 tests passed, including Markdown dispatch and escaping. |
| `make test-web_client` | All 309 Gleam tests and five isolated renderer adapter checks passed. The adapter checks also passed under Bun independently. |
| `bash scripts/test.sh client --match client@ui_` | All 353 web UI tests passed, including real listener responses for the renderer's HTML, script and independent CSP. |
| License collector unit tests | Three tests passed. Notice generation found license files for every locked production dependency. |
| `make gen-client` and `make client-check` | Generation, source/body digest checks and negative gate self-tests passed. |
| `make fmt-check` and `make doc-check` | Passed. Existing documentation warnings remain; source-line citations moved by the route changes were repaired. |
| Affected package lint | `web_client`, `web_view` and `client` passed with zero errors. Existing census warnings remain. |
| `make server-shipment` | Built successfully twice during implementation. Rebuild after the final asset generation before the browser drive. |
| `npm audit --omit=dev` | Zero reported vulnerabilities for the pinned dependency graph at the time of the run. |

The adapter tests use a controlled vendor promise and a minimal DOM fixture.
They prove the adapter's queue, request restrictions, result vocabulary and
rejection behavior, not actual Mermaid layout or browser enforcement. The route
tests prove response headers and asset selection, not that a browser applied them.

## Initial implementation: independent review

One report-only adversarial pass examined the isolation contract, revision and
lifecycle ownership, build gate and test failure modes. Every reported finding
was checked against source before fixing it. A focused re-check of the fixes
reported no additional code findings.

The fixed findings were:

- Indented YAML frontmatter bypassed the initial configuration guard. The pinned
  Mermaid parser accepted a two-space-indented `theme: forest` configuration.
  The guard now recognizes leading whitespace, with space/tab regression cases.
  Replacing it with the old guard in a scratch copy makes the adapter test fail.
- The browser drive required a new light-theme render even when light was already
  effective. It now switches to the opposite effective theme first and requires
  a newer rendered revision for each transition.
- Selecting the first cached Bun could use a different version. Generation now
  reads the version in the locked Lustre tool and selects only a matching binary.

The build also retains dependency license notices as a separately stamped
release artifact. No test was removed or assertion weakened to address the
local environment failures below.

## Initial publication: unfinished validation

`make check` failed before package execution in five unchanged script tests:
four installer pruning expectations and one signoff fixture's fake Git remote
lookup. The jail denies `/bin/ps`, and the signoff fixture attempted to resolve
`origin.example.invalid`. These failures are not a successful full gate.

A subsequent full client-suite attempt encountered jail-dependent failures and
was terminated with exit 152 (the runner reported signal 24) before completing.
It establishes no complete client-suite result. An initial broad `ui_` filter
also selected `tui_` fixtures; the exact `client@ui_` module prefix was used for
the separate, passing web UI run above. This does not replace the full suite.

The disposable browser seed could not start through `bin/loomd`: daemon
startup reported that `/bin/ps` could not be consulted. The check is in
`host_bootstrap_ffi.erl`'s native process-identity path. An initial suggestion
to use the shipment entrypoint directly was wrong: inspection confirms that
`bin/loomd` already executes that entrypoint, so it would reach the same check.
The identity check is unchanged; a live daemon run needs an unjailed runner.

Consequently, `scripts/web_mermaid_check.sh` has not been executed. Real SVG
contents, browser CSP enforcement, layout, source disclosure/copy interaction,
streaming recovery, theme changes and reconnect behavior still need the live
browser drive. Full hosted CI and strict Linux signoff are also unverified.
The branch must remain draft until those validation requirements are met.


## Gleam controller follow-up

Baseline: controller `22891231e`, generated assets `2c4d5a5f3`. The earlier
adapter measurements above describe the JavaScript implementation before this
refactor. Its policy and lifecycle cases now live in `web_mermaid`'s pure
controller tests. The five remaining JavaScript tests cover only the minimal
DOM/vendor binding, including promise and exception conversion. The unchanged
parent protocol and content policies remain those accepted in protocol 091.

The combined `scripts/check.sh web_client web_mermaid web_view` run passed:
309 parent tests, five FFI checks, 19 controller tests and 1,131 view tests.
After the final tail-recursion fix, the controller suite passed all 20 tests
and built warning-free. Asset regeneration and the offline gate, format and
doc-check passed again. Frame-package lint has zero errors and two R18 helper
census warnings; session-client lint has zero errors. Metadata regressions
passed: 35 test-scope cases, 27 affected-package cases and 23 orientation cases.
The parent bundle is unchanged and contains no frame-program or SVG-parser
imports. The renderer bundle is about 5.4 MB uncompressed.

A fresh report-only review of the refactor reproduced a source-policy
regression: Gleam's trim and LF-only splitting accepted NBSP/BOM-indented or
CR-only frontmatter that the pinned vendor treats as configuration. The guard
now uses ECMAScript codepoint whitespace and line boundaries. The old compiled
controller fails the NBSP refusal assertion; the fixed controller covers every
ECMAScript whitespace character, line boundary and cross-line click arguments.
A focused re-check found that the new line scan could exhaust the JavaScript
call stack on a source with 31,980 newlines. Its recursive call is now in tail
position, with a near-limit regression. Independent Node assertions confirmed
the generated loop and both fixes, with no further delta findings.

A standalone component fixture served the actual compiled frame with its
production child policy, but Chrome exited before publishing a DevTools
endpoint. No browser DOM or CSP test executed. The offline diagnostic found
Chrome installed and no active browser daemons. The named browser session was
explicitly closed, and the temporary fixture server was stopped and observed
terminal. No sandbox-disabling launch was attempted.

Hosted CI run [39197514303](https://github.com/Roasbeef/loom/actions/runs/39197514303)
is green for the previously published `746cb0bfb`, including both platform
gates. That corrects the initial publication's unverified hosted-CI status,
but does not validate the controller-refactor head. Hosted checks for the new
head, strict Linux signoff and the real daemon/browser drive remain required
before the draft becomes ready.


## Browser drive and review fixes (2026-10-19)

The branch was rebased onto main `490792538` and driven against a real seeded
daemon (`make gen-client server-shipment`, `scripts/web_seed/seed.sh` on
private ports, then `scripts/web_mermaid_check.sh`) in Chrome for Testing,
outside the jail that blocked the earlier attempts. The first run found two
defects that no unit test could see, because both live in the real vendor or
the real browser rather than in the controlled-promise fixtures.

Every flowchart failed and fell back to source while sequence diagrams
rendered. Mermaid 12 lays flowcharts out with ELK, and elkjs's browserified
prelude reaches for a CommonJS `require` that Bun's IIFE output rewrites to an
undefined `__require`. A debug build of the same vendor reproduced
`ReferenceError: __require is not defined` on the ELK path. The fixed
configuration now pins `layout: "dagre"`; with it, flowchart, state, class,
ER, gantt, pie, mindmap and sequence diagrams all render. Directives that
could select another layout are already refused.

Dark-palette diagrams sat on an opaque white box. The frame document declared
no colour scheme while the page declares `dark`, and a browser paints an
opaque canvas behind a frame whose scheme differs from its iframe element's.
The frame runtime now sets its root `color-scheme` from the request's theme.
Screenshots after the fix show transparent frames in both themes.

The drive script itself had never run and could not pass: helpers were
installed before the ticket redirect replaced the document, the checks
outlasted one CDP evaluation, and the streamed answer row is replaced by the
committed row when the turn ends, so diagrams captured once went stale. Each
is fixed in the script. After the fixes, all 21 checks pass on repeated runs:
flowchart and sequence render under the real response CSP, the invalid fence
keeps its source open, the frame document is inaccessible to the page, no SVG
enters the parent shadow tree, parse failure and the 32,001-unit bound fall
back to source, recovery and a 30-revision burst keep only the latest source,
foreign-window and stale-revision replies are ignored, both theme transitions
redraw, configuration, indented frontmatter and `click` directives are
refused, and a reconnected element ignores its departed frame. The observer
page renders the same diagrams, and the session page made no request to any
other origin.

A report-only Fable review of the rebased branch then found two lifecycle
gaps, both fixed. The parent's ten-second deadline started when the source was
read, so it also counted each frame's load of the 5.4 MB renderer; on a remote
daemon with several diagrams, later frames answered after the deadline and
stayed unavailable. The deadline now starts when the request is posted. A
mount scheduled for the next paint could also land after the element was
removed and install a window listener nothing would release; a detached
element now installs nothing. The review also showed that a `flowchart-elk`
header still selects ELK; it fails closed to source, and the docs now say so.
The drive passed all 21 checks again after these fixes, as did the 353
`client@ui_` route tests.

The renderer's npm bundle, lock, notice collector, frame document and binding
checks moved from `web_client/mermaid` to `web_mermaid/bundle`, so one package
owns the frame program and its FFI checks run in its own lane. Two repeated
phase matches were folded. Not covered here: Firefox and Safari.

## Many diagrams: caching and frame lifetime (2026-10-19)

The seed's fake model answers `mermaid many` with 24 small flowcharts in one
streamed answer. Measured in Chrome for Testing against a local seeded daemon,
from send to every framed diagram shown, with Chrome's total RSS sampled
before and three seconds after:

| Variant | Time to shown | Frame loads | Live frames at end | Chrome RSS growth |
| --- | --- | --- | --- | --- |
| One frame per diagram, renderer `no-store` | 9.0 s | 48 | 24 | 1,018 MB |
| Same, renderer `private, max-age=3600` | 8.5 s | 48 | 24 | 920 MB |
| Frames only near the viewport, `no-store` | 8.1 s | 26 | 2 | 423 MB |

Each diagram loads twice: once in the streamed row and again in the committed
row that replaces it, so 24 diagrams cost 48 loads of the 5.4 MB renderer. The
time is dominated by streaming, so caching barely moves it on a local daemon,
and memory is dominated by each frame's own renderer heap, roughly 20 to 40 MB,
which caching does not touch. The renderer therefore stays `no-store`, like
every other UI asset, with no versioned path to keep in step across upgrades.
Instead a diagram's frame is created only once the element comes within a
viewport of the visible area, and is kept from then on. Opening a long
transcript now starts renderers only for what is on screen. The remaining
growth in the third row is mostly frames made while the answer streamed at
the bottom of the page, which are dropped when the committed row replaces
them. A remote daemon would also save the transfer, about 260 MB in the first
row. The 21-check drive passes with lazy frames; it now scrolls each diagram
into view, since the page follows the newest row.
