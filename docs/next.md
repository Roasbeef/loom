# Next

**Read this first.** This is the handoff between sessions: where the tree
stands against the plan of record, what to work on next, the rulings
already made so nobody re-litigates them, what is deliberately left open,
and how to verify a change. Rewrite it when you finish a body of work.

It is deliberately not a history; the git log and the PR bodies carry how
each change was reviewed. Re-baselined 2026-09-02 against `main` at
`96232c2`, with every claim below checked against the tree or against a CI
run rather than carried forward, and the places where the previous edition
was wrong named as such.

---

## Where the tree is

The plan of record is `docs/issue-plan.md` and its milestone `v0.1 —
claimed, true, and self-extending`, with the acceptance rows and the
evidence rule in `docs/loom-implementation-spec.md` Part 4. Phases 1
through 3 are substantively in the tree. Phase 4, the promotion ladder
that the milestone's own name calls self-extending, has not been started.
Phase 5 has not been started either, but the substrate it needs exists.

| Phase | Body of work | Where it stands |
|---|---|---|
| 1 | Claimed and true (M0–M4), #1–#13 | Code done and CI green; the gate itself is one owner action away (#1). #62 and #99 are answered by measurement and want closing. |
| 2 | Orchestration seam (M4.5 / WP-N), #20–#24 | Landed. M4.5's row stays `partial` because the sample's fan-out reaches a scripted Agency rather than live children. #24 and #93 are still open. |
| 3 | Semantic tools, routing, memory (M5), #14, #15, #16, #25–#29 | Routing, session id, the capability router, triggered rules, MCP through code mode and both memory stages are on `main` and tested. #25 and #26 moved to phase 5. #106 stays open on the jail decision. |
| 4 | Promotion ladder (M6 / WP-M), #18, #30–#33, #100 | Zero. No `packages/ext`, and `ExtensionZone`, `ExtTool`, `ExtHook`, `ExtProjection` and `load_binary` return no hits across `packages/*/src`. |
| 5 | Language-service tier, #25 (LSP), #26 (DAP) | Not started. The supervised long-lived stdio peer both need is `packages/mcp`'s client and transport, which exist. |

### Phase 1: the gate has started closing

The previous edition said CI had never completed a run and that Landlock
had never executed anywhere. Both were true when written and both are
false now.

CI completes. The last six merge runs on `main` are green across all four
jobs: `gate (linux)`, `gate (macos)`, `jail (linux)` and `soak (200
seeds)`. The `jail (linux)` job runs the sandbox self-test with **nine of
nine probes ENFORCED and zero skipped**, and the enforcement matrix step
agrees with `.github/enforcement-expectations`. On that same job the
applied-layer list printed by `make e2e` and by both code-mode stages
reads `degraded=False` with `landlock:abi=7` beside `bwrap`, `cgroup-v2`,
the two rlimits, `no-new-privs` and `seccomp-net`. That is the layer #62
was filed against, observed rather than asserted.

Phase 1's remaining work is therefore bookkeeping and one owner action:

- **#1** (set `gate-linux` as the required check on `main`) is unblocked
  and is the last thing the closing criterion names.
- **#99** ("CI has never completed a run") and **#62** ("nobody has ever
  run Landlock") both need the measurement posted on them and then
  closing. Per `docs/execution.md` §6 the correction goes on the issue,
  not only in a commit.
- **#155** ("soak (200 seeds) is red on `main`") is a flake rather than a
  standing red: it has failed once in the last twelve `main` runs. The
  evidence that is still live is the **nightly long soak**, whose last run
  failed `make soak` in the `seeds 1001..` and `seeds 1501..` bands while
  `seeds 1..` and `seeds 501..` passed. Re-scope the issue onto the
  nightly bands before picking it up.

Part 4's caveat that no CI run had ever completed, and its M2 note that
Landlock had never executed, are corrected in the same change as this
file. What they do not do is promote any row: a green gate is the evidence
the rows were missing, not a re-reading of their acceptance criteria.

### Phases 2 and 3: the work landed, some issues did not close

Everything phases 2 and 3 name is on `main`: the orchestration seam, the
capability router (`fs.*`, `kv.*`, `report.emit` and `mcp.<server>` all
served through `codemode/workspace` and `client/mcp`), one canonical
session id, model routing walking a real fallback chain, triggered rules,
memory stages M1 and M2, and MCP reached through generated per-server
capability modules. Three issues stay open over completed work, for
different reasons:

