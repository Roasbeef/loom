# Reading follow-up review

The expanded follow-up starts at `78c5138f` on `tui/readable-scrollback` and
is carried by draft PR #349. This report covers structured notes, workspace-first
session ordering, direct patch rendering, and the durable session Git baseline.
The earlier source-cleanup and scrollback changes remain in the same PR.

## Independent review

One report-only pass checked the working tree, including the new baseline module
and protocol 029. It found one functional omission: default `git log -p` shows a
merge header without the bytes introduced while resolving that merge. A clean
worktree would then hide those changes from both available views.

The capture now requests `--diff-merges=first-parent`. The real jailed Git fixture
creates a merge with `resolved-only` contents absent from both parent versions,
commits it, and verifies those bytes remain in the committed patch stream while
current worktree status is empty. The review found no additional actionable
baseline, decoding, rendering, or picker findings.

## Validation

`make check-client` passed all 1,545 tests. The worktree module's eleven tests ran
against the real helper, including baseline reuse, a clean committed worktree,
an unborn starting repository, merge-resolution bytes, patch truncation, and the
encoded response ceiling. The client gate also ran the real TUI/server flow and
the joined queue/worktree/completion flow. Optional shipped-release lifecycle
fixtures require their separate environment and are not established by this run.

`make check-tui` passed all 354 tests. New checks cover wrapped JSON note values,
compact hierarchy, stable directory ranking without prefix collisions, literal
patch fences and indentation, different addition/removal styles, committed-view
selection across changing file status, and optional bounded wire decoding.
`make lint-client`, `make lint-tui`, and `make doc-check` passed with zero errors.

The first client run exposed seven fixture failures. Four shared fixture builders
used `/bin/sh` as a helper placeholder on the assumption that assembly never
checked out a helper. First-activation Git observation makes that assumption
false. Those builders now use the existing protocol-speaking helper, preserving
the original lifecycle assertions; the complete final gate passes.

## Boundaries

The baseline is captured before model work on first activation, retained under
a reserved fact, and bound to the session and workspace. A legacy session without
that record does not acquire a guessed historical HEAD. A fork cannot inherit
another session's attribution. The committed view shows repository changes since
the baseline, not authorship by the agent, and retains the explicit 24-commit and
four-KiB patch limits from protocol 029.

The work was built in the isolated checkout. It did not replace installed
binaries or stop the operator's running daemon or extension satellite. Hosted
checks must still validate the published head; local macOS results do not claim
Linux signoff.
