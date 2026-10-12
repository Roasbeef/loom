# Current handoff

Baselined October 12, 2026 against `8215026d5b2498dbdcea8e3af2da22a74e629e70`
on `web/history-while-running`. This edition covers browsing web history while
an operation runs. The installed daemon has not been updated.

The previous edition described the tool-latency branch and its older validation
heads. That is historical context, rather than the state of this checkout;
its full evidence and open decisions remain in the
[prior handoff](https://github.com/Roasbeef/loom/blob/8215026d5b2498dbdcea8e3af2da22a74e629e70/docs/next.md).
Do not carry those green gates forward as validation of this change. The
project-wide plan remains `docs/issue-plan.md`.

## What changed

The web view used to refuse older history at its row cap, showing “Older turns
come back when the current turn finishes.” Both operator and observer pages
now keep offering Load older. A full live turn or capped summary page switches
to a frozen ancestry endpoint. Further range reads move backward, evicting the
newer end instead of extending retained history without limit.

Live captures still supply current authorization, operation state and metadata.
Historical transcript projection uses the frozen window, including advisor
commentary. Stream fragments do not appear under historical rows. The endpoint
parks with its strand when the reader switches away and back.

Compact tool groups split at entry boundaries only beyond their joined results.
This keeps the row cap from discarding unseen calls and keeps overlapping
outcomes together. Raw history retains the existing 600-record / 16 MiB bounds;
normal historical pages draw at most 300 raw rows. An indivisible entry or
an overlapping batch can exceed the row cap, as the existing live projection
already permits for an indivisible block. Per-row expansion remains bounded.
Historical folds use their retained calls and honor expand/collapse clicks.

Jump to latest retires the historical request and captures the newest tail.
Late correlated replies cannot attach to that tail. Both pages expose the real
read-only return button at `component.latest_path`; the observer socket admits
only its exact click path. The floating browser button and composer send
activate it. The browser waits for `history="live"`, then follows after paint,
so replacing a tall historical page cannot cancel the explicit return.

## Verification boundary

The full web view suite passed 996 tests; the browser decision suite passed 296.
The client suite passed 4,489 tests. Conformance passed all 98 tests with native
Go cache paths. An earlier affected run used a temporary `GOCACHE`; its unchanged
SQL Go LSP fixture omitted that variable from its jail environment and failed
because Go tried to create the native cache outside the granted path. No
conformance assertion or source was changed to obtain the passing run.

The independent advisor review found the tool-group continuity, historical
fold and live advisor-overlay defects. Each has a regression. Restoring the
fold and overlay defects makes their new tests fail; the corrected full suite
passes. Final affected-package, generated-asset and Linux signoff results belong
on the PR at their tested commit.

An isolated browser fixture loaded the actual generated bundle and actual
server-rendered historical/latest states. It verified backward paging, return
to the bottom, and continued following after another row arrived. It simulated
the server patch; it did not exercise a live Codex provider or the installed
daemon. The initial browser run caught a transient-shrink return failure; the
server acknowledgement and after-paint scroll fixed it.

## Next steps

1. Finish the affected-package gate and publish this branch as a PR. Record
   the exact head and gate results there; do not infer them from this handoff.
2. Run `LOOM_SIGNOFF_HOST=gilgamesh-signoff make signoff-remote` on the published
   head and inspect hosted CI. Keep any remaining failures explicit.
3. Merge and update the running daemon only with the owner's authorization.
   Exit: the deployed web view can browse older history during an operation
   and Jump to latest resumes following new output.

## Parent and child completion follow-up

October 12, 2026: PR #965 extends the Sol context-budget documentation change
with the resumed-child completion fix, based on this branch's merge base
`8215026d5`. The handoff above describes the separate history-while-running web
change; its validation does not cover this follow-up.

The taproot-assets recording showed the parent finishing while its resumed
`audit-sync-history` child was still active. The child then recorded
`parent_finished`; the provider warning described an unconfirmed cancellation
acknowledgement. The fix keeps a naturally finishing parent operation open
while attached child operations remain active. The born-placed follow-up names
current handles. The guard applies while the Agency holder is available and
uses the existing synchronous hook ordering to read the separate writer and
session store. The shared UI joins the exact
aborted result to its recorded cause. Protocol-change/042 carries the addendum.

Focused validation passed 156 Agency tests, 482 shared projection tests and
29 snapshot tests, with regressions for resumed child completion, explicit
parent cancellation, and attribution in the transcript, web turn layout and
inspector. The six goal end-to-end tests passed in five repeated runs, and
the unchanged runtime passed all 201 tests. A shutdown regression retains the
previous completion behavior after the holder retires; this avoids planting
follow-ups during shutdown, but leaves a completion-protection boundary during
an independent holder restart. TUI (1,365), conformance (98), lint (240), and
sandbox gates passed. The sandbox gate needs Homebrew ahead of the app-bundled
`rg` on PATH, because the test exercises the jail's Homebrew read grant.
Independent review found no blocking issue. The final full client rerun passed
all 4,490 tests with exit 0. House lint, doc-check and configuration-key
self-tests also passed. Earlier full-gate failures exposed hook-ordering and
shutdown regressions that were fixed; their green replacement checks are the
validation above. Hosted CI must still attest to the pushed head. The installed
daemon has not been replaced. The owner's local Sol context setting is 500,000;
already-open sessions need reopening to acquire changed model metadata.

## Go LSP load failure follow-up

The btcd-release session `01a1323a-968b-74d0-8920-64441faa424e` recorded a
Go 1.26.9 toolchain download trying to write the read-only host module cache.
Installed Go was 1.26.8. Gopls subsequently returned `no views`, hiding the
retained load error. The LSP projection now preserves the load cause beside
server refusals until a typed semantic result establishes recovery. All 192
LSP tests and independent review passed. The local `[lsp.go]` profile now pins
prepared Go 1.26.9 at `~/sdk/go1.26.9`, with read-only SDK and module-cache
grants. The production profile decoder and private-cache validator accept it.
A real jail A/B reproduced the old error and returned all four
`Proxy.DialContext` references with the SDK toolchain. No network or extra
host write grant was needed. Existing sessions need reopening for the profile
change; the installed daemon has not been replaced.
