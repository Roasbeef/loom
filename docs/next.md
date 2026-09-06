# Next

Read this first. This is the handoff for the single-daemon and multiplayer
work: the implemented boundaries, evidence from the shipped binary, and the
release gates deliberately left open. Rewrite it after the next completed
body of work. Commit and review history belongs in Git and the review records,
not in another chronological addition to this file.

Re-baselined on 2026-09-06 against `client/daemon-acceptance` at `854a3b7d`
and the subsequent CI corrections described below.
Claims below were checked against that tree, exact local command results,
or the named hosted run.
After the closing run failed, the owner authorized CI corrections and measured
verification. This includes the narrow Linux process-absence correction and
the explicit macOS advisory policy below, not further acceptance slices.

## Where the tree is

The [single-daemon plan](design-notes/single-daemon.md) numbers seven phases,
0 through 6. One daemon now manages sessions across workspaces. Restart
restores catalogue metadata; only authorized explicit selection opens a
runtime. The broader release acceptance is not complete.

| Body of work | Current state |
|---|---|
| Contracts and ownership, phases 0 and 1 | Protocols 014–016, reclaimable addresses, parked assembly and retained cleanup failures are implemented. Weft 0.4.4 is pinned. |
| Lifecycle and routing, phases 2 and 3 | Singleton startup, durable creation keys, bounded admission, lazy catalogue restore, current authority and credited snapshots are implemented. |
| TUI and domains, phases 4 and 5 | Shared durable state, principal attribution, invitations, revocation, presence and session switching have shipped-binary coverage. Network delivery remains client-driven reconciliation, not pushed token streaming. |
| Release acceptance, phase 6 | The closing local client gate passes. The last published platform gate failed; final-dependency resource proof, confinement and the remaining joined observations stay open. |

