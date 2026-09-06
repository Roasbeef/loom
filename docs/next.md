# Next

Read this first. This is the handoff for the single-daemon and multiplayer
work: what is implemented, what has been verified, and what still prevents
completion. Rewrite it after the next verified milestone; do not append
another checkpoint above it.

Re-baselined on 2026-09-06 against `client/instance-custody` at
`13969336` (production/build changes through `46312646`, followed by the
paired-soak test correction). Current claims below were checked against the tree, recorded
test results, or GitHub. Historical claims that were not reverified are
identified as such. The project-wide plan remains [issue-plan.md](issue-plan.md);
the active work follows [the single-daemon plan](design-notes/single-daemon.md)
and [the multiplayer brief](design-notes/multiplayer.md).

## Where the tree is

**The single-daemon experience is implemented, but final acceptance is incomplete.**
One listener manages sessions across workspaces. Restart restores the catalogue,
and explicit authorized selection opens a runtime. The client uses the daemon
for startup and `/sessions`; it does not retain the old per-session server path.

| Body of work | Current state |
|---|---|
| Contracts and reusable sessions, phases 0 and 1 | Reviewed protocols 014, 015 and 016; reclaimable addresses; owned assembly and retained cleanup failures. Weft 0.4.4 is pinned. |
| Daemon lifecycle and routing, phases 2 and 3 | Private catalogue, singleton ownership, bounded admission, current-credential checks, session routes, and snapshot transfer are implemented. |
| TUI and lifecycle integration, phases 4 and 5 | Server-backed selection, safe replacement, uncertain submissions, shared domains, detached scheduling and lazy restart have targeted tests. |
| Default and release acceptance, phase 6 | Clean local full gate and Linux CI pass. macOS CI exposed the aggregate soak timing assertion; its paired correction passes targeted tests. Independent review found production blockers. SQLite adoption and filesystem confinement remain open. |
| Filesystem follow-up | Unfinished work is preserved outside the committed daemon slice. No workspace-overlap confidentiality claim is established. |

The plan has seven phases numbered 0 through 6, not a separate phase 7.
The owner rejected backwards compatibility and legacy import for this work.
Do not revive those historical migration items while reading the original plan.

### Review and commit scope

