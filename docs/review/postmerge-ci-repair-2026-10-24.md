# Post-merge CI fixture repairs

Base: main `d70c7d073c96a0afb8d28e676003e6bace147099`. Scope: test/support
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
formatting and diff checks pass. Full local client validation subsequently
completed with exit zero, 5,328 tests passed in 632.12 seconds and 57 visible
prerequisite skip diagnostics. These skips are not executed coverage.

## Subsequent hosted run and diagnostic

Repair head `8f8e54db2`, run 40147468081, passed hosted Linux checks, including
both repaired tests, 5,328 client tests, 194 LSP tests, delegated jail and the
strict Linux census. Hard macOS e2e passed 15 terminal, four bootstrap, 112 e2e
and 441 code-mode tests; its terminal census was clean.

MacOS advisory shard 1, artifact 12582901342, failed
`client@remote@remote_nodes_test:two_sessions_get_a_tree_each_on_a_worktree_workspace_across_nodes_test`:
2,431 client tests passed and one failed. Both earlier repaired tests passed.
The scenario returned child exit two, a caught child exception. Both uploaded
logs truncate the nested error, and no child dump exists in the artifacts;
there is no established root cause. The module took 21 seconds, and the child
watchdog uses a distinct exit status, so increasing that deadline is unsupported.
Shard 2, artifact 12582912242, completed the whole check. The macOS strict census
was skipped, and shard 1 did not reach its downstream conformance, TUI or lint
checks. The run is an actual failure despite its normalized success badges.

Thirty fresh direct scenarios pass, followed by all five scenarios in the
original EUnit module order. The fixture, support, distribution fixture FFI and
workspace package are byte-identical to pre-#1110 base `3e258a2f3`; relevant
worktree lifecycle executable lines are unchanged. This is positive local
non-reproduction evidence, not proof of the underlying cause.

The test-only scenario boundary now prints its existing complete error
string to stderr before returning that same error. This prevents EUnit's
bounded term rendering from discarding the child exception on another failure.
No assertion, timeout or skip changes. One bounded fresh hosted attempt is
warranted after diagnostic validation; another failure requires diagnosis of
its complete child error before further retries. Original #1110/#1111 raw
failures and skipped censuses remain part of the record.


## Shipped subagent completion before restart

At diagnostic head `318bfbc816`, run 40153045412 attempt 1 completed both full
macOS checks: 2,432 and 2,896 client tests, both earlier repairs and all 194 LSP
tests passed. Shard 2 then failed artifact upload with
`Failed to CreateArtifact: Unable to make request: ENOTFOUND`. The macOS gate
failed its upstream-success requirement, leaving downloads and strict census
unexecuted. This was a distinct infrastructure failure after passing tests.

The publisher retried only failed jobs on the same head. Attempt 2's raw shard 2,
artifact 12585333107, had 2,895 client tests passed and one failed, command exit
one. Its untruncated crash report identifies
`daemon_shipped_remote_subagents_test.await_lines_within/3:894`, called from
`session/5:737`: the fourth child's `beat4` file did not reach two lines within
the existing 120,000 ms bound after the box restart. The nested HTTP fixture
and remote-duo assertions propagated this failure rather than identifying an
HTTP script mismatch. Both artifact downloads and strict macOS census were
skipped despite the gate's success badge.

A checkout-local test shipment was built successfully. Five real shipped
subagent runs passed with enforcement and no skips, taking 92–93 seconds each.
The fixture and its provider/remote-duo support are unchanged since pre-#1110
base `3e258a2f3`. This local evidence did not identify the cause by itself.

A controlled disposable compiled variant added a three-second sleep only after
the sibling shell wrote the third marker. The unchanged fixture then crashed
the box before that sibling operation settled. Recovery correctly delivered a
failed `grant-sibling` tool result with an unknown external outcome, which the
success-only ordered provider script permanently refused. Its refusal also
blocked the fourth child's later request. This reproduced the exact `beat4`
readiness assertion and command exit one in 174.65 seconds. A first probe had
omitted the runner's existing EUnit timeout scale and was invalid; it supplied
no failure evidence. The valid probe retained the original scale and deadlines.

With the same three-second delay, inserting the existing settlement-log barrier
before the deliberate crash passed every original heartbeat, transcript and
release assertion, command exit zero in 96.51 seconds. The captured daemon
log shows `operation.settled` for `third-directory-child` before restart. The
runtime emits that event after the terminal operation transition is committed.

The tracked fix adds that existing `await_log` call and its rationale after the
sibling marker/no-question checks. The marker proves shell progress, not terminal
completion; the barrier enforces the fixture's existing premise that no child is
running when the box is killed. No delay is committed, and no production API,
assertion, deadline or skip declaration changes. This reproduces and removes a
reachable cause of the hosted heartbeat failure; it does not explain the earlier
remote-worktree child-exit failure. Real shipped repeats, fresh independent
review and new exact-head hosted validation remain separate gates.

Evidence: /private/tmp/followup-shipped-subagents-{1..5}.log,
/private/tmp/followup-shipped-delay-probe2.log,
/private/tmp/followup-shipped-barrier-probe1.log and their `*-evidence/` directories.
Full hosted attempt logs and manifests remain under
/private/tmp/loom-pr1112-318bfbc81-ci40153045412-attempt{1,2}-*.
