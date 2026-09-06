# Single-daemon review triage

**Date**: 2026-09-06 · **Status**: review complete, acceptance in progress

The [source review](single-daemon-final-surface.md) examined the daemon and
multiplayer working tree against the pinned lifecycle baseline. A separate
review examined the private-query SQLite repair now submitted as
[esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105).

## Bottom line

**No new actionable source finding was reported; release acceptance remains open.**

There are no new finding IDs to disposition. The review did not turn the
previously measured resource defect or the missing platform evidence into
passing results.

## Where this stands

The corrected client gate passes 1,298 tests in 213.88 seconds. A fresh release
build and release smoke pass in 18.93 and 2.80 seconds, respectively. The smoke
observes normal daemon exit, two explicit sessions and bundled runtime startup;
it does not prove a model turn or populated-catalogue restart. These local
results predate adoption of the SQLite repair.

The original soak adds 192 database/WAL descriptors over 16 measured cycles.
An explicit evaluation of the repaired binding holds the count at 68 across
all 16 cycles, and all 35 dependency tests pass. The dependency files still
select the original release. A code-path override is evidence for the fix,
not a reproducible shipping dependency.

Both local CI attempts stopped during OTP installation, before repository
tests. The explicit PR workflow returned exit 1 after 66.40 seconds because
`otp/Install` was missing. Linux installation and declared enforcement are
therefore unverified by those runs.

## Remaining acceptance

Adopt a reproducible native dependency containing the query repair, then
repeat the combined gates, resource measurements and release smoke on that
dependency state. Establish the Linux install/start/enforcement result.
Keep filesystem dispatch and native-isolation evidence separate from the
verified multiplayer behavior; both remain unfinished work, not properties
established by this review. The handoff must name the final commit and tests
before the daemon PR can be called ready.