[PR #239](https://github.com/Roasbeef/loom/pull/239) targets
`client/daemon-review-fixes` ([#238](https://github.com/Roasbeef/loom/pull/238)),
above [#237](https://github.com/Roasbeef/loom/pull/237) in native stack 231.
All three are out of draft but remain unmerged. Review readiness does not
mean green CI or completed release acceptance. The integration worktree is
`.claude/worktrees/daemon-candidate`. Preserve the separate
`.claude/worktrees/single-daemon` tree and its excluded native-policy,
planner and protocol 017 edits; do not build them into this candidate.

### Corrections to the previous handoff

The previous edition accumulated individual test passes and described joined
shipped schedule coverage as missing. The new native schedule fixture now
proves Saved inactivity and once-only overdue resumption across explicit opens.
It does not prove recurring cursors, a detached future timer, or whole-VM
schedule recovery.

A shared answer appearing without another keypress is not evidence of server
push. The terminal's ordinary refresh can produce that result.
[Issue #240](https://github.com/Roasbeef/loom/issues/240) records the remaining
live-delivery design: push committed records to subscribed connections, stream
deltas to peers, and serialize concurrent submits instead of returning a busy
conflict. The [multiplayer architecture](architecture/multiplayer.md) states
the current pull-only boundary.

The HTTP fixture's socket handoff race is repaired at `ee7b5617`.
A worker could previously finish before Mist transferred its socket.
The repair parks it until transfer completes; no timer or dependency patch
was needed. macOS logged that race and still passed the shipped fixture,
so the race is not an established cause of Linux's missing tool marker.

Failure diagnostics also needed verification. An intentional exit-7 command
showed that one terminal sample after marker expiry was stale. Commit
`d8a128d2` refreshes and retains samples inside the unchanged 15-second
budget. Commit `c9e043de` then reduces the poll outcome before asserting:
EUnit prints a failed assertion's value, so retaining the full model there
could disclose fixture credentials. The final negative reports the actual
tool error and only a short assertion error. See the
[closing review](review/single-daemon-acceptance-closing.md).

### Verified results and their limits

The subsequent CI-correction gate exited 0 with **1,345 tests in 297.85
seconds**, with all five shipped fixtures enabled and the complete live-tool
suffix executed. Its strict census independently passed with only the
existing Darwin `/proc` prerequisite. Client lint and documentation checks
passed. The focused revised fixture passed in 8.24 seconds; a deliberately
noisy probe failed its intended bounded error in 0.82 seconds after helper
retirement, then the no-op was restored before the full gate.

The full client gate passed all **1,344 tests in 296.01 seconds**, with all
five shipped fixtures enabled. Its command exited 0; the strict skip census
independently exited 0 with only the declared macOS `/proc` prerequisite.
Client lint exited 0 with zero errors and 91 warnings. The documentation gate
also exited 0. This full gate includes `c9e043de` and the schedule candidate
before its final review and the observe-policy unit test. The subsequent
focused results below verify those closing changes; do not label that earlier
full gate as a run of every test in the final tree.

| Shipped fixture | What it proves |
|---|---|
| `tui_shipped_multiplayer_test` | Alice, Bob and Reader share exact durable records and authorship; configuration, presence, invitations, observer refusal, live revocation and refused/successful switches use real sockets. A jailed tool stays in A1 while A2 in the same workspace and B in another make progress. |
| `daemon_shipped_recovery_test` | Whole-VM loss after durable reservation preserves the original creation identity; metadata restoration does not initialize the reserved target. |
| `daemon_shipped_identity_recovery_test` | Whole-VM loss after SQLite identity publication preserves that identity and the original writer lease. Pending selection fails visibly; explicit recovery waits for the natural lease expiry. |
| `daemon_shipped_stop_test` | A's original provider socket closes, owner control observes Saved, B progresses on its original attachment, and explicit reopen resumes one durable user admission under a new incarnation. |
| `daemon_shipped_schedule_test` | An overdue configuration added while A is Saved does not run during B's progress. Explicit open fires it once; another reopen preserves the exact fired cell and message records. |

The final stop fixture at `5d1decf2` independently passed in **3.72 seconds**;
its five held-provider negative controls passed in **0.97 seconds**.
Request-count and closure observations reject evidence already recorded before
stop or reopen. They are not cross-sender linearization guarantees.

The schedule fixture independently passed in **3.48 seconds** through ordinary
configuration and the real scanner, without a scanner poke or injected clock.
Its read-only captures use existing generated SQL and retain the exact fired
cell plus every message variant. Final reviewed `aaa52741` passed in
**3.67 seconds** after type/prose corrections and an equivalent `result.map`
cleanup. All assertions were retained. A Held/Failed first scanner tick retries
after 60 seconds, beyond the fixture's eight-second terminal await, so a boot
transient fails loudly rather than passing or silently extending the test.

The reviewed observe-policy commit `39468f84` passed its policy regression and
the complete focused soak in both modes: default enforcement in **12.02 seconds**,
explicit observation in **11.92 seconds**. Observation emitted all 18 paired
timing lines. Its policy test still rejects an over-budget result in enforce
mode. Neither mode skips the soak or its correctness assertions.

The final marker diagnostic negative exited 1 in **21.06 seconds**, with the
intended exit-7 result and a short assertion value. An exact-value check found
no fixture owner credential in its log. Restoring the ordinary command passed
in **7.60 seconds**. The earlier large local failure log was restricted to its
owner and not shared. These fixture-only credentials are not production keys.

Concurrent native startup also has the existing bootstrap lifecycle fixture.
The [six mutation controls](review/single-daemon-mutation-gates.md) remain
separate evidence. Two owner-authenticated Herdr terminals used the Baseten
example, painted shared replies and switched/rejoined sessions before verified
daemon shutdown. That live drive used no tools and proves neither distinct
principal authority nor filesystem confinement.

### Hosted evidence

The first closing cycle finished red at `854a3b7d`. The owner then authorized
a test-only correction and another measured cycle; this is not a blind rerun
of the failed head. PR #239's verification section records the exact next
published head and terminal result. Do not call a queued or partial run green.

The correction probes the actual shipped helper under `serve.base_policy`
with a portable shell no-op. Only explicit enforcement degradation omits the
final live-tool section, with a visible marker and an ordinary-Linux-only
declaration. The delegated jail job now runs the same shipped fixture without
that declaration. The three initial opens get a named 20-second bound;
all turn, marker and cleanup bounds remain. macOS's existing latency
observation policy is unchanged. Neither correction diagnoses the macOS
opening delay or weakens the production sandbox.

| Head and run | Observed result |
|---|---|
| `de2fc5fd`, [34058458721](https://github.com/Roasbeef/loom/actions/runs/34058458721) | Repaired multiplayer passed: ordinary Linux ran four non-tool exchanges with the exact prerequisite marker; the delegated jail and macOS ran all eight. Jail's three censuses passed. Linux's strict native-departure check exposed `ESRCH`; macOS's separate in-process provider wait expired. Both had 1,344 client passes and one failure; their final censuses were skipped. Seeds passed. |
| `854a3b7d`, [34056261144](https://github.com/Roasbeef/loom/actions/runs/34056261144) | Linux's tool marker failed after explicit demanded-enforcement refusal. macOS's initial terminal opening exceeded eight seconds, cause unknown. Both reported 1,344 client passes and one failure; both final censuses were skipped. Jail and 200 seeds passed. Current 18 soak pairs per platform passed their numeric bounds, with all five-owner samplers completed. |
| `b0b4013a`, [34051513588](https://github.com/Roasbeef/loom/actions/runs/34051513588) | Linux failed the 15-second tool marker assertion. macOS failed paired latency, 506 ms against 342 ms. Each had 1,336 client passes and one failure; both final censuses were skipped. Jail and 200 seeds passed. |
| `37726c23`, [34050399218](https://github.com/Roasbeef/loom/actions/runs/34050399218) | Both platform check/bootstrap steps passed; later dependency resolution failed on Hex 502. Neither final census ran. Jail and 200 seeds passed. |
| `5df064c8`, [34046753887](https://github.com/Roasbeef/loom/actions/runs/34046753887) | All four jobs and both independently checked censuses passed. This older green head is not acceptance for later commits. |

The latest failing macOS pair measured baseline 46 ms (HTTP 7, subscribe 20,
drain 19) and stressed 506 ms (HTTP 88, subscribe 397, drain 21). Its twelve
credit waits were at most 6 ms. That `b0b4013a` run retained six macOS and
18 Linux pairs, with all five process samplers completed. Older cached fixture
reports were excluded.

B's storage actor appeared inside SQLite step during the slow subscription.
Those coarse counters do not time native calls, garbage collection or host
scheduling. Source tracing rules out full-history materialization in this
fixture: cycle five has four selected metadata cells and ten recent message
descriptors, with identical query work in both paired conditions. Those counts
are source-derived, not a hosted database census. Dirty-I/O scheduling is a
possible boundary, not a diagnosed cause. The explicit policy exception below
does not explain the delay.

The owner's closing decision, recorded in
[issue #241](https://github.com/Roasbeef/loom/issues/241), makes only the hosted
macOS paired-latency assertion observational through
`LOOM_SOAK_LATENCY_BOUND=observe`. The numeric budget, workload, JSONL and
sampler remain; a measured miss is logged rather than failing that job.
All other correctness assertions still gate, and the default/local/Linux
path continues to enforce the bound. This is an explicit gate-policy change,
not a performance fix or proof that the missed bound is met. Do not extend
that exception or infer a cause from the coarse counters.

Linux's native daemon log and tool result were not retained in that earlier run, so
the missing marker's cause remains unestablished. The new diagnostic makes a
future failed marker useful; it is not a claimed causal repair.

### Final process-observation and macOS policy corrections

The Linux target-stat reader now classifies `ESRCH`, like `ENOENT`, as
confirmed absence. Procfs can open a target entry before its task disappears;
the later read then reports no such process. Only that target read changes:
boot-id and self-stat reads, other errors and birth matching stay strict.
The shipped departure assertion is unchanged. The existing host package's
eight tests pass locally; its Darwin run does not exercise this Linux race.
The failed shipped run and the kernel's target-read semantics are the
regression evidence, not a deterministic injected test.

Under the owner's macOS relaxation, only hosted macOS's `make check` step is
now advisory (`continue-on-error`). Every test still runs and its log remains
an artifact. Bootstrap, Seatbelt checks, E2Es, documentation and the final
census keep their own failure verdicts. No additional test deadline changes.
[Issue #127](https://github.com/Roasbeef/loom/issues/127) tracks the separate
load-sensitive provider wait; [#241](https://github.com/Roasbeef/loom/issues/241)
tracks latency. A successful workflow under this policy does not establish
that the advisory package check passed. Inspect and report that step's actual
result separately. The next exact-head cycle is recorded on PR #239.

## What to do next

The closing scope does not start these follow-ups. Preserve their distinction
between a missing implementation, an unresolved design and missing evidence.

### 1. Add an explicit memory-off observation

[Issue #245](https://github.com/Roasbeef/loom/issues/245) records the smallest
follow-up, extending the existing shipped workload after native
retirement. Read the existing catalogue through a read-only URI and generated
`storage/sql.domain_page`; require its two workspace-private mappings and use
their persisted memory/digest paths, not guessed hashes. Require those outputs
to be absent and parse exact log event keys: positive daemon listening,
memory readiness and daemon stopped, but no `distillpass.started_event`.

Exit: the workload proves no distillation-start event or persistent output.
This does not prove that the explicit `remember` capability is unavailable,
and configuring distillation off alone is not the observation.

### 2. Design and implement live delivery, #240

[Issue #240](https://github.com/Roasbeef/loom/issues/240) is the next product
boundary, not a reason to call current reconciliation broken. Decide authority
revalidation for pushed records/deltas and visible ordering for concurrent
submits before changing those paths.

Exit: a shipped fixture admits two operators' concurrent prompts in the
chosen order, delivers records without client catch-up, streams to Reader,
and stops revoked delivery at the required authority boundary. It does not
silently relax membership or add a global command queue without a decision.

### 3. Adopt the SQLite retirement repair

Shipping resolves sqlight 1.2.0 and Hex esqlite 0.9.0, not the evaluated fork.
[Issue #247](https://github.com/Roasbeef/loom/issues/247) owns the release or
fork-publication decision and the prepared-statement busy-error limitation.
[Upstream esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105) remains
the repair to adopt. [ADR-002](adr/002-sqlite-binding.md) explains the build
constraint: an ordinary Gleam Git/path dependency does not build this Rebar
package. The preferred route is a patched native Hex release.

Historical evaluation observed 192 additional database/WAL descriptors over
16 cycles with the original binding and a stable 68 with the repair. These are
not the shipping artifact's guarantee.

Exit: the reproducible shipping dependency graph contains the fix, and
resource/release/platform checks pass on that graph. No cache patch, forced
collection, parallel package publication or source-built compiler workaround
is authorized by this handoff.

### 4. Resolve the remaining release evidence

The [acceptance drive](design-notes/single-daemon.md#the-acceptance-drive)
still requires the joined load/crash observations and application confinement.
Classify hosted latency using unchanged workloads and evidence attributed to
the exact run. [Issue #241](https://github.com/Roasbeef/loom/issues/241) tracks
the performance work needed to restore hosted macOS enforcement. Its design
options remain proposals, not measured repairs. Preserve named component tests
when composing a shipped drive.

Exit: each remaining requirement below has evidence for the final artifact,
with explicit platform limitations. Do not repeat already-proven startup,
invitation and live-tool scenarios as if they were wholly absent.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**One daemon, metadata-only restart.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) requires
explicit authorized opens. Listing and preview never resume work. Backwards
compatibility and legacy import were excluded.

**Retirement requires original evidence.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains the
native port until observed exit. Caller timeout, port closure and late
`noproc` do not prove transitive cleanup. Failed cleanup retains custody.

**Authority is server-owned and checked at use.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md) and
[016](../protocol-change/016-record-human-origin.md) define membership,
activation and human origin. Workspace memory is owner-private; sharing
requires session-only scope and explicit transcript acceptance.

**Uncertain mutation and durable recovery are different.**
[ADR-009](adr/009-record-terminal-attempt-custody.md) retains attempt identity;
[ADR-010](adr/010-retain-one-unsent-terminal-command.md) allows one unsent
command during reconciliation. A terminal never resends an uncertain mutation.
Runtime close does not abort its operation: a later explicit open can resume
durable intent, including another provider request for the one admitted turn.

**Production SQL is generated; connection policy is centralized.**
`make gen-sql` owns query outputs; `storage/sqlite_policy` owns shared
pragmas and typed overrides. Raw SQL is acceptable in tests. Process machinery
uses Weft; Erlang stays limited to necessary host operations.

## Deliberately open

None of these is unfinished work somebody forgot.

- **Native filesystem confinement, [#242](https://github.com/Roasbeef/loom/issues/242):** excluded PrivateScratch and application
  filesystem-dispatch work is unresolved. Membership does not prove a model
  cannot read daemon credentials or another workspace's database. Do not retry
  restricted native implementation through another worker or tool.
- **Shipped approval route, [#243](https://github.com/Roasbeef/loom/issues/243):** existing effect tests inject a narrower policy.
  Ordinary Bash allows and clamps to 600 seconds; no shipped configuration
  exposes the needed narrower wall budget. This is a product-policy gap, not
  permission to fake an approval or substitute a native execution error.
- **Joined authority/fault matrix, [#246](https://github.com/Roasbeef/loom/issues/246):** exact revocation between admission and
  delivery remains scripted-authority coverage. Cooperative stop is not an
  uncooperative drain or a process-kill test. Other publication-step crashes
  remain beyond the two shipped boundaries.
- **Pressure and scheduling, [#246](https://github.com/Roasbeef/loom/issues/246) and [#244](https://github.com/Roasbeef/loom/issues/244):** shipped maximum-image, rapid-switch and final
  dependency resource-load observations remain open. Recurring cursors,
  detached future timers, whole-VM schedule recovery and ambiguous-prompt
  acknowledgements are not covered by the new one-shot fixture.
- **Live delivery and memory off:** [#240](https://github.com/Roasbeef/loom/issues/240)
  is undesigned/unbuilt work; the explicit no-maintenance oracle in
  [#245](https://github.com/Roasbeef/loom/issues/245) is designed but unbuilt.
- **Toolchain freshness, [#248](https://github.com/Roasbeef/loom/issues/248):**
  Gleam 1.18.1's direct-path fingerprint handling causes repeated resolution;
  the upstream fix and release/source-build choice are recorded there. Do not
  disguise a Hex failure as a test failure or patch dependency caches.

## How to verify

Build the ordinary shipped prerequisites in this integration tree first.
Do not build the excluded native edits from the other worktree.

```sh
make binaries server-shipment
LOOM_BOOTSTRAP_E2E_SERVER="$PWD/bin/loomd" \
LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key \
LOOM_TEST_TIMEOUT_SECONDS=600 \
bash scripts/check.sh client
make lint-client
make doc-check
```

The complete release gate remains separate:

```sh
LOOM_BOOTSTRAP_E2E_SERVER="$PWD/bin/loomd" \
LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key \
LOOM_TEST_TIMEOUT_SECONDS=600 \
python3 scripts/with_timeout.py 900 -- \
  make check dist e2e-client-bootstrap e2e-multiplayer soak-daemon
```

**Capture each gate's own exit code.** A successful log tail is not a test
result. Freeze source during a gate and run the strict skip census on its
actual logs. macOS's declared `/proc` prerequisite skips the whole real-MCP
fixture before setup; it does not establish that exchange.

**Bound waits and keep notifications live.** Test wrappers enforce deadlines
and scoped idle-sleep prevention. The crash-recovery fixture intentionally
waits for the original 60-second writer lease; a timeout is failure, not drain
proof. Re-arm Substrate after notifications. See [execution.md](execution.md)
for the remaining operating hazards.
