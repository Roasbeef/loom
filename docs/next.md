# Current handoff

Baselined October 13, 2026 against implementation commit `b3d1ade5d821ebd8d172af899837285ed4725152`,
rebased onto main at `e86d6fddd002d8060b44aa5f10e9c99e3098bc51`.
PR #977 has been merged into PR #979's branch; #979 now lands both Responses
diagnostics and the deployment-status CI correction. The project-wide plan
remains `docs/issue-plan.md`. No running daemon was updated by this work.

Main's register-decoding work remains intact. Its exact persisted-blob cache,
bounds, invalidation and corruption checks are described in
[the measurement report](review/register-decoding-2026-10-12.md) and the
[main handoff](https://github.com/Roasbeef/loom/blob/e86d6fddd002d8060b44aa5f10e9c99e3098bc51/docs/next.md).
PR #972 is merged; its handoff's queued-CI wording is historical.

## What changed

A failed Responses attempt previously retained the same constant corruption
report for every malformed event, semantic witness and resource limit. The
recorded failures identified the affected operations, but neither the daemon
log nor durable messages retained the rejected check or offending wire event.
Those past failures cannot establish whether the provider violated the
protocol or Loom rejected a valid response.

Every malformed call site now supplies a fixed reason code. Private item
verification preserves distinct phase, closure, status, contiguity and content
reasons; final-response guards distinguish identity ordering, remote error,
output mismatch, unclosed items, sparse indices and status mismatch. Decoder
failures identify their local call site. `packages/provider/README.md`
documents the diagnostic fields, reason families and stability convention.

The existing corruption report carries an allowlisted current event family,
sequence, output/content/summary/annotation positions, last accepted sequence
and cumulative delivered bytes. Unknown event names become `unknown`;
malformed numbers become `invalid`; integers outside signed 32-bit range become
`range`. Missing or null positions become `absent`. The byte count describes
chunks delivered to the adapter, not the offset of the failed event.

These are diagnostic bounds, not new acceptance limits. No provider text,
arguments, identifiers, model name, ciphertext, annotations or parser excerpt
enters the report. Its subject and context fit the existing gateway and core
bounds. Runtime retains the description in the existing durable `errorMessage`;
request context remains in `diagnostics`. No error variant, wire field, retry
policy or validation predicate was added or relaxed.

## Deployment-status CI correction

The ordinary Linux runner's existing enforcement skip is declared by its exact
marker. The delegated Linux jail job separately requires the real deployment
fixture to execute with an empty skip allowance and uploads its log. No fixture
assertion or enforcement demand was removed or relaxed.

## Verification boundary

At the previous combined head `f3d0c7bd3106de8eec98f5c076f0d5459a51d848`,
required hosted CI passed both aggregate gates. Full containerized Linux signoff
passed in 1,703 seconds, including client, runtime/storage/session/events,
conformance, fast, static, enforcement and release verification, with a clean
skip census. The delegated deployment fixture executed and passed. The hosted
macOS advisory client suite hit its existing package-wide 1,200-second deadline;
its successful job conclusion does not establish a completed test suite.

Provider and runtime regression coverage, diagnostic redaction/bounds, baseline
controls and independent reviews are recorded in PR #977. CI policy controls
and independent review are recorded in PR #979. The rebase changes only the
handoff resolution relative to applying these reviewed changes on the new main.
The new pushed head needs fresh hosted CI and Linux signoff; previous-head
results above are historical evidence, not signoff for this head.

## Live failure distinction

The later recurring `responses_error` failures are explicit provider-error
responses with missing or unrecognized error codes. They take a different path
from malformed-stream validation. Existing durable history retains only the
generic error, so the original provider reason cannot be reconstructed and
these diagnostics do not identify it. No provider-error acceptance, retry or
redaction policy was changed to speculate about those failures.

## Next steps

1. Validate the new pushed head and merge #979 with the owner's authorization
   once required hosted checks and exact-head Linux signoff are green.
2. After deployment, capture a malformed-stream recurrence's reason and safe
   structural context, then build a minimal reproduction before attributing it
   to provider behavior or Loom compatibility. A daemon update is separate.
3. Keep generic provider-error diagnostics separate from stream-validation
   diagnostics; further work on that path requires its own scoped change.