- **#106** (MCP through code mode) is **open, and the work is on `main`.**
  Earlier editions of this file said both "closed on the issue" and "still
  open on #106", which is how a reader loses trust in a handoff. The truth
  is that the increment shipped and the issue is held open by one
  question that was split out of it: whether an MCP server process runs
  inside a jail (**#109**), which is undesigned rather than unbuilt. Do
  not close #106 on the strength of the code; close it when #109 has an
  answer, or close it and let #109 carry the question alone.
- **#24** (let an approved escalation widen a code-mode execution) is
  open, and Part 4's M4.5 section records the grant composing onto the run
  phase and only the run phase as done. Verify against `make e2e-codemode`
  before closing.
- **#93** (phase-2 closeout doc pass) is why the README carried false
  statements about the tree: that the router served only `proc.run`, that
  triggered rules and hindsight memory did not exist, and, worst, that no
  MCP server runs anywhere but in the jail. Those are fixed, along with
  the stale Landlock and #97 claims and Part 4's M4, M5 and CI notes. The
  rest of #93's sweep over the build and getting-started docs is owed.

M4.5's row stays `partial` for a real reason and not a doc lag: no single
run has put a model-written program in front of *live* child strands, and
by Part 4's own rule a criterion met with a test-supplied substitute is
not met.

### Phase 4 is at zero, and it is the release's named capability

There is no `packages/ext`, and grepping `packages/*/src` for
`ExtensionZone`, `ExtTool`, `ExtHook`, `ExtProjection` and `load_binary`
returns nothing. `docs/issue-plan.md` says M6 is at 0% and that is still
exactly true. Its hard part was never `code:load_binary` but the TCB
freeze (#33) plus a recorded adversarial review, so budget for that rather
than for the loader. The extension ruling below changes the shape of the
phase: most of what the first extensions need no longer requires the L3
loader at all.

### Memory: the consumer is live, the producer is inert

The recall half is real and proved: `client/history` and the
`history_search` tool, the notes digest at `run_start`, the memory store
and its protected digest sidecar, the `remember` tool, the distillation
pipeline in `client/distill` with leases, caps, redaction and provenance,
the erasure cascade, and the structural anti-feedback exclusion, with two
cross-session proofs in `packages/client/test`.

The producer never runs in the shipped product. `import client/distill`
appears in exactly two files and both are tests; `client/serve` imports
`client/memory` for the digest read and the `remember` seam, and never
`client/distill`. `client/distill.main` exists, but no Makefile target, no
`bin/` shim and no release entry point reach it, so an operator gets
distillation only from a source checkout. That is **#149**, a release
blocker, and it is the whole gap between "memory is built" and "memory is
a product feature".

**#124** is the bug underneath it: provenance is batch-level and a live
head is exactly one batch, so a cascade over a session that fed the
current head empties the head outright, and the surviving sources keep
their high-water cursors, so the pipeline can never rebuild. A test pins
the loss deliberately.

Memory is also the only subsystem with no `docs/architecture/` page.

---

## What to do next

In this order. The first item is a body of work; the rest are smaller and
can be interleaved by whoever is not on it.

### 1. Extensions: out-of-tree capability that never touches the TCB

`docs/design-notes/extension-architecture.md` carries the argument, the
vocabulary, the manifest and the phased plan; **ADR-007** records the two
rulings that outlive it. Both arrive with PR #170, so on a tree where that
has not merged the two files are a forward reference. This is the next
body of work and it subsumes most of phase 4.

The acceptance test for the whole of it is a new repository that
implements web search as an extension: an operator installs it, the model
has a `web_search` tool it calls directly, and the API key never enters
the jail and never enters `loom.toml`.

Four phases, in order:

1. **`loom_ext`, the manifest, vetting, install records, `loom ext`.**
   Exit: installing a fixture extension writes an install record, and a
   hostile fixture (FFI, a forbidden import, an oversleep at load) is
   refused naming the layer that caught it.
2. **Tool registration and jailed dispatch, plus broker-served
   `net.request` with an allowlist, caps and secret bindings.** Exit: the
   web-search repository installs and the model calls `web_search` in a
   real drive, a request outside the allowlist is refused in band, and an
   end-to-end reads both the jail's environment and every frame on the
   capability channel and finds no key. **This is the milestone the owner
   named.**
3. **Persistent satellite and the `hook_call` frame.** A reverse direction
   on the capability channel, so it is a `protocol-change/` proposal
   written before the phase starts, not drift.
4. **Tier H behaviours, hot load, rollback and the TCB freeze** (#32,
   #33), only for what phase 3 cannot express.

Phases 1 and 2 touch `broker`, `codemode`, `client`, `tools` and a new
`packages/ext`, and no frozen Part-1 interface. The promotion ladder's L1
skill store (#30) and L2 candidate pipeline (#31) become the
agent-authored on-ramp into the same manifest and the same install record
rather than a parallel mechanism, and **#100**'s vocabulary work is done
inside the design note's hook table rather than after it.

Note what this does *not* do: **#144** (provider-backed web search as a
core tool) is the other answer to the same question and it is a core
change by construction, because `loom.toml`'s top-level key list, the
`cap` prelude, its digest-gated description, the vetting allowlist, the
capability router and `client/serve`'s fixed `registry(...)` signature are
each a closed literal in this repository. The extension route is the one
that opens the registry seam. Decide which one #144 becomes before
building either.

### 2. Close the phase-1 gate

Small, and it is what the milestone's closing criterion actually asks for.
Post the CI and Landlock measurements on **#99** and **#62** and close
them, re-scope **#155** onto the nightly soak bands, and set `gate-linux`
as the required check (**#1**). Part 4's own stale caveats are corrected
in this change.

One thing to land first, because it is the only red left in the loop: the
**macOS `runtime` interleave stall**. `gate (macos)` has failed twice in
the last twelve `main` runs, both times on
`runtime@interleave_test.abort_interleave_test` timing out inside
`support/harness.wait_terminal`, with a `process.call` panic from
`runtime/strand_runtime.claim_through` in the crash dump beside it. The
cause and the fix are **#171**: the drain ledger read a `noproc` reaper as
a destroyed drain proof, and the harness counted its wait in sleeps rather
than in time, so on a loaded runner it never got to say what it thought
had happened. That PR was open when this was written and may already be
merged; the ruling it establishes is below.

### 3. Memory: make the producer run, then fix the cascade

**#149** first: distillation has to run in the shipped session lifecycle,
with a release entry point rather than a source checkout. **#124** after
it, because an unrecoverable cascade matters much more once the pipeline
is actually producing. A `docs/architecture/memory.md` belongs with the
first of the two.

### 4. After that

Phase 5 (**#25** LSP, **#26** DAP) starts from `mcp/client` plus
`mcp/transport`, which is the supervised long-lived stdio peer both need.
**#18** (chaos runner and ten-minute soak) is the only test that separates
a rollback from a leak and so belongs with extension phase 4. **#107**
(async code mode) sits outside every ladder with its design dossier on the
issue, awaiting prioritization.

---

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**Extensions run jailed by default, and reach the network through the
broker** (`docs/adr/007-extension-tiers-and-brokered-egress.md`,
`docs/design-notes/extension-architecture.md`). An installed extension has
one manifest and up to two bodies. A tool is always jailed; a hook is
harness-resident only when it cannot be jailed, because the risk is in the
hooks and not the tools: a tool call is a request the model made and the
broker judges, while a hook fires on the harness's own timeline with the
harness's own data in hand. `net.request` is served by the broker making
the HTTP request on the host under a per-extension policy, so no socket
ever exists in the jail and the credential is named in configuration, held
by the harness, and absent from both the jail and the channel.

**Process machinery goes through weft, and `docs/weft.md` is the standing
guide.** Phases 1 through 3 of loom#159 are on `main`: the strand driver's
recovery gate, `broker/exec` and `codemode/launch` as state machines,
`provider/custodian` and the effect reaper as witnessed runs, the
launcher's bounded waits on `weft/poll`, and then weft 0.4.1's periodic
timeout and injected clock under the broker heartbeat, the writer's lease
renewal, `client/escalate.park` and `client/agency.wait_loop`. The page
carries which shape maps to which primitive, the nine rules a port is held
to, and the standing rejections. Weft does not shrink the tree and nobody
should expect it to: the adoption measured net +1,191 lines here, because
an exhaustive `case state, message` matrix with every unreachable pair
written out is larger than the recursive functions it replaces. What it
buys is one owner per race.

**The `noproc` claim rule, both halves.** The drain ledger installs its
monitor when it *handles* a claim, so the pid a claim names should still
be alive at that moment whatever the driver does in between. The claim is
therefore made from a leaf owner the scope adopts before releasing it
(`runtime/strand_runtime.claim_through`), pinned by
`restart_reap_test.reaper_claim_outlives_a_driver_killed_mid_claim_test`.
That ordering is the claim protocol's own guarantee and it cannot be the
ledger's only defence, because a claim reaches the ledger as a message and
a reaper that drains and exits in the gap can be met no other way.
`noproc` is what a monitor answers about a pid that was already gone and
never a reason a process exits with, so the ledger reads it as a departure
and retires that generation rather than treating it as a lost drain proof
and taking the session tree down (#171,
`drain_registry_test.claim_naming_an_already_departed_reaper_retires_it_test`).
A weft scope holds itself alive until every effect it adopted has exited
and says `weft_drain_proof_lost` when it cannot, so a pid met as `noproc`
provably left nothing running. `Killed` and every other abnormal reason
still fail the session closed.

**A model-created schedule may steer, but may not wake.**
`ModelSchedulesSteer` is the default; the addendum in
`docs/design-notes/scheduled-heartbeats.md` carries the argument. The
original open default rested on per-schedule expiry bounding the session,
and **#161** showed it does not: a fresh name is a fresh clock, so a woken
model can create the next schedule before this one expires, and the
priority order puts isolation before capability. The tools stay registered
and a model can still create schedules; none wakes an idle strand unless
the operator writes `[schedules] model_created = "wake"`. A schedule
always targets the strand that created it, and `scheduleseam.create`
refuses a subagent outright until the ownership model in #154 and #163
exists.

**`AGENTS.md` and `CLAUDE.md` are both read, in that order** (#169).
`client/system_prompt.discover` fills two slots: the `AGENTS.md`
instructions, taken from the workspace, else the operator's global under
`~/.agents` then `~/.loom`, and then the workspace's `CLAUDE.md`. A
workspace file beats both globals, and `AGENTS.md` renders first because
it is the file every other harness reads and `CLAUDE.md` is the additions
to it. Each file arrives in an `<instructions>` fence naming its path and
an origin of `workspace` or `user-default`, and the default pack tells the
model that at most one `user-default` block exists and that it is always
first, which is the one claim a project file cannot forge by position.
Every read warns and continues under the same byte bound, `HOME` unset
included.

**MCP is code-mode only, and the jail decision is open** (#106, #109).
Generated per-server capability modules, never a generic
`cap/tools.invoke` dispatcher: a generic dispatcher does not falsify the
vetting theorem, it collapses its discriminating power, because the bound
becomes "the whole registry, for every program". The bound is per server
and not per tool, deliberately, because a human trusts a server. What
remains undecided is where the server process runs.
`mcp/transport.PortTransport` spawns it **unjailed** and its own module
doc says so: an unjailed spawn there is the production primitive and not
the final security posture. `docs/architecture/mcp.md` records the jail as
an open decision. Do not let any document claim otherwise.

**The ledger keys on `{op_id, step_id}`; paths key on `{op_id, step_id,
source_index}`.** The pair is the batch identity the broker pools on and
the triple is the execution identity; `source_index` is absent from
`ExecIdentity` because adding it would mint one ledger per `code_mode`
call and read the pooled cap as a per-call cap by another door (ADR-005's
addendum). Relatedly, the abort-epoch table is measured and not pruned,
because pruning is unsafe in both directions and the dangerous one is
silent.

**A host missing a code-mode prerequisite registers no `code_mode` tool at
all**, because a tool definition is a byte prefix of the provider's cached
region, paid on every request of every strand for the session's life. Code
mode itself ships in the main release artifact with `DIST_CODEMODE=0` as
the opt-out (`docs/distribution.md`).

**R3 and R8 will never gate, and R10's exemptions are the formatter's.**
The first two over-report by construction, and measuring rather than
refusing is the point. R10 exempts a comment at the top of a block and one
between two constructor fields because `gleam format` deletes a blank line
in both positions while preserving one between two *variants*, so
"completing" the rule with constructor fields would demand what the
formatter removes.

---

## Deliberately open

Named, with an issue where one exists. None of these is unfinished work
somebody forgot.

- **The MCP server jail** (#109). Undesigned, not unbuilt, and the
  load-bearing gap in the only third-party extension path that works
  today. `mcp/transport` is the seam an answer attaches to.
- **The rest of MCP's v1 cuts**: HTTP transport plus OAuth (#108), an
  end-to-end against a third-party server from the wild (#110),
  elicitation (#111), `listChanged` (#112). Together these are what
  separates "a third party can add a tool" from "a third party can add a
  hosted tool".
- **Nested `AGENTS.md` files** are not read (#172). The convention's rule
  is that the closest file to the edited file wins, and Loom's prompt
  assembly has no notion of the files under a path: `Host.guidance` is one
  string fixed at session open. Per-edit precedence needs a per-tool-call
  channel instead, landing after the cached prefix rather than inside it.
  That is a question about where directory-scoped instructions belong in
  the two-channel doctrine, and it should be answered before anything is
  built.
- **`cap/task` on weft.** A clean fit for the run engine, but `cap` is the
  satellite-side prelude with no weft dependency, and adding one puts weft
  into the offline build seed. That is a distribution decision
  (`docs/distribution.md`).
- **One weft gap upstream**: a monitored, non-panicking call against a
  pre-existing pid, which is what `broker/internal/call.try_call` and its
  siblings hand-roll. The other two the census named are closed in 0.4.1.
- **The residual `runtime` interleave flakes** that #171 does not claim to
  close. #171 removes the `noproc` cause and makes the harness honest
  about time; it names the rest as pre-existing, none of them yet seen in
  CI.
- **Playbooks** (#139). Loom has no prompt-level skill mechanism, and the
  word "skill" appears once in `packages/*/src`, unrelated. The extension
  design note proposes that an extension may ship `skills/<name>/SKILL.md`
  and that the server surfaces name, description and location in the
  system prompt, which would make #139 arrive as a side effect. Track it
  there rather than building it twice.
- **Scheduling follow-ups**: on behalf of a subagent (#154), `cap/schedule`
  on the orchestration seam (#156, a decision rather than work: widening
  the intersection of the two allowlists costs a confinement property a
  test asserts), a schedule that never fires never expires (#157), and
  #162 through #165.
- **`net.request` is unserved** today, gated on an egress proxy sidecar
  that is out of the release. ADR-007 is the route that changes this, for
  extensions, without the sidecar.
- **Compaction stages C1/C2 and memory stage M3** are out of the release
  by design and have no issue.

---

## How to verify

`make help` lists the commands. `make check` is the full gate and is
exactly what CI runs; `make check-<package>` narrows it; `make doc-check`
checks the doc graph and the citations; `make lint` is the house-rule
lint; `make selftest` says which enforcement layers the kernel actually
provides; `make e2e` and `make e2e-codemode` are the jailed end-to-ends
(`make codemode-seed` prepares the offline cache the second needs).

Four hazards, each of which has cost real time here.

**Verify a gate by its own exit code.** `make check > log; echo $?; tail
log` reports `tail`'s status and has produced confident false greens here
more than once. Capture `make`'s status directly into the log, then read
the log for failures. The background form is the same trap: a detached
gate finishes with the wrapper's status, and the recorded `MAKE_EXIT=`
line means nothing until somebody reads it.

**`make check-<package>` does not run lint, and a failing package never
reaches lint either.** `scripts/check.sh` runs the lint only when it is
given no package arguments, and it runs it last under `set -e`, so a
package that fails aborts before it. `make doc-check` is a separate target
that `make check` never runs at all, and in CI it is a separate step after
the gate, so a red gate means neither ran. After fixing a failure, run
`make lint` and `make doc-check` on their own.

**A fresh worktree can fail on Hex rather than on your diff.** A new tree
resolves every package's dependencies from scratch, and enough parallel
requests hit the Hex API rate limit; it presents as a build failure with
nothing to do with the change. Wait and re-run before diagnosing.

**Do not put a verification worktree under `/tmp`.** Code mode correctly
refuses a cap socket there, because the jail replaces `/tmp` with the
scratch tmpfs, and `/tmp` also breaks `make codemode-seed` discovery. Put
it beside the repository and remove it when done.

Two more belong to the tree rather than to the gates: a long-lived tree's
incremental build cache can produce a deterministic failure in a package
the diff never touched, so check a fresh-worktree control before calling
it a flake; and `make gen-prelude` and `make gen-sql` produce committed
artifacts the build gates rather than regenerates, so changing
`packages/cap`'s public surface without regenerating fails
`make prelude-check`.

`docs/execution.md` is the rest: how a wave is planned, how sub-agents are
briefed and monitored, the standard of proof, and why a correction goes on
the issue rather than only in a commit.
