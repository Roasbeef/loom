# Draft issue breakdown

**Draft. Nothing here has been created.** No issue, milestone, or label
exists on GitHub; this document proposes them so the owner can cut, merge,
and re-rank before anything is filed.

Sources: `docs/spec-gaps.md` (the triage tables), the Part 4 status column
and §5.1 of `docs/loom-implementation-spec.md`, `docs/review/m4-triage.md`,
`docs/review/m5-agent-comms-judgment.md`, `.github/`,
`docs/design-notes/compaction-and-memory.md`,
`docs/design-notes/orchestration-comparison.md`, and `docs/code-tour.md` §17.

---

## The milestone

**Name: `v0.1 — claimed and true`.**

Shipping v0.1 does not mean new capability. M1 through M4 are all recorded
partial, and the release is the work of making those four rows read `done`
under Part 4's own rule — demonstrated by a test or a live run, not under
test-supplied hooks, and not on a host that could not enforce what it
claims. Concretely that means compaction runs in production rather than in
the demo's own hooks, some production path raises an escalation, a green
code-mode run proves the jail engaged, the TUI's end-to-end drives the real
server, and `make check` passes on both platforms §0.3 names. Everything
beyond those rows — the orchestration seam, role routing, the promotion
ladder, memory — is out.

**Closing criterion.** Every acceptance criterion in the M0–M4 rows of Part
4 is demonstrated, the "What the rows still owe" section is empty for those
rows, and `gate-linux`, `gate-macos`, and `jail-linux` are all green on
`main` with `gate-linux` set as the required check. macOS passing means the
suites run or skip for a declared reason; it does **not** mean a macOS jail
exists (§5.1, and "Not in the first release" below).

---

## How I grouped, and why

The twenty orphans in `spec-gaps.md` are not twenty issues. They land in ten
places, and six of them land in the same one.

