# Retained report renderer review

The foreground code-mode renderer commits the complete canonical report through
the original pinned owner before returning a preview and its result reference.
The existing inline and background paths keep their prior behavior. Trusted
assembly must explicitly select the retained constructor and report custody
profile; this component alone does not enable remote code mode.

## Invariants

The retained path bypasses full JSON rendering. It preserves the original
MessagePack outcome, including binary values and nontext map keys, and copies
all trusted call and enforcement metadata through the checked report constructor.
Preview traversal visits at most 32 nodes. Individual strings are sliced by UTF-8
bytes before escaping, and the final text remains below 4,096 bytes. A preview
never substitutes for the complete stored value.

The owner adapter checks operation, step and source index against its captured
original ToolKey. Retention failure, invalid metadata and runtime failure return
no reference and no claim that execution never started. Only actual VetRejected
and CompileFailed variants produce the closed no-terminal refusal. The retained
constructor refuses background-capable configurations before invoking callbacks.

## Independent review

Astra found one regression-test defect. The wrong-context control originally
asserted inside the managed worker; removing the production source-index guard
caused that assertion to crash the worker, which still satisfied the outer test's
expected failure. The corrected control sends the actual result to its parent
and asserts there. The original production guard was correct; the corrected
control now fails when that guard is removed.

Independent restored-source runs passed both actual client controls and all 72
code-mode module controls. Three additional reviewer controls cover every call
status and enforcement stage, async-constructor refusal, and invalid metadata
before retention. These controls are now retained in the repository. Six compiled
mutations failed their intended assertions, including the corrected wrong-context
case and an unsafe grapheme-based preview truncation.

Root's final full tools gate passes all 707 tests, including the three retained
reviewer controls. The focused client integration replay passes 93 controls
with no skips, including the two renderer/custody controls. Format, package lint
and documentation checks pass; existing lint and citation warnings remain.
The actual client controls use real owner SQLite, SHA-256, report/final admission,
aligned chunk reads and restart without reexecution; their compiler outcome is
injected. The previous broad client gate passed 2,855 tests with fifteen optional
SKIPs. Neither result establishes physical satellite execution, authenticated
production read-route availability, companion lifecycle or separate-host acceptance.

The review report digest is
`393db4650414c6fcc586df166e15f82407d6a3bda95075b9201f76720c0be2b3`.
The [report design](../design-notes/distributed-final-results.md) records the
remaining assembly obligations and exact custody budget.

## Actual compiler fingerprint correction

A later trace to the production compiler exposed a mismatch missed by the
injected fixtures and initial review. `build.fingerprint_directory` returns the
`tools/blob.ref_for` spelling: `sha256-` plus 64 lowercase hexadecimal digits.
Metadata originally accepted only bare hex, so real successful compilation
could not be retained. The separate metadata validator now preserves that exact
compiler fingerprint. Result URI content digests retain their original bare-hex
contract; no compatibility form was added solely for unreleased test fixtures.

A real jailed execution reproduced the failure before correction: the renderer
could not retain its report and the owner rejected a final without prior report
custody. This is a distinct regression witness, not a compiler failure. The
corrected live producer/reader replay is still in progress.

Root's corrected gates pass 186 core tests plus 72 JavaScript finite-value
checks, 182 cap tests, 202 storage tests and 707 tools tests. The focused client
replay passes 101 tests with no skips. Independent review rechecked the codec,
renderer, custody and reader against the corrected metadata and found no second
routine producer-format mismatch. Explicit metadata bounds still refuse excessive
observations rather than truncate them.

The updated independent report digest is
`71558120e9371b49275aa66c2dbe62d0af1225c21b58ffce019a1d99918cecac`.
The first parallel Make invocation collided while rebuilding shared TUI shipment
prerequisites; a subsequent serial invocation exposed one stale JavaScript test
fixture. Both failed runs are retained in evidence. After correcting that fixture,
the complete serial package command returned zero.
