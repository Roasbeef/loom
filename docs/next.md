# Next

**Read this first.** This is the handoff between sessions: where the tree
stands against the plan of record, what to work on next, the rulings
already made so nobody re-litigates them, what is deliberately left open,
and how to verify a change. Rewrite it when you finish a body of work.

It is deliberately not a history; the git log and the PR bodies carry how
each change was reviewed. Re-baselined 2026-09-03 against `main` at
`1137d64`, with every claim below checked against the tree or against a
CI run rather than carried forward, and the places where the previous
edition was wrong named as such. The previous edition was baselined at
`96232c2`, 117 commits ago, and most of what it called the next body of
work is now on `main`.

---

## Where the tree is

The plan of record is `docs/issue-plan.md` and its milestone `v0.1 —
claimed, true, and self-extending`, with the acceptance rows and the
evidence rule in `docs/loom-implementation-spec.md` Part 4. Phases 1
through 3 are substantively in the tree. Phase 4, the promotion ladder
the milestone's name calls self-extending, has changed shape: the
extension architecture that subsumes most of it is built through its own
phase 3, and what remains of the ladder is the tier-H loader and the TCB
freeze. Phase 5 has not been started, and the extension route is now its
intended home.

| Phase | Body of work | Where it stands |
|---|---|---|
| 1 | Claimed and true (M0–M4), #1–#13 | Code done; CI completes and is green more often than not. The gate is one owner action away (#1, and `main` has no branch protection today). #62 and #99 are answered by measurement and still open. |
| 2 | Orchestration seam (M4.5 / WP-N), #20–#24 | Landed. M4.5's row stays `partial` because the sample's fan-out reaches a scripted Agency rather than live children. #24 and #93 are still open. |
| 3 | Semantic tools, routing, memory (M5), #14, #15, #16, #25–#29 | Routing, session id, the capability router, triggered rules, MCP through code mode and both memory stages are on `main`. #25 and #26 moved to phase 5. #106 stays open on the jail decision (#109). |
| 4 | Promotion ladder (M6 / WP-M), #18, #30–#33, #100 | Extension phases 1–3 built and merged (#170, #175–#182, #195, #196, #198, #199, #200): `packages/ext`, `loom ext`, brokered `net.request`, jailed dispatch, a session-lived satellite per extension, `hook_call`, and the hook bus. Tier H (#32) and the TCB freeze (#33) are not started. |
| 5 | Language-service tier, #25 (LSP), #26 (DAP) | Not started. The design note names both as extensions over the persistent satellite, blocked on a `[proc]` grant for binaries. |

### Phase 1: green, with a different red than the previous edition named

The previous edition said the last six merge runs on `main` were green
across all four jobs and that `gate (macos)` had failed twice in twelve
runs, both times on the `runtime` interleave stall. Neither is true now.
Of the twelve completed `main` runs before this baseline, three failed,
all on `gate (macos)`, and none of the three was the interleave stall:
one was `writer_publish_test` sending to an unregistered name beside an
`escalation_test` await (the shape #180 then fixed in the drain-registry
test), one was a `cap_test` assertion, and one was `make e2e` with a
single failure. The interleave cause #171 removed has not recurred.

The soak is better than the previous edition said, not worse: `soak (200
seeds)` passed in all twelve of those runs, not eleven. The nightly long
soak is where the red lives, and it is narrower than claimed: its last
run failed only the `seeds 1001..` band, with `seeds 1..`, `seeds 501..`
and `seeds 1501..` green. **#155** should be re-scoped onto that one band
before anybody picks it up.

The `jail (linux)` job still runs the self-test with nine of nine probes
enforced and zero skipped, and `make e2e`'s applied-layer line reads
`degraded=False` with `landlock:abi=7` beside `bwrap`, `cgroup-v2`, the
two rlimits, `no-new-privs` and `seccomp-net`. That measurement is on
**#62** in this change; the previous edition said the spec's M2 note was
corrected and it was only half so, the environment list in Part 4 still
said Landlock had never executed until this change.

