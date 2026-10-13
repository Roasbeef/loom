# Current handoff

Baselined October 13, 2026 against implementation commit
`eaa3c7a18e2a8ca88cf614d4754a2caeccbc5c8d` on `provider/responses-failure-reasons`.
The branch now depends on CI prerequisite PR #979 at
`ba2a0db8a01117c26e15e37322564effc6a75e66`. The project-wide plan remains
`docs/issue-plan.md`.

The prerequisite handoff describes the deployment-status skip declaration and
strict delegated Linux fixture. It remains in the
[CI base](https://github.com/Roasbeef/loom/blob/ba2a0db8a01117c26e15e37322564effc6a75e66/docs/next.md).
The Responses code is byte-identical to previously validated PR #977 head
`4d90080fe3a9227ebc1c12c5144cfc5ee0ee1dc9`; that head's results are historical
validation, not exact-head signoff for this rebased branch. No running daemon
was updated by this work.

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

## Verification boundary

The 44 Responses tests passed, including distinct text/part/item/terminal
failure reasons, once-only terminal assertions, framing and byte-limit codes,
malformed and oversized numeric markers, unknown-event redaction, and
preservation through gateway scrubbing. All three runtime retry-hint tests
passed, including the new real subscription-adapter to scrubber to failure
settlement to durable message-codec regression. Provider lint passed with
zero errors. The independent advisor review found no actionable issue in
invariants, bounds, redaction, simplification or nearby variants.

At the prior Responses head, the affected gate passed in documented parallel
mode, with 4,491 client, 306 provider, 202 runtime and 98 conformance tests.
Full Linux signoff and every hosted test job passed. The hosted Linux aggregate
rejected an undeclared deployment-status enforcement skip. PR #979 corrects
that policy and separately requires the fixture to execute in the delegated
Linux jail with an empty skip allowance.

This rebase preserves the provider, runtime-test and package-documentation
files exactly. New-head hosted CI and Linux signoff are pending at this
checkpoint; their final results belong on the PR. No live malformed-provider
recurrence has been captured with the new codes.

## Next steps

1. Validate the new pushed head, including Linux signoff and hosted CI.
   Exit: the aggregate gate accepts the declared ordinary-runner limit and
   the delegated deployment fixture executes without a skip.
2. Review and land CI prerequisite #979 before Responses PR #977, with the
   owner's authorization. Neither PR was merged by this work.
3. After deployment, inspect a recurrence's reason and structural context.
   Exit: identify the rejecting check and build a minimal reproduction before
   attributing the failure to provider behavior or Loom compatibility. Raw
   stream recording and a speculative acceptance change remain outside scope.
