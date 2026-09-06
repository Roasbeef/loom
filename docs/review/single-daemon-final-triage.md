# Single-daemon review triage

**Date**: 2026-09-06 · **Status**: follow-up review found blockers; acceptance in progress

The [source review](single-daemon-final-surface.md) examined the daemon and
multiplayer working tree against the pinned lifecycle baseline. A separate
review examined the private-query SQLite repair now submitted as
[esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105).

## Bottom line

**The first source pass reported no new actionable finding. The subsequent
independent PR review found blockers; the PR is not ready to merge.**

The later review is pinned to `3cc360b5`. It identified a readiness query
whose timeout requests daemon shutdown before HTTP authentication, and a
caller-controlled transfer budget whose expiry poisons the session reader.
Both paths were verified against the source. The reviewer is leading a
separate fix branch; its final report and verified fixes must supersede this
checkpoint before merge.

Additional reports cover domain reopen during quiescence and serialized
catalogue/authorization work. A proposed helper-slot repair remains under
review: nonzero native exit proves process termination, not necessarily
joined retirement of its effect descendants. Preserve that distinction when
triaging it. These findings do not close the previously measured SQLite
retention or missing filesystem confinement.

## Where this stands

The reviewed working tree passed 1,298 client tests in 213.88 seconds. Clean
verification then exposed three fixture-ordering defects. The provider relay
must install its original witness before beginning an immediately completing
request. The terminal fixture must acknowledge monitor delivery before another
process triggers owner shutdown. The native fork test must observe the durable
agent identity rather than a temporary notice overwritten by reconciliation.

The relay's late-witness negative fails with `ProofLost`; the corrected group
passes nine tests. A trace captured the terminal control owner's `Normal` exit
with a `noproc` monitor event for the same PID. An acknowledged OTP system
request establishes delivery before shutdown; 250 untraced repetitions and the
independent 11-test module pass. The untraced negative did not reproduce.
Requiring the authoritative two-agent snapshot reproduced the old fork
assertion failure; the corrected native E2E passes in 6.09 seconds. These are
test corrections, not relaxed retirement or production guarantees.

The clean release build and smoke at `e9b46e1f` passed in 30.99 and 2.82
seconds. At its docs/test-only descendant `d2597a6c`, distribution and real
client bootstrap E2E passed in 49.12 and 35.15 seconds. The smoke observes
normal daemon exit, two explicit sessions and bundled runtime startup; it does
not prove a model turn or populated-catalogue restart. Both developer startup
smokes pass at `46312646`. Its full clean gate passed in 377.69 seconds,
including 1,298 client tests, 204 TUI tests, 69 conformance tests, native Go
checks and lint (zero errors, 615 warnings). The documentation-only descendant
`5af17a7e` passed `make doc-check`. These results all predate adoption of the
SQLite repair.

[CI run 34026704945](https://github.com/Roasbeef/loom/actions/runs/34026704945)
on `3cc360b5` passed the Linux full gate, bootstrap and deliverable smokes,
Linux jail job, and 200-seed soak. The macOS job failed one client soak
assertion: B's authenticated full-snapshot transfer took 3070 milliseconds
against an aggregate 1000-millisecond bound. The other 1297 client tests
passed. Five unchanged local reproductions and a single-scheduler run passed;
neither the failing cycle nor the responsible stage was recorded in CI.
The paired full-snapshot correction compares the same immutable B entries
before and while A is unread in each cycle. It bounds the stressed total by
twice that cycle's baseline plus 250 milliseconds. Individual receive deadlines,
finite credits, full transfer validation and provider/retirement assertions
remain. This measures the stalled peer's penalty rather than imposing a fixed
deadline on a growing number of serial credits. The independent reviewer
rejected an initial-response-only bound because it could miss later credit
slowdown; the paired design retains that check.

Five corrected runs passed. A temporary delay before each stressed credit
failed the paired assertion: baseline 102 milliseconds, stressed 866, allowed
454, with two credits and no receive timeout. The restored source passed in
17.80 seconds; independent verification passed in 17.33 seconds. The test-only
correction is `13969336`. Both totals and stage timings are emitted before the assertion
and saved in the fixture JSONL. This does not establish which stage caused
the earlier CI delay, nor dismiss that failure as a flake.

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
