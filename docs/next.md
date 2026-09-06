# Next

Read this first. This is the handoff for the single-daemon and multiplayer
work: implemented boundaries, verified results and remaining release
requirements. Rewrite it after the next verified milestone rather than
adding another checkpoint above it.

Re-baselined on 2026-09-06 against `client/daemon-acceptance` at `816a18b2`.
The implementation, review dispositions and evidence below were checked
against that tree or the explicitly named earlier gate. The plan remains
[issue-plan.md](issue-plan.md), with required observations in the
[single-daemon acceptance drive](design-notes/single-daemon.md#the-acceptance-drive)
and [multiplayer brief](design-notes/multiplayer.md).

## Where the tree is

One daemon manages sessions across workspaces. Restart restores catalogue
metadata; authorized explicit selection opens a runtime. The broader
release goal is not complete.

| Body of work | Current state |
|---|---|
| Contracts and ownership, phases 0–1 | Protocols 014–016, reclaimable addresses, parked assembly and retained cleanup failures are implemented. Weft 0.4.4 is pinned. |
| Lifecycle and routing, phases 2–3 | Singleton ownership, durable creation keys, bounded admission, lazy catalogue restore, current authority and snapshot transfer are implemented. |
| TUI and domains, phases 4–5 | Idle authorization, maintenance revival and worker-owned control recovery are fixed and tested. The shipped daemon now has a distinct-principal native-TUI configuration fixture. |
| Default and release acceptance, phase 6 | Full local, packaging, multiplayer, soak and refreshed live-terminal checks pass for the named implementation. Remote platform acceptance, SQLite adoption, confinement and the remaining combined drive are open. |

The plan numbers its seven phases 0 through 6. Backwards compatibility and
legacy import were explicitly excluded; do not revive their historical cases.

### Branch and review state

Draft [#237](https://github.com/Roasbeef/loom/pull/237) remains frozen at
`3ec78b9e`, above [#235](https://github.com/Roasbeef/loom/pull/235).
Draft [#238](https://github.com/Roasbeef/loom/pull/238) is published at
`33387530`, based on #237. Native GitHub stack 231 contains that chain.
Draft [#239](https://github.com/Roasbeef/loom/pull/239) publishes
`client/daemon-acceptance`, based on #238. Its first published head was
`e829a2a0`; the follow-up adds a CI prerequisite repair and whole-VM
reservation recovery. All remain unmerged.

The previous handoff said the reviewed slice awaited publication and that
idle authorization, cadence revival and synchronous control recovery
remained unfinished. Those statements are now superseded:

- Idle transfer maintenance no longer queries authority. Requests and
  outbound replies retain their live checks.
- An explicit open revives only a recoverable idle domain fence. Resume
  withdraws parked replies, and the registry replaces the settle subject.
  An already-decided old reply cannot settle a later close.
- List, open and create recover control inside their managed worker.
  Cancellation retires an unfinished handshake. Each recovered action owns
  a temporary control connection; uncertain creation is never resent.
- Durable recovery tests reopen the catalogue after reservation and after
  database identity publication, preserving identity and original custody.
- The shipped bootstrap target now runs Alice, Bob and an observer through
  separate native TUI drivers against the actual daemon executable.

The [closing review](review/single-daemon-acceptance-closing.md) found no
high-severity issue. Its gateway-hint finding was rejected after tracing
actual assembly: the shipped runtime does not install those hint senders.
Do not attribute the CI latency failure to that unreachable path. Accepted
changes clarified the fixture capability and replaced a timed negative with
a check after actual completion. A trigger acknowledgement is not a
completion barrier. No production behavior changed during review triage.

The primary worktree, `.claude/worktrees/single-daemon`, retains excluded
filesystem policy, planner, native helper and protocol 017 edits. Preserve
them. `.claude/worktrees/daemon-candidate` is the integration tree; its
dependency caches have not been patched to manufacture a pass.

### Verified results and their limits

At `ebe0f96c`, the combined `make check dist e2e-client-bootstrap
e2e-multiplayer soak-daemon` gate exited 0 in **431.65 seconds**. It covered
1,322 client tests and 206 TUI tests, packaging and the enabled shipped
multiplayer fixture. Ordinary package runs explicitly skip that fixture
without its executable environment variable; the shipped target runs it.
The paired soak bound was unchanged. The documentation gate exited 0 with
zero errors and 136 warnings.

The subsequent delta through `9cc115c5` changes test ordering and prose,
not implementation behavior. Its cadence tests passed 14 cases in 1.71
seconds and registry tests passed seven in 0.85 seconds. Removing fence
withdrawal compiled and failed the intended test; exact restoration and
recompilation passed. The fresh-subject regression separately failed when
subject replacement was removed and passed after restoration.

Two rebuilt native clients also used one packaged daemon with the Baseten
example and background extraction disabled. Both painted a shared reply
without another keypress. One terminal created a second session, received
an independent reply, then rejoined the first and submitted another shared
reply. Both detached; the daemon logged `daemon.stopped`, its native
process departed and its enclosing command exited 0. These were two
owner-authenticated terminals with no tool calls. They do not establish
distinct-principal live-tool isolation or switching during a jailed effect.

Remote CI remains a separate gate. At parent `33387530`,
[run 34031696305](https://github.com/Roasbeef/loom/actions/runs/34031696305)
passed Linux, jail and 200-seed jobs but failed macOS: paired soak cycle six
took 399 ms against a 372 ms allowance. Five exact local reproductions
passed. The cause is unestablished; per-credit timestamps now accompany the
unchanged assertion. Neither a local pass nor a rejected review hypothesis
makes the remote failure green.

The new shipped recovery fixture fills runtime capacity, receives the exact
capacity refusal after durable reservation, then kills the birth-verified
fixture VM. Restart must preserve the reservation and domain mapping without
opening a runtime or creating the target file. Ordinary open is refused;
retrying the same creation key initializes the original SQLite identity.
The reviewed fixture passed in 1.98 seconds. The complete extended
`e2e-client-bootstrap` target passed in 28.26 seconds, and both shipped
fixtures ran together under the package runner's executable environment.

At `e829a2a0`, [run 34035552410](https://github.com/Roasbeef/loom/actions/runs/34035552410)
passed Linux jail and 200-seed jobs. Linux passed its substantive checks but
failed the skip census: the shipped multiplayer prerequisite was unset in
ordinary `make check`. Commit `f17d9875` builds the shipped prerequisites
first and supplies their absolute executable path to both platform gates.
It adds no skip waiver; both shipped fixtures run in ordinary check and in
the dedicated target.

That run's macOS gate failed the unchanged paired soak: cycle five took
2,062 ms against 346 ms. Five focused local reproductions passed, and the
full local client suite passed 1,323 tests in 219.35 seconds, including the
same soak. The latter omitted the executable environment; the dedicated
shipped runs above establish those conditional cases. Source inspection
does not establish the CI delay's cause. A's unread piece was already
serialized; shared registry, history and scheduler/native-I/O contention
remain candidates, not diagnoses. Do not weaken the bound or call the local
passes a repair. The follow-up needs its own remote results.

The earlier six mutation gates remain documented in
[mutation evidence](review/single-daemon-mutation-gates.md). The two new
in-process durable tests kill builders and registries. The shipped fixture
adds whole-VM loss before assembly, not an exhaustive crash-at-every-
publication-step sweep. Identity-before-confirmation remains uncovered in
the shipped executable.

## What to do next

### 1. Publish the follow-up and verify its platforms

Push the reviewed follow-up to #239, send its exact head and gate evidence,
and monitor both platform jobs. Native stack 231 already places it above
#238. Keep the PR draft while release acceptance is incomplete. Re-baseline
this handoff after new CI evidence; do not carry an earlier run's result
as the new head's result.

Exit: the reviewed follow-up is correctly stacked and its own platform
results are known and triaged. This does not authorize merging the Loom
stack, relaxing the soak bound or dropping the requirements below.

### 2. Adopt the SQLite retirement repair

Shipping still resolves sqlight 1.2.0 and Hex esqlite 0.9.0, not the evaluated
fork. [esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105), head
`45dbb48c`, was open and unmerged at this checkpoint.
[ADR-002](adr/002-sqlite-binding.md) explains why an ordinary Gleam git/path
dependency cannot build this rebar package. The preferred route is a patched
native Hex release. Do not patch build caches, force garbage collection or
publish a parallel package to conceal that constraint.

The earlier evaluation observed 192 additional database/WAL descriptors over
16 cycles with the original binding and a stable 68 with the repair. Those
are historical evaluation results, not the shipping artifact's guarantee.

Exit: the reproducible shipping dependency graph contains the fix, and
resource, release and platform checks verify that graph without overrides.

### 3. Complete confinement and the remaining shipped drive

Application filesystem dispatch and the separate PrivateScratch work remain
unresolved. Authorization tests do not prove that a model in workspace A
cannot read daemon credentials or alter B's database through overlap. Do
not retry restricted native implementation through another worker or tool.

The remaining joined acceptance includes live-tool switching, failure
containment, whole-VM publication crash boundaries and resource pressure
against the shipped daemon and clients. Preserve distinct-principal checks
and report platform skips explicitly.

Exit: every remaining required observation in the
[acceptance drive](design-notes/single-daemon.md#the-acceptance-drive) has
evidence for the final artifact. Green package tests and native enforcement
probes do not substitute for application confinement.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**One daemon, metadata-only restart.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) requires
explicit authorized opens; listing and preview never resume work.

**Retirement requires original evidence.** Protocol
[014](../protocol-change/014-helper-shutdown-witness.md) retains the native
port until exit. Caller timeout, port closure and late `noproc` do not
prove transitive cleanup. Failed cleanup retains custody and capacity.

**Authority is server-owned and checked at use.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md) and
[016](../protocol-change/016-record-human-origin.md) define membership,
revocation, activation and human origin. Workspace memory is owner-private;
sharing requires session-only scope and explicit transcript acceptance.

**Uncertain mutations are not resent.**
[ADR-009](adr/009-record-terminal-attempt-custody.md) retains attempt identity;
[ADR-010](adr/010-retain-one-unsent-terminal-command.md) permits one unsent
command during reconciliation on an adopted attachment. Replay has no effects.

**Production SQL is generated; connection policy is centralized.**
`make gen-sql` owns schema/query outputs. `storage/sqlite_policy` owns
shared pragmas and typed overrides. Raw SQL is acceptable in tests. Use Weft
for process machinery and keep Erlang limited to necessary host operations.

## Deliberately open

None of these is unfinished work somebody forgot. The release gaps above
are required work, not optional roadmap entries. Bounded source enumeration
still performs per-row catalogue reads; eliminating them is a separate
optimization. Broader extension, MCP, compaction, scheduling and seeded-TUI
work retains its existing design notes and issues, whose current states
were not re-audited for this slice.

## How to verify

```sh
LOOM_TEST_TIMEOUT_SECONDS=600 python3 scripts/with_timeout.py 900 -- make check dist e2e-client-bootstrap e2e-multiplayer soak-daemon
make doc-check
```

**Capture the gate's own exit code.** A successful log tail is not a test
result. Keep the candidate unchanged during a gate. Never build excluded
native edits in the primary tree as part of the published candidate.

**Bound waits and keep notifications live.** Test wrappers enforce independent
deadlines and scoped idle-sleep prevention. A timeout is failure, never drain
proof. Keep Substrate armed after notifications. A withdrawn reply can cause
a Weft unexpected-message warning; that is expected, not proof of a current
fence failure. [execution.md](execution.md) records the remaining hazards.
