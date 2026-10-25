# Post-merge CI fixture repairs

Base: main `d70c7d073c96a0afb8d28e676003e6bace147099`. Scope: four test/support
files, with no production source, dependency, deadline, skip declaration or
wire/API change. The new helper is in the existing internal test-only memory
FFI boundary; there is no new production FFI.

## Actual hosted failures

On #1110 head `4e479fcc14395fe57d1bde1b0ce2c1f161379ade`, run 40142266544:

| Raw artifact | Actual result |
| --- | --- |
| macOS shard 1, artifact 12581286191 | client 2,431 passed, one failed. Retention fixture observed whole-door delta 53,272 words versus marker 53,248; trace sizes both 748. |
| macOS shard 2, artifact 12580592479 | LSP 193 passed, one failed. Expected diagnostics `undefined: x`, received an empty list. Downstream client packages did not execute. |

Both raw `make check` commands exited one, although the advisory job badges
reported success. The macOS fan-in skipped artifact downloads and the strict
skip census. Its success badge therefore supplies no passing census evidence.
Full logs are retained under
/private/tmp/loom-pr1110-4e479fcc1-ci40142266544-macos-shard{1,2}.log and
/private/tmp/loom-pr1110-4e479fcc1-ci40142266544-gate-macos.log.

## Retention measurement

The new #1110 fixture compared two independently opened assemblies. The same
62-bit UUID rand_b can be represented as an immediate integer or a two-word
bignum on this BEAM. That operation UUID occurs twelve times in the flattened
machine/door graph, yielding the exact unrelated 24-word difference. Five
untouched focused runs passed, but a controlled nine-pair real-assembly probe
reproduced the failure even with identical paths and settings. Reusing a path
alone cannot fix it. This was measurement noise in the new fixture, not a
confirmed retained-memory regression.

The corrected test counts exact `secrets.Failure` markers in the actual
borrowed capability door. The existing test-only FFI walks tuples, lists, maps
and closure environments, unfolding sharing as a process copy does, without
executing callbacks. Pure Gleam cannot inspect those environments. Ordinary
assemblies must hold zero markers; padded trace callbacks must hold zero;
the complete padded door must hold exactly 4,096, one required Settings snapshot.
This directly pins the original capture invariant rather than widening a byte
bound. UUID representation no longer affects the oracle.

Five repaired focused runs pass with warning-free builds. Helper sanity
checks cover shared closures, maps, improper lists and absent markers. An
isolated generated-BEAM negative control restoring the old broad Settings
capture fails as intended: trace 4,096 versus zero and whole door 12,288 versus
4,096. No production source or normal build artifact was changed for that probe.
Logs: /private/tmp/loom-evolution-{before,path-probe,leaf-probe,after,negative,lint-final}.log.

## LSP fixture ordering

The failing fixture sent its changed diagnostics through a separate five-ms
fake-server timer, while settlement immediately began a 60-ms deadline.
There was no ordering edge ensuring the new diagnostics arrived before expiry.
Five original focused runs and the baseline full package passed, but suspending
only the fake at its delayed-publication action reproduced the exact empty
publication failure. The real client correctly returned diagnostics it had seen.
The entire LSP package is byte-identical between `3e258a2f3` and this repair base;
this race predates #1110.

For the ignores-barrier fixture, the changed publication is now immediate,
followed by an acknowledgement through the existing test/emit route. Same-stream
ordering ensures the client stored that publication before `emit` returns.
Only then does the unchanged 60-ms settlement start. The response resolves a
normal request waiter and does not answer the document-symbol barrier. Both
strict outcome/content assertions remain. The positive answers-barrier fixture
still delays its publication after the barrier and retains its distinct test.

All 194 LSP tests and 200 repeated repaired cases pass. An isolated negative
BEAM control that wrongly permits settlement while awaiting the barrier fails
the strict DeadlineExpired assertion. Logs are
/private/tmp/followup-lsp-{race-repro,focused-repeat,negative-control,final-check}.log.

## Review and remaining validation

A fresh independent report-only review found no actionable issue in the four
changed files, including oracle correctness, capture multiplicity and the
publication/acknowledgement ordering. It inspected evidence but did not rerun
the suites and is not hosted-CI signoff. Scoped client lint, LSP full gate,
formatting and diff checks pass. Full local client validation is running at
publication; repair-head hosted checks remain pending. These are distinct
from original failures and from unrelated successful Linux or hard e2e lanes.
