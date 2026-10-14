# Current handoff

October 13, 2026. This work starts at `dc70d25d4` (v0.3.2) and develops
`feature/btw-side-queries`. The previous edition described the history browsing
branch and separate LSP/child-completion follow-ups; its validation is historical,
not evidence for this feature. The installed daemon has not been replaced.

## Accepted design

Protocol-change/087 records the owner's accepted baseline: frozen context,
bounded follow-ups, explicit refresh, and no tool execution, available from both
TUI and web while main work continues. Context is the latest effective dispatched
request, including request-local transformations, plus a settled final answer.
It excludes streaming fragments and pending tool exchanges. Questions and answers
remain private, ephemeral attachment state outside the transcript.

The implementation adds the daemon side service, a dedicated correlated command,
shared panel state and polling, and both UI surfaces. Anthropic's request-scoped
cache-prefix hint preserves the frozen user-block endpoint before adjacent-user
merging, within the existing four markers. Model, system, tool and thinking
settings stay stable. Original output-token settings prevent an inherited thinking
budget exceeding a newly lowered ceiling. A settled fallback pins its actual
model before replaying the answer.

## Verification evidence

The scripted side-service tests passed: frozen follow-ups, refresh, private
histories, bounds, generated-tool-call refusal, cancellation/drain, disconnect
and gateway restart. Shared UI, web, provider, runtime and conformance lanes
passed, including 483 session-view tests, 999 web tests and 302 provider tests.
Static checks, warning-free builds, shipment preparation, documentation checks
and the skip census passed. The initial provider socket failures were sandbox
`eperm`; the full provider suite passed outside that execution sandbox.

The affected gate's first client lane exhausted its default 1200-second test
budget without an assertion failure. The exact affected gate rerun with
`LOOM_TEST_TIMEOUT_SECONDS=3600` passed in 1352 seconds: all 4497 client tests,
1369 TUI tests, the other affected lanes and the strict skip census. An earlier
ordinary client rerun omitted the shipped-fixture environment and is not the
replacement-gate evidence.

Hosted test, build, jail, soak and end-to-end jobs passed on `a25e80fe6`, including
the macOS aggregate gate. The Linux aggregate gate found one pre-existing missing
ordinary-runner skip declaration for `shipped deployment status`. The owner
authorized the narrow CI fix. Its census replay against the captured hosted log
is clean. Enforced Linux signoff on `a25e80fe6` passed in 1710 seconds with a
strict clean skip census, proving the fixture ran without that waiver. The
configured `gilgamesh-signoff` alias targets `obelisk`; the driver confirmed that
hostname. The declaration applies only to the ordinary hosted Linux gate.

The independent advisor review found that refusing an overlapping side action
erased a running board and stopped polling. Preserve its history/status and
update only the notice; a regression passed. Web panel buttons now use the
existing control path, preserving the main draft; that regression also passed.

The owner has no Anthropic credits hooked up; live Anthropic cache/latency testing
is deliberately deferred to the PR. Fixtures prove request shape and custody,
not live cache reads or savings. The installed daemon has not been replaced.

## Review iteration and personal E2E

The review loop confirmed three medium findings in round one: busy command lanes
could repeatedly arm an expired browser polling timer; the painted TUI split
disagreed with scrolling, image and copy geometry; and typed drain outcomes were
lost before capacity accounting. Round two found a separate side paging width
mismatch under the docked rail. All four are fixed in `7c96483dc`, `348a7e113`
and `69d4d6461`. Round three and its separate triage are clean at the medium
cutoff. Three fresh, bounded cold reviewers approve the service/runtime,
shared UI, and provider/protocol slices at `69d4d6461`.

Drain proof loss now reserves capacity for the remaining side-service lifetime,
including across Clear, Forget and Reset. Clearing a failed panel cannot admit
more than two possibly live transports. The regression uses a real HTTP owner
loss, also checks clean request reuse, and settles usage once. Focused client
side-service tests pass (6), shared session-view tests pass (486), and TUI side
regressions pass (8), alongside the selection and image checks.

The primary reviewer personally drove the real TUI, daemon and web UI against a
local deterministic OpenAI SSE fixture. Main streaming continued during private
side queries from both attachments. Raw outbound requests prove that TUI
follow-ups retained the old base after main context advanced and web refresh
adopted the new base. Overlap made no provider call. Side cancellation closed
only the side transport while main output advanced and the web draft survived.
A generated call to the advertised bash tool was refused: one inference request,
no continuation, no execution marker. The six durable conversation entries at
that checkpoint contained only main questions and answers, with no side markers.

On rebuilt source, a 15 KB side answer's tail is reachable through ordinary TUI
paging with the rail docked. Main mouse-wheel scrolling reaches the oldest
loaded rows while the panel remains open. A real mouse drag emits an OSC52
clipboard payload of `LONG_START`, preserving the side answer's leading characters. A new attachment forgets side history;
the rebuilt web controls preserve the main draft through Clear and Close.
Evidence lives under the ignored `build/pr981-personal-e2e/` fixture directory
and `/private/tmp/loom-pr981-review/`, rather than in the tracked source tree.

Hosted CI on `04dd10575` has now completed successfully on both Linux and macOS;
that precedes the review fixes. The new full affected run is still in progress. Its first static lane found five
line citations shifted by the layout fix; those references were corrected and
`make doc-check` passes. This initial run will retain its failed static status;
its package checks and skip census must be assessed independently, followed by
a clean complete run if necessary. No successful final-head gate is implied.

Low UX observations remain follow-ups: resetting side scroll after refresh,
side-wheel routing, and side paging key precedence over help/notes (#983). A direct
integrated observer/fallback capture regression remains a coverage improvement (#984).
The missing v2 client-protocol reference has been filled in.

## Next steps

1. Finish the local affected run, verify the corrected static gates, and record
   exact-head hosted CI and strict Linux signoff after pushing this iteration.
   Use the owner-confirmed `gilgamesh-signoff` alias. Its `obelisk` hostname and
   separate signoff account are intentional; do not ask for confirmation again.
2. Exercise live Anthropic cache usage when credits are configured. Record model,
   prefix size, cache reads/writes, latency, and main-request reuse after the side
   query. Merge and replace the installed daemon only with owner authorization.
