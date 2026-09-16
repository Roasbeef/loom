# PR #433 gap fixes

The default remains `full`. This follow-up repairs prompt parity, records an
inherited session's effective tool surface before recovery, and adds a
reproducible whole-roster cost comparison. It does not promote minimal mode.

## Delegation and recovery instructions

The version-9 pack uses one shared delegation fragment for both rosters.
It covers self-contained briefs, worthwhile task boundaries, separate file
ownership in shared workspaces, batch waits against one deadline, pending
results, descendant-only waits, readable final answers, and verification of
returned claims. A note records durable state without notifying anyone; a
message asks a running peer to act. An ended parent's refusal belongs in the
child's final answer.

API instructions are selected separately. Direct hosts name `agent_*` tools.
Minimal hosts use `cap/strand` on orchestration. Checkpoint notes are strand
board cells, while `cap/memory.remember` proposes longer-term consolidation.
History, context, memory, jobs and schedules use workspace executions. A
result schema constrains the child's `result` note; the readable final answer
remains separate. The real-model run exercised that distinction.

Older custom packs with inline delegation remain valid. Their content is not
replaced with shipped prose. A pack referencing a new binding must carry the
fragments that binding can select; unknown placeholders and missing selected
fragments remain corrupting errors. Tests cover both compatibility and refusal.

## Restart ordering

`session_roster.prepare` commits the resolved roster and seam choice into
`session/tool-roster` before the runtime writer or recovered strands start.
Later boots reuse that choice, even if the daemon default changes. The
catalogue retains the original creation request, preserving retry equality.
No prompt or strand configuration is rewritten, so explicitly restricted
children remain restricted.

Legacy inherited sessions use `full`: the pre-feature `c5fb6038` catalogue
has no roster setting, and full was the only available roster. An explicit
choice from the unreleased branch remains authoritative on first migration.
A malformed reserved fact refuses startup. A later explicit seam flag that
conflicts with the saved surface also refuses, rather than widening the
operator's restriction. The protocol 039 addendum records
these semantics.

Coverage includes both default-flip directions, an interrupted first boot,
legacy and explicit migration, explicit seam persistence, corruption refusal,
and unchanged prompt/child registers. A real boot/restart test also observes
the provider's tool array after changing the configured default from full to
minimal, alongside identical pinned text and primary configuration.

## Complete-roster measurement

See [the design note](../design-notes/tool-roster-and-dyn.md) for the command
and complete table. Both-seam full/minimal arrays are 59,922/42,038 bytes,
a 29.8% reduction. Comparing the defaults, full/workspace versus minimal/both,
is 51,885/42,038 bytes, a 19.0% reduction. These are serialized JSON bytes,
not tokens. The prompt is measured separately; MCP, extensions and skills
are excluded symmetrically.

The earlier workspace-only description bound remains useful, but does not
measure the default minimal array. A new complete-roster check exercises all
four roster/seam combinations using shipped allowlists and router capability
names. Recall capabilities appear only on the workspace offer, as in boot.

## Real-model smoke comparison

The same CSV aggregation task ran through the shipped daemon, real providers,
and jailed tools with `moonshotai/Kimi-K3` via the operator's configured
Baseten endpoint. Main and child used the same model. Each session read five
CSV rows, wrote category totals, kept a checkpoint note, delegated an
independent audit, and waited for its result. Both wrote exactly
`{"apple":10,"pear":12,"plum":9}`, and both children independently confirmed it.
The durable board cells and terminal results were inspected after completion.

| Candidate | Roster | Completion | Tool calls, including child | Elapsed | Reported total tokens | Tool failures |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Initial version-9 wording | Full | Correct, audited | 10 | 35.2 s | 219,688 | 0 |
| Initial version-9 wording | Minimal | Correct, audited | 16 | 62.0 s | 420,059 | 3 |
| Final wording, second run | Full | Correct, audited | 11 | 26.8 s | 241,262 | 0 |
| Final wording, second run | Minimal | Correct, audited | 17 | 52.8 s | 402,946 | 4 |

Minimal's three failures were an unused-variable compiler warning promoted
to an error, a forbidden foreign-interface submission, and an incorrect
note-prefix lookup. It recovered from each. The compiler and vetting failures
occurred after capability discovery; discovery alone did not prevent them.
The boundary correctly refused the foreign-interface program before execution.

The final-wording run again completed both audits and wrote the expected
checkpoint/result notes. Minimal recovered from three compile failures
(missing imports or constructors, and guessed report-helper names) plus a
shell listing that encountered a deliberately masked directory. These are
observed model errors, not a claim that the code-mode boundary failed. The
second daemon also persisted `session/tool-roster` before either run.

This is a small smoke comparison, not a benchmark or promotion decision.
The runs were sequential, provider cache state was not reset, and user-level
instructions and stop hooks were present in both. Each stop hook added one
background watcher call; daemon shutdown retired the fixture's jobs. Token
figures sum the recorded assistant usage across parent and child, including
cache reads; they are not uncached input tokens or a billing estimate.
Elapsed time spans the first durable user message through the final assistant.
No installed daemon or configuration was modified. A broader model/task sweep
remains necessary before considering a different default.

## Independent review and validation

A separate report-only review found incorrect seam wording and an impossible
recall capability in the measurement fixture. Both were corrected against
the production allowlists and routers. The review found no further reachable
restart-ordering, corruption, restriction-widening or custom-pack issue.

Local validation passed: the full client suite (1,867 tests), all 105 prompt
tests, all 80 boot tests after adding the explicit-seam refusal, and all six
final roster persistence tests using production-encoded configurations.
Client and prompt lint, repository format checks and documentation checks
passed with no errors. Existing lint/documentation warnings remain. The
shipped server was rebuilt for the final-wording model comparison.

The initial client run's sole failure was the old expected prompt version,
which was updated from 8 to 9 and verified by both the focused prompt module
and the clean full-client rerun. Hosted CI must be checked on the pushed
follow-up head. Remote Linux signoff remains separately approval-blocked;
local macOS execution and hosted CI do not stand in for that signoff.
