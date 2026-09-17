# Child-run lifecycle review

Scope: the working diff on `agent/child-run-lifecycle`, based on `b3bb6b9d`.
The requested fix covers Agency continuation handles, budgets, parent custody
and observable stop reasons. An independent report-only review traced admission,
reaping, legacy records and nearby consumers before the final gates.

The reviewer confirmed that operation-keyed records preserve history and that
continued admission publishes metadata atomically. It found a parent-finalization
race: the run-end hook fires before the final strand-state commit. We closed
that race with a guarded operation-phase read. Explicit send refuses a parent
at a finishable checkpoint; a direct operator prompt takes no owner there.
The regression parks the real completion hook and verifies both paths.

Three adjacent limitations remain outside this Agency patch. The schedule
scanner still treats a finished original brief as the end of its target, and
schedule run-end retirement still matches that original brief. A resumed child
therefore cannot rely on fresh schedules behaving like those on a new child.
Legacy reaped strands already classified as `Abandoned` by the rule scanner
remain excluded by that scanner. New per-operation cancellation facts do not
create that permanent mark, so held rules remain retryable at the cost of
continued scanning. Schedule cancellation is now observed after the original
run's terminal result rather than its earlier stop-intent mark. Fixing the
remaining policies needs separate scheduling and rule-lifetime regressions;
neither is presented as solved here.

The reviewer also noted that an asynchronous old-hook survival assertion could
observe the child before the hook finishes. The ownership test directly checks
the durable new owner, while the immediate survival assertion is only a smoke
check. Exact-operation cancellation is enforced in production by
`api.abort_operation`; the deterministic admission-boundary test covers the
new finalization guard without relying on reaper scheduling.

The full gate caught a compatibility regression in direct host admission with
corrupt lineage. The existing rule-scanner contract keeps that conversation
promptable. The fix distinguishes failed lineage decoding from a failed store
read: direct host admission preserves the corrupt cell under a sequence guard
and mints no inferred lifecycle; explicit agent admission still refuses it.
The original rulescan regression is unchanged, and a runtime regression covers
the strict agent and permissive host paths together.

Final validation on the implementation tree passed `make check` with exit
status zero, including 1,855 client, 466 tools, 304 code-mode and 558 TUI tests.
Lint reports zero errors and 821 warnings. The documentation gate passes.
Opt-in shipped fixtures keep their existing environment-dependent skips; no
installed daemon or client was changed for validation.

The branch was then rebased onto merged PR #438 (`eadc0587`). Range comparison
confirms the implementation commit is patch-equivalent; only `docs/next.md`
needed a conflict resolution, retaining both handoffs. The affected package
gates passed again with 144 runtime, 466 tools, 304 code-mode and 1,858 client
tests. Rebased lint reports zero errors and 809 warnings, and documentation
checks pass. The implementation has not been installed.