- **Six one-line amendments become one housekeeping issue** (#9). M2
  integration 1, WP-K 1, WP-A 7, WP-I 7, WP-L 6 and M2 integration 2 are
  all "add a sentence to a normative document". They share a reviewer, a
  branch, and an afternoon. Filing them separately would produce six cards
  whose combined diff is smaller than one of the real issues below.
- **Four wiring-seam items become one issue** (#11). M3 runtime wave 11,
  12, and 13 and WP-L 8 are all decisions about `client/wiring.request_target`
  and the config `client/serve` builds around it: which identity gets
  committed, which role gets dispatched, whose `thinking` wins, and where
  per-identity model facts come from. Fixing any one of them opens the same
  function. Splitting them guarantees three merge conflicts.
- **Two api-shaped gateway duplications become one issue** (#14). WP-L 2
  and WP-L 3 are both "the gateway reimplements what `runtime/api` should
  expose".
- **Two provider stubs become one issue** (#16). WP-F 6 and WP-F 7 are both
  "an adapter ships a placeholder and the spec names the real thing
  elsewhere".
- **Three "a suite does not fail when it should" findings become one issue**
  (#6). The dropped steer under lease theft, the 108-byte `sun_path` limit
  in the code-mode test rig, and M0's printed-not-asserted p50 are three
  different files, but they are one failure mode, and it is the exact
  failure mode `.github/workflows/ci.yml` was written to close. One person
  fixing all three keeps the argument in one place.

Against that, four things get their own issue because the work genuinely
diverges: the macOS blocker (#2), compaction C0 (#3), the production
escalation raiser (#4), and the satellite enforcement report (#5). Each has a
different owner-shaped question, a different package, and a different test
that proves it.

**Four items are decisions, not tasks** (D1–D4). They are recorded as work,
but the work is trivial once the question is answered and unspecifiable
until it is. Filing them as tasks would hand an implementer a policy call.

**The shape of the plan: sixteen issues and four decisions.** Ten issues and
two decisions (D1, D3) sit in the `v0.1` milestone; six issues and two
decisions (D2, D4) sit outside it.

---

## Labels

| Label | For |
|---|---|
| `release-blocker` | in the `v0.1` milestone |
| `kind:bug` / `kind:feature` / `kind:decision` / `kind:housekeeping` | what the issue is |
| `kind:security` | touches the sandbox, the broker, or the policy path |
| `area:sandbox` `area:broker` `area:runtime` `area:client` `area:provider` `area:codemode` `area:events` `area:conformance` `area:ci` `area:docs` | package or surface |
| `owner-action` | cannot be done by an agent; needs a human with repo admin |

---

## Issues in the milestone

### 1. Set `gate-linux` as the required status check on `main`

**Problem.** CI landed in `fb3005e`, and nothing enforces it. A gate that
does not block a merge is a report, not a gate.

**Why it matters.** Every other issue in this milestone is verified by that
job. Until it is required, "the milestone is done" rests on someone
remembering to look.

**Done.** Branch protection on `main` requires `gate (linux)`; the other
three jobs stay advisory (`gate-macos` until #2 lands, then it joins).

**Pointers.** `.github/workflows/ci.yml`, header comment: "Only `gate-linux`
is meant as the required status check for merging."

**Labels.** `release-blocker`, `owner-action`, `area:ci`

---

### 2. Make `make check` pass on macOS

**Problem.** `gate-macos` is red and expected to stay red. `loom-exec` has
no jail for darwin, so it refuses to serve without `--allow-unenforced`
(`packages/sandbox/internal/jail/platform.go`), and nothing on the Gleam
side can pass that flag: `broker/exec.SpawnConfig` has no field for extra
helper arguments. Four suites spawn the real helper and treat a helper that
will not start as a failure — `broker`'s and `tools`' integration tests
panic outright; `conformance`'s and `codemode`'s end-to-end rigs assert
their way to the same place.

**Why it matters.** §0.3 defines a work package as done when its exit
criteria pass in CI on Linux *and* macOS. That sentence has been unmet since
WP-A. It is also the only red job in the tree, and a permanently red job
stops being read within a week.

**Done.** `gate-macos` is green. Two halves, and the second needs a design
call worth making explicitly in the issue:

1. `SpawnConfig` grows a field for extra helper arguments, and the wiring
   passes `--allow-unenforced` on a platform the helper reports as
   *unsupported* (never on one it reports as *degraded* — that distinction
   is the whole point of the split).
2. The four suites either run unenforced under that flag, or skip with a
   declared reason. If they skip, `.github/scripts/skip_census.sh` must
   learn to tell a declared platform skip from an undeclared one —
   `.github/enforcement-expectations` is the precedent for how to declare
   it, and the same rule should apply: a skip that stops being necessary
   must fail the job.

**Pointers.** `.github/workflows/ci.yml` (`gate-macos`, and its comment
naming the four suites), `packages/sandbox/internal/jail/platform.go`,
`packages/sandbox/cmd/loom-exec/main.go`, `broker/exec.SpawnConfig`,
`packages/broker/test/broker/integration_test.gleam`,
`packages/tools/test/tools/integration_test.gleam`,
`packages/conformance/test/support/jail.gleam`,
`packages/codemode/test/support/rig.gleam`, `.github/scripts/skip_census.sh`.

**Labels.** `release-blocker`, `kind:bug`, `area:ci`, `area:sandbox`,
`area:broker`

---

### 3. Make compaction live in production (stage C0)

**Problem.** `client/serve` installs `runtime/effects.default_hooks()`: the
threshold never fires, every structural decision declines, and
`client/wiring.dispatch` settles a `SummaryRequest` as an in-band
"structural summaries are not wired to a provider surface yet". The
compaction visible in `make check-client` is `client/demo`'s own hooks
answering with a canned string. An overflowing production run dies.

**Why it matters.** M3's row claims "fork + compact live". The branch index
already assumes compaction happens — it bounds its divergence copy at the
newest compaction on the path — so this is not only a context feature.
`runtime/hooks` is a real registry with no caller outside tests.

**Done.** Stage C0's exit criteria, verbatim from the design note: the M3
demo passes with `demo_hooks` deleted; a conformance scenario drives
threshold, overflow-retry and manual `Compact` end-to-end including
kill/recover mid-compaction; `make e2e` shows a session crossing the
threshold, compacting, and continuing.

**Note.** An implementation is landing in parallel across `packages/client`,
`packages/prompt`, and `packages/runtime`. File this as the issue that
*closes* on those exit criteria rather than as fresh work, and sequence #8
after it — both edit `client/serve`.

**Pointers.** `docs/design-notes/compaction-and-memory.md` Part 0 and Part
5 stage C0, `client/wiring.build_effects`, `runtime/effects.default_hooks`,
`runtime/hooks`, spec Part 4 M3 note, §5.1 "a production hook registry".
This also discharges the summaries half of spec-gaps M2 integration 3,
whose recorded home is M5 — see the judgment note under #11.

**Labels.** `release-blocker`, `kind:feature`, `area:runtime`, `area:client`

---

### 4. Raise escalations from a production path

**Problem.** No production path raises an escalation. `tools/tool.refusal_outcome`
turns a broker denial into an ordinary in-band `is_error` result carrying
the wanted grants, and the durable escalation record the approve/deny
commands act on is written only by `client/demo` and the simulation surface.
Where the gateway does raise, it raises through the unscoped
`api.raise_escalation`, whose approvals no clearance will ever load. And in
code mode every clearance the pipeline makes passes `grants: []`, so an
approved denial widens nothing.

**Why it matters.** The machinery beneath the raiser is real and tested —
call attribution, single consume by CAS, structural validation of the
approved subset. The raiser is the missing link, and without it the whole
approval path is dead code. Both M2's and M4's Part 4 notes cite it.

**Done.** A production tool call refused by policy raises a scoped record
through `api.raise_escalation_for`; an operator approval is consumed by that
exact call's clearance; a code-mode execution re-run under an approved
escalation actually carries the grants. `make e2e` covers the round trip.

**Blocked by D1** — the shape of "raises" (always, or only under an
interactive session policy) is a policy call, not an implementation detail.

**Pointers.** spec-gaps WP-L 1 and WP-J 15; `docs/code-tour.md` §17;
`tools/tool.refusal_outcome`, `runtime/api.raise_escalation_for`,
`client/demo`, `conformance/simulation/surface`.

**Labels.** `release-blocker`, `kind:feature`, `kind:security`,
`area:runtime`, `area:client`, `area:codemode`

---

### 5. Carry the satellite's enforcement report in every code-mode outcome

**Problem.** `satellite` reports enforcement only on `CallExited`, and
`destroy` aborts the operation as soon as the outcome arrives. A healthy run
therefore reports the build's layers and nothing for the node, so the tool
says — honestly — that a stage which made no report is not a claim it was
confined.

**Why it matters.** M4's row is accepted on a green run that does not prove
the jail engaged. It is also the first item WP-N sequences before the
orchestration seam, on the grounds that an orchestrator is the first thing
anyone runs unattended.

**Done.** The report is carried in `Ran` (or emitted on the abort path), so
every code-mode outcome including the happy path carries it, asserted by
`make e2e-codemode` — which is WP-N's own exit wording.

**Pointers.** spec-gaps WP-J 14; spec Part 2 WP-N, second bullet; spec Part
4 M4 note; `packages/codemode`, `packages/cap`.

**Labels.** `release-blocker`, `kind:bug`, `kind:security`, `area:codemode`,
`area:sandbox`

---

### 6. Stop three suites reporting something other than what they prove

**Problem.** Three unrelated files, one failure mode.

1. **A dropped steer under lease theft.** `conformance/simulation/surface.apply`
   calls `api.steer_quietly` and discards the `Result`; `api.enqueue` retries
   only `tx.StaleExpectation`, so a stolen lease returns `CommitFailed`, the
   steer vanishes, and the transcript diverges by one turn. Reproduced on
   seed 264 against the pre-refactor planner, so it is a harness fault, not a
   planner one.
2. **A 108-byte `sun_path`.** In an agent worktree the code-mode test's cap
   socket path measures 119 bytes and every code-mode test fails with
   `einval`. The production launcher already names execution directories by
   a short digest and refuses an oversized path in band; the test harness
   does not, so the failure reads as a code fault.
3. **M0's p50 is printed, not asserted.** The SQLite perf smoke test prints
   2.6 ms against a 5 ms target. A regression would not fail the gate.

**Why it matters.** `soak-short` now runs 200 seeds on every pull request.
A rare red in an otherwise deterministic suite is the worst kind, because it
trains a reader to re-run rather than look. And (3) is the same mechanism
the CI commit was written to close: a check that cannot fail is not a check.

**Done.** The simulation honors the result (or `enqueue` retries
`CommitFailed` the way it retries `StaleExpectation`); the code-mode test
harness uses the launcher's digest naming or refuses with the launcher's
worded reason; the p50 target is asserted.

**Pointers.** spec-gaps "planner navigability pass" items 1 and 2; spec Part
4 M0 note; `conformance/simulation/surface`, `runtime/api.enqueue`,
`packages/codemode/test/support/rig.gleam`,
`packages/conformance/test/conformance/storage_suite_test.gleam` (the p50
report).

**Labels.** `release-blocker`, `kind:bug`, `area:conformance`, `area:runtime`

---

### 7. Drive the real TUI against the real server in a test

**Problem.** M3's row reads "TUI thin client drives everything via
protocol". As built, the two ends are pinned to one fixture corpus and the
TUI's own end-to-end runs against a Go fake gateway. `make dev` attaches the
real TUI to the real server, but a human drives it; no test does.

**Why it matters.** A fake on both sides of a protocol proves the fixture,
not the protocol. Of M3's three recorded shortfalls this is the cheapest to
close and the one most likely to catch a real drift.

**Done.** One end-to-end that starts `client/serve`, attaches the real TUI
binary, drives a turn and a fork through it, and asserts on the transcript.

**Pointers.** spec Part 4 M3 note; `packages/tui`, `client/serve`,
`scripts/dev.sh`.

**Labels.** `release-blocker`, `kind:bug`, `area:client`, `area:conformance`

---

### 8. Root the session tree under an application supervisor

**Problem.** Close is a controlled crash: the otp static supervisor offers
no graceful external shutdown, so `api.close` kills the tree and releases
the lease. WP-E recorded this as acceptable "until a long-lived host
exists". `client/serve` is now that host.

**Why it matters.** A server whose only shutdown path is killing its own
supervision tree is fine in a test and wrong in production. Commits are
atomic so durable state is safe; the objection is operational, not
correctness.

**Done.** The session tree roots under an application supervisor; `serve`
shuts a session down without a crash; the lease is released on the way out.

**While you are there.** `gateway.default_options` sets `bus: None` and
`serve` never supplies one, so `bus.publish` has no caller outside the
package's own tests and the writer's post-commit publication is production's
only hint source. Decide whether `serve` should supply a bus, or record that
the writer path is the design.

**Sequence after #3** — both edit `client/serve`.

**Pointers.** spec-gaps WP-E 3; `docs/code-tour.md` §17;
`runtime/supervisor`, `client/serve`, `client/gateway.default_options`.

**Labels.** `release-blocker`, `kind:bug`, `area:runtime`, `area:client`

---

### 9. Land the six normative amendments the gap log names

**Problem.** Six recorded items are each one sentence in a normative
document, and none is scheduled.

| Item | The amendment |
|---|---|
| M2 integration 1 | §0.2's time-injection rule must state that one clock — or one era — is injected across runtime, tools, and broker. Found live: misaligned eras made the broker refuse every call as past deadline. |
| WP-K 1 | Promote the catch-up frontier rule to a §0.2 convention: a projection catch-up reading more than one scan must bound every scan by a frontier sequence read before the first. |
| WP-A 7 | Restate WP-A's "≥95% branch coverage on decoders" in terms something can check. No Gleam coverage tooling exists; the real compensation is adversarial corpora plus per-variant property tests. |
| WP-I 7 | Decide whether the tool timeout ceiling is the tool-side clamp (600 s max, 120 s default) or session policy. The entry deferred it to runtime wiring, which has landed. One §3 line. |
| WP-L 6 | Address queued-versus-placed acks in the protocol document's reply table. |
| M2 integration 2 | Define a wire mapping for `stream_options`, or remove it. The runtime carries a bag the provider request cannot express and the wire drops it. **Removal is an amendment; mapping needs a `protocol-change/` proposal**, since §1.5 is frozen. |

**Why it matters.** Six of the twenty orphans, closed in one branch. Two of
them (the clock era, the frontier rule) are load-bearing rules discovered by
a live failure and currently recorded only in a gap log nobody reads before
writing code.

**Done.** The six edits land; the six entries move to settled in
`spec-gaps.md`; §5.1's count drops from twenty to fourteen.

**Labels.** `release-blocker`, `kind:housekeeping`, `area:docs`

---

### 10. Run the two sandbox probes the jail runner can now afford

**Problem.** Two things M2 owes were deferred for want of a kernel, and
`jail-linux` now supplies one (bubblewrap installed, AppArmor's userns
restriction lifted).

1. The hostile-satellite tabletop's kernel half — a hostile `.beam` loaded
   directly, bypassing vetting, reaches nothing on the filesystem or the
   network.
2. The `setsid` escape probe, which WP-H's exit list names and which has no
   implementation at all.

**Why it matters.** M4's row is accepted with the tabletop's kernel half
outstanding, and M2's with a named probe missing. Both are now cheap.

**Done.** Both run in `jail-linux` and appear in the self-test's enforcement
matrix, so `.github/enforcement-expectations` covers them.

**Not in scope.** The `Proxy` non-allowlisted-host probe, which needs the
egress sidecar — out of this release, see below.

**Pointers.** `docs/review/m4-triage.md` "Still deferred to a target-tier
kernel"; spec Part 4 M2 note; `.github/workflows/ci.yml` (`jail-linux`);
`packages/sandbox/internal/selftest`.

**Labels.** `release-blocker`, `kind:security`, `area:sandbox`, `area:ci`

---

## Decisions

Filed as decisions because the answer is the work. Each names its options;
none should be handed to an implementer unanswered. D1 and D3 carry
`release-blocker`; D2 does not, and D4 sits with the out-of-milestone issues
below because it scopes M4.5.

### D1. When does a policy refusal become an escalation?

Today a broker denial is rendered as an in-band tool error carrying the
wanted grants, and no escalation record is written. Options:

- **(a) Never.** In-band refusal is the whole story; delete the raiser path
  and let `approve`/`deny` serve operator-initiated widening only. Cheapest,
  and makes the approval machinery's existence hard to justify.
- **(b) Always raise, and keep the in-band error.** Every denial writes a
  scoped record; the model sees the refusal immediately and an operator may
  approve out of band, with the re-execution carrying the grants. Most
  faithful to design §5.3; risks a record per refusal in a loop.
- **(c) Raise under an interactive session policy only.** A session flag
  decides. Adds a policy field, and a second code path to test.

Blocks #4. Note the two-directional fail-safe already built underneath: a
lost consume race drops the grants and the call clears under base policy; a
crash after consumption spends the grant without executing.

**Labels.** `release-blocker`, `kind:decision`, `kind:security`

---

### D2. Promote the citation checker to error level?

`scripts/doc_check.sh` resolves each source citation — a path with a line
number after a colon — and confirms the backticked symbol named just before
it still sits within a few lines. At the time of writing it reports 473
citations, 444 resolving, 151 symbol-checked, and 72 drifted — nearly all in
review documents, which record what was true at a commit. It is a warning
while the backlog stands. Options:

- **(a) Stay a warning.** The drift list is the work queue for
  `/doc-gardening`; nothing regresses silently because staleness already
  warns.
- **(b) Exclude `docs/review/**` and promote the rest to error.** Review
  documents are historical records and arguably should not be re-pinned at
  all; the remaining backlog is small enough to clear in the same branch.
  This is the option I would take.
- **(c) Clear all 72, then promote everything.** Most honest, most work, and
  re-pins documents whose value is being a snapshot.

**Labels.** `kind:decision`, `area:docs`, `area:ci`

---

### D3. Per-execution cgroup limits: accept the gap, or build delegation?

`internal/cgroup.Detect` returns the helper's *own* cgroup as the base, and
`Setup` writes `memory.max`/`pids.max` in a child of it. Those files exist
only if the base lists the controllers in `cgroup.subtree_control`, and
cgroup v2 forbids a non-root cgroup from having both member processes and
enabled controllers. So the helper gets a usable hierarchy only in the true
root cgroup — not the shape a systemd host, or a GitHub runner, puts it in.
`.github/enforcement-expectations` records this as a `known-gap`, and that
file's own rule says moving a probe there is "a deliberate reduction in what
CI proves". Options:

- **(a) Accept it.** Memory and pid ceilings are best-effort outside a
  delegated hierarchy; say so in `packages/sandbox/CLAUDE.md` and the design
  doc, and stop implying otherwise.
- **(b) Take a delegated hierarchy as configuration.** The operator (systemd
  `Delegate=yes`, or a container runtime) hands the helper a cgroup path it
  owns; `Detect` uses it when present and reports honestly when absent.
  Makes the limits real in the shape production actually runs.
- **(c) Move base-cgroup creation into the broker**, which spawns the helper
  and could place it. Largest change; puts a kernel concern on the Gleam
  side of the trust boundary.

This is release-scope because M2's row cannot honestly read `done` while a
layer the design names is structurally unreachable in production — but the
answer may legitimately be (a).

**Labels.** `release-blocker`, `kind:decision`, `kind:security`,
`area:sandbox`

---

## Issues outside the milestone

### 11. Settle the wiring seam's four model-routing questions

Four recorded items all live in `client/wiring.request_target` and the config
`client/serve` builds around it:

- **The fallback chain is never walked** (M3 runtime wave 11). `request_target`
  always returns `ForResolved`, because recovery must re-dispatch exactly
  what was committed. The chain tail is parsed, validated, and inert — while
  `effects.md`, the design doc, and `docs/examples/loom.toml` all read as
  though it engages. Resolving it means committing the *role*, or having
  recovery consult the chain in force at commit time.
- **Only `main` is dispatched on** (M3 runtime wave 12). `subagent`, `plan`,
  `summarize`, and `vision` rows are parsed, validated, registered, and
  select nothing.
- **A catalogue entry's `thinking` never reaches the wire** (M3 runtime wave
  13). `request_target` overwrites it on both branches. Either it is the
  default a strand overrides, or it should be refused the way `headers` is.
- **Off-route model facts fall back** (WP-L 8). A strand switched by
  `set_config` to an entry its role does not resolve to does overflow
  arithmetic against the wiring config's fallback context window.

M5 owns the first two; the last two are orphans whose proposed home is M5.
They should move together.

**One judgment worth flagging:** spec-gaps M2 integration 3 is filed as
homed at M5, but its structural-summaries half was M3's and M3 passed
without it. That half belongs to #3, not here.

**Labels.** `kind:feature`, `area:client`, `area:runtime`

---

### 12. Mint a canonical session id in `core`

WP-K 4 and WP-C-full 3 are the same gap counted twice: the event bus keys
sessions by a caller-supplied string, `events/search` cannot scope a query
to a session, and the SQLite schema's `parent_session_id` column stays
unwritten because Loom has no session-id concept. Needs a `protocol-change/`
proposal against §1.1. Proposed home M5; also a precondition for compaction's
stage M1 (session-scoped recall).

**Labels.** `kind:feature`, `area:runtime`, `area:events`

---

### 13. Service the eight cap modules the router refuses

Of the nine cap modules vetting admits, the shipped router services exactly
one, `proc.run`. The rest vet, compile, and refuse in band. M4's acceptance
does not require them — the migration sample runs on `proc.run` — so this is
out of the release, but it is the largest undocumented gap between what
`docs/architecture/code-mode.md` describes and what runs.

**Labels.** `kind:feature`, `area:codemode`

---

### 14. Move acceptance-plan building and idle-strand creation behind `runtime/api`

WP-L 2: the gateway and the conformance runner each build acceptance plans
and commit through the writer; two copies argue for `api.compact` and
`api.navigate`. WP-L 3: strand creation always takes a task brief, so
protocol fork and create-strand seed registers in the gateway themselves; an
optional-brief variant closes it. Same shape, adjacent code, one branch.

**Labels.** `kind:housekeeping`, `area:runtime`, `area:client`

---

### 15. Build the chaos runner and the ten-minute soak

WP-E's own exit criteria name random process kills under load and a
ten-minute soak; `make soak` is the deterministic-simulation seed soak, and
WP-T's chaos runner does not exist. **This is not release-blocking**, and the
distinction is worth stating: M1's *acceptance* names the interleave harness
and the 30-turn cold open, both green. The chaos tier is a work-package exit
criterion M1 was accepted without. It should be recorded as owed by WP-T
rather than as an M1 shortfall.

**Labels.** `kind:feature`, `area:conformance`

---

### 16. Replace `provider`'s two shipped stubs

WP-F 7: only the environment secret backend ships; the per-OS keychain
backends WP-F's scope names sit behind the seam. WP-F 6: adapters zero every
cost field, while §3.4 calls the ledger the billing source of truth, so
pricing tables need a ledger-side home. The design note sequences the pricing
half after WP-N with the token-budget work. Both are "the adapter ships a
placeholder"; both want a Part 5 track number rather than a floating entry.

**Labels.** `kind:feature`, `area:provider`

---

### D4. Are WP-J 15 and 16 in WP-N's scope?

WP-N's spec says outright that spec-gaps WP-J 15 (an approved escalation
widening a code-mode execution) and WP-J 16 (one threaded `ExecIdentity`,
so one-ledger-per-execution is a property of the types rather than a
convention `make e2e-codemode` itself breaks) "are in scope only if the
owner puts them there". This plan puts the escalation half in the release
(#4) on the grounds that M2 and M4 both cite it; WP-J 16 has no such claim
and should be answered here.

**Labels.** `kind:decision`, `area:codemode`

---

## Priority order

Top-down. "Blocks" means the later issue is harder or unverifiable without
the earlier one.

| Rank | Issue | Blocks | Why here |
|---|---|---|---|
| 1 | #1 Require `gate-linux` | everything | Minutes of owner time, and it is what makes every fix below binding. |
| 2 | #2 macOS gate green | — | The only red job. §0.3's definition of done has been unmet since WP-A, and a red job nobody expects to go green stops being read. |
| 3 | #3 Compaction C0 | #8 | M3's largest untrue claim, and the branch index already assumes it. Implementation in flight — sequence around it, do not restart it. |
| 4 | #4 Escalation raiser (+ D1) | — | An approval path with no raiser is a tested feature that does not exist. Cited by both M2's and M4's notes. |
| 5 | #5 Satellite enforcement report | WP-N | M4 is accepted on a run that cannot prove the jail engaged — the sandbox's entire value claim. Also WP-N's first prerequisite, so it sits on the M4.5 critical path too. |
| 6 | #6 Three suites that under-report | — | Cheap, and it protects the gate that verifies ranks 2–5. A flaky soak red is worse than a documented gap. |
| 7 | D3 cgroup limits | #10 | Answer before the sandbox work: (b) or (c) changes what the jail runner must assert. |
| 8 | #10 Two sandbox probes | — | Now affordable; closes the last two M2/M4 sandbox shortfalls the runner can reach. |
| 9 | #7 TUI end-to-end | — | The cheapest M3 shortfall. |
| 10 | #8 Application supervisor | — | After #3, same file. |
| 11 | #9 Six amendments | — | An afternoon; closes six of the twenty orphans. |
| 12 | D2 citation checker | — | No dependency; answer whenever. |

Outside the milestone, in the order I would take them: #11 wiring seam
(feeds M5), D4, #12 session id, #14 api surface, #16 provider stubs, #15
chaos runner, #13 cap router.

---

## Not in the first release

Named here so no issue implies otherwise.

| Body of work | Where it is recorded | Why it stays out |
|---|---|---|
| **A macOS jail** (WP-H phase 2, Seatbelt) | spec §5.1, Part 4 M3 note | Deliberately unbuilt: a generated profile can only be tested against the string it was told to emit, which cannot distinguish deny-by-default from permissive-through-a-typo. The platform refuses rather than degrades, so nothing runs silently unconfined. Issue #2 makes macOS *build and test*; it does not make macOS *safe*. |
| **The egress proxy sidecar** | spec Part 5 track 10, §5.1 | Track 10 hardens a sidecar that does not exist. `Proxy(allowlist)` fails closed today — jailed exactly as network-off, with a skipped `network-proxy` entry saying the allowlist was not enforced. Correct behaviour, no release dependency. |
| **The MCP adapter** | spec-gaps WP-G 9 | In WP-G's scope, deferred post-M2, integrated by no row since. Wants a Part 5 track number of its own. |
| **The promotion ladder and hot-loading** (WP-M, M6) | spec Part 2 WP-M, Part 4 M6 | Not started, and nothing in M0–M4 depends on it. |
| **The chaos runner and ten-minute soak** | spec-gaps WP-E 8, §5.1, issue #15 | M1's acceptance criteria are both green; the chaos tier is a WP-E/WP-T exit criterion M1 was accepted without. Record it as owed by the work package, not as a milestone shortfall. |
| **The orchestration seam** (WP-N / M4.5) | spec Part 2 WP-N, `orchestration-comparison.md` | Depends on M4 and the `agent_*` tools, on nothing in M5 or M6. Issue #5 is its first prerequisite and is in the release; the seam itself is not. |
| **Memory stages M1–M3, compaction C1/C2** | `compaction-and-memory.md` Part 5 | C0 is the bar for "runs at all"; the later stages make it good. |
| **Role routing, LSP/DAP, TTSR** (M5) | spec Part 4 M5 | Not started. Issue #11 feeds it. |

---

## Where each orphan went

All twenty items in `spec-gaps.md`'s "Deferred work with no home" table, so
the owner can check nothing was dropped.

| Item | Goes to |
|---|---|
| WP-L 1 (production denial-raiser) | #4 — in milestone |
| WP-J 15 (escalation widens nothing in code mode) | #4 — in milestone |
| WP-J 16 (one threaded `ExecIdentity`) | D4 — owner decides whether WP-N owns it |
| WP-E 8 (chaos tier) | #15 — out, with the argument stated |
| WP-E 3 (application supervisor) | #8 — in milestone |
| WP-G 9 (MCP adapter) | Not in the first release |
| WP-F 7 (keychain backends) | #16 — out |
| WP-F 6 (pricing tables) | #16 — out |
| WP-K 4 + WP-C-full 3 (canonical session id) | #12 — out |
| M2 integration 2 (`stream_options`) | #9 — in milestone |
| WP-L 8 (per-identity model facts) | #11 — out |
| M3 runtime wave 13 (catalogue `thinking`) | #11 — out |
| WP-I 7 (tool timeout ceiling) | #9 — in milestone |
| M2 integration 1 (one clock or era) | #9 — in milestone |
| WP-K 1 (catch-up frontier rule) | #9 — in milestone |
| WP-A 7 (decoder coverage criterion) | #9 — in milestone |
| WP-L 2 (`api.compact` / `api.navigate`) | #14 — out |
| WP-L 3 (optional-brief `create_strand`) | #14 — out |
| WP-L 6 (queued vs placed acks) | #9 — in milestone |

The eight items in the "Deferred work with a home" table get no issue: their
homes (M4.5, M5, Part 5 tracks 4 and 6) are all outside this release. Two
exceptions are argued above — WP-J 14's home is M4.5 but M4's row owes it
(#5), and M2 integration 3's summaries half was M3's and belongs to #3.

---

## One item I could not place

`docs/review/m5-agent-comms-judgment.md` closes with a designed-in hole it
declines to fix: a child strand cannot get an answer from its parent while
the parent is inside `agent_wait`, and `agent_send` to a *finished* parent
opens a fresh run — which is the exact property the design rejects
auto-enqueue over. The reviewer's instruction is "either bound that leg or
drop it from the rejection argument; as written the design contradicts
itself."

That is neither a bug nor scheduled work. It is a design document arguing
against itself, and the fix is one of two edits the owner must choose
between. It is not release-blocking — the shipped behaviour is coherent, the
*argument* for it is not — so I have left it off the issue list rather than
inventing a milestone for it.
