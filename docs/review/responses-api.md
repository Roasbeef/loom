# Public Responses adapter verification

This record covers issue #117 Track A on `provider/responses-api`, based on
`40fc5dcb`. The implementation is split into adapter, catalogue, runtime
coverage, and documentation commits. It does not close the subscription
track or the separate provider transport/redaction issues.

## Contract and coverage

| Boundary | Evidence |
|---|---|
| Request projection | `responses_request_test.gleam` checks ordered history, flat tools, text/images, tool-error envelopes, thinking settings, and omitted provider state. |
| Stream settlement | `responses_test.gleam` checks byte chunking, interleaving, identity, completion witnesses, terminal reasons, usage, replay bounds, and malformed input. |
| Configuration and dispatch | Catalogue, domain-resolution, and gateway tests distinguish Responses from Chat Completions and reject unsupported authentication combinations. |
| Runtime tool turn | `responses_e2e_test.gleam` uses the real gateway, client wiring, runtime, and memory store. Scripted HTTP and one trusted fixture tool produce two requests and an exact four-message durable chain. |
| Resource ownership | The adapter uses the existing tracked transport. The opt-in live runner installs its original drain witness before beginning and requires observed drain even after failure. |

The request-only secret canary proves that the fixture does not copy its
authentication header into durable data. It does not prove that arbitrary
successful provider output cannot echo a secret; #148 remains open. The
adapter also does not repair OTP's non-success-body buffering boundary in
#147. No new dependency, native helper, FFI, SQL, or frozen interface is added.

## Independent review

A fresh, report-only reviewer checked the implementation and tests, then
rechecked only the fixes. Two findings were accepted:

1. Message phase was omitted from canonical replay metadata. The fix retains
   optional `commentary` or `final_answer`, validates supplied initial phase,
   and checks item-done/final agreement. Tests cover replay, conflicts, and
   malformed values.
2. The runtime fixture filtered input by type, so reordered history or lost
   ordinary text could pass. It now destructures the exact item sequence and
   checks the original user text, assistant text, and commentary phase.

Both findings were closed on source reinspection. The reviewer did not run
the author's gates; their results are recorded separately below.

## Mutation checks

Each mutation changed the implementation, failed the intended assertion,
and was restored before the positive rerun and commits:

| Mutation | Observed failure |
|---|---|
| Ignore argument-done disagreement | Stream witness regression failed. |
| Remove the replay metadata size guard | Oversized-metadata regression failed. |
| Duplicate ciphertext onto every reasoning part | Single-copy signature regression failed. |
| Drop reasoning items from outgoing replay | Runtime fixture saw four input items instead of five. |
| Drop phase from canonical metadata | Replay assertion could not recover `commentary`. |

## Gate results

Native verification on September 7 passed across split runs. The full
package loop passed through client (1,409 tests, 378.40 seconds) and TUI
(211 tests, 8.13 seconds), then correctly failed the new conformance
fixture's indentation check. After the formatter-only correction, the
remaining conformance (70 tests), lint package (127 tests), and Go sandbox
checks exited zero in 38.55 seconds. Provider passed all 228 tests in the
full loop. The earlier attempt had stopped on Hex rate limiting before
client tests; the repository's Hex-only retry wrapper was used thereafter.

Final format, generated-prelude, and documentation checks exited zero in
2.16 seconds. Documentation reported zero errors and 137 existing warnings.
Repository lint exited zero in 3.27 seconds, with zero errors and 635
warnings. The strict skip census passed with only the declared Darwin
real-MCP fixture skip caused by absent procfs. No timeout or skip policy was
relaxed.

The rebuilt server and bundled release exited zero in 59.99 seconds.
The no-system-Erlang release smoke exited zero in 2.87 seconds and proved
readiness, explicit session admission, shutdown, and bundled code mode.
These are native local results, not a claim that one uninterrupted
`make check` or hosted CI had passed at this snapshot. Hosted results belong
to the PR's current commit checks.

The opt-in public API smoke exited 1 after 7.63 seconds and printed
`drain: confirmed`. One bounded diagnostic request established
`credit_balance_exhausted` in `response.failed`; no further paid requests
were attempted. Successful live public inference remains unverified until a
funded API account runs the explicit smoke. This failure is not a passing
skip or evidence of malformed stream handling.

The local Actions emulator could not install OTP 29.0.5: setup-beam reported
that `/home/runner/_work/_temp/.setup-beam/otp/Install` was missing. A run of
the actual PR workflow reproduced the bootstrap failure and exited 1 in
67.38 seconds, before source tests. Native local gates and hosted CI are
separate evidence; this rehearsal is not reported as green.

## Remaining issue scope

[ADR-012](../adr/012-responses-and-subscription-boundaries.md) records why
Codex subscription inference is deferred. Reopening it requires a supported
integration boundary that preserves Loom's ownership of history, tools, and
the agent loop. No subscription parser stub or credential reader ships here.
The issue's older strict argument-decoding instruction is superseded by
#189's corrective tool-result behavior; that correction is also recorded on
[issue #117](https://github.com/Roasbeef/loom/issues/117#issuecomment-5568266694).
