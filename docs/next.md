# Next

Read this first. This is the handoff for the single-daemon, multiplayer and
background-jobs work: the implemented boundaries, evidence from the shipped
binary, and the release gates deliberately left open. Rewrite it after the
next completed body of work. Commit and review history belongs in Git and the
review records, not in another chronological addition to this file.

Re-baselined on 2026-09-08 against `origin/main` at `e167cbdd`, which carries
the whole per-session confinement wave (#319 through #328). Claims below were
checked against that tree, exact local command results, a named `signoff/linux`
run, or the pull request that landed them. The daemon acceptance material is
carried forward from the 2026-09-06 edition and was not re-measured; where it
names a run, that run is the evidence.

## Where the tree is

The [single-daemon plan](design-notes/single-daemon.md) numbers seven phases,
0 through 6. One daemon now manages sessions across workspaces. Restart
restores catalogue metadata; only authorized explicit selection opens a
runtime. The broader release acceptance is not complete. The background-jobs
plane is a separate body of work and it is finished.

| Body of work | Current state |
|---|---|
| Contracts and ownership, phases 0 and 1 | Protocols 014–016, reclaimable addresses, parked assembly and retained cleanup failures are implemented. Weft 0.4.4 is pinned. |
| Lifecycle and routing, phases 2 and 3 | Singleton startup, durable creation keys, bounded admission, lazy catalogue restore, current authority and credited snapshots are implemented. |
| TUI and domains, phases 4 and 5 | Shared durable state, principal attribution, invitations, revocation, presence and session switching have shipped-binary coverage. Network delivery now pushes: commit notices, presence and attachment leave the hub unsolicited, and concurrent prompts on one strand are queued rather than refused. See "Live delivery" below. |
| Release acceptance, phase 6 | The closing local client gate passes. The last published platform gate failed; final-dependency resource proof and the remaining joined observations stay open. Filesystem confinement is no longer among them. |
| Background jobs | Landed. The pure state, the actor, the model-facing surface, the shipped fixture and the step-scoped abort are all in the tree; issue #183 is closed by them. See "Background jobs" below for what each piece is and what proves it. |
| Per-session filesystem confinement, [#242](https://github.com/Roasbeef/loom/issues/242) | Done. The jail's base view is a minimal root on both platforms, the daemon's secrets are masked as a second layer, eleven self-test probes are required in CI, and a shipped fixture proves it against `bin/loomd`. See "Filesystem confinement" below. |

[PR #239](https://github.com/Roasbeef/loom/pull/239) targets
`client/daemon-review-fixes` ([#238](https://github.com/Roasbeef/loom/pull/238)),
above [#237](https://github.com/Roasbeef/loom/pull/237) in native stack 231.
All three are out of draft but remain unmerged. Review readiness does not
mean green CI or completed release acceptance. The integration worktree is
`.claude/worktrees/daemon-candidate`. Preserve the separate
`.claude/worktrees/single-daemon` tree and its excluded native-policy,
planner and protocol 017 edits; do not build them into this candidate.

### The merge gate runs locally now

The `main` ruleset requires a pull request and a `signoff/linux` commit
status, and that status is produced on a developer machine rather than by
waiting on hosted CI. [PR #308](https://github.com/Roasbeef/loom/pull/308)
added `scripts/signoff.sh`, which runs every CI command as six parallel lanes
on one checkout, reads a skip census over all of their logs using the hosted
jail job's declarations, and posts the verdict. On Linux it obtains a
process-empty cgroup v2 base without root by re-executing itself under
`systemd-run --user --scope -p Delegate=yes`, so the shipped fixtures that
demand helper enforcement run enforced rather than degraded. Every
gleam-invoking lane is wrapped in `.github/scripts/hex_retry.sh`.
`scripts/signoff_remote.sh` runs the same gate for a pushed HEAD on a Linux
box named only by `LOOM_SIGNOFF_HOST`, in a `loom-signoff` checkout the
script owns. `scripts/e2e_client_bootstrap.sh` is the former Makefile recipe
extracted so a lane and CI run the same file, and Go 1.26.3 is pinned by a
`toolchain` line in `packages/sandbox/go.mod`. The first real
`signoff/linux` status was posted on #308's own head by the script.

The measured shape of a warm run on a 32-core Linux box is about ten minutes
of wall clock. The critical path is entirely the client lane: the client
package suite takes about 390 seconds serially, and the bootstrap fixtures
run behind it in the same lane. Every other lane finishes inside three
minutes, the 200-seed soak and the enforcement self-test included; the self
test reported 9 of 9 layers enforced with no sudo at the time, and 11 of 11
today. The macOS lane on the
developer's Mac ran green in 573 seconds. Hosted CI keeps running as the
record, but nothing waits on it.

Running the whole suite under real bubblewrap is what the local gate proved
first, and it found bugs hosted CI could not see: the hosted Linux check
runner has no bubblewrap, so the helper runs degraded there, and Seatbelt
tolerates a missing path. Five defects and one gate race surfaced on the
first local runs. [#303](https://github.com/Roasbeef/loom/issues/303) was the
jail evasion test's own `unshare --fork`, which on util-linux before 2.38
inherits `SIG_IGN` for TERM; the cancel ladder under test was correct, and
the payload now traps with perl.
[#304](https://github.com/Roasbeef/loom/issues/304) was the extension
install's build plane inheriting the session policy's `.blobs` mask over a
path that never exists under a read-only parent; it now has
`serve.build_plane_policy` with no mask and a pure regression test.
[#307](https://github.com/Roasbeef/loom/issues/307) was four drifted
`serve.gleam` citations, which had left `doc-check` red on `main`.
[#306](https://github.com/Roasbeef/loom/issues/306), filing
[#305](https://github.com/Roasbeef/loom/issues/305), was the two-approvals
fixture pressing Esc before the inspector had opened; it now waits for the
overlay. [#310](https://github.com/Roasbeef/loom/issues/310) was the
code-mode test rig naming its scratch root `$HOME/.loom-cmtest/e2e-<fixed
name>`, shared by every checkout on a machine and deleted at each start, so
two concurrent checkouts corrupted each other's build root and failed the
manifest-hash reproducibility assertion; the root is now per-checkout by a
12-hex digest of the checkout path, kept short for the `sun_path` bound. The
sixth was a race in the gate itself rather than in the product: tui's
launch-lock test and the bootstrap fixtures both name scratch roots by the
millisecond, so they now run in one lane.

### Filesystem confinement

[Issue #242](https://github.com/Roasbeef/loom/issues/242) is done. The previous
edition listed it as item 1 under "What to do next" and as unbuilt under
"Deliberately open"; both are stale as of this one. Nine pull requests landed
between `c71dea4a` and `e167cbdd`:
[#319](https://github.com/Roasbeef/loom/pull/319),
[#320](https://github.com/Roasbeef/loom/pull/320),
[#321](https://github.com/Roasbeef/loom/pull/321),
[#322](https://github.com/Roasbeef/loom/pull/322),
[#323](https://github.com/Roasbeef/loom/pull/323),
[#325](https://github.com/Roasbeef/loom/pull/325),
[#326](https://github.com/Roasbeef/loom/pull/326),
[#327](https://github.com/Roasbeef/loom/pull/327) and
[#328](https://github.com/Roasbeef/loom/pull/328).

**What a session's jail sees on Linux.** The base view was `--ro-bind / /`,
which made `readable_roots` decorative and put every other workspace, every
other session's scratch and every credential on the account within a jailed
payload's reach. #326 replaced it with bubblewrap's own root tmpfs plus a
tolerant read-only bind of each system root in `SystemRoots`: `/usr`, `/bin`,
`/sbin`, `/lib*`, `/etc`, `/opt`, `/var/lib`, the resolver runtime directories
under `/run`, `/run/current-system` and `/nix/store`, each bound only when it
exists. On top of that come the policy's own readable and writable roots, the
`protected` masks, the policy's explicit mounts and the scratch tmpfs at
`/tmp`, in that order, and then `--remount-ro /` last so a payload cannot
create anything in the root itself. #328 removed the harness's remaining
`readable_roots: ["/"]`, so the narrowing is live rather than latent. What a
session's jail does not see is the rest of the account, other workspaces, and
other sessions' state.

**What it sees on Darwin.** #326 also replaced the Seatbelt profile's
unconditional `(allow file-read*)` with per-root subpath allows over
`DarwinSystemRoots` and the policy's own regions, so reads are an allowlist
there too. #327 added read-metadata on every proper ancestor of every granted
region, in both the policy's spelling and the symlink-resolved one, emitted
before the trailing protected denies so a protected ancestor still wins:
`realpath(3)` reads metadata up the whole path it canonicalizes, and the old
whole-host view had covered that incidentally.

**The daemon's secrets are the second layer, not the only one.** Every daemon
session's base policy masks the owner token, the catalogue, the session
databases, the lock and the invite material through
`serve.protecting_state_root`, and #319 extended those masks to the extension
install's build plane. Masking does not depend on where `--state-dir` points,
so it holds for a state root placed inside a workspace, which omission from a
minimal root would not. Both layers stay.

**The enforcement evidence.** `loom-exec --self-test` now runs eleven probes,
each declared `required` in `.github/enforcement-expectations`, which fails the
job when the run and the file disagree in either direction: `env not in
allowlist withheld`, `output flood truncated at cap`, `orphaned grandchild
reaped via pgroup`, `write outside writable_roots denied`, `protected path
masked from reads and writes`, `daemon state root unreachable from a session
jail`, `host path outside the mount plan unreadable`, `direct socket denied
under network off`, `fork bomb capped by pids limit`, `observed setsid escape
reaped`, and `unvetted beam denied host write, secret, and network`. The two
that this wave added are the last-named base-view probe and the state-root one,
and both run an unmasked control first (#320 for the state root, #326 for the
base view), so a jail that refuses everything cannot be read as a pass.

**The product-level proof** is
`packages/client/test/client/daemon_shipped_confinement_test.gleam` (#321). It
boots the shipped daemon on a fresh state root with two workspaces, creates
session B first so its database exists, then drives session A's jailed `bash`
tool at the owner token, the catalogue and B's database by absolute path, with
a positive read of a file the same tool wrote in A's own workspace. It asserts
on the secret rather than the error, because the platforms refuse differently:
a masked file on Linux is a `/dev/null` bind that reads as zero bytes, while on
Darwin the read is denied outright. Both databases are witnessed by their
SQLite header on the host before the negatives run, so a moved layout fails
loudly instead of passing for free.

**The zero-config defaults.** A session base is assembled rather than
configured. `serve.admitting_user_toolchains` binds a fixed set of well-known
per-user toolchain directories under `$HOME` when present, every entry
read-only and `MountOptional`; `protocol-change/020` lists them.
`serve.widening_path_dependencies` derives sibling checkouts from `gleam.toml`
`path =` dependencies, read-only and filtered to those outside the workspace,
the way linked worktrees are already derived from `.git`. A `[workspace]
mounts` line in the launch configuration is the escape hatch for what no
manifest describes, and it is the only source of write access outside the
workspace. The read-only ruling has one reason: the jail's `HOME` is
`<workspace>/.codemode/home`, so cargo, go, npm, hex, gleam and rebar already
write their caches under the workspace, and a read-write bind of `~/.cache`
would have helped no build while exposing the operator's account.

### Corrections to the previous handoff

The previous edition described background jobs as three pull requests in
flight with one open design contradiction. That is stale in both halves. Five
pull requests landed ([#260](https://github.com/Roasbeef/loom/pull/260),
[#263](https://github.com/Roasbeef/loom/pull/263),
[#267](https://github.com/Roasbeef/loom/pull/267),
[#266](https://github.com/Roasbeef/loom/pull/266) and
[#269](https://github.com/Roasbeef/loom/pull/269)), the contradiction is
settled by `broker.abort_step`, and the shipped fixture asserts the settled
behaviour rather than working around it. Do not plan jobs work from the
design note's work-package table; plan it from "Queued behind it" below.

The previous edition also did not know about the websocket admission bug that
[#268](https://github.com/Roasbeef/loom/pull/268) fixed. It is on `main` and
it is a ruling, not a patch; see "Rulings already made".

The earlier edition accumulated individual test passes and described joined
shipped schedule coverage as missing. The native schedule fixture proves
Saved inactivity and once-only overdue resumption across explicit opens. It
does not prove recurring cursors, a detached future timer, or whole-VM
schedule recovery.

The previous edition described [#240](https://github.com/Roasbeef/loom/issues/240)
as undesigned and unbuilt, and described network delivery as pull-only. Both
are stale: the ruling is `docs/design-notes/live-delivery.md`, the wire change
is `protocol-change/018`, and both halves are on `main`. See "Live delivery"
below for what landed and what it deliberately leaves open.

The caution that edition raised still stands and is worth keeping, because it
is what shaped the fixture. A shared answer appearing without another keypress
is *not* evidence of server push: the terminal's ordinary 250 ms refresh can
produce exactly that result, and it remains in the client as the recovery path.
Distinguishing the two is why `session_channel.Capture` records what asked for
each cut and why the shipped fixture reads that provenance rather than timing.

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

Every pull request in the confinement wave was merged on a green
`signoff/linux` run of its own head, and each such run includes the self-test
with its declared expectations. The recorded wall times are 445 seconds for
#319, 441 for #321, 447 for #322, 443 for #325, 440 for #326 and 451 for #328;
each PR's status names the exact run. The self-test reported 10 of 10 probes
enforced before #326 and 11 of 11 after it. On macOS the evidence is local
rather than hosted: `make check`, `make e2e`, `make e2e-codemode`, the
bootstrap fixtures and `make selftest` (11 of 11) were run on the developer's
Mac for #326 through #328.

The gate itself was noisy on 2026-09-08. #327 went red four times before a
green run: `client@history_test` twice, `daemon_shipped_recovery_test` failing
`await_resident` with `Error(Disconnected)`, and a conformance soak
`routing_test` storm retry ladder. A baseline dry run on `origin/main` went red
once (`serve_test`) and then green, which is what separates gate flakiness from
the change under test. Client timing was unchanged at roughly 220 seconds
throughout. All of it is recorded on
[#324](https://github.com/Roasbeef/loom/issues/324); do not read a single red
run in this window as a regression without repeating it.

Three things the wave does **not** prove. The minimal root has not been
exercised against a Nix wrapper tree or an asdf-shim `gleam` layout;
`protocol-change/020` records both as gaps, and an asdf shim gets a
`MountRequired` refusal naming the directory rather than a working jail,
because resolving a shim means reading a script and the harness has no
`read_link`. The Darwin `realpath` regression that #327 fixed is not
discriminated by `a_real_jailed_build_installs_test` in
`packages/client/test/client/extension_test.gleam`, which still fails on macOS
for reasons the wave did not establish; the discriminator is the Go unit test
`TestSeatbeltCanonicalizesInsideAGrantedRoot` in
`packages/sandbox/internal/jail/seatbelt_darwin_test.go`, which fails on the
head before #327 with the same error the build reported and passes after it.
And nothing here proves anything about a build cache shared between sessions,
which is deliberate; see the ruling below.

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
also exited 0. Those numbers predate the jobs stack and the socket admission
fix; they are the daemon acceptance evidence, not a count of the current tree.

| Shipped fixture | What it proves |
|---|---|
| `tui_shipped_multiplayer_test` | Alice, Bob and Reader share exact durable records and authorship; configuration, presence, invitations, observer refusal, live revocation and refused/successful switches use real sockets. A jailed tool stays in A1 while A2 in the same workspace and B in another make progress. |
| `tui_shipped_live_delivery_test` | Two native terminals and one raw v2 wire client. The wire client submits on a strand already running and is answered `queued`, which only a client that tracks no liveness can reach; both terminals accumulate two or more pushed stream fragments prefixing the answer before its entry exists in that terminal's cut, a count the one-fragment snapshot preview cannot reach; both terminals' `Model.notices` rise by at least the four records the two turns commit; the wire client's own `catch_up` reassembles to the same durable records; a member revoked mid-answer loses his socket at the per-frame authority check and no frame follows the close. Added with #240; not part of the counts above. |
| `daemon_shipped_recovery_test` | Whole-VM loss after durable reservation preserves the original creation identity; metadata restoration does not initialize the reserved target. |
| `daemon_shipped_identity_recovery_test` | Whole-VM loss after SQLite identity publication preserves that identity and the original writer lease. Pending selection fails visibly; explicit recovery waits for the natural lease expiry. |
| `daemon_shipped_stop_test` | A's original provider socket closes, owner control observes Saved, B progresses on its original attachment, and explicit reopen resumes one durable user admission under a new incarnation. |
| `daemon_shipped_schedule_test` | An overdue configuration added while A is Saved does not run during B's progress. Explicit open fires it once; another reopen preserves the exact fired cell and message records. |
| `daemon_shipped_jobs_test` | The background-jobs plane end to end. Three scenarios, described under "Background jobs" below. |
| `daemon_shipped_confinement_test` | A jailed tool in session A obtains neither the owner token, nor the catalogue, nor session B's database, by absolute path, while a positive read of a file it wrote in its own workspace returns the per-run marker with a zero status. Added with #321; not part of the counts above. |

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
daemon shutdown. That live drive used no tools and proves no distinct
principal authority; filesystem confinement is proved separately by
`daemon_shipped_confinement_test` and the self-test probes.

### Hosted evidence

The merge gate this section describes as the thing to wait on is
superseded by the local signoff above; hosted runs remain the record and
the historical evidence below, but no merge waits on one.

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

## Background jobs

A job is a jailed process the harness starts on the model's behalf that
outlives the tool call which started it. It is bounded by a wall fixed at
start, owned by a strand, observable through a bounded rolling tail plus a
full spill, and killable through the same TERM-then-KILL ladder a cancelled
foreground call climbs. The design and every ruling behind it are in the
[design note](design-notes/background-jobs.md); the mechanism as the effect
plane sees it is in [effects.md](architecture/effects.md#background-jobs).

### What landed and where

**The actor and one runner per job.** `client/jobs.gleam` is a `weft/actor`
in `client/serve`'s *restartable* services tier beside `extension_hosts`,
bound to a reclaimable `weft/registry` address so a replacement answers where
the original did and no caller caches a subject. Each job gets a plain weft
task of its own, and that task — not the actor — calls `broker.clear_call`.
Both reasons come from the broker's own contract: `clear_call` waits out a
full helper pool in the caller's process, and an actor blocked on congestion
could not answer a poll; and the relay monitors the caller and cancels the
execution when that process dies, so the caller has to be a process that
lives exactly as long as the job. The runner folds the `CallOutput` stream
and reports the outcome; the actor writes the terminal fact only when that
outcome arrives, because a weft outcome is reported once the worker has
exited, so the scope's exit is the drain proof. The task is plain rather
than managed: a managed task exists to witness owners a worker discovers
while it runs, and this one discovers none.

**The durable record.** Each job is a `job/<id>` register in the session
store, a key prefix inside the existing `fact.custom` namespace, so it cost
no protocol change. It is the tenth reserved corner in `runtime/api.gleam`
and is written only through `put_reserved_fact_expecting`; creation uses the
expect-absent CAS, so two incarnations racing to start the same job cannot
both land. The lifecycle and the codec are pure in `client/jobstate.gleam`,
property-tested with no process. A restart never re-adopts: a job's process
is a child of a helper and the helper is a child of the VM, so the
replacement actor's first act, before it serves one request, is to sweep
`job/*` and commit `Lost(VmRestart)` for everything still live. It holds
those records in memory so a later poll answers `Lost` rather than
`NotFound`, which is reserved for "no such job, or somebody else's".
`OwnerRestart` exists in the vocabulary and is never reported; telling the
actor's first start from a supervisor restart needs state that outlives the
actor and dies with the VM, bought for a word nobody branches on.

**The bounded tail and the per-stream spill.** `client/jobtail.gleam` is a
pure, UTF-8-safe rolling window with a monotone byte cursor: `push` appends
and drops from the front past the cap, `since(cursor)` returns what arrived
after the cursor plus the new cursor, and a cursor that predates the retained
window is answered with a `dropped` count rather than a silent skip. Eight
KiB is retained per stream. The whole of each stream goes to its own staging
file under the blob root while the job runs and is promoted to a
content-addressed ref at termination, recorded in the terminal fact and read
with `fs_read`. There are two staging files rather than the one the design
note imagined, because `JobSpill` has a field per stream and one file for
both would have had to interleave them. A boot that finds a staging file with
no live job unlinks it.

**One door, two model-facing surfaces.** `client/jobseam.Door` is the whole
of what the model can reach, and it is the only enforcer of four things: the
per-strand ceiling, the wall clamp, ownership, and the `job/<id>` fact
writes. `client/jobtools.gleam` translates between the actor's vocabulary and
the tools' one. Above it, `tools/job.gleam` carries `job_poll`, `job_kill`
and `job_send`, and `tools/bash.gleam` gains `mode`, a two-variant type whose
`background` arm admits a job and returns the handle at once. Beside it,
`cap/job.gleam` is `job.start`, `job.poll`, `job.list`, `job.kill` and
`job.send` as typed Gleam a vetted program calls. The capability routes
`ServedHere` in `codemode/workspace.gleam` rather than as a jailed
`ClearedCall`, because the harness actor answers it and only the job's own
process is jailed, and it sits on `default_cap_modules` and nowhere else so
the `{cap/report}` intersection with the orchestration modules still holds. A
job started from a tool call and one started from a program are the same
record with the same owner, and either surface polls or kills what the other
started, because ownership is the strand.

**A hook may not start one.** An extension invocation whose origin is
`hosts.HookEvent` is handed `workspace.no_jobs()` in
`client/extension/dispatch.gleam`. A hook's operation is the single
session-long operation minted for every hook in the session: nobody sees it
as a running step, so nobody can abort it, and a `context` hook calling
`job.start` on each event would leave hour-long processes owned by `main`
that the model never asked for and cannot find. The capabilities stay routed,
so a hook that asks reads that reason rather than an unknown-capability
denial. `docs/architecture/extensions.md` carries the ruling.

**The ceilings.** Four non-terminal jobs per strand, refused in band the way
the orchestration seam refuses `spawn_ceiling`. There is no session-wide
limit in this cut; the design note records the pool arithmetic instead of
pretending it away. The wall defaults to one hour and is clamped to one hour,
and `[jobs].max_wall` in `loom.toml` — in seconds, parsed beside the other
known tables in `client/catalog.gleam` and read in `client/serve.gleam` —
raises that ceiling and cannot lower it, because a lower ceiling is what the
session's own sandbox policy already expresses. A caller that asks for longer
than the ceiling is given the ceiling and told what it got in
`Started.wall_ms` rather than refused. The deadline is fixed at start and
never renewed, and its four enforcers cannot disagree because all four read
one number: the capability token, the relay's receive deadline, the helper's
own wall timer, and the budget ledger.

**A step-scoped abort, and what it spared.** A job clears under
`{op_id, "job/" <> id}` — the operation that started it, and a synthetic step
naming the job — so a foreground `bash` earlier in the same batch cannot cap
it and a second job in the batch is not refused outright. Keeping the
operation half put the job in reach of a sweep nobody meant it to be in reach
of: a code-mode teardown used to reap its satellite with `broker.abort` on
the whole operation, so a job started from a program read `Lost(HelperLoss)`
the moment the program returned. `broker.abort_step(op_id, step_id:)` is the
narrowing. It revokes exactly that pair's tokens, cancels its actives and
drops its ledger, and the two teardown sites in `codemode/satellite.gleam`
and `codemode/launch.gleam` now call it on the run phase's own step. It needs
a sweep counter of its own beside the operation's, and a clearance is judged
against the **sum** of the two, because a step abort that bumped the
operation's counter would refuse a resumed clearance of every sibling step,
including the detached job it exists to spare. The step in that sweep is
still the batch's, so a teardown reaps the batch's other tool calls exactly
as the operation-wide abort did. ADR-005's second addendum carries all of it.

**The operator's abort still reaches a job.** `broker.abort` is unchanged, so
aborting the operation that *started* a job kills it, which is what an
operator asking for that means. The wiring has two halves and only one is the
runtime's: the `abort` command commits the cancel marker and stops the
strand's live effects through `api.abort`, and a detached job is nobody's
live effect, so the hub also sweeps the effect plane through
`gateway.Options.effect_abort`, which `client/serve` fills with
`broker.abort`. The host has to join the two, because `runtime` may not
depend on `broker` and only the broker holds the other half of the ledger.
The reach is bounded by that door and the bound is worth stating: `abort`
names the strand's *current* operation, so it kills the jobs of the turn
still running. A job started two turns ago outlives its operation by design,
and the operator stops it with `job_kill` or by ending the session.

### How it is verified

`packages/client/test/client/daemon_shipped_jobs_test.gleam` is the
acceptance evidence, and it runs for real in two places: the macOS gate, and
the Linux jail job's *Shipped background jobs with delegated enforcement*
step, which is the only run that exercises the pid namespace. On a host
without demanded enforcement — the ordinary Linux gate — the whole file
declines with one declared reason (`.github/declared-skips-linux-gate`).

Three scenarios. The first is the motivating case: a scripted turn backgrounds
`tail -f build.log`, the fixture appends three lines from outside the jail,
the next turn's poll is shown those three lines and nothing else with the job
still pending, a kill produces a terminal state naming the owner and carrying
the helper's `cancelled` witness, and the payload is proved gone. The second
drives the same door from code mode through a real hermetic build and a real
jailed satellite: one program starts a job and returns its id, a later program
in its own execution finds that record under that id **and in `running`**, and
kills it. That `running` reading is the whole of what the scenario found the
first time it ran, and reverting either teardown site to the operation-wide
abort and rebuilding the shipment kills it. Note the rebuild: the fixture
drives `bin/loomd`, so a mutation left in the sources alone passes. The third
SIGKILLs the VM and proves the sweep commits `Lost`, the model's own poll
reads it, and nothing is respawned.

How the payload's departure is proved is a property of the host, and the
fixture decides it once in `PayloadIdentity`. Under `HostPid` — Darwin, where
the jail has no pid namespace — the payload publishes its own host pid and
the fixture qualifies it by birth, exactly as the recovery fixtures qualify a
VM. Under `NamespacedPid` no number a payload writes names a host process, so
it writes none and the proof is the daemon's terminal record plus the jail's
containment. The fixture fences the payload itself rather than its group;
here they are one process, because the command `exec`s into `tail`.

What the fixture deliberately does not cover is the operator's abort. Every
turn it drives runs to completion, so by the time the fixture can send a
command the operation that started the job has closed. `client/jobs_test`
pins that path instead, with the real hub over the session's real open
operation and only the broker scripted.

Below it: `client/jobstate_test` property-tests the pure lifecycle and the
codec, `client/jobtail_test` the bounded window and its `dropped` reports,
`client/jobs_test` the actor (ceiling, deadline, cancel ladder, restart reap,
the operator's abort), `tools/job_test` the tool surface and its refusal
codes, `codemode/workspace_test` the five capability routes and their row
decoding, and `broker/broker_test` the step sweep itself —
`abort_step_reaps_one_step_and_spares_the_rest_test` and
`an_abort_step_during_a_congestion_wait_spares_the_sibling_test`.

### Queued behind it

None of these is blocking, and each is small enough to do alone.

- **Collapse `client/jobtools` into a tools-vocabulary door.** It exists only
  to translate between `client/jobs`' vocabulary and `tools/job`'s. The
  actor's vocabulary came first because WP2 had to name the states before a
  tool surface existed to name them for. If `jobseam` spoke the tools
  vocabulary directly, as `client/scheduleseam` does, one of the two
  translations disappears. Deferred because it is a rename across a working
  surface with no behaviour behind it, and the fixture that would catch a
  mistake is the expensive one.
- **Evict terminal `Held` entries from the actor's table.** The actor keeps
  every record it has decoded, deliberately, so a poll can answer `Lost`
  rather than `NotFound`; nothing evicts a terminal one. A long session
  accumulates them without bound. Deferred because the fix needs a retention
  rule that says what a poll of an evicted job should read, and inventing one
  before anybody has seen the growth is the wrong order.
- **Give `LossReason` a variant for a helper's own failure cause.** A settled
  `broker.CallFailed` carries an `ExecFailure` and `client/jobs` drops it,
  committing `RunnerLost(HelperLoss)`, which says the helper went away and
  nothing about why. That is the one loss a model might act on differently.
  Deferred because it changes a durable codec, so it wants doing once with
  the right variant set rather than twice.
- **Measure `cap/job`'s prelude cost.** Tool-surface cost is arithmetic paid
  on every request of every strand; the capability prelude's is paid on every
  code-mode build, on every host, whether or not the program mentions jobs.
  Nobody has measured what these five operations added. Deferred because it
  is a measurement, and the answer might be that there is nothing to do.
- **Size a dedicated job pool if the shared one starves.** A running job
  holds one helper for its whole life out of a pool of four to sixteen, and
  sixteen strands each holding four jobs would exhaust the largest pool. The
  design note records the arithmetic and deliberately waits for real use
  rather than pre-building a second pool; this is the one question its review
  left open.
- **Put `job_output` on the event bus once
  [#240](https://github.com/Roasbeef/loom/issues/240) lands.** The runner
  already folds the `CallOutput` stream in one place, so a live event is one
  more subscriber rather than a new mechanism. It was deferred because under
  pull-only delivery it would have been inert; #240 has landed, so the reason
  for the deferral is gone and this is now ordinary queued work.

## Live delivery

[Issue #240](https://github.com/Roasbeef/loom/issues/240) is done. The shipped
daemon no longer serves every terminal by pull, and the previous edition's
"undesigned/unbuilt" entry for it is wrong as of this one.

### What landed and where

The ruling is [`docs/design-notes/live-delivery.md`](design-notes/live-delivery.md)
and the wire change is
[`protocol-change/018`](../protocol-change/018-pushed-delivery.md), ACCEPTED.
Four pieces, all additive:

- **The daemon announces.** `client/serve` starts a `commit_forwarder` per
  session hub and subscribes the writer to it, so a commit reaches the hub at
  all, and it nests the two provider taps — `tap_provider` around
  `tap_preview_provider` — so every token is teed to the hub as a
  `ProviderDelta` while the bounded preview survives as the catch-up
  fallback. `client/gateway` lifts the network guard on `pull_and_broadcast` and
  `broadcast_delta`, primes its high-water under network delivery, and splits
  `send_to` on the *envelope*: an envelope with a `reply_to` keeps the bounded
  reply path, one without goes through `deliver`, which is the per-frame
  `check_binding` that path has always run. There is no second authority path
  and no second size bound — a pushed `committed` frame carries a seq and a
  strand, not the record.
- **The socket writes.** `client/daemon/session_socket` registers a real sink
  and gains one `Push` signal; a failed pushed write stops the socket exactly
  as a failed reply does.
- **Concurrent prompts are ordered.** A `prompt` on a busy strand is held in
  the hub's per-strand FIFO and answered `mutation_outcome {status:
  "queued"}`, then submitted with its own submitter's recorded origin when the
  run settles. Four deep per strand; a fifth gets the `conflict` the command
  used to answer with.
- **The terminal accepts what it did not ask for.** `tui/session_wire.decode`
  gained a `Pushed` outcome, `tui/session_channel` turns a notice into an
  immediate catch-up (deferred to the next `Ready` while a request is in
  flight) and records *why* it asked, and `tui.Model.last_capture` keeps that
  reason on the capture that painted something. Every notice is separately
  reported as `Update.Noticed` before the lane decides whether to capture, and
  `tui.Model.notices` counts them: which capture painted is a race with the
  idle refresh, whereas the arrival of the frame is not. A queued prompt
  renders as a booked turn rather than a refusal.

### How it is verified

`packages/client/test/client/tui_shipped_live_delivery_test.gleam` is the
shipped fixture, in `make e2e-client-bootstrap` after the multiplayer one and
therefore in both `e2e-client-bootstrap (linux)` and `e2e (macos)`. Two
native terminals and one raw v2 wire client, against the built `bin/loomd`
and a paced loopback provider, prove five things: a second operator submits
on a strand that is already running and is told `queued`; both terminals
accumulate at least two stream fragments prefixing the answer while no entry
for that answer exists in their cuts, which a credited cut cannot produce
because the snapshot preview projects as one fragment however many tokens it
holds; both terminals' `Model.notices` rise by at least the four records the
two shared turns commit; the two terminals and the wire client's own
`catch_up` hold identical durable records with the two human turns attributed
to the two different operators; and a member revoked mid-answer loses his
socket at the per-frame check, after which the socket produces no frame at
all.

Three fixture-shape notes a later reader will want. Bob is a wire client and
not a terminal because the queue is reachable only from a client whose view
of the strand is stale, which a terminal on a pushing daemon is not for long:
it would send `steer`, for which there is no `queued` acknowledgement. Live
delivery is counted rather than read off `last_capture`, because which capture
painted an answer is a race with the 250 ms idle refresh — a legitimate path
that, when its catch-up is already in flight, paints first and leaves the
notice to be dropped as naming a sequence already held. And
`provider_http.Paced` exists only so that an answer occupies an interval
— without it there is no moment in which a fragment exists and its entry does
not. `docs/architecture/multiplayer.md` has the fixture's full account.

The gateway's own tests cover the queue bound, drain failure and the decoder;
the fixture deliberately does not repeat them.

### Deliberately open

Three, and each is recorded in the design note rather than only here:

- **A durable queue.** A held prompt does not survive a hub restart. Making it
  durable needs a pending-run operation in `machine` — a new operation kind, a
  new state space, and a durable object whose only reader is a convenience.
  The reply says `queued` and not `admitted` precisely so a client is written
  against a queue a restart drops.
- **Registry-pushed revalidation.** Pushed delivery re-checks authority per
  frame, as replies do. The registry-pushed revision from the review wave
  stays deferred; the measurement that would reopen it is the soak showing the
  per-frame cost. With the delta tee wired that cost is now one registry call
  per pushed delta per peer, so the soak is measuring a per-token rate rather
  than a per-commit one.
- **Retiring the snapshot preview.** Once every shipping terminal consumes
  pushed deltas the `tap_preview_provider` lease machinery is redundant. It
  stays until a release has been cut with both, because it is the catch-up
  fallback for a terminal that attaches mid-answer.

Two cosmetic terminal windows are named in
[PR #276](https://github.com/Roasbeef/loom/pull/276)'s description and were
left alone on purpose, because both close at the next capture: fragments of
an operation that started after the cut in flight was taken are repainted
from the commit, and a finished operation's thinking stream can outlive its
successor's first text by one refresh.

## What to do next

Preserve the distinction these items draw between a missing implementation,
an unresolved design and missing evidence. The order below is a
recommendation, not a dependency chain, except where it says so.

### 1. Take #85's remaining prerequisites

[Issue #85](https://github.com/Roasbeef/loom/issues/85)'s first prerequisite
was per-session confinement, and that is now done, so the rest of its list is
what stands between the tree and an honest VM driver, in its own order: make
the enforcement vocabulary driver-scoped or negotiate it in `hello` (with
[#64](https://github.com/Roasbeef/loom/issues/64)), then settle the
shared-versus-copied workspace question, and only then a vsock `Transport`
variant.

The item to resist is writing the transport first. It produces a driver that
works in a demo and misreports its own enforcement, which is the one failure
mode this codebase has consistently refused to ship.

Exit: each prerequisite is settled where it lives — a protocol change, a
design-note ruling, or an ADR — before any VM transport code exists. `#85` is
`phase:debt`; nothing in the release acceptance waits on it.

### 2. Write a daemon-level deterministic-simulation script

The multiplayer acceptance drive names convergence properties that no shipped
fixture reaches, because each is a crash or a race at a point a scripted turn
cannot stop on. Four are worth a script: a crash between creation and
publication replayed with the same creation key, a restart with a lifecycle
request already pending, an approve/deny race that must settle on exactly one
winner, and a revocation with a command already queued behind it.

Scope it as a multi-session script over the real writer, in the existing
runner rather than a second one, and leave the enforcement and resource
observations where they are: those are shipped fixtures against `bin/loomd`
and a simulation cannot make the kernel claim. Read
[`docs/architecture/simulation.md`](architecture/simulation.md)'s "What this
does not cover" first. It is the honest account of what the runner is: message
interleaving is not controlled, so a seed can interleave differently on two
runs and both must converge, and `control.attempt` still holds a real
millisecond budget as a deadlock backstop. A convergence property is exactly
the shape that survives those limits; a timing property is not.

Exit: each of the four properties is a named scenario with a seed, the runner
reports a violated one with its `[timing]` and `[verdict]` annotations, and
the acceptance drive's convergence half cites the script rather than a manual
drive.

### 3. Fix the history-index flake under the parallel runner

[Issue #324](https://github.com/Roasbeef/loom/issues/324) is
`client@history_test` failing under `LOOM_TEST_PARALLEL=8` on the local Linux
gate, a different case each time and clean on every immediate re-run. It cost
real time in this wave: the 2026-09-08 burst put #327 red four times and #323
red once, and separating it from the change under test needed a baseline dry
run on `origin/main`. The issue records the suspects (a shared scratch path
named by the millisecond, a `persistent_term` slot, an SQLite file left open by
a sibling) and the two native signal deaths seen alongside it.

Exit: the issue's own acceptance — `history_test` and `memory_lifecycle_test`
pass twenty consecutive runs under `LOOM_TEST_PARALLEL=8` on the Linux gate, or
the shared resource is named and the module is in `scripts/serial-tests` with
that reason.

### 4. Close the daemon domain-teardown admission window

The registry fences a workspace domain when its last dependent retires and
keeps the fenced slot in its book until the witness exits. Every admission
naming that domain in the window is refused `unavailable`, which is a real
refusal of a legitimate open. The shipped schedule fixture now works around
it by waiting on the daemon's own domain census as a second barrier after
`Saved`, and `stop_saved` in `daemon_shipped_schedule_test` says so. That is
a fixture paying for a product behaviour. The clean fix is queueing the open
on the closing slot so the caller waits rather than being refused.

Exit: an explicit open naming a domain in `DomainClosing` is admitted once
the witness exits, without the caller polling a census; the schedule fixture
drops its second barrier and still passes.

### 5. Take the two jobs-plane cleanups

The `jobtools` collapse and the terminal `Held` eviction above. Both are
contained, both are in one package, and doing them while the plane is fresh
is cheaper than doing them after the next reader has learned the current
shape. The `LossReason` variant can ride with them if the codec change is
taken at the same time.

Exit: `client/jobtools` is gone or is only what `scheduleseam`'s translation
is; the actor's table has a stated retention rule with a test; `make
check-client` and `make lint-client` pass.

### 6. Add an explicit memory-off observation

[Issue #245](https://github.com/Roasbeef/loom/issues/245) records the smallest
daemon follow-up, extending the existing shipped workload after native
retirement. Read the existing catalogue through a read-only URI and generated
`storage/sql.domain_page`; require its two workspace-private mappings and use
their persisted memory/digest paths, not guessed hashes. Require those outputs
to be absent and parse exact log event keys: positive daemon listening,
memory readiness and daemon stopped, but no `distillpass.started_event`.

Exit: the workload proves no distillation-start event or persistent output.
This does not prove that the explicit `remember` capability is unavailable,
and configuring distillation off alone is not the observation.

### 7. Adopt the SQLite retirement repair

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

### 8. Resolve the remaining release evidence

The [acceptance drive](design-notes/single-daemon.md#the-acceptance-drive)
still requires the joined load/crash observations. Its confinement
requirement is met; see "Filesystem confinement" above.
Classify hosted latency using unchanged workloads and evidence attributed to
the exact run. [Issue #241](https://github.com/Roasbeef/loom/issues/241) tracks
the performance work needed to restore hosted macOS enforcement. Its design
options remain proposals, not measured repairs. Preserve named component tests
when composing a shipped drive.

Exit: each remaining requirement has evidence for the final artifact,
with explicit platform limitations. Do not repeat already-proven startup,
invitation and live-tool scenarios as if they were wholly absent.

### 9. Declare the sequential groups the parallel test flag needs

[PR #309](https://github.com/Roasbeef/loom/pull/309) added an opt-in
`LOOM_TEST_PARALLEL=N` to `scripts/test.sh`, which wraps the runner's test
list in an EUnit `inparallel` group. The ordering pushes down to individual
tests rather than stopping at the module boundary, so N counts tests and no
module is internally sequential. [The design
note](design-notes/parallel-tests.md) carries the timing table and the census
of what breaks, grouped by the resource each failure collides on: the
VM-global atom counter that three `runtime` tests assert does not move, the
capability channel's single `persistent_term` slot that every fake-channel
test in `cap` and `ext` writes, the shared `httpc` profile behind `provider`
and `broker`, the broker scratch directory one test asserts is empty while
its siblings write policy files into it, and four tests whose fixed
wall-clock deadlines fail under load without colliding on anything.

The recommended next step is a declared per-package sequential group, an
EUnit `inorder` group nested inside the `inparallel` one, for the modules
that touch VM-global state, plus a private `httpc` profile for `provider`,
a per-helper tmp root for the broker emptiness assertion, and rewriting the
four fixed-deadline tests to wait on their observable rather than on a
duration. The expected result is a client lane near three minutes and a
whole Linux gate near four. This is queued behind the owner's ruling on the
serial-group pattern; do not encode a default N before that ruling.

Exit: the sequential groups are declared beside the packages they belong to,
`make signoff` runs the client lane with the flag on, and no test buys its
green run with a longer sleep.

### 10. Three small follow-ups from the confinement wave

None of these blocks anything and each is a paragraph of work.

- **`scripts/signoff_remote.sh` does not forward `SIGNOFF_PARALLEL`.**
  `scripts/signoff.sh` exports it as `LOOM_TEST_PARALLEL`, defaulting to 8, but
  the remote wrapper passes nothing, so `SIGNOFF_PARALLEL=1` on the developer's
  machine does not reach the box. That mattered during the #324 investigation,
  where a sequential run was the evidence being sought. It is being fixed;
  check before redoing it.
- **The per-session cache overlay is deliberately not built.** It was
  considered as a way to keep one session's cache writes invisible to another,
  and `protocol-change/020` settles it by removing the premise: with every
  per-user entry read-only, there is no write for an overlay to isolate. Reopen
  it only alongside a decision to grant write access outside the workspace.
- **The `ext install` state-root residual is closed.** The previous edition
  recorded that the install infers the state root as the parent of its
  extensions root, so a daemon started with `--state-dir` elsewhere left the
  live token unmasked in the build jail. `serve.build_plane_policy` builds on
  `policy.workspace_default` and never grants `readable_roots: ["/"]`, so under
  the minimal root a state root the install did not guess is outside the view
  entirely. It is closed by omission, which is what the wave predicted, and it
  needs no second guess at the path.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**The merge gate is local, and its status is only ever posted by the
script.** A pull request is still required by the `main` ruleset and stays
required with signoff in place, because the PR is the paper trail. The
`signoff/linux` status attests that a named person ran the gate and nothing
more, so it is posted only from `scripts/signoff.sh`'s verdict; never type
`gh signoff` by hand. The Linux lane is the required status; macOS stays
advisory until its lane has a flake-free record. No machine, hostname or
address for a signoff runner enters the tree: the host lives in
`LOOM_SIGNOFF_HOST` and in the developer's ssh config.

**The jail's base view is an allowlist.** `protocol-change/020` replaced
`--ro-bind / /` with a root tmpfs plus explicit binds, and replaced Seatbelt's
unconditional `(allow file-read*)` with per-root subpath allows. A denylist
over a shared account has no closing condition; an allowlist covers what nobody
thought to name. `/` is remounted read-only last so a payload cannot create
anything in the root itself.

**A `readable_roots` of `/` still means the host view, and that is the
compatibility tie.** An older harness sending `["/"]` outranks the tmpfs and
rebuilds the whole-host view, reported as `base=host-view` in the audit where
the minimal base reports `base=minimal`. That is why #326 could land before
#328 with no version bump; `packages/sandbox/CLAUDE.md` states it at the
mechanism.

**`protocol-change/004` is ACCEPTED with two amendments, made before it
landed.** `kind` is dropped, because its three values rendered identical argv,
and `required` is a two-variant `MountRequirement` rather than a naked `Bool`,
which lint R9 rejects. Editing a PROPOSED, unimplemented proposal is not silent
drift; the never-edit rule protects accepted decisions. #322 carries both.

**There is no `GrantMount`.** A mount composes as the meet like every other
policy field, so a tool asking for one the base does not carry produces a
narrowing and an in-band refusal. Adding a grant would have put mounts on the
escalation path and tangled #242 with
[#243](https://github.com/Roasbeef/loom/issues/243)'s open question about which
principal a shared daemon prompts. #243 stays independent and can be decided
later without reopening any of this.

**A mount may not overlap a `protected` path, and duplicates are refused at
validation.** bwrap and Seatbelt resolve an overlap in opposite directions, so
rather than pick one, `validate` on both sides refuses a mount that covers or
is covered by a protected path, a duplicate mount path, a trailing slash and a
`..` segment. Merging happens earlier, at assembly: `serve.merging_mounts`
collapses mounts that several sources derived to the same exact path, which is
what a Homebrew or `~/.local/bin` gleam produces. Merge at assembly, refuse at
validation; #322 and #328 carry the two halves.

**The per-user toolchain set is read-only.** The jail's `HOME` is under the
workspace, so every build already writes its caches there; a read-write bind of
`~/.cache` would have helped no zero-configuration build while giving a session
write access to the operator's account. `~/.local/share` is out of the set
entirely. Write access outside the workspace comes from a `[workspace] mounts`
line an operator wrote, and nowhere else. `protocol-change/020` carries it.

**`gleam` is mounted by its binary's directory, `erl` by its install prefix.**
A cargo-installed `gleam` would otherwise bring `~/.cargo/credentials.toml`
into every jail, while an ERTS `ROOTDIR` really is the region `erl` needs to
boot, and discovery prefers the emulator the daemon itself runs on so the
heuristic is the fallback that does not fire.

**Darwin grants read-metadata on every ancestor of every granted region.**
`realpath(3)` reads metadata up the whole path it canonicalizes, so a nested
readable root was granted while the path to it was not. Existence and mode of
a directory whose name the payload already has is not a secret, and Linux
exposes the same shape because bwrap creates mountpoint parents in the root
tmpfs. The grants sit before the trailing denies, so a protected ancestor still
wins. ADR-006's addendum and #327 record it.

**The helper's own bind is skipped when the view already covers it.** Stage two
re-executes the helper inside the jail, so its binary is part of the view, but
binding it unconditionally turned the workspace's `bin/loom-exec` into a
read-only mountpoint under the dogfooding arrangement. #326 records the
measurement at the code.

**One daemon, metadata-only restart.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) requires
explicit authorized opens. Listing and preview never resume work. Backwards
compatibility and legacy import were excluded.

**Socket admission is a handler turn, and a deferred transfer owes a
barrier.** mist starts every websocket process with a hard 500 ms initializer
budget it does not expose, and a missed budget kills the process together
with its TCP socket, which the peer reads as an abrupt close rather than a
refusal. Admission is two cross-actor calls whose own budgets total six
seconds, so it cannot live there: `on_init` mints its subjects, sends itself
`Admit`, and returns, and the permit transfer and gateway attach run on that
message. mist hands over the socket and calls `set_active` only after the
initializer returns, so `Admit` is queued before the peer can deliver a byte.
Deferring the transfer costs one thing the initializer gave for free: the
upgrading HTTP process releases its reservation the instant the upgrade
returns and then exits, and `root.transfer` refuses a reservation whose HTTP
owner has released it. So the websocket process signals a subject owned by
the HTTP process as soon as the transfer has been attempted, and the HTTP
process waits on that signal before releasing. It is a consumed reply from
the one process that sends it, not a cross-sender ordering assumption. The
two invariants are written into `packages/client/CLAUDE.md`; the mechanism
and the mist internals are in `client/daemon/session_socket.gleam`'s module
doc. [PR #268](https://github.com/Roasbeef/loom/pull/268) is the change, and
`admission_slower_than_the_initializer_budget_still_serves_test` is the
regression, which suspends the hub with `erlang:suspend_process` so the delay
is exact on a sixteen-core laptop and a three-core runner alike.

**A routine teardown does not borrow the operator's reach.** A code-mode
satellite is reaped with `broker.abort_step` on its own step, never
`broker.abort` on the operation, because a background job clears under a
sibling step of that operation and is meant to outlive it. `broker.abort`
keeps its meaning for the operator. The step sweep counts separately and a
clearance is judged against the sum of the two counters. ADR-005's second
addendum records it; reverting either teardown site fails the shipped
fixture's second scenario, but only after a rebuild of `bin/loomd`.

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

- **Two host layouts the minimal root does not handle:** an asdf-shim `gleam`
  gets a `MountRequired` refusal naming the directory rather than a working
  jail, because resolving a shim means reading a script and the harness has no
  `read_link`; the remedy is an explicit `[workspace] mounts` line. A Nix
  wrapper tree, where `code:root_dir()` is `.../lib/erlang` and the `erl`
  script's shebang and libc live outside it, is recorded the same way. Both are
  in `protocol-change/020`, and neither has been run.
- **Running the filesystem tools as a jailed payload** is not #242 and was not
  taken with it. It is #85's shared-versus-copied workspace question, a much
  larger change to `tools`. The design pass of 2026-09-08 also found a
  resolve/open race in `tools/fs.*` while looking at it, a harness-side path
  check followed by a harness-side open that a symlink swap defeats; that
  belongs on an issue of its own and has not been filed.
- **Shipped approval route, [#243](https://github.com/Roasbeef/loom/issues/243):** existing effect tests inject a narrower policy.
  Ordinary Bash allows and clamps to 600 seconds; no shipped configuration
  exposes the needed narrower wall budget. This is a product-policy gap, not
  permission to fake an approval or substitute a native execution error. It
  applies to a job's start unchanged, since a job admits under exactly the
  rules a foreground `bash` does.
- **Joined authority/fault matrix, [#246](https://github.com/Roasbeef/loom/issues/246):** exact revocation between admission and
  delivery remains scripted-authority coverage. Cooperative stop is not an
  uncooperative drain or a process-kill test. Other publication-step crashes
  remain beyond the two shipped boundaries.
- **Pressure and scheduling, [#246](https://github.com/Roasbeef/loom/issues/246) and [#244](https://github.com/Roasbeef/loom/issues/244):** shipped maximum-image, rapid-switch and final
  dependency resource-load observations remain open. Recurring cursors,
  detached future timers, whole-VM schedule recovery and ambiguous-prompt
  acknowledgements are not covered by the new one-shot fixture.
- **Live delivery's three remainders:** a durable queue for held prompts,
  registry-pushed revalidation in place of the per-frame check, and retiring
  the snapshot preview. [#240](https://github.com/Roasbeef/loom/issues/240)
  itself is done; see "Live delivery" above and the design note for why each
  of the three was left.
- **Memory off:** the explicit no-maintenance oracle in
  [#245](https://github.com/Roasbeef/loom/issues/245) is designed but unbuilt.
- **The release-versus-transfer barrier has no unit test.** The regression
  that exists covers a slow *gateway attach*, by suspending the hub. Covering
  the barrier itself needs a slow `root.transfer`, which means a fake root
  the socket tests do not have today. The path is exercised in every shipped
  daemon fixture and the five-second wait is only ever paid in full on a
  doomed path, so this is a coverage gap rather than an untested behaviour.
- **The jobs follow-ups** listed under "Queued behind it" above, each with
  the reason it was deferred. None gates anything.
- **Converting an overrunning foreground call into a job** is the second half
  of #183 and was deliberately not taken. The approval that admitted a
  bounded call did not admit an unbounded one, so conversion needs either an
  explicit opt-in on the call or a policy rule, and neither was obvious
  enough to settle alongside the first cut.
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

Signing off is a separate command and it is the one the merge waits on:

```sh
make signoff SIGNOFF_ARGS=--dry-run
LOOM_SIGNOFF_HOST=<ssh alias> make signoff-remote
```

The first runs every lane on this platform and posts nothing. The second
pushes nothing for you, so push the branch first: the remote box fetches by
SHA and `gh signoff` refuses a commit no remote holds. Per-lane logs land
under `build/signoff/`, and the lane table printed at the end says which to
read. The Linux box must run the compiler CI builds, the Gleam 1.18.1 tag
plus the fix commit named by `GLEAM_PATCHES` in `.github/workflows/ci.yml`;
the released compiler re-resolves path dependencies through the Hex API on
every invocation and seven lanes at once meet the per-address rate limit.

**Capture each gate's own exit code.** A successful log tail is not a test
result. Freeze source during a gate and run the strict skip census on its
actual logs. macOS's declared `/proc` prerequisite skips the whole real-MCP
fixture before setup; it does not establish that exchange.

**Rebuild the shipment before trusting a shipped fixture.** These fixtures
drive `bin/loomd`, not the freshly compiled tree, so a mutation left in the
sources alone passes. The jobs fixture's second scenario is the case that
proved it.

**Bound waits and keep notifications live.** Test wrappers enforce deadlines
and scoped idle-sleep prevention. The crash-recovery fixture intentionally
waits for the original 60-second writer lease; a timeout is failure, not drain
proof. Re-arm Substrate after notifications. See [execution.md](execution.md)
for the remaining operating hazards.
