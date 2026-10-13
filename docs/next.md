# Current handoff

Baselined October 13, 2026 against CI commit
`0d2b9405a` on `ci/shipped-deployment-enforcement`, based on
`dc70d25d42da531284225bf399f40f82e13539d4`. This branch is the CI follow-up
to Responses diagnostics PR #977; it does not include that PR's provider
changes. The project-wide plan remains `docs/issue-plan.md`.

The previous edition described older history-browsing, child-completion and
Go LSP work. Those test counts and next steps are historical, not evidence for
this branch. The prior edition remains in the
[base commit](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
No running daemon was updated by this work.

## What changed

The hosted Linux client suite passed but the aggregate census rejected
`SKIP shipped deployment status: platform enforcement unavailable`. The fixture
uses the same enforcement-gated pair as the distributed runtime tests; the
ordinary runner can lack that prerequisite. Its declaration was missing.

The ordinary Linux policy now declares that exact existing marker. The
Linux jail job separately runs the deployment-status fixture after joining
its verified delegated cgroup. An empty declaration set makes every skip fail
that step. Both executor-up and executor-down assertions must execute, and the
fixture log is uploaded with the jail evidence. No fixture assertion or
sandbox demand was removed or relaxed.

## Verification boundary

The real shipped deployment-status fixture passed locally. Replaying the four
actual hosted Linux logs fails with the base declaration file and passes with
the correction. An empty allowance still rejects the hosted skips and accepts
the executed fixture log. Removing the deployment marker from those inputs
makes the new declaration fail as stale. All three skip-reporting self-tests
passed; the workflow parses as YAML and the new shell step passes `bash -n`.
Independent advisor review found no actionable issue.

The new-head hosted jobs and full Linux signoff are pending at this checkpoint.
Their final verdicts belong on the follow-up PR at the tested head. The earlier
#977 signoff validates its separate head, not this branch's workflow changes.

## Next steps

1. Publish this follow-up, run required Linux signoff, and inspect hosted CI.
   Exit: the ordinary Linux aggregate is green and the delegated deployment
   step has a passing real-fixture log with no skip.
2. After owner-authorized landing, update #977 against the corrected base and
   obtain fresh CI evidence. Neither PR has been merged by this work.
