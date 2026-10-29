# Responses failure recovery

Loom baseline: `fcbc7d9b468f8381a5ada5579d5b23a690e4ea65`, October 28, 2026.
This follows the merged [PR #1140](https://github.com/Roasbeef/loom/pull/1140).
The implementation was integrated onto main `da27f068d` without changing
either reviewed patch; `git range-diff` reports both commits unchanged.

## Evidence and change

Two on-disk assistant failures recorded only
`provider stream error (responses_error): Responses provider reported failure`,
terminal classification, and one attempt each. Manual continuation subsequently
succeeded. The active daemon identified itself as the #1140 merge. The store
did not retain the upstream error code, message or event kind, so the original
cause cannot be recovered or attributed to capacity, access or quota.

Direct Responses errors used the outer envelope instead of nested `error`.
Unrecognized failures became terminal, and neither HTTP-success headers nor
event error headers could carry retry advice through `StreamError`.

In this change, we normalize nested and flat failures, retain safe structural
diagnostics, and give unclassified Responses failures the existing ceiling of
three total generations. The gateway forwards these failures immediately;
runtime settlement and the machine own retry scheduling and durable narrowing.
Recognized permanent labels beat conflicting transient labels and throttle
prose, including quota denials sent as HTTP 429. Protocol
[104](../../protocol-change/104-streamed-failure-retry-advice.md) adds optional
structured retry advice, using the existing parser and backoff path.

## Codex source comparison

The close read pins openai/codex to
[`f276b82185f021e7b8d532a3851413bc79a67594`](https://github.com/openai/codex/tree/f276b82185f021e7b8d532a3851413bc79a67594).
The following source groups were traced together, rather than inferring retry
policy from the SSE parser alone:

- [SSE event fold and reader](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/codex-api/src/sse/responses.rs),
  [failed-response mapping](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/codex-api/src/sse/responses_error.rs)
  and [HTTP bridge](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/codex-api/src/api_bridge.rs).
- [Core retry loop](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/core/src/responses_retry.rs),
  [provider defaults](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/model-provider-info/src/lib.rs),
  [typed retry eligibility](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/protocol/src/error.rs)
  and [retry deadline parser](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/http-client/src/retry_after.rs).
- [Turn settlement and cleanup](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/core/src/session/turn.rs),
  [item/tool dispatch](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/core/src/stream_events_utils.rs)
  and [transport ownership](https://github.com/openai/codex/blob/f276b82185f021e7b8d532a3851413bc79a67594/codex-rs/core/src/client.rs).

| Path | Pinned Codex | Loom after this change |
| --- | --- | --- |
| Direct `error` | Reads nested errors specially for model-not-found and Flex. Other direct errors are ignored by the semantic fold; EOF commonly supplies generic stream failure. | Normalizes nested or flat errors immediately. This is deliberate compatibility behavior, not an identical Codex dispatch. |
| `response.failed` | Reads `response.error`; recognized codes select typed policy, other decoded errors are retryable. Missing or malformed errors become a stream or retryable error. | Known code/type selects policy; missing, null, malformed or unfamiliar labels become bounded generic recovery. Usage has its own strict decoder. |
| Permanent errors | Failed-response mapping primarily dispatches by code. HTTP bridge distinguishes quota/usage denials from throttling. | Shared permanent vocabulary checks both code and type before transient evidence. Permanent labels also beat 5xx; this stronger Loom rule is not claimed as exact Codex parity. |
| Error then completion | Usually retains the error until EOF; a later completion can succeed. Flex and incomplete errors can return immediately. | First terminal wins. Later bytes cannot turn a failed response into accepted output. |
| Completion witnesses | Accepts a smaller completed envelope. Malformed event JSON is logged and skipped. | Requires identity, closure and canonical-output witnesses. No successful-response validation is relaxed. |
| Incomplete response | Content filtering can retry with extra guidance; interruption can complete with `end_turn=false`; other reasons return typed incomplete errors. | Existing length/filter/unmapped-stop semantics remain. This PR does not broaden incomplete recovery. |
| Cancellation | No dedicated cancelled-response fold; absent later completion, EOF produces disconnect. | Verified cancellation remains Aborted; cancellation and lost drain proof are terminal. |
| Retry budget | Defaults to five stream retries and four HTTP retries, independently configurable up to 100. Websocket fallback can reset the stream count; opt-in connection retry can be unbounded. | Generic Responses errors cap total machine generations at three and end the gateway walk. Earlier attempts count, later errors inherit the narrowed cap, and stricter operator limits win. Other transient classes retain configured policy, possibly unbounded. |
| Backoff advice | Uses receipt-based deadlines, seconds or HTTP dates, exponential jitter, and some rate-limit message parsing. Overload/capacity types need advice to retry. | Structured HTTP/event advice uses whole-number milliseconds or seconds, taking the larger hint and then max(hint, local backoff). No HTTP dates, fractional seconds or message parsing. Named overload retains Loom's existing transient policy. |
| Cleanup | Consumer closure stops the SSE task; cancellation tokens and turn cleanup drain work. Idle timeout defaults to 300 seconds. | Total-attempt deadline and positive native-transport drain proof remain authoritative before retry. Missing proof cannot be converted to recovery. |
| Partial tools/content | Completed output items can dispatch tools before response completion; in-flight tool futures drain after failure and completed items can remain in history. | Deltas are provisional. Failure settles empty content, and only settled successful ToolUse can execute a batch. Retry cannot execute a partial tool. |
| Usage | Completion and incomplete paths can retain usage. Failed-response mapping does not carry failed usage. | Valid failed usage survives, missing usage remains uncertain, and every actual attempt is accounted once. Malformed counts still fail validation. |
| Privacy | Several errors retain remote message text and broader support metadata. | Fixed descriptions, allowlisted labels and checked event/sequence/byte/media/request-ID observations only. Remote messages, arbitrary identifiers, headers and credentials stay out. |

This comparison found and closed a diagnostic-to-policy interaction: appending
`error_type=rate_limit_error` could make a selected permanent code retryable
through the old free-text throttle matcher. Tests now exercise both directions
of conflicting permanent/transient labels through the real adapter and retry
classifier. The shared predicate also prevents HTTP quota denials from entering
fallback solely because their status is 429.

## Verification record

The initial adapter regressions failed before implementation. Ten focused
adapter tests now cover normalization, conflicting labels, chunk boundaries,
single terminal, privacy, usage and advice. Four runtime tests exercise real
normalization, durable settlement and retry execution with a scripted provider
seam: recovery on attempt three, exhaustion at three, and a stricter one-attempt
policy. Nine machine recovery tests cover durable narrowing, unlike failures,
summary paths and the advised not-before deadline.

Eight semantic mutations were rejected by test assertions: ignoring nested
errors, increasing the ceiling, removing permanent precedence, dropping stream
context, ignoring event advice, taking the smaller HTTP/event hint, erasing the
hint during scrubbing, and retrying a permanent HTTP 429. Restored source passes
the focused suite. Compile failures were not counted as mutation kills.

Before integration, full provider (356), runtime (215), machine (103), harness
(29) and conformance (115) package gates pass locally. Format, full house-rule lint and documentation
checks pass. All 5,468 local client tests pass; shipped-daemon fixtures require
the separately supplied server and remain for hosted/signoff execution.
One independent adversarial review found no actionable findings across
invariants, simplification and nearby variants. Final-head hosted CI and Linux
signoff are required before readiness; their current outcomes belong in the
PR verification record. No live
provider request, production update or daemon restart was performed. These
deterministic fixtures establish policy and custody, not the upstream cause of
the original two failures or live endpoint behavior.
