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

## Next steps

1. Check hosted CI on the final head after the narrow CI declaration fix.
   Confirm whether `gilgamesh-signoff` targeting `obelisk` is the intended host,
   then run signoff on that final head. Record results in PR #981 before readiness.
2. Exercise live Anthropic cache usage when credits are configured. Record model,
   prefix size, cache reads/writes, latency, and main-request reuse after the side
   query. Merge and replace the installed daemon only with owner authorization.