Phase 1's remaining work is bookkeeping and one owner action: post the
measurements on **#99** and **#62** and close them, re-scope **#155**,
and set `gate-linux` as the required check (**#1**).

### Phases 2 and 3: unchanged since the previous edition

Everything phases 2 and 3 name is on `main`. Three issues stay open over
completed work, for the same reasons as before: **#106** is held open by
the MCP jail question split into **#109**; **#24** wants a check against
`make e2e-codemode` before closing; **#93**'s sweep over the build and
getting-started docs is still owed. M4.5's row stays `partial` because no
single run has put a model-written program in front of live child
strands, and by Part 4's own rule a criterion met with a test-supplied
substitute is not met.

### Phase 4: the extension architecture is built through phase 3

The previous edition said phase 4 was at zero, that there was no
`packages/ext`, and that the extension work was the next body of work,
arriving with a PR that had not merged. All three were true when written.
Now:

- **`packages/ext`** is the package an extension compiles against inside
  the jail: `ext.gleam` (the tool vocabulary), `ext/hook.gleam` (the typed
  hook vocabulary and the JSON wire shapes) and `ext/runtime.gleam` (the
  receive loop over `hook_call` frames). The harness side is
  `packages/client/src/client/extension/`: archive reading, the manifest,
  install and its record, discovery, `loom ext install|list|remove|verify`,
  the egress policy, the router seam, dispatch, the hook bus and the host
  registry.
- **`net.request` is served**, by `broker/egress` making the HTTP request
  on the host under a per-extension policy, so the previous edition's
  "deliberately open" entry saying it was unserved and gated on a sidecar
  is retired.
- **The acceptance test the owner named passed** on 2026-09-02: `loom ext
  install https://github.com/Roasbeef/loom-web-search` fetched over
  codeload, and a Kimi K3 session called `web_search` and answered from
  Brave's results with `BRAVE_API_KEY` in the server's environment and
  nowhere else. That is a documented drive, not a CI job; the e2e that
  reads the jail's environment and every frame on the channel is what CI
  runs.
- **Phase 3's exit criteria are met by the e2e** in
  `packages/client/test/client/extension_e2e_test.gleam`, over real jailed
  satellites: a jailed `tool_call` hook blocked a call and the refusal
  named the extension, a jailed `context` hook appended a message within
  the cap, two invocations cost one node launch, and an oversleeper was
  reaped with its extension marked unavailable for the rest of the
  session.
- `docs/issue-plan.md`'s "M6 is at 0%. There is no `packages/ext`" is
  corrected in this change. What the plan's M6 closing criterion still
  owes is exactly what phase 4 below names: the L0→L3 ladder test with a
  live rollback, the TCB freeze test, and a recorded adversarial review.

The previous edition's grep for `ExtensionZone`, `ExtTool`, `ExtHook`,
`ExtProjection` and `load_binary` still returns nothing, because the
shipped vocabulary is different; do not read that grep as "phase 4 is at
zero" again.

What phase 3 deliberately left out, each recorded at the site: the host
registry is not stopped on `serve` shutdown (the supervisor kills it and
the launcher's janitor reaps every node, so only enforcement reports are
lost); `agent_settled` is accepted by the manifest and carried by the bus
but nothing in the harness fires it; `agent_end` carries no outcome word
because it is asked before the terminal transaction commits; the host
registry serialises the whole session's invocations rather than one
extension's; and Linux never ran the phase 3 e2e locally, only in CI.

### Memory: the consumer is live, the producer is inert

Unchanged. `import client/distill` appears in exactly two files and both
are tests; `client/serve` imports `client/memory` and never
`client/distill`; `client/distill.main` exists and no Makefile target,
`bin/` shim or release entry point reaches it. That is **#149**, a
release blocker. **#124** is the unrecoverable cascade underneath it.
Memory is still the only subsystem with no `docs/architecture/` page.

---

## What to do next

In this order. The first item is a body of work; the rest are smaller and
can be interleaved by whoever is not on it.

### 1. Extension phase 4: tier H, rollback, and the TCB freeze

**#32**, **#33**. The design note's phase 4 paragraph is the spec: the
loader compiles a tier-H body from vetted source under a
harness-controlled module name, checks the compiled artifact's import
table against the tier-H allowlist before loading it (the runtime half of
#33's two mechanisms; the vetting lint is the compile-time half), runs it
under a supervised, time-boxed wrapper, and rolls back to the previous
artifact when a load or a first call fails.

Exit: a fixture tier-H `context` hook loads, transforms, and is replaced
without a restart; a body whose beam imports anything outside the
allowlist is refused at load naming the module; the freeze test walks the
TCB modules and shows none is reachable from a loaded body; a hook that
oversleeps is killed by the wrapper and the extension is marked failed in
its record; and an adversarial review of the loader is recorded in
`docs/review/`, with its HIGH findings closed or explicitly accepted.
That review is part of the rung, not something that happens if there is
time; `docs/issue-plan.md` budgets for it and the phase 3 reviews this
week each found real bugs the author's own pass had not.

Note what this does *not* do: it does not widen the hook vocabulary
(**#100** is done inside the design note's table, and a tier-H body
answers the same events a jailed one does); it does not build the L1
skill store or the L2 candidate pipeline (**#30**, **#31**), which are
the agent-authored on-ramp into the same manifest and install record and
can follow; and it does not touch `ext.remember`/`ext.recall`, which the
design note names and no phase has commissioned.

### 2. Close the phase-1 gate

Small, and it is what the milestone's closing criterion actually asks for.
Post the CI and Landlock measurements on **#99** and **#62** and close
them, re-scope **#155** onto the nightly `seeds 1001..` band, and set
`gate-linux` as the required check (**#1**). The macOS reds worth a look
first are the three named above; none is the interleave stall.

### 3. Memory: make the producer run, then fix the cascade

**#149** first: distillation has to run in the shipped session lifecycle,
with a release entry point rather than a source checkout. **#124** after
it. A `docs/architecture/memory.md` belongs with the first of the two.

### 4. Decide #144 against the extension route

**#144** (provider-backed web search as a core tool) is now the other
answer to a question the extension route has answered in practice. The
registry seam the previous edition called closed is open (#178), so the
argument that #144 must be a core change no longer holds. Decide whether
#144 closes as "done by loom-web-search" or stays as a core tool for
operators who will not install extensions.

### 5. After that

Phase 5 (**#25** LSP, **#26** DAP) is designed as extensions: a long-lived
JSON-RPC child the extension starts from `session_start` through
`cap/proc`, in the jail, which needs a `[proc]` manifest table granting
binaries and the toolchain in the jail's readable roots. **#18** (chaos
runner and ten-minute soak) is the only test that separates a rollback
from a leak and belongs with item 1. **#107** (async code mode) sits
outside every ladder with its design dossier on the issue. **#181**
(pluggable secret backends behind one `SecretStore`) is the follow-on to
the process-environment secret lookup extensions use today.

---

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**Extensions run jailed by default, and reach the network through the
broker** (`docs/adr/007-extension-tiers-and-brokered-egress.md`,
`docs/design-notes/extension-architecture.md`). An installed extension has
one manifest and up to two bodies. A tool is always jailed; a hook is
harness-resident only when it cannot be jailed, because the risk is in the
hooks and not the tools. `net.request` is served by the broker making the
HTTP request on the host under a per-extension policy: https only, an
exact origin allowlist, a method allowlist, reserved and malformed headers
refused, TLS verified with session resumption off, same-host redirects
only, a streamed size cap, one monotonic deadline, and the credential
named in configuration, held by the harness, and absent from both the
jail and the channel.

**The install fetches an archive over the broker, never `git clone`**
(`docs/design-notes/extension-architecture.md`, "Hardening the install").
The source is fetched under a one-host egress policy, read by a total
tar.gz reader that refuses symlinks, `..`, oversize entries and off-host
redirects, pruned to the extension's own tree, vetted against the
extension seam ahead of the compiler, compiled offline inside the
code-mode sandbox, and pinned by the tree digest the record carries. The
record is written last and discovery re-digests, re-vets and fingerprints
the artifact on every boot.

**`prompt_snippet` is required, diverging from pi** (the design note's
status paragraph). A tool that would be silently unlisted is refused at
install, because an install is the one moment the author is present to
read the refusal.

**A persistent satellite per extension, and `hook_call` is the reverse
direction** (`protocol-change/012-hook-call.md`, ACCEPTED 2026-09-02;
`docs/design-notes/extension-architecture.md`, Decision 3). The satellite
lives for the session and computes between invocations but cannot act: a
cap-channel token is minted per invocation and revoked on the answer, one
invocation is outstanding per satellite, and a deadline destroys the node
rather than waiting on it. The node runs under its own operation, never
the first caller's, because the broker's abort of an operation cancels
every execution under it and code mode aborts its operation on every
teardown; the phase 3 review found that a host launched under a run's
operation died the first time `code_mode` ran in that run.

**The hook bus is a `weft/event_manager`** (the design note, "The hook
bus"; `packages/client/src/client/extension/hooks.gleam`). One handler
per installed extension in load order; notifications by `notify`, the
`tool_call` gate by `sync_notify` with any block winning, and the two
chained transforms, `context` and `tool_result`, as a fold rather than a
fan-out. The fan-out runs on a deadline-bounded weft worker, never on the
strand driver, because an unanswered `call` exits its caller. The
`Invoker` the bus is given must return inside its documented bound and
must never raise, because the manager is linked to the host process and
has no rescue; `hosts.invoke_event` meets that by construction and a
queued invocation that cannot answer inside its caller's window is
refused rather than started. A malformed verdict costs the handler its
place on the bus and is logged; it is never read as a policy.

**The client surface is a different surface area** (the design note,
"The rest of pi's surface, mapped"). `user_bash`, `ui_prompt_*`, `ctx.ui`,
commands, shortcuts and flags belong to the TUI's own extension surface
under its own ruling, not to the harness vocabulary; the manifest reserves
a `[client]` table for it.

**Process machinery goes through weft, and `docs/weft.md` is the standing
guide.** Phases 1 through 3 of loom#159 are on `main`, and the hook bus
is the first consumer of `weft/event_manager`, which the adoption note's
census had said fit nothing in the tree. The page carries which shape
maps to which primitive, the nine rules a port is held to, and the
standing rejections. Weft does not shrink the tree: the adoption note
measured net +1,191 lines through phase 2 and a further +167 for phase
3, because an exhaustive `case state, message` matrix is larger than the
recursive functions it replaces. What it buys is one owner per race.

**The `noproc` claim rule, both halves.** The drain ledger installs its
monitor when it *handles* a claim, so the claim is made from a leaf owner
the scope adopts before releasing it
(`runtime/strand_runtime.claim_through`), pinned by
`restart_reap_test.reaper_claim_outlives_a_driver_killed_mid_claim_test`.
That ordering cannot be the ledger's only defence, because a claim reaches
the ledger as a message and a reaper that drains and exits in the gap can
be met no other way. `noproc` is what a monitor answers about a pid that
was already gone and never a reason a process exits with, so the ledger
reads it as a departure and retires that generation (#171,
`drain_registry_test.claim_naming_an_already_departed_reaper_retires_it_test`).
`Killed` and every other abnormal reason still fail the session closed.
The comment above the claim site in `strand_runtime.gleam` said the
opposite until this change; the test was right and the comment was stale.

**A model-created schedule may steer, but may not wake.**
`ModelSchedulesSteer` is the default; the addendum in
`docs/design-notes/scheduled-heartbeats.md` carries the argument, and
**#161** is the evidence. None wakes an idle strand unless the operator
writes `[schedules] model_created = "wake"`. A schedule always targets the
strand that created it, and the schedule seam's private `create`, reached
through `door`, refuses a subagent outright until the ownership model in
#154 and #163 exists.

**`AGENTS.md` and `CLAUDE.md` are both read, in that order** (#169).
`client/system_prompt.discover` fills two slots, a workspace file beats
both globals, and `AGENTS.md` renders first because it is the file every
other harness reads. Each file arrives in an `<instructions>` fence naming
its path and origin, and the default pack tells the model that at most
one `user-default` block exists and that it is always first.

**MCP is code-mode only, and the jail decision is open** (#106, #109).
Generated per-server capability modules, never a generic dispatcher,
because a generic dispatcher collapses the vetting bound to "the whole
registry, for every program". `mcp/transport.PortTransport` spawns the
server **unjailed** and its own module doc says so; `docs/architecture/mcp.md`
records the jail as an open decision. Do not let any document claim
otherwise.

**The ledger keys on `{op_id, step_id}`; paths key on `{op_id, step_id,
source_index}`** (ADR-005's addendum). `source_index` is absent from
`ExecIdentity` because adding it would mint one ledger per `code_mode`
call. The abort-epoch table is measured and not pruned.

**A host missing a code-mode prerequisite registers no `code_mode` tool at
all**, because a tool definition is a byte prefix of the provider's cached
region. Code mode ships in the main release artifact with
`DIST_CODEMODE=0` as the opt-out (`docs/distribution.md`).

**R3 and R8 will never gate, and R10's exemptions are the formatter's.**
The first two over-report by construction. R10 exempts a comment at the
top of a block and one between two constructor fields because
`gleam format` deletes a blank line in both positions.

---

## Deliberately open

Named, with an issue where one exists. None of these is unfinished work
somebody forgot.

- **The MCP server jail** (#109). Undesigned, not unbuilt. `mcp/transport`
  is the seam an answer attaches to.
- **The rest of MCP's v1 cuts**: HTTP transport plus OAuth (#108), an
  end-to-end against a third-party server from the wild (#110),
  elicitation (#111), `listChanged` (#112).
- **Extension secrets come from the process environment.** An extension's
  `[[net.secret]]` names an environment variable the server reads and the
  broker injects into the request; there is no vault, keychain or command
  backend. That is **#181**, filed after the design settled on one
  `SecretStore` seam, and it is undesigned in the sense that the seam's
  shape is the open part.
- **`ext.remember` and `ext.recall`**, the `ext/` reserved fact prefix, and
  a producer for `agent_settled`. All named in the design note, none
  commissioned; an extension that declares `agent_settled` is logged inert
  at boot rather than left to look as if it fired.
- **Per-extension serialisation of invocations.** The host registry is one
  actor whose mailbox is the queue, so two different extensions invoked
  from two strands at once wait on each other. The module doc names the
  case and the per-extension lease that fixes it, to be built when the
  case is measured rather than imagined.
- **`[proc]` grants for extensions**: the jail's readable roots would need
  the toolchain and the manifest would need to name which binaries an
  extension may run. This is what phase 5 (#25, #26) is blocked on, and it
  is undesigned.
- **Nested `AGENTS.md` files** are not read (#172). `Host.guidance` is one
  string fixed at session open; per-edit precedence needs a per-tool-call
  channel, which is a question about the two-channel doctrine before it is
  a build.
- **`cap/task` on weft.** `cap` is the satellite-side prelude with no weft
  dependency, and adding one puts weft into the offline build seed. That is
  a distribution decision.
- **One weft gap upstream**: a monitored, non-panicking call against a
  pre-existing pid, which `broker/internal/call.try_call` and the host
  registry's `ask` still hand-roll.
- **The residual `runtime` interleave flake**: the `tools` scenario's
  boundary count, pinned at 14 in `interleave_test.gleam`, reported 13
  about four times in a thousand under the previous edition's stress
  runs. Two parallel tool calls whose results arrive together look like
  the cause; relaxing the pinned count is the owner's call.
- **Playbooks** (#139). An installed extension's `skills/**` is already
  part of the installed subset, so the storage half exists; what does not
  is the server surfacing name, description and location in the system
  prompt. Track it on the extension route rather than building it twice.
- **Scheduling follow-ups**: on behalf of a subagent (#154), `cap/schedule`
  on the orchestration seam (#156), a schedule that never fires never
  expires (#157), and #162 through #165.
- **Compaction stages C1/C2 and memory stage M3** are out of the release
  by design and have no issue.

---

## How to verify

`make help` lists the commands. `make check` is the full gate and is
exactly what CI runs; `make check-<package>` narrows it; `make doc-check`
checks the doc graph and the citations; `make lint` is the house-rule
lint; `make selftest` says which enforcement layers the kernel actually
provides; `make e2e` and `make e2e-codemode` are the jailed end-to-ends
(`make codemode-seed` prepares the offline cache the second needs, and
the extension e2e refuses a stale seed until it is rebuilt).

Five hazards, each of which has cost real time here.

**Verify a gate by its own exit code.** `make check > log; echo $?; tail
log` reports `tail`'s status and has produced confident false greens here
more than once, including one in this week's extension work. Capture
`make`'s status directly into the log, then read the log for failures.

**`make check-<package>` does not run lint, and a failing package never
reaches lint either.** `scripts/check.sh` runs the lint only when it is
given no package arguments, and it runs it last under `set -e`. `make
doc-check` is a separate target that `make check` never runs, and in CI it
is a separate step after the gate, so a green `make check` with a red
doc-check is the ordinary way a PR fails: three citation line numbers
drifted on #200 after its author's last doc-check, and it cost a CI
round. Run `make doc-check` on the final tree, after the last commit.

**A fresh worktree can fail on Hex rather than on your diff.** A new tree
resolves every package's dependencies from scratch, and enough parallel
requests hit the Hex API rate limit; it presents as a build failure with
nothing to do with the change. Wait and re-run before diagnosing.

**Do not put a verification worktree under `/tmp`.** Code mode correctly
refuses a cap socket there, because the jail replaces `/tmp` with the
scratch tmpfs, and `/tmp` also breaks `make codemode-seed` discovery. Put
it beside the repository and remove it when done.

**A PR that conflicts with `main` gets no CI at all.** GitHub cannot
compute the merge ref, so the checks never start and `gh pr checks`
reports nothing rather than a failure. Rebase first; #199 sat with no
checks for an hour because of a one-file docs conflict.

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
