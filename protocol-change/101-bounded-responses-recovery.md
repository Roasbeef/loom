# Protocol 101: Bounded Responses stream recovery

**Status**: ACCEPTED after independent design review. **Affects**: Part 1.3 retry settlement and Part 1.5 provider errors.

## Problem

Responses can close an output item while a streamed part still lacks its closing witness. Loom rejects that response with `item_parts_unclosed`. Repeated live failures make manual continuation disruptive, but the retained diagnostics do not identify the open part or final item status. No raw event trace establishes the upstream cause. Validation must remain strict.

Ordinary transient failures can use an unbounded retry policy. Classifying all malformed streams as transient would permit an indefinitely repeated compatibility failure.

## Decision

Add `provider/stream.RecoverableStreamCorruption(report)` for this precise missing-part-closure guard. Every other malformed-stream check retains its existing terminal classification. Add `provider/retry.RetryableWithin(backoff_hint_ms, max_attempts)`; this corruption selects a ceiling of three total machine generation attempts.

The gateway forwards this class immediately rather than walking its fallback chain. The runtime retains its original error and accounting, marks the failure retryable through the existing convention, and adds the structured integer `retry_max_attempts = 3` to assistant diagnostics. Summary failures carry the same field in `OperationError.details`. Policy never parses the diagnostic reason string.

Before deciding whether another attempt remains, the machine narrows the captured policy to the smaller of its existing finite bound and this ceiling. It saves that policy in retry-wait state. Subsequent transport, rate-limit and orphan failures cannot restore an unbounded policy. Summary retry state follows the same rule. Positive integer ceilings are validated; malformed values never increase a configured bound.

The ceiling counts total machine generation attempts, not HTTP requests. Earlier rate-limit or orphan attempts consume the allowance. An ordinary gateway fallback walk can contain multiple HTTP requests; an eligible corruption terminates that walk. This conservative accounting permits at most two recovery retries without adding a per-error counter or durable state field.

Existing backoff, cancellation, drain proof, failure recording and usage settlement remain authoritative. Partial tool calls from a failed attempt cannot execute, and a fresh attempt cannot reuse its displayed deltas as accepted content.

## Structural diagnostics

At the failing guard, retain only allowlisted item kind, canonical status, first unclosed part kind and closure state, plus total and unclosed part counts. Keep existing event, sequence, output and byte positions. Unknown status values become a fixed marker. IDs, text, arguments, reasoning, ciphertext and arbitrary remote values stay out. Verify the final scrubbed diagnostic fits the existing bound.

## Alternatives and cost

Relaxing closure validation would accept output without the required witness. Retrying every malformed stream would hide permanent decoder failures. Gateway-local retries would hide individual failures from durable machine settlement. A new recovery counter or configuration knob would add state when the existing attempt number and serialized bounded policy suffice.

The cost is a provider error/classification extension and a structured retry-cap convention in existing diagnostic fields. The durable schema and operation-state shape do not change. Old recordings without the field retain their behavior. Older executables do not implement the new recovery policy.

## Review and proof

Independent design review selected machine-owned sticky policy narrowing and immediate gateway forwarding. Tests must cover the three-attempt cap under an initially unbounded policy, a stricter one- or two-attempt policy, serialize/reload between unlike failures, summary behavior, preserved failures and usage, no fallback on eligible corruption, confirmed drain before retry, and no execution of partial tool calls. Diagnostics tests must inspect the final scrubbed error and reject content leakage.