The daemon slice is published as draft
[#237](https://github.com/Roasbeef/loom/pull/237), above lifecycle PR
[#235](https://github.com/Roasbeef/loom/pull/235). Native `gh stack view`
reports the preceding open branches as session-services (#233),
session-ownership (#234), and instance-lifecycle (#235), with no rebase needed
at this checkpoint.

The commits separate bounded test execution (`c32c1f44`), daemon implementation
(`c12d22eb`), generated SQL (`7699065e`), dependency locks (`e9b46e1f`),
architecture documentation (`f066cd7e`), and test monitor ordering
(`d2597a6c`), followed by the terminal fork assertion (`bdffaf78`), recovery
documentation (`e9e30b02`), acknowledged monitor delivery (`d59ba83d`), and
developer command updates (`46312646`). Current launch guidance is updated in
`5af17a7e`; the paired soak correction is `13969336`. The
[source review](review/single-daemon-final-surface.md) reported no new
actionable finding. A subsequent independent review of published head
`3cc360b5` found blockers; the updated
[triage](review/single-daemon-final-triage.md) distinguishes those passes.
The PR is not ready to merge.

The primary worktree is `.claude/worktrees/single-daemon`. Its remaining
uncommitted filesystem policy, planner, native helper and protocol 017 work is
not part of these commits. Preserve it. The clean verification worktree,
`.claude/worktrees/daemon-candidate`, contains only committed work; no
dependency cache has been patched to make its gates pass.

### Verification and its limits

The clean full `make check` at `46312646` passed in 377.69 seconds. It
includes all 1,298 client tests (220.78 seconds), 204 TUI tests, 69 conformance
tests, the remaining Gleam packages, native Go checks and house-rule lint.
Lint reports zero errors and 615 warnings. The outer deadline was 900 seconds,
with 600-second package deadlines. No `SKIP` marker appeared in this log;
that is not a substitute for the separate platform enforcement reports.
The docs-only descendant `5af17a7e` passed `make doc-check` with zero errors.

The earlier full client run passed all 1,298 tests in 213.88 seconds.
A subsequent clean `make check` failed after 370.62 seconds, with 1,296 client
tests passing and two failing. These are different runs; the earlier pass did
not establish that the candidate was clean.

The relay fixture started an immediately completing request before installing
its drain witness. It now prepares, monitors, then begins. A negative control
that installs the witness after confirmed retirement fails with `ProofLost`.
The corrected relay group passes all nine tests in an independent 15.28-second
run. The terminal fixture now follows explicit stop or test-parent death,
rather than its own two-second timer. Removing the timer was insufficient:
the same failure recurred in the clean run at `bdffaf78`.

The next clean run failed one terminal E2E assertion after 332.19 seconds,
with 1,297 client tests passing. The fork had succeeded, but the authoritative
snapshot replaced its transient local notice before the test read it. Requiring
the two-agent snapshot reproduced that failure deterministically. The corrected
test verifies the exact durable strand identity and its stable name in
`/agents`; the independent root run passed in 6.09 seconds.

The clean run at `bdffaf78` failed after 318.15 seconds with 1,297 client
tests passing. A process trace then captured the control owner's `Normal`
exit while its original monitor reported `noproc`. The monitor request had
not necessarily arrived before the terminal, a different sender, triggered
shutdown. The corrected fixture waits for an OTP system reply from the
control owner before releasing the terminal. Both strict `Normal` assertions
remain. The traced barrier passed 100 repetitions, the untraced barrier
passed 250, and the independent final module passed all 11 tests in 0.87
seconds. The untraced negative did not reproduce; the traced schedule did.

The clean release at `e9b46e1f` built in 30.99 seconds; its smoke passed in
2.82 seconds. Subsequent changes through `d2597a6c` are docs and tests only.
The smoke checks bundled runtime startup with no host Erlang on `PATH`,
authenticated v2 readiness, two explicit sessions, shared-domain maintenance,
helper discovery and normal daemon exit. It does not prove a model turn or a
populated-catalogue restart. Seed preparation passed but explicitly did not
verify the offline jailed build on this host.

At `d2597a6c`, the self-contained client build passed in 5.45 seconds and its
smoke passed in 0.54 seconds. Real client bootstrap E2E passed in 35.15 seconds,
including startup, detach/reuse and launcher-lifetime checks. `make dist`
passed in 49.12 seconds and produced server, bundled-client and slim-client
archives for macOS arm64. These artifacts still contain the original SQLite
dependency, so packaging success does not close resource acceptance.

A relocated installation of those artifacts passed an authenticated daemon
probe in 1.89 seconds, including explicit sessions and confirmed native exit.
That probe does not cover an interactive installed client. At `46312646`,
the updated source-mode developer smoke passed in 11.51 seconds, and its
shipment counterpart passed in 27.77 seconds. Both check catalogue-only startup,
the authenticated control route and clean shutdown.

The packaged helper self-test passed all nine enforcement probes with zero
skips in 1.61 seconds on macOS. That verifies the helper's declared probe
policies, not the missing application filesystem dispatch or workspace-overlap
confidentiality requirement.

The internal multiplayer fixtures use real WebSockets, real SQLite and
independent native TUI loops with scripted providers. Separate tests cover
operator/observer authority, concurrent approval resolution, actual approved
effects, session switching, shared domains, lazy restart, blocked provider
drain and detached schedules. [Multiplayer architecture](architecture/multiplayer.md)
names what each fixture proves.

The live Herdr drive used two owner-authenticated terminals against one daemon.
Both submitted and rendered replies without a second keypress; switching one
terminal to the other session produced a shared transcript and presence of two.
That establishes the live owner experience, not distinct-principal authority.
The daemon was stopped cleanly after the drive. Its isolated evidence remains
under `build/test_db/loom-live-multiplayer.tz67PE` in the primary worktree.

The original resource soak added 192 SQLite database/WAL descriptors over
16 measured cycles. The repaired binding kept 68 descriptors throughout an
equivalent evaluation; atoms and helper count also remained stable. This was
a shared test VM, not an isolated daemon RSS benchmark. A passing soak's
assertions do not override its measured descriptor growth.

### SQLite retirement is fixed upstream, not adopted here

The fix is [esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105),
commit `45dbb48ce28c4d78b5cb93de0e1e78bb79f859d9`. It is open and unmerged
at this checkpoint. All 35 dependency tests pass; removing private-query
cleanup makes all five new regressions fail. The fix has independent review.

[ADR-002](adr/002-sqlite-binding.md) records the mechanism and packaging
constraint. A query's private statements must finalize before it returns.
Manual prepared statements keep their existing contract. Loom still uses
sqlight; no custom database binding replaces it.

Gleam 1.18.1 cannot build this native rebar dependency through an ordinary
git or path dependency. The preferred adoption route is a patched esqlite
Hex release. The evaluation used an explicit code-path override, which is
not a shipping dependency. Do not alter build caches or force garbage
collection to conceal the retention.

### Platform evidence

The published head `3cc360b5` completed
[CI run 34026704945](https://github.com/Roasbeef/loom/actions/runs/34026704945).
Linux full checks, client bootstrap and deliverable smokes passed, as did
Linux jail enforcement/E2E and the 200-seed soak. macOS failed one client
soak assertion: an authenticated B snapshot took 3070 milliseconds against
a fixed 1000-millisecond aggregate budget. Its other 1297 client tests
passed. Five unchanged focused local runs and a single-scheduler variant
passed, so that CI failure's exact cause remains unestablished. The test's
measured work grows with B's transcript. The corrected test pairs the same
immutable B snapshot before and while A is unread, with a stressed limit of
twice the same-cycle baseline plus 250 milliseconds. Five corrected runs
passed; delaying stressed credits failed the intended comparison, and the
restored source passed in 17.80 seconds, followed by an independent run in
17.33 seconds. The recorded diagnostics now precede
the assertion. These targeted results do not replace the next platform gate.

Local CI was attempted both through automatic discovery and explicit
`ci.yml` selection. Linux jobs stopped during OTP installation because the
runner's `otp/Install` executable was missing; repository tests did not run.
The explicit workflow also skipped its macOS VM job because Tart was absent.
These are failed or skipped attempts, not Linux or macOS CI passes.

GitHub main is `5e2112b1ace369f5e108072d64cffc1b9b466bf6`.
Its [CI run](https://github.com/Roasbeef/loom/actions/runs/33935822041)
passed. The later [nightly](https://github.com/Roasbeef/loom/actions/runs/33962443810)
failed only in the long `seeds 1001..` soak job; its cold Linux gate passed.
Neither run verifies this daemon branch.

## What to do next

### 1. Verify the soak correction and independent review fixes

The bounded full check on `46312646` and documentation gate on `5af17a7e`
passed, and final publication head `3cc360b5` passed the documentation gate.
PR #237 is correctly based on #235. The paired full-snapshot correction in
`13969336` has its delayed-credit negative control and independent restored
pass. It remains separate from production fixes and needs the next CI verdict.

Freeze the branch for the independent reviewer's fix wave, which will
use a separate worktree and branch above that head. The confirmed readiness
timeout can request daemon shutdown before authentication; a near-expired
transfer can also turn its caller's budget into session-wide reader failure.
Review and test the fixes, plus the consolidated remaining findings, before
integrating that branch with native `gh stack`. Preserve transitive retirement
proof when evaluating any proposal to reuse a slot after nonzero helper exit.

Exit: the corrected slice has green platform gates, verified review fixes,
accurate evidence and a correctly stacked PR. This step does not discard unfinished
filesystem work or declare the overall goal complete.

### 2. Adopt the SQLite repair and rerun resource acceptance

Use a reproducible native package containing PR #105. Rebuild without an
evaluation override, then repeat the combined tests, open/close measurements
and release smoke. Measure descriptors, atoms, mailboxes, helpers, memory and
unrelated-session latency; state which quantities have asserted bounds and
which are observations.

Exit: the shipping dependency graph reproduces the fix and resource retirement.
Do not publish a parallel public package or replace the database binding merely
to bypass the current packaging constraint.

### 3. Complete confinement and platform acceptance

Application filesystem dispatch still bypasses the jailed planner. The
separate native PrivateScratch work under protocol 017 remains restricted and
unverified. Neither planner tests nor multiplayer authorization tests prove
that a model in A cannot read daemon credentials or alter B's database through
overlapping workspaces. Preserve the unfinished slice; do not describe it as
implemented confinement.

Run installation/startup and declared enforcement checks on macOS and Linux.
Exercise the final packaged client+daemon together, including concurrent
startup, selection, detach, restart and resource pressure.

Exit: the final artifact meets the remaining
[acceptance drive](design-notes/single-daemon.md#the-acceptance-drive), with
scope and skips stated. Owner administration of branch protection is separate;
do not bypass it to manufacture merge readiness.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**One daemon owns sessions across workspaces; restart restores metadata only.**
Listing and preview never resume work. Authorized explicit opens for the same
saved session converge on one runtime. The
[execution ruling](design-notes/single-daemon.md#execution-ruling) excludes
legacy compatibility and leaves existing user data untouched.

**Retirement requires original evidence.** A caller timeout, port closure or
late `noproc` observation does not establish successful transitive drain.
Failed cleanup retains custody and occupancy. Protocol
[014](../protocol-change/014-helper-shutdown-witness.md) keeps the native port
open until helper exit; [sessions](architecture/sessions.md) records the
session/domain ownership boundary.

**Authority is server assigned and checked at use.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md) and
[016](../protocol-change/016-record-human-origin.md) define owner control,
membership, human origin, revocation and session activation. Workspace memory
is owner-private. Sharing requires session-only scope and explicit acceptance
of any existing transcript; isolation does not sanitize earlier recalled text.

**Uncertain submissions are never automatically resent.**
[ADR-009](adr/009-record-terminal-attempt-custody.md) retains attempt identity
through replacement. [ADR-010](adr/010-retain-one-unsent-terminal-command.md)
permits one unsent command to wait during reconciliation on an already-adopted
attachment. Initial synchronization refuses mutation admission. A replay
renders recorded traffic and performs no outbound effects.

**SQL stays generated and connection policy stays centralized.**
Production schema/query changes go through `make gen-sql`.
`storage/sqlite_policy` owns common pragmas plus typed per-database policy.
Raw SQL in tests is acceptable. Keep process machinery in Weft and native
FFI limited to the host operations Gleam cannot express.

**Older subsystem decisions retain their own homes.**
Use [compaction](architecture/compaction.md) for checkpoint/recall invariants,
[memory](architecture/memory.md) for atomic head/cursor rewind and domain
maintenance, [extension architecture](design-notes/extension-architecture.md)
for jailed extensions and deferred in-VM loading, [MCP](architecture/mcp.md)
for its unjailed transport boundary, and
[scheduled heartbeats](design-notes/scheduled-heartbeats.md) for scheduling
authority. This handoff does not duplicate their specifications.

## Corrections to the previous handoff

The previous file accumulated overlapping checkpoints and old project-wide
claims. These corrections replace them:

- Weft 0.4.4 is published and pinned. The old local-path/0.4.2 release blocker
  is obsolete. The nine direct consumers are not waiting on another Weft tag.
- Compaction PR #223 is merged and #132 is closed. That closure does not mean
  `ProjectState` was implemented; notes and structured task-state projection
  remain different capabilities.
- Web search #144 is closed through the separately installed extension.
  Memory #124 and #149 are closed; daemon maintenance is domain-owned, not a
  separate boot worker for each session.
- The TUI has injected presentation time. #220 was a documentation PR, not
  proof that the full seeded simulator shipped. Keep existing native tests.
- Multiplayer is active implemented work, not an optional final roadmap item.
  Single-bearer and unguarded-denial descriptions are historical, superseded
  by protocols 015/016 and the current approval path.

## Deliberately open

None of these is unfinished work somebody forgot. The daemon acceptance gaps
above are required work; the items here are separate project scope.

**Repository administration:** #1 remains open and the live API reports
`main.protected=false`. #99 and #62 are closed with their measured evidence;
they are not proof of this branch's checks. #155 remains the long nightly
soak issue.

**Extension follow-ups:** #30/#31 cover the agent-authored on-ramp; #32 is
deferred until an in-VM consumer requires it. `agent_settled` still has no
production caller, and the host registry still serializes invocations across
the session. Keep those gaps in the extension design, not in daemon startup.

**MCP follow-ups:** #108 through #112 remain open for HTTP/OAuth, server
confinement, third-party end-to-end coverage, elicitation and list changes.
The current port transport remains unjailed.

**Other prior roadmap items:** full seeded TUI simulation and the scheduling
brief's residual limits were not established as complete by this audit.
Consult their design notes and issue records before changing scope. Historical
timings, old local jail skips, and speculative flake diagnoses from earlier
editions are not current evidence.

## How to verify

Run `make check`, `make doc-check`, and the relevant E2E targets on the final
committed tree. `make codemode-seed` prepares release prerequisites;
`make release` must precede `make release-smoke`. `make dist` also builds
and smoke-tests the client. Keep the live Herdr drive complementary to the
internal TUI and authorization tests.

**Capture the gate's own exit code.** A later `tail` succeeding says nothing
about the test command. Named progress and an independent deadline are part
of the gate, not optional monitoring:

```sh
LOOM_TEST_TIMEOUT_SECONDS=600 python3 scripts/with_timeout.py 900 -- make check
LOOM_TEST_TIMEOUT_SECONDS=120 bash scripts/test.sh client --match provider_relay_
```

**Keep timeouts and sleep prevention separate.** Test wrappers use
`caffeinate -i` on macOS and enforce wall/monotonic deadlines. A timeout is
failure, never drain proof. Earlier multi-hour pauses included host sleep;
do not diagnose a deadlock from a quiet log alone.

**Use a clean verification worktree outside /tmp.** The jail replaces /tmp,
so cap sockets there cannot establish a valid code-mode test. Preserve
uncommitted work and distinguish clean-candidate evidence from a working-tree
run.

**Check omissions as well as failures.** Package checks do not run the full
lint gate, doc-check is separate, and seed setup may explicitly report that
offline confinement was not verified. A failed or skipped platform setup
does not test the product.

[execution.md](execution.md) carries the rest of the verification and
coordination procedure.
