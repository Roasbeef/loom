# Next

Read this first. This is the handoff for the single-daemon and multiplayer
work: implemented boundaries, verified results and remaining release
requirements. Rewrite it after the next verified milestone rather than
adding another checkpoint above it.

Re-baselined on 2026-09-06 against `client/daemon-acceptance` at `4744fe7a`.
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
| TUI and domains, phases 4–5 | Idle authorization, maintenance revival and worker-owned control recovery are fixed and tested. The shipped fixture covers distinct-principal configuration, invitation boundaries, presence recovery, two real HTTP turns and live membership revocation. |
| Default and release acceptance, phase 6 | Published `33aa9ef1` passes both platforms and corrected censuses. Revocation head `e50d3d2c` passes Linux, jail and seeds but fails the recurring macOS paired-latency assertion. The reviewed selector follow-up passes locally. SQLite adoption, confinement and the remaining combined drive remain open. |

The plan numbers its seven phases 0 through 6. Backwards compatibility and
legacy import were explicitly excluded; do not revive their historical cases.

### Branch and review state

Draft [#237](https://github.com/Roasbeef/loom/pull/237) remains frozen at
`3ec78b9e`, above [#235](https://github.com/Roasbeef/loom/pull/235).
Draft [#238](https://github.com/Roasbeef/loom/pull/238) is published at
`33387530`, based on #237. Native GitHub stack 231 contains that chain.
Draft [#239](https://github.com/Roasbeef/loom/pull/239) publishes
`client/daemon-acceptance`, based on #238. Its first published head was
`e829a2a0`; published `34323df1` includes the CI prerequisite repair and both
whole-VM recovery boundaries. The reviewed follow-up through `df960471` adds
presence recovery and two real HTTP turns across Bob's reconnect, published
at `0bc46d32`. The reviewed follow-up through `e2480830` adds shipped
invitation boundaries and repairs hidden prerequisite diagnostics, published
with docs at `33aa9ef1`. Commit `0606cb89` adds the reviewed live membership
revocation drive, published with docs at `e50d3d2c`. Commit `e8ec249e` adds
reviewed failed-selector preservation. All remain unmerged.

Commit `4744fe7a` adds bounded, test-owned observations to the recurring
paired-latency failure without changing its workload or assertion. It is
diagnostic evidence, not a claimed timing repair.

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
  separate native TUI drivers against the actual daemon executable. Its
  finite loopback provider checks the latest user text, then all three
  terminals compare exact durable records and authors across two turns.

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

The reviewed sampler's focused soak passed in **11.75 seconds** at
`4744fe7a`. Its first run passed in 11.76 seconds and recorded all 18 pairs,
with one to three samples per condition and normal sampler completion.
The observed batch durations ranged from 0 to 3 ms across that first run;
they do not measure the sampler's total effect on other processes. No direct
caller-failure injection was run: cleanup on that path follows the existing
Weft linked relay/scope guarantee. The final client lint gate reported zero
errors and 91 warnings after the small type/prose review cleanups.

The failed-selector candidate passed `make check-client` with its own exit
0 in **290.78 seconds**, including 1,332 tests and all three enabled shipped
fixtures. Its strict local census passed with only the declared macOS `/proc`
skip. The review found no high- or medium-severity issue; after small prose
and redundant-assertion cleanups, focused `e8ec249e` passed in **4.78 seconds**.
The package gate preceded those cleanups; the focused run verifies them.

The actual `/sessions` page contains the authorized second session. Real
navigation highlights it before the owner revokes only that membership.
Enter receives the exact refusal without replacing Alice's original identity,
records, inbox or socket. An owner still attaches to the target. Alice then
sends a fresh configuration that Reader receives, and her attachment and
socket remain the originals after that traffic. This is refusal before
replacement, not a mid-transfer failure or switching during a live tool.

The live-revocation candidate's combined check, distribution, bootstrap,
multiplayer and soak gate exited 0 in **566.05 seconds**. It reported 1,332
client tests and 206 TUI tests, with all three shipped fixtures enabled in
ordinary check and the dedicated target. Its strict local macOS census
exited 0 with the existing `/proc` prerequisite skip and no undeclared skips.
After the review's small assertion corrections, the final shipped fixture
at `0606cb89` passed in **4.33 seconds**. The full gate preceded those
corrections; the focused result verifies them. No deadline was widened.

Bob must be live and writable before the owner revokes his membership. His
raw socket then receives exact normal close code 1000 and actual TCP closure;
his terminal disconnects on its next refresh. Alice and Reader receive the
same subsequent configuration and author while Bob retains his old cut.
Bob's credential still authenticates control, but cannot list, inspect or
reattach to the revoked session. The narrow admission/delivery race remains
separate scripted authority coverage, not a claimed shipped observation.

The final combined `make check dist e2e-client-bootstrap e2e-multiplayer
soak-daemon` gate exited 0 in **563.63 seconds** at `e2480830`. It reported
1,332 client tests and 206 TUI tests. The executable and public dummy
provider key were supplied to ordinary check as well as the dedicated
target, enabling all three shipped fixtures in both runs. The strict local
macOS census then exited 0: one existing `/proc` prerequisite skip and no
undeclared skips. That prerequisite skips the real-MCP fixture before
setup; its passing EUnit result does not establish that fixture's coverage.

The shipped multiplayer fixture now also creates a real second workspace.
Alice and Reader cannot list, inspect, open, stop or upgrade to its session;
owner probes subsequently verify that the same runtime remains live. Reader
cannot open even the invited session. Both members are denied owner-only
invitation and shutdown operations, and a raw observer connection is denied
the same configuration mutation Alice later completes. The reviewed focused
fixture passed in **3.87 seconds** before the combined gate. These are
authority checks, not application filesystem-confinement proof.

Commit `e2480830` sends prerequisite diagnostics to stderr, following the
existing TUI harness convention. EUnit captures stdout from passing tests,
which previously hid conditional skips from the census. Twelve bounded
Python regressions passed in **3.53 seconds**, including actual EUnit output
and declared, undeclared and stale census cases. No prerequisite, assertion,
skip declaration or runner capture behavior changed. Earlier remote census
results on both platforms under-counted skips. The repaired reporting has
since passed both platform censuses at `33aa9ef1`; this does not retroactively
validate the earlier counts or establish remote coverage for `0606cb89`.

The provider/ordering candidate's combined `make check dist
e2e-client-bootstrap e2e-multiplayer soak-daemon` gate exited 0 in
**497.05 seconds**. It covered 1,332 client tests and 206 TUI tests, packaging
and all three enabled shipped fixtures in the dedicated target. The later
review corrections add type annotations, equivalent decoded-model capture
and explanatory prose; the final eight helper tests passed in **0.65 seconds**
and the final shipped integration at `df960471` passed in **3.46 seconds**.
No safety assertion or per-terminal await deadline was removed or widened.
The latest documentation gate exited 0 with zero errors and 136 warnings.

Ordinary local package runs explicitly skip the shipped fixtures without
their executable environment variable; CI supplies it before ordinary check.
The dedicated target also supplies the public dummy provider key. The paired
soak bound is unchanged. The provider fixture uses actual chunked HTTP, not
an injected transport, and the two turns include server-assigned user
authorship, exact record equality, rendered answers and idle completion.

The earlier identity-recovery review correction adds a session-correlated
`storage_open_failed` observation to the immediate recovery retry. Its
focused shipped fixture passed in **61.59 seconds**. The assertion excludes
earlier configuration/helper failures, but does not identify the exact
storage error. The unchanged original lease remains the safety assertion.

The earlier delta through `9cc115c5` changes test ordering and prose,
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

At `0bc46d32`, [run 34041432159](https://github.com/Roasbeef/loom/actions/runs/34041432159)
passed Linux, jail and 200-seed jobs. macOS test commands also returned zero,
but its final skip census failed because the still-required `/proc`
declaration matched no visible diagnostic. This exposed the stdout capture
problem above; deleting the declaration would hide it. That run had neither
a Hex failure nor a paired-soak assertion failure. The next published head
must rerun both platform censuses with the reporting repair.

Published `33aa9ef1` then passed
[run 34043916766](https://github.com/Roasbeef/loom/actions/runs/34043916766):
Linux, macOS, jailed E2E and 200-seed soak all succeeded. Both platform logs
report 1,332 client and 206 TUI tests. Their censuses were independently read:
Linux emitted no skip, and macOS emitted the existing `/proc` marker and
matched its declaration. These are the first verified remote censuses after
the reporting repair. The declaration's old explanation incorrectly said
the MCP exchange had run; source inspection shows the whole fixture skips
before setup. Only that explanation is corrected, not its marker or waiver.

The subsequent live-revocation head `e50d3d2c` failed
[run 34045168260](https://github.com/Roasbeef/loom/actions/runs/34045168260)
only on macOS's unchanged paired-soak assertion: cycle one measured 346 ms
against 342 ms. Linux, jailed E2E and 200-seed soak passed; Linux's census
was independently verified clean. macOS's census was not reached. Its client
summary was one failure and 1,331 passes, not a clean package gate.

That pair's baseline was 46 ms: HTTP 11, subscribe 28 and drain 7. The stressed
measurement was 346 ms: HTTP 162, subscribe 50 and drain 134, with credit
round trips of 23, 10, 100 and 1 ms. The preceding cycle already had a slow
563 ms baseline against 446 ms stressed. Delays occur in separate phases;
these timings do not establish whether scheduling, native I/O or shared
service contention caused them. No threshold change or blind rerun followed.

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
passes a repair.

At `ffacaa5b`, [run 34036856149](https://github.com/Roasbeef/loom/actions/runs/34036856149)
again failed. Linux check, bootstrap and documentation passed; later server
shipment failed on a Hex API rate limit. macOS failed paired soak cycle nine:
498 ms against 370 ms. Both then-enabled shipped fixtures ran and passed in
ordinary check, validating the prerequisite repair. The timing failure's
cause remains unestablished. Production client and server sockets already
enable TCP_NODELAY; a raw fixture option difference is not a causal finding.
At `34323df1`, [run 34038875459](https://github.com/Roasbeef/loom/actions/runs/34038875459)
passed the Linux gate, deliverables, strict census, jail and 200-seed jobs.
macOS also passed `make check`, including the unchanged paired soak. Its
later bootstrap invocation failed on a Hex rate limit before compilation
or EUnit: job `101501867569`, runner exit 1 in 1.77 seconds, step exit 2.
One infrastructure retry failed on the same limit while rebuilding
`tui-shipment`, before tests: attempt 2, job `101504590127`, step exit 2.
No further immediate retry was made. This is not green platform acceptance
or an explanation of the earlier timing failures.

The repeated dependency resolution has an upstream cause. Gleam 1.18.1
updates only the first missing or changed direct-path fingerprint per
invocation, then resolves again; the client has fifteen direct path
dependencies. [Issue #6244](https://github.com/gleam-lang/gleam/issues/6244)
reports this behavior and Hex rate limits. Merged
[PR #6246](https://github.com/gleam-lang/gleam/pull/6246), commit `860f8224`,
updates all fingerprints in one pass and adds a regression. At this
checkpoint the latest published compiler was still 1.18.1, without the fix.
The workflow already shares the workspace and caches package builds; another
ordering change does not repair the compiler's freshness bookkeeping.

The toolchain choice remains with the user: wait for a release containing
that fix, or pin CI to a compiler built from the fixed source commit. No
source-built compiler, fingerprint rewrite or dependency-skip workaround
has been adopted. This explains resolver traffic, not the macOS soak delay.

The earlier six mutation gates remain documented in
[mutation evidence](review/single-daemon-mutation-gates.md). The two new
in-process durable tests kill builders and registries. The shipped fixtures
now cover whole-VM loss both before assembly and after SQLite identity
publication, before catalogue confirmation. The latter observes actual MCP
initialize, kills only the birth-qualified VM, verifies durable identity and
reservation after death, and waits for the original writer's natural
60-second lease expiry before same-key recovery. It changes no timestamps
and uses no production test hook. These two cases are not an exhaustive
crash-at-every-publication-step sweep.

## What to do next

### 1. Publish the selector follow-up and classify platform timing

Push the reviewed selector follow-up to #239, send its
exact head and gate evidence, and monitor both platform jobs, including
their repaired skip censuses. Native stack 231 already places it above
#238. Keep the PR draft while release acceptance is incomplete. Re-baseline
this handoff after new CI evidence; do not carry an earlier run's result
as the new head's result.

The next hosted run includes bounded process observations beside the paired
soak. The sampler retains at most 128 observations at a 25 ms cadence within
a 3.2-second horizon, names truncation and joins before the pair is evaluated.
It watches fixed measurement, registry and gateway PIDs through the existing
process-info wrapper; no new FFI or VM-global monitor is installed. Both
conditions pay that diagnostic overhead. Process state, queue and GC counters
can suggest causes, not prove them; an absence of observed activity cannot
distinguish host descheduling from waiting on I/O. Preserve the workload and
assertion while classifying that evidence.

The next grouped shipped-client increment is successful A-to-B-to-A switching
with a peer still active on A and positive updates in both sessions. Existing
shipped bootstrap tests already prove concurrent startup convergence; repeat
that work only when joining it into the complete drive. Successful switching
with an in-process daemon and the owner-only live drive are earlier evidence,
not this missing distinct-principal shipped observation.

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
LOOM_BOOTSTRAP_E2E_SERVER="$PWD/bin/loomd" \
LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key \
LOOM_TEST_TIMEOUT_SECONDS=600 \
python3 scripts/with_timeout.py 900 -- make check dist e2e-client-bootstrap e2e-multiplayer soak-daemon
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
