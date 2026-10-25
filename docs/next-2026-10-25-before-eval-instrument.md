# Current handoff

Two bodies of work are live. Remote evolution slice 3 closed with the PR that
added this section; the post-merge CI repair below it is still open on draft
PR #1112 and is unchanged here.

## Remote evolution, slice 3: closed

A session on an executor can now author, test, select and run extensions and
programs, built and run on the executor's checkout. The pieces, in order:

- Step 4 (PR #1113): an `executor_evolution` actor per scope with code mode,
  under `custody.Evolution`. The census reports `Compiles(identity)` or
  `Uncompiled(reason)`, and the identity is computed from the host with its
  evolution door withdrawn, so offering `cap/evolution` cannot change it.
- Step 5: `client/evolution/machine/remote` sends the eight protocol-v5
  evolution messages, and `serve` chooses the local, remote or no machine.
  The executor's code mode offers `cap/evolution` and routes each call to the
  owner as `Capability(OwnerCapCall)`, keyed `(code_mode call key, cap,
  ordinal)`.
- Step 6: `sessions.move` refuses a session that serves a `Session`-scoped
  selection whose approval still stands. It checks both places
  `serve.evolution_root` can put the catalogue, and an unreadable catalogue
  refuses the move.
- Step 7: `evolution_remote_acceptance_test` (`make e2e-evolution-remote`), on
  two shipped daemons, covers an extension, a program candidate and an
  executor restart.

Bugs the acceptance run and the reviews found, all fixed in the same PR:

- A proposal's relative directory was resolved on the orchestrator.
- A hook that lost the link dropped its handler for good.
- A session with a selected extension could not be reopened, because recovery
  ran before the Agency holder started. This affected local sessions too.
- The move check read only one catalogue location.

Rulings, not to re-litigate: refuse the move rather than carry catalogue rows;
eight messages in version 5, with trials and core getting their own bumps; no
`Hands.recover` by key, since an evolution door follows its `code_mode` call's
`replay: Never`; a remote check has no rolling output tail; one catalogue per
daemon holds both placements' candidates.

Open, in rough priority:

1. Slice 4: trials and prompt profiles on executor sessions. The `Authority`
   guard for prompt trials on a registered session is not added yet.
2. Retire and publish still run inside the evolution actor's own turn, so a slow
   retire stalls other requests to that scope's plane. Moving retire into a weft
   task is the fix.
3. Untested: a pool of executors, a link cut during staging, an orchestrator
   restart with a selection in flight, a prepare or snapshot in flight at
   close, hooks across a real link cut, and background programs calling
   `evolution.*`.
4. After two in-place upgrades, an empty alias record stays on the executor
   until the scope closes. A publish answered `UnknownHandle` is reported as
   "migration lost" but not re-staged; 098 describes the re-stage.

## Post-merge CI repair

This is the post-merge CI repair, based on main
`d70c7d073c96a0afb8d28e676003e6bace147099` on
`codex/postmerge-fixture-repairs`. The published diagnostic head was
`318bfbc816db7fe816a546e6c3160f75ef7ba8de`; the next change orders the
shipped fixture's sibling completion before its deliberate daemon crash. The [previous handoff](next-2026-10-24-before-postmerge-repair.md)
is preserved exactly; its local gates and performance measurements retain their
original observation cuts. The [repair report](review/postmerge-ci-repair-2026-10-24.md)
records reproduction, causal evidence and validation.

### What happened

PR #1110 merged as `141788049d93cfe97a427e350d75001bd88d091c` and PR #1111
as `d70c7d073c96a0afb8d28e676003e6bace147099` before their hosted checks
finished. #1111's older merge script continued after only its watcher child
was stopped. The remaining merge processes were subsequently terminated.
The user was notified. A merge is not a completed CI verdict.

Raw #1110 macOS artifacts contradict the normalized success badges. Shard 1
failed `client@evolution_retention_test:startup_padding_does_not_grow_evolution_trace_test`
with a 24-word excess. Shard 2 failed
`lsp@client_test:a_publication_without_the_barrier_does_not_settle_test`
with an empty diagnostic publication. Both `make check` commands exited one;
downstream packages did not run. The macOS fan-in skipped artifact downloads
and its strict skip census, despite its success badge. Those original failures
remain evidence even if another run passes.

### Repairs

Both changes are test-only. The real evolution-door fixture now counts its exact
startup marker through closure environments. Independently minted UUID integers
can vary by two BEAM words; twelve captured copies explain the unrelated
24-word difference. The repaired oracle requires zero markers in trace and
exactly one 4,096-marker snapshot in the whole door, preserving the intended
capture invariant without increasing a size tolerance. A small helper extends
the existing test-only FFI because Gleam cannot inspect closure environments.

The LSP fixture acknowledges the changed publication through its existing
`test/emit` request before starting the unchanged 60 ms settlement deadline.
The document-symbol barrier remains unanswered, and both the exact deadline
outcome and diagnostic assertions remain. Its separate positive test still
covers publication arriving after the barrier. The entire LSP package was
unchanged between pre-#1110 base `3e258a2f3` and this repair base: that fixture
race predates the optimizations. The retention fixture was introduced by #1110.

### Validation at publication

Five original focused runs passed for each intermittent fixture, followed by
controlled probes that reproduced each exact failure. Five repaired retention
runs and 200 repeated LSP cases pass. The full LSP gate passes all 194 tests,
including format, warning-free build and lint. Client scoped lint passes.

Negative controls restore broad Settings capture and allow settlement without
a barrier, respectively; each fails its strict repaired assertion. One fresh
independent report-only review found no actionable issue in the four-file
source delta, including the capture oracle and stream ordering.

The full local client gate completed with exit zero: 5,328 tests passed in
632.12 seconds. Its 57 visible prerequisite skips are not executed coverage.
Repair head `8f8e54db2` also passed hosted Linux checks with 5,328 client tests,
194 LSP tests and clean strict skip censuses. Hard macOS e2e passed 15 terminal,
four bootstrap, 112 e2e and 441 code-mode tests, with a clean terminal census.

Raw repair-run 40147468081 macOS shard 1 nevertheless failed the cross-node
worktree scenario, with 2,431 client tests passed and one failed. Both earlier
repairs explicitly passed. The child exited two, but EUnit truncated its nested
error; no underlying cause is established. Shard 2 completed the whole check.
The macOS fan-in skipped its strict census, so this run is not green.

Thirty fresh direct worktree scenarios and the original five-test remote-node
EUnit module pass locally. The fixture, support, distribution fixture FFI and
workspace package are unchanged since pre-#1110 base `3e258a2f3`; relevant
worktree lifecycle executable lines are unchanged too. This supports an
intermittent failure predating the optimizations, but does not identify its
cause. Test-only diagnostic logging now prints the existing complete scenario
error to stderr before returning the same error. Assertions, deadlines and skip
declarations remain unchanged; a subsequent failure must retain its child error.

The original #1111 audit is complete: its first macOS shard repeated the known
retention fixture failure, its second shard truly completed the whole check,
and its macOS strict census was skipped. Neither original merge is a passing
hosted-CI verdict.

### Shipped fixture ordering repair

Run 40153045412 attempt 1 at `318bfbc816` completed both macOS whole checks,
including all 5,328 client tests and both earlier repaired assertions. Shard 2
then failed artifact upload with `ENOTFOUND`; the strict macOS census did not
execute. The publisher retried only failed infrastructure jobs on the same
head. That attempt 2 failed a different test, despite normalized green badges:
`daemon_shipped_remote_subagents_test` expired waiting for `beat4` to reach two
lines after the box restart. Its callback-wrapper assertions hid that cause,
but the crash report retained the underlying `await_lines_within` assertion.
The macOS strict census was again skipped. PR #1112 remains unmerged.

Five real shipped local runs passed without skips after building a test-only
shipment. A controlled disposable BEAM variant then delayed the sibling shell
three seconds after its marker write. The fixture crashed the box while that
shell was still running; recovery correctly returned an interrupted tool result,
which the success-only ordered model fixture refused permanently. The fourth
child's request was refused too, reproducing the exact heartbeat timeout.

The same delayed variant passes every original assertion when the test waits
for the sibling's `operation.settled` event before crashing the box. The tracked
fix uses the existing `await_log` helper with `third-directory-child`; there is
no committed delay, deadline increase, assertion relaxation or production change.
The event is emitted after the terminal operation transition is committed, unlike
the marker, which proves only shell progress. This makes the fixture's existing
claim that no child is running at restart true. The earlier remote-worktree
failure remains unexplained; do not attribute it to this distinct ordering race.

### What remains

1. Complete the five real shipped repetitions and independent review of this
   ordering fix, then publish the exact new head to draft repair PR #1112.
2. Inspect all exact-head hosted checks, raw macOS whole-check artifacts and
   executed strict skip censuses. Merge only after actual validation is green;
   success badges and a skipped census do not satisfy the requirement.
3. Preserve the failed-run evidence separately from later passes. Do not retry
   a new failure without diagnosis or loosen an assertion or deadline.

No production installation, daemon restart, hotpatch, live state inspection or
credential search was performed. Local test shipments and their disposable
provisioned daemons were built and run for reproduction. The enrolled
inspector/viewer is unchanged.
