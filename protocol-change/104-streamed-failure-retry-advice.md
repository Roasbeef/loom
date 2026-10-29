# Protocol 104: Streamed failure retry advice

**Status**: ACCEPTED by the repository owner for this change. **Affects**:
Part 1.5 provider errors and the existing Part 1.3 retry settlement convention.

## Problem

Responses errors can carry `error.headers` retry advice after the HTTP response
has already started. The two-field `StreamError` cannot retain that advice.
Unknown failed-response errors also collapse to a generic terminal failure,
requiring manual continuation even when the next generation succeeds.

Two recorded failures establish that generic terminal classification prevented
automatic recovery. Their original upstream codes and messages were not
retained, so they do not establish an upstream cause.

## Decision

Extend `provider/stream.StreamError` from `(api_error_type, message)` to
`(api_error_type, message, retry_after_ms: Option(Int))`. Other adapters and
local refusals supply `None`. Diagnostic scrubbing preserves the integer.
The Responses adapter selects nested `error` objects for direct error events,
retaining compatibility with flat envelopes, and reads `response.error` for
`response.failed`.

Only case-insensitive `retry-after-ms` and `retry-after` fields in
`error.headers` can supply event advice. A string or the first string in an
array follows the existing whole-number header parser. A present malformed
millisecond field does not fall back to seconds. The adapter takes the larger
valid delay from HTTP and event headers. HTTP dates, fractional seconds and
remote-message delay extraction remain unsupported.

Classification carries this optional delay through `Retryable` or
`RetryableWithin`. Existing runtime settlement writes it to structured
`retry_after_ms` diagnostics; the machine waits at least the larger of this
delay and its local backoff. No policy is recovered from diagnostic prose.
The durable schema and operation-state shape do not change.

Unclassified `responses_error` selects protocol 103's `RetryableWithin` with
three total generation attempts, including the initial generation. Its gateway
walk ends immediately, and the machine persists the narrower retry budget.
Earlier attempts count; later failures cannot restore an unbounded policy.
Stricter configured limits remain authoritative. Named transient errors retain
their existing configured retry policy, which may be unbounded.

Recognized permanent request, access, quota, policy and context codes take
precedence over transient code/type labels, HTTP statuses and throttle prose.
Unknown HTTP 429 retains existing throttle behavior. Context overflow remains
eligible for compaction through the existing machine classification.

## Diagnostics and custody

Failure diagnostics contain fixed local descriptions, allowlisted error labels,
local markers for absent/invalid/unrecognized labels, and the checked stream
position and transport context. Remote messages, unfamiliar codes and types,
arbitrary headers, body text and credentials stay out. The gateway's existing
byte bound and credential scrub remain authoritative.

Strict framing, terminal witnesses, first-terminal behavior, accounting and
confirmed transport drain are unchanged. Failed partial output cannot become
accepted content or an executable tool call. Retrying starts a fresh generation.

## Alternatives and cost

Parsing a retry delay from the human diagnostic would mix policy with prose
and permit remote text into a sensitive boundary. A gateway-local retry loop
would hide attempts from durable settlement. A new counter is unnecessary
because protocol 103 already narrows and persists the generation budget.

The interface change requires every `StreamError` constructor and pattern to
be migrated together. Older recordings remain readable because they store
settled messages and structured diagnostics, rather than this runtime variant.
Older executables do not apply the new classification or retain event advice.

## Proof

Adapter tests cover nested/flat errors, conflicting permanent/transient fields,
absent and malformed error fields, safe diagnostics, chunk boundaries, one
terminal, failed usage, header precedence and malformed advice. Gateway tests
prove immediate forwarding without fallback and one actual attempt's usage.
Runtime tests exercise recovery, exhaustion and stricter configured budgets;
codec and machine tests prove the durable cap and server-advised wait.

The [comparison record](../docs/review/responses-failure-recovery.md) documents
the pinned Codex implementation and the deliberate differences.
