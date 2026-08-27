# Issue plan

**Filed.** Issues #1–#20 exist on `roasbeef/loom`; this document is the plan
of record behind them and uses GitHub numbers throughout. The milestone
itself must still be created by hand — the MCP server exposes no milestone
tool — so `release-blocker` is the queryable proxy for "in the release".

Sources: `docs/spec-gaps.md` (the triage tables), Part 2, the Part 4 status
column and §5.1 of `docs/loom-implementation-spec.md`,
`docs/review/m4-triage.md`, `docs/review/m5-agent-comms-judgment.md`,
`.github/`, `docs/design-notes/four-decisions.md`,
`docs/design-notes/compaction-and-memory.md`,
`docs/design-notes/orchestration-comparison.md`,
`docs/architecture/code-mode.md`, and `docs/code-tour.md` §17.

---

## The milestone

**Name: `v0.1 — claimed, true, and self-extending`.**

Shipping v0.1 means the whole system, not the honest subset of it. An
earlier draft of this plan proposed a release that added no capability:
make M0–M4's partial rows read `done` and stop there. That work is still
the first thing that happens, but it now *gates* the release instead of
closing it. M4.5, M5 and M6 are core to the design, and M6 in particular is
the claim the system exists to make — a harness that writes Gleam, proves
it in a sandbox, and hot-loads it into itself. A first release without it
is not a release of this system.

Four bodies of work, in order.

**Phase one makes the existing rows true.** M0 through M4 are recorded
partial, and the release makes them `done` under Part 4's own rule —
demonstrated by a test or a live run, not under test-supplied hooks, and
not on a host that could not enforce what it claims. Compaction runs in
production rather than in the demo's own hooks; some production path
raises an escalation and an approved grant can actually reach a policy
decision; a green code-mode run proves the jail engaged; the TUI's
end-to-end drives the real server; `make check` passes on both platforms
§0.3 names. This gates the rest, because building three unbuilt milestones
on four accepted on partial evidence is the exact fault the reconciliation
just exposed.

**Phase two is the orchestration seam (M4.5, WP-N).** A second code-mode
seam carrying `cap/strand` and `cap/report` and nothing else, so a program
can fan out over subagents and join on one deadline deterministically,
instead of the model spending a turn per spawn. The authorization model is
reused rather than invented: the same `client/agency` closures the `agent_*`
tools call, judged against the same `Caller`, with the same total refusals.

**Phase three makes the harness competent at real code (M5).** Role routing
that actually walks its fallback chain; triggered rules; memory that
survives a compaction; and **MCP reached through code mode** (#106), as
generated per-server capability modules rather than registered tools. It
also pays the last M4 debt — the capability names vetting admits that the
shipped router refuses (#16) — because the promotion ladder is built on top
of them.

> **Amended.** This phase originally led with `lsp_*` and `dap_*`. Both moved
> to phase five (#25, #26) and MCP took their place. Each of those serves one
> capability family and needs a long-lived stateful stdio peer that
> `proc.run`'s one-shot exec cannot carry; MCP opens every server that
> already exists, on a specified protocol, through a seam code mode already
> has. The `lsp.*` arm of #16 — four of its thirteen names — moved to phase
> five with #25 rather than being stubbed against a client that does not
> exist.
>
> The count in the old wording was also wrong. It read "eight of the nine cap
> modules"; counting modules that actually reach the harness through
> `dispatch.call`, four of the nine need no router work at all, and the real
> surface is thirteen capability names across five modules. The correction is
> on #16.

**Phase five is the language-service tier.** `lsp_*` over a sandboxed,
per-project language-server client (#25), and `dap_*` over the same port
seam (#26). Both need the long-lived stdio peer that phase three
deliberately does not build, and the `lsp.*` capability names wait here for
the client rather than being stubbed twice.

**Phase four is the promotion ladder (M6, WP-M).** An agent writes a Gleam
tool, saves it as a named skill, compiles it against a wider prelude, proves
it against its tests inside the jail, and — with one recorded human
decision — the running harness loads it into itself, with unload and
rollback.

### Be honest about the size

M6 is at 0%. There is no `packages/ext`; nothing in the tree crosses the
line the design draws. Its hard part is not `code:load_binary`, which is
one call. The hard part is the **TCB freeze**: proving that the extension
API cannot reach `StorageWriter` or broker internals, by compile-time
visibility *and* runtime name checks — both, because either alone fails a
different attack. Below L3 every defense is a kernel; at L3 the extension
runs inside the harness VM and the only boundaries left are the package
graph and what the loader checks by name.

Proving that responsibly means an adversarial review pass of the kind code
mode got, recorded in `docs/review/`. That pass had three reviewers and the
central claim still needed correcting. Budget for the same outcome here,
and treat the review as part of the rung rather than as something that
happens if there is time.

M5 is roughly a work package and a half of new tool surface, and one of its
acceptance criteria cannot pass as written (below). M4.5 is the smallest of
the three and the best specified. This is not a small release. It is the
design.

### Closing criterion

Every acceptance criterion in the M0 through M6 rows of Part 4 is
demonstrated under Part 4's evidence rule; "What the rows still owe" is
empty; and `gate-linux`, `gate-macos` and `jail-linux` are green on `main`
with `gate-linux` set as the required check.

Three riders:

- **M5's row cannot close as written.** "Fallback chain survives injected
  429 storm" is not demonstrable by any code path today, because
  `client/wiring.request_target` always returns `ForResolved` and never
  `ForRole`, so the chain tail is parsed, validated and inert. #14 either
  makes the chain reachable or the row needs an amendment; the criterion
  cannot simply be run.
- **M6 closes on two tests and a document**: the L0→L3 promotion-ladder
  integration test with a live rollback mid-session, the TCB freeze test,
  and a recorded adversarial review of the extension zone whose HIGH
  findings are closed or explicitly accepted.
- **macOS green means the suites run or skip for a declared reason.** It
  does not mean a macOS jail exists (§5.1, and "Not in the first release"
  below).

---

## Phases, and what gates what

The work is sequential, and a flat list of thirty-three issues is unusable.
Each phase opens when the one before it closes; inside a phase, order is
advisory except where an issue names a dependency.

| Phase | Body of work | Issues | Opens when |
|---|---|---|---|
| 1 | Claimed and true (M0–M4) | #1–#13 | now |
| 2 | The orchestration seam (M4.5 / WP-N) | #20, #21–#24 | phase 1 closes |
| 3 | Semantic tools, routing, memory (M5) | #14, #15, #16, #25–#29 | phase 2 closes |
| 4 | The promotion ladder (M6 / WP-M) | #18, #30–#33 | phase 3 closes |

**Why phase 1 gates everything.** Not out of tidiness — four of its issues
are literal preconditions of later phases.

- **#5**, the satellite's enforcement report, is WP-N's own second bullet
  and appears verbatim in M4.5's acceptance row. An orchestrator is the
  first thing anyone runs unattended, and "we could not confirm the jail
  applied" is not an answer for that case.
- **#11 (D1)** picks the mechanism by which an approved escalation is ever
  spent. #4 applies that mechanism to the tool path; #24 applies the same
  mechanism to code mode. Choosing it inside a work package would choose it
  implicitly, for the seam with the larger blast radius.
- **#2** is §0.3's definition of done. Every later work package inherits it;
  a permanently red job stops being read within a week, and then the gate
  that verifies phases 2–4 is decorative.
- **#13 (D3)**'s honesty patch makes `FullEnforcement` mean something. Both
  the orchestrator and the extension candidate runner execute inside the
  satellite jail, and today a policy demanding memory and pid ceilings
  passes full enforcement with those ceilings unapplied.

**Why phase 2 precedes phase 3.** WP-N's seam and #16's cap-module work
both edit the cap router. Doing them in parallel is a merge conflict in the
most security-sensitive dispatch in the tree; doing #16 second also lets
`cap/lsp` be serviced against the LSP client #25 builds rather than stubbed
twice.

**Why phase 3 precedes phase 4.** A skill that can only call `proc.run` is
not a capability, and the L1 rung's whole premise is that a saved program
keeps working. #16 is therefore an M6 precondition wearing an M4 label.
Memory's stage M1 needs the canonical session id (#15) to scope a query at
all.

**Inside phase 4**, #33 (the TCB freeze) depends on #32 for an API to
freeze, and #32 does not close until #33 does. The extension zone is built,
then proven, then shipped — in that order, and the milestone does not close
on the middle step.

---

## How the phase-1 issues were grouped

Kept from the original plan, because the grouping still holds. The twenty
orphans in `spec-gaps.md` are not twenty issues; they land in ten places,
and six of them land in the same one.

- **Six one-line amendments became one housekeeping issue** (#9). M2
  integration 1, WP-K 1, WP-A 7, WP-I 7, WP-L 6 and M2 integration 2 are
  all "add a sentence to a normative document". They share a reviewer, a
  branch, and an afternoon.
- **Four wiring-seam items became one issue** (#14). M3 runtime wave 11,
  12 and 13 and WP-L 8 are all decisions about `client/wiring.request_target`
  and the config `client/serve` builds around it. Fixing any one of them
  opens the same function.
- **Two api-shaped gateway duplications became one issue** (#17).
- **Two provider stubs became one issue** (#19).
- **Three "a suite does not fail when it should" findings became one issue**
  (#6). Three different files, one failure mode, and it is the exact
  failure mode `.github/workflows/ci.yml` was written to close.

**Four items were decisions, not tasks** (#11–#13, #20). All four now have
argued verdicts in `docs/design-notes/four-decisions.md`; the issues carry
them, and the owner ratifies.

---

## Labels

| Label | For |
|---|---|
| `release-blocker` | in the release — the queryable proxy for the milestone |
| `phase:1` `phase:2` `phase:3` `phase:4` | which phase the issue opens in |
| `kind:bug` / `kind:feature` / `kind:decision` / `kind:housekeeping` | what the issue is |
| `kind:security` | touches the sandbox, the broker, the policy path, or the TCB |
| `area:sandbox` `area:broker` `area:runtime` `area:client` `area:provider` `area:codemode` `area:events` `area:conformance` `area:ci` `area:docs` `area:tools` `area:ext` | package or surface |
| `owner-action` | cannot be done by an agent; needs a human with repo admin |

---

## Phase 1 — claimed and true (M0–M4)

Filed as #1–#13; bodies are on GitHub and unchanged. Summarized here so the
phase is readable in one place.

| # | Title | Why it is in the release | Labels |
|---|---|---|---|
| 1 | Set `gate-linux` as the required status check on `main` | A gate that does not block a merge is a report. Every other issue is verified by that job. | `owner-action` `area:ci` |
| 2 | Make `make check` pass on macOS | §0.3's definition of done has been unmet since WP-A, and this is the only red job in the tree. | `kind:bug` `area:ci` `area:sandbox` `area:broker` |
| 3 | Make compaction live in production (stage C0) | M3's largest untrue claim. The branch index already assumes compaction happens. Implementation in flight — sequence around it. | `kind:feature` `area:runtime` `area:client` |
| 4 | Thread the grants channel, and raise escalations from a production path | Retitled and rescoped after D1's advisory pass: the raiser is the cheap part, the severed grants channel is the work, and the code-mode half moved to #24. | `kind:feature` `kind:security` `area:runtime` `area:client` |
| 5 | Carry the satellite's enforcement report in every code-mode outcome | M4 is accepted on a run that cannot prove the jail engaged. Also WP-N's first prerequisite. | `kind:bug` `kind:security` `area:codemode` `area:sandbox` |
| 6 | Stop three suites reporting something other than what they prove | `soak-short` runs 200 seeds per pull request; a rare red trains a reader to re-run rather than look. | `kind:bug` `area:conformance` `area:runtime` |
| 7 | Drive the real TUI against the real server in a test | A fake on both sides of a protocol proves the fixture, not the protocol. | `kind:bug` `area:client` `area:conformance` |
| 8 | Root the session tree under an application supervisor | Close is a controlled crash, and `client/serve` is now the long-lived host WP-E said to wait for. Sequence after #3. | `kind:bug` `area:runtime` `area:client` |
| 9 | Land the six normative amendments the gap log names | Six of the twenty orphans, one branch. Two are load-bearing rules found by a live failure. | `kind:housekeeping` `area:docs` |
| 10 | Run the two sandbox probes the jail runner can now afford | The kernel that made them impossible now exists in `jail-linux`. | `kind:security` `area:sandbox` `area:ci` |
| 11 | **D1.** When does a policy refusal become an escalation? | Verdict argued: raise always with deterministic ids; the release work is the spend mechanism, not the raiser. Blocks #4 and #24. | `kind:decision` `kind:security` |
| 12 | **D2.** Promote the citation checker to error level? | Verdict argued: (b) plus three amendments. **Not release-blocking** — no dependency either way. | `kind:decision` `area:docs` `area:ci` |
| 13 | **D3.** Per-execution cgroup limits: accept the gap, or build delegation? | Two decisions filed as one. The honesty patch is release scope regardless: today a `FullEnforcement` policy demanding mem/pid ceilings passes with them unapplied. | `kind:decision` `kind:security` `area:sandbox` |

Order inside the phase: #1, then #2, then #3, then #11 → #4, then #5, then
#6, then #13 → #10, then #7, #8, #9. #12 whenever.

---

## Phase 2 — the orchestration seam (M4.5 / WP-N)

Content and ordering come from `docs/design-notes/orchestration-comparison.md`,
which argues the verdict and deliberately does not put the interesting part
first. Its first two steps are already filed: structured results (#21) and
honest enforcement reporting (#5, in phase 1).

### #20. **D4** — ratify the WP-J 15 / WP-J 16 split

Already filed as a decision. `four-decisions.md` argues the verdict:
**split them.** WP-J 16 lands as WP-N's first commit (#22); WP-J 15 moves
out of #4 and into WP-N (#24), because it is D1's unresolved spend
mechanism wearing a code-mode costume and cannot be specified until that
mechanism is chosen. Ratifying this opens the phase.

### #21. Give a spawn request a `result_schema`, and hold the child to it

**Problem.** `Waited.Ready` carries `report: String`. A parent that wants a
file list has to ask for one in prose and parse prose.

**Why it matters.** This is the precondition for everything else in the
phase: deterministic orchestration over a `String` result is a script that
regexes prose, which is worse than a model reading it. Loom is most of the
way there already — `agent_note` writes typed `JsonValue` cells and `Ready`
carries them back, so JSON crosses this seam intact. What is missing is the
parent stating the shape up front and the child being held to it.

**Done.** `SpawnRequest` grows an optional `result_schema`, carried into the
child's brief and into its terminal validation; `Waited.Ready` gains a typed
result beside the prose `report`; the `agent_*` tools expose it. A child
whose terminal result does not match its schema fails naming the schema; a
matching one comes back as typed JSON, not prose.

**Scope.** `tools/agent` and `client/agency` are the only modules that
change.

**Pointers.** spec Part 2 WP-N, first bullet; `orchestration-comparison.md`
gap 2 and "What closing each gap would take".

**Labels.** `release-blocker`, `phase:2`, `kind:feature`, `area:runtime`,
`area:client`

### #22. Thread one `ExecIdentity` through the code-mode pipeline (WP-J 16)

**Problem.** Identity and budget are specified in three places. `ExecConfig`
has the caller assemble `BuildConfig`, `SatelliteConfig` and `ExecId`, each
carrying its own operation, step and budget. The broker opens one ledger per
`{op_id, step_id}`, and the end-to-end builds under `step_id <> "-build"`,
opening a second ledger against the same `Budget` value.

**Why it matters.** The build/run split is deliberate — different phase,
different policy, different enforcement report — and the two are sequential,
so the doubled outstanding cap is latent rather than live. The defect is
that nothing *types* how many identities a caller may mint, so a third one
is a copy-paste away. WP-N adds the largest new caller this pipeline will
ever get, which makes this the cheap moment.

**Done.** One threaded `ExecIdentity` from which the build phase is derived,
one parent budget, phases named in the type. No caller can mint a third
identity, and the ledger count per execution is a property of the types
rather than a convention `make e2e-codemode` itself breaks. Behaviour
unchanged.

**Sequence.** WP-N's first commit, or the branch immediately before it.

**Pointers.** spec-gaps WP-J 16; `four-decisions.md` D4;
`codemode/codemode.ExecConfig`, `codemode/build.BuildConfig`,
`codemode/satellite.SatelliteConfig`, `codemode/satellite.ExecId`,
`broker/budget`.

**Labels.** `release-blocker`, `phase:2`, `kind:housekeeping`,
`area:codemode`, `area:broker`

### #23. Build the orchestration seam: `cap/strand` + `cap/report`, its own allowlist, its own ceiling

**Problem.** A code-mode program cannot orchestrate. Every Loom fan-out is N
`agent_spawn` calls plus an `agent_wait`, each a tool call, each a turn,
each occupying context. The plan exists only as a sequence of decisions the
model made; it cannot be read, diffed, or rerun.

**Why it matters.** Loom has already built the expensive half — a vetted,
typed, compiled, jailed program with real cancellation is exactly the
substrate a deterministic orchestrator wants. The only reason it cannot
orchestrate is that nobody wrote an agent-shaped module. And Rule Zero
closes the alternative: a trusted interpreter in the harness VM is
model-influenced execution in the harness VM, so the script runs outside,
which means it needs a channel back to the broker — which is this seam.

**Done.** A submission is vetted against one of two allowlists: the existing
*workspace* seam (`cap/{fs, proc, net, git, lsp, report, task, actor, kv}`)
or the new *orchestration* seam (`cap/strand` + `cap/report`, nothing else).
`codemode/vet/policy` is already an opaque per-submission allowlist, so this
is a configuration of machinery that exists. `cap/strand` provides `spawn`,
`wait` (a list of handles against one deadline), `send`, `note`/`notes` and
`roster` as RPC stubs over `cap_call`, serviced by the same `client/agency`
closures the `agent_*` tools call and judged against the same `Caller`. The
seam gets a hard ceiling on spawn admissions per execution, plus the
existing rule that a program may address only the lineage its own strand
roots.

**Exit** (WP-N's own, and M4.5's acceptance row):

- an orchestration sample — a documented program submitted verbatim by its
  test, as WP-J's migration sample is — fans out over the fixture repo,
  joins on one deadline, and returns one structured result;
- **seam confinement, both directions**: an orchestration-seam program
  importing `cap/fs` or `cap/proc` is rejected by vetting, and a
  workspace-seam program importing `cap/strand` is rejected, both as the
  structured rejection the model reads;
- a program looping past the spawn-admission ceiling is refused in band *at*
  the ceiling, and the refusal names it;
- spawning or messaging outside the program's own lineage is refused under
  the existing total refusals — `NotADescendant`, `DepthCapReached`,
  `FanOutCapReached`, `UnknownTool`, `ParentRunEnded`.

**Must not.** Put `cap/fs`, `cap/proc`, `cap/net` or `cap/git` on the
orchestration seam — which capabilities travel together is the whole point,
and an orchestrator that can also write files is a materially worse thing to
hand a model than one that cannot. Run any part of the orchestrator in the
harness VM. Raise `depth_cap`, `fan_out` or `session_strands`. Build a
model-readable token budget or verification-pattern primitives: the design
note sequences both *after* this milestone, and a verification pattern built
before the loop that runs it is a pattern the model must remember to follow.

**Depends on** #21 (structured results), #5 (enforcement report), #22.

**Pointers.** spec Part 2 WP-N; `orchestration-comparison.md` "The verdict:
connect them, through a second seam"; spec-gaps WP-J 5;
`codemode/vet/policy`, `client/agency`, `packages/cap`.

**Labels.** `release-blocker`, `phase:2`, `kind:feature`, `kind:security`,
`area:codemode`

### #24. Let an approved escalation widen a code-mode execution (WP-J 15)

**Problem.** Every clearance the code-mode pipeline makes passes empty
grants — at the build call, the node launch, the launch policy composition,
and the cap router. An approved escalation widens nothing. It fails closed,
so this is a liveness gap rather than a hole, but the approval path through
code mode is inert.

**Why it matters.** This is the same severed grants channel #4 fixes in the
workspace tool path, one seam over. Decide the spend mechanism once, in
#11; apply it to the tool path in #4; apply it here. The order is forced —
doing this first would choose the mechanism implicitly, inside a work
package, for the seam with the higher blast radius.

**Done.** Grants thread into `ExecConfig` and compose at the launch policy;
a code-mode execution re-run under an approved escalation carries them,
asserted by `make e2e-codemode`.

**Depends on** #11 (the mechanism), #4 (its first application), #22 (one
identity to thread them alongside).

**Pointers.** spec-gaps WP-J 15; `four-decisions.md` D4 and "Where D1 and D4
meet"; `codemode/build`, `codemode/launch`, `codemode/satellite`.

**Labels.** `release-blocker`, `phase:2`, `kind:feature`, `kind:security`,
`area:codemode`

---

## Phase 3 — semantic tools, routing, memory (M5)

M5's row reads `+I(lsp,dap), routing, TTSR, memory`, and its acceptance is
"semantic rename across fixture repo via LSP; DAP breakpoint session;
fallback chain survives injected 429 storm". Three existing issues move into
this phase: #14 (routing), #15 (the session id memory needs), #16 (the cap
modules the ladder is built on).

### #25. `lsp_*` tools over a sandboxed, per-project language-server client

**Problem.** The agent edits code by hashline anchors and greps for symbols.
It has no semantic view: no rename, no references, no definition, no
diagnostics. `cap/lsp` ships as a prelude stub with nothing behind it.

**Why it matters.** M5's headline acceptance criterion is a semantic rename
across the fixture repo, and it is the tool gap that most separates the
harness from what an engineer actually does to a codebase.

**Done.** A language-server client over a stdio port, supervised per
project, running under the broker's sandbox policy like any other spawned
process; `lsp_*` tools on top of it with total decoders at the wire
boundary. Acceptance: a semantic rename across the fixture repo, driven by
the model, with the edits landing through the ordinary hashline path.

**Owns the shared seam.** The supervised, sandboxed stdio-port client is
also what #26 runs on. Build it here.

**Pointers.** spec Part 2 WP-I ("Later in M5"); spec Part 4 M5; `cap/lsp`;
`packages/tools`, `packages/broker`.

**Labels.** `release-blocker`, `phase:3`, `kind:feature`, `area:tools`,
`area:broker`

### #26. `dap_*` tools: a debug-adapter session over the same port seam

**Problem.** No debugger surface exists.

**Why it matters.** M5's second acceptance criterion is a DAP breakpoint
session. See "One argument against" below — this is the weakest
release-blocking claim in the plan, and it is in the release on the owner's
decision.

**Done.** `dap_*` tools over the port client #25 builds; a breakpoint
session against the fixture repo — set, run, hit, inspect, continue —
demonstrated by a test rather than by a human at a terminal.

**Depends on** #25.

**Pointers.** spec Part 2 WP-I; spec Part 4 M5.

**Labels.** `release-blocker`, `phase:3`, `kind:feature`, `area:tools`

### #14. Settle the wiring seam's four model-routing questions

Already filed. Moves into the release: M5's third acceptance criterion is
"fallback chain survives injected 429 storm", and that criterion **cannot
pass as written** — `request_target` always returns `ForResolved`, never
`ForRole`, so the chain tail is parsed, validated and inert. The issue also
carries the two orphans whose proposed home is M5 (catalogue `thinking`,
per-identity model facts) and the "only `main` is dispatched on" gap. All
four open the same function.

**Labels.** add `release-blocker`, `phase:3`

### #15. Mint a canonical session id in `core`

Already filed. Moves into the release as memory's precondition:
`events/search` cannot scope a query to a session, and the schema's
`parent_session_id` column stays unwritten, because Loom has no session-id
concept. Needs a `protocol-change/` proposal against §1.1.

**Blocks** #28.

**Labels.** add `release-blocker`, `phase:3`

### #16. Service the eight cap modules the router refuses

Already filed. Moves into the release, and the reasoning is the widening
itself: the promotion ladder's premise is that an L0 program keeps its shape
as it climbs. A skill that can only call `proc.run` is not a capability, so
L1 and L2 are hollow on top of a router that services one module of nine.
This is the largest undocumented gap between what
`docs/architecture/code-mode.md` describes and what runs, and M6 is built
directly on it.

**Sequence.** After #23 — both edit the cap router — and after #25, so
`cap/lsp` is serviced against a real client rather than stubbed twice.

**Labels.** add `release-blocker`, `phase:3`

### #27. Triggered rules (TTSR): a per-strand stream scanner

**Problem.** Project rules either occupy context permanently or do not
exist. Loom has neither a rule store nor anything watching model output.

**Why it matters.** Design §8: project rules dormant at zero context cost, a
per-strand stream-scanner process injecting a rule when its trigger fires in
model output — cheap, killable, off the hot path. §10 makes the performance
requirement explicit: TTSR scanning runs on scheduler-preempted processes so
an expensive projection can never delay a settlement.

**Done.** A durable rule store; a per-strand scanner process fed by the
streaming parse; injection through the existing hook registry. A dormant
rule costs zero context, demonstrated by a projection test. A scanner that
crashes, hangs, or floods cannot delay a settlement — asserted, not argued.
A conformance scenario covers trigger, injection, and scanner death
mid-turn.

**Pointers.** `docs/loom-design.md` §8 and §10; spec Part 4 M5, Part 5 track
8; `runtime/hooks`, `packages/runtime`.

**Labels.** `release-blocker`, `phase:3`, `kind:feature`, `area:runtime`

### #28. Memory stage M1 — recall and surfacing

**Problem.** A fresh session cannot find a decision made in a previous
session's compacted-away history. The index that would answer the question
is already built and has no production caller.

**Why it matters.** The design note's stage M1 is composition only: no new
storage, no new services. It is the cheapest memory that exists, and it is
the stage that makes compaction survivable rather than merely correct.

**Done.** Stage M1's exit criteria, from `compaction-and-memory.md` Part 5:
`events/search` wired into `client/serve` (open plus event-bus-driven
sync); session scoping in SQL; the `history_search` tool registered; the
`agent/` notes digest injected via `run_start`. Exit: a fresh session finds,
by search, a decision made in a previous session's compacted-away history.

**Depends on** #15 — the session scoping is the session id.

**Cross-reference, not duplication.** The compaction note stages C1
(compaction becomes good) and C2 (cache-clever, behind measurements) beyond
the C0 that #3 lands. Neither is named by an acceptance row, and both stay
out of this release; see "Not in the first release".

**Pointers.** `docs/design-notes/compaction-and-memory.md` Part 5 stage M1;
`packages/events`, `client/serve`.

**Labels.** `release-blocker`, `phase:3`, `kind:feature`, `area:runtime`,
`area:events`

### #29. Memory stage M2 — the memory session and the distillation pipeline

**Problem.** Nothing persists a lesson across sessions. Hindsight memory is
design text.

**Done.** Stage M2's exit criteria, from the design note: registered
`memory/*` custom entry types with provenance; the distillation pipeline
(extract → consolidate) leased, capped and redacted, writing to a
per-workspace memory session; `run_start` injection of the digest under a
token cap, fenced and attributed; the `remember` tool. Exit: conformance
scenarios for the pipeline's crash points and caps; a demonstrated
preference persisting across two sessions; the anti-feedback exclusion
tested.

**The security paragraph is part of the issue, not a footnote.** Memory is
durable prompt injection by construction. Three mitigations are required,
and the note names them: provenance on every distillate, auditable back to
source entries; injection always fenced and attributed ("distilled from
session X, N sessions ago"), never presented as operator text; and the
anti-feedback rule made structural — the pipeline skips `memory/*` entries
and injected digests *by type*, not by string matching. One interaction is
genuinely unsolved and should be recorded rather than closed: the precise
rewrite's "erase X" contract cannot mechanically reach prose derived from X,
and erasure guarantees stop at the first derivation unless every derivation
keeps full source lists.

**Depends on** #28.

**Out of scope.** Stage M3 — retention cadence during sessions,
mental-model-style named distillates, cross-workspace memory, the tokenizer
upgrade, and Part 5 track 8's memory→skill promotion path. The note is
explicit that M3 is judged later, on M2 evidence.

**Pointers.** `docs/design-notes/compaction-and-memory.md` Part 3 and Part 5
stage M2; spec Part 5 track 8.

**Labels.** `release-blocker`, `phase:3`, `kind:feature`, `kind:security`,
`area:runtime`, `area:events`

---

## Phase 4 — the promotion ladder (M6 / WP-M)

The ladder, from `docs/architecture/code-mode.md`:

```
L0  code-mode program     ephemeral, satellite-jailed, dies with the call
L1  session skill         L0 saved as a durable, named, reusable entry;
                          runs at L0 privileges
L2  extension candidate   compiled against a wider but still
                          capability-stubbed prelude; runs its tests in the
                          sandbox, results attached
L3  installed extension   after explicit human approval: hot-loaded into
                          the harness ExtensionZone
L4  core change           a pull request to Loom; ordinary review and
                          release; never runtime-loaded
```

L0 is built. L1 through L3 are this phase; L4 is a pull request and needs no
mechanism. There is no `packages/ext` today.

Two properties carry up the ladder and must be true at every rung: **nothing
self-promotes** — the step from a proven candidate to an installed extension
requires a human decision, recorded durably — and **the shape of the code
does not change as it climbs**. An installed extension is an OTP actor
implementing a typed behaviour, which is the same actor model `cap/actor`
hands a jailed program at L0.

### #30. L1: the skill store

**Problem.** A code-mode program dies with the call. There is no way to save
one, name it, and run it again.

**Done.** Named code-mode programs as durable entries with provenance;
invoke-by-name **re-vets and re-compiles from source**, rather than caching
an artifact keyed by name — the design's hard rule is that we never load a
`.beam` we did not compile, and at L1 that rule means the source is the
stored thing. A skill runs at L0 privileges, in the same satellite jail, on
the same allowlist. A skill whose source stops passing vetting refuses in
band naming the rejection, rather than running a stale artifact.

**Depends on** #16 — a skill that can only call `proc.run` is not a
capability.

**Pointers.** spec Part 2 WP-M, L1; `docs/loom-design.md` §7;
`docs/architecture/code-mode.md` "the promotion ladder".

**Labels.** `release-blocker`, `phase:4`, `kind:feature`, `area:ext`,
`area:codemode`

### #31. L2: the candidate pipeline

**Problem.** Nothing compiles a program against anything but the L0 prelude,
and nothing runs a program's own tests.

**Done.** An extension prelude allowlist — wider than L0's, still
capability-stubbed, so a candidate is written against the API it will have
at L3 without holding it yet. A test-in-jail runner that executes the
candidate's tests inside the sandbox and attaches the results durably to the
candidate entry, so the promotion decision at L3 is made against evidence
rather than a claim.

**Exit.** A hostile L2 candidate — attempts FFI, oversleeps, leaks processes
— is rejected or killed **at each defense layer**, and the refusal names the
layer that caught it. One layer catching all three is not the criterion.

**Depends on** #30.

**Pointers.** spec Part 2 WP-M, L2 and its exit list; `docs/loom-design.md`
§7.

**Labels.** `release-blocker`, `phase:4`, `kind:feature`, `kind:security`,
`area:ext`, `area:sandbox`

### #32. L3: extension behaviours, hot load, unload and rollback

**Problem.** Nothing crosses into the harness VM. This issue is where the
harness gains a capability at runtime.

**Done.** Typed behaviours — `ExtTool`, `ExtHook`, `ExtProjection` — and an
ExtensionZone that supervises them under time-boxed invocation wrappers.
Vetting runs on **source** against the extension allowlist and the harness
compiles that source itself; `code:load_binary` installs under
harness-controlled `ext_{name}_{vsn}` names. Unload and rollback (`code:purge`
plus reload of the previous version) restore the prior version mid-session.
Load and unload emit durable events. An unapproved candidate cannot install:
promotion takes an explicit human decision or a pre-declared org policy for
signed sources, recorded durably either way.

**Exit.** WP-M's promotion-ladder integration test: an agent-authored
fixture tool goes L0→L3 and serves a live tool call, and a rollback restores
the prior version mid-session.

**Depends on** #31. **Does not close until #33 closes** — the zone is built,
then proven, then shipped.

**Pointers.** spec Part 2 WP-M, L3; `docs/loom-design.md` §7 hard rules;
`docs/architecture/code-mode.md` "the promotion ladder".

**Labels.** `release-blocker`, `phase:4`, `kind:feature`, `kind:security`,
`area:ext`, `area:runtime`

### #33. Freeze the TCB, and have someone attack it

**Problem.** Design §7's hard rule: "The trusted computing base is not
runtime-extensible. Storage, state machine, broker, sandbox drivers never
change at runtime. Self-improvement grows the tool and hook surface only.
This line is what makes the idea shippable." Nothing enforces that line
today, because nothing crosses it today. #32 makes something cross it.

**Why it matters, precisely.** Every rung below L3 is defended by a kernel —
a jail the extension no longer runs in once it is loaded. At L3 the only
boundaries left are Gleam's module visibility and whatever the loader checks
by name. A hot-loaded module that can obtain a `StorageWriter` reference
writes past every invariant the durability plane holds, with no commit
boundary and no audit line. This is the issue that decides whether the
headline feature is shippable.

**Done — two mechanisms, both, not either.** The spec's wording is
"compile-time visibility + runtime name checks", and the conjunction is the
requirement:

1. **Compile-time.** The extension behaviours' package exposes no path to
   `StorageWriter`, to broker internals, or to the raw `cap_call` channel.
   Enforced by the package graph and checked by a test that fails when a new
   export opens one, so the freeze survives the next refactor.
2. **Runtime.** Loaded modules carry harness-controlled `ext_*` names, and
   calls out of a loaded module are checked by name against a deny set — so
   a module that compiles clean and reaches at runtime is refused rather
   than served.

**And an adversarial review pass, recorded.** A review of the extension zone
in `docs/review/`, with a named reviewer set, findings triaged, and HIGHs
either closed or explicitly accepted. Code mode got exactly this treatment
and it was not ceremonial: three reviewers went at it and the central claim
still needed correcting. Budget for the same outcome. This is the reason M6
is expensive, and it is not `code:load_binary`.

**Exit.** WP-M's TCB freeze test passes; the review document exists and its
HIGH findings are resolved.

**Depends on** #32. **Gates the milestone.**

**Pointers.** spec Part 2 WP-M exit list; `docs/loom-design.md` §7;
`docs/review/` (code mode's own pass as the precedent).

**Labels.** `release-blocker`, `phase:4`, `kind:security`, `area:ext`,
`area:runtime`

### #18. Build the chaos runner and the ten-minute soak

Already filed, and previously argued out of the release on the grounds that
M1's *acceptance* is green and the chaos tier is a WP-E/WP-T exit criterion
M1 was accepted without. That argument held for a release that shipped no
new runtime behaviour. It does not hold for this one.

The release now ships a harness that mutates its own running supervision
tree. #32's rollback criterion — "restores the prior version mid-session" —
is a liveness claim under load, and random process kills under load are the
only test that separates a rollback which restores a version from one that
restores a version and leaks the old one's processes. §0.3 also wants the
work package's own exit criteria met, and this is one of them.

**Labels.** add `release-blocker`, `phase:4`

---

## One argument against, made once

**DAP (#26) is the weakest release-blocking claim in this plan.** LSP earns
its place: semantic rename is what separates an agent that edits text from
one that edits code, and #16 and #30 both consume the client it builds.
Nothing consumes DAP. No phase-2 or phase-4 issue depends on it, no
acceptance criterion outside M5's own row mentions it, and a breakpoint
session is inherently interactive in a harness whose core is headless — the
demonstration is a test driving a debugger rather than an engineer using
one. Cutting it would remove a protocol adapter and a tool family from the
release and cost nothing else in the tree.

The second-weakest is memory stage M2 (#29), which could ship as M1-only
recall and still leave the release coherent; its cost is a durable pipeline
with crash points, caps, redaction, and a security posture that has to be
argued.

The owner's decision is that M5 is core and ships whole. Both are in the
release, labelled `release-blocker`, and this paragraph is the whole of the
objection.

---

## Not in the first release

Named here so no issue implies otherwise. The list is much shorter than it
was.

| Body of work | Where it is recorded | Why it stays out |
|---|---|---|
| **A macOS jail** (WP-H phase 2, Seatbelt) | spec §5.1, Part 4 M3 note | Deliberately unbuilt: a generated profile can only be tested against the string it was told to emit, which cannot distinguish deny-by-default from permissive-through-a-typo. The platform refuses rather than degrades, so nothing runs silently unconfined. #2 makes macOS *build and test*; it does not make macOS *safe*. |
| **The egress proxy sidecar** | spec Part 5 track 10, §5.1 | Track 10 hardens a sidecar that does not exist. `Proxy(allowlist)` fails closed today — jailed exactly as network-off, with a skipped `network-proxy` entry saying the allowlist was not enforced. Correct behaviour, no release dependency. |
| **The MCP adapter** | spec-gaps WP-G 9 | Widening to M6 makes the case *against* it stronger, not weaker: the promotion ladder is Loom's own answer to the problem MCP solves, and the design says outright that the persistent-actor mode is something "nothing MCP-shaped can express". Shipping both in one release would ship two extension stories. Wants a Part 5 track number. |
| **Compaction stages C1 and C2** | `compaction-and-memory.md` Part 5 | C0 (#3) is the bar for "runs at all". C1 makes it good — file-operation tracking, blob-ref carry-forward, branch summaries through the navigation host, the TUI divider — and C2 is explicitly gated on measurements C0 has not produced yet. No acceptance row names either. |
| **Memory stage M3** | `compaction-and-memory.md` Part 5 | The note is explicit: judged later, on M2 evidence. Each item is an extension of a running system, which is the only position worth designing them from. |
| **A model-readable token budget, and verification primitives** | `orchestration-comparison.md` gaps 3 and 4; WP-N "must not" | WP-N forbids building either inside M4.5, and for a stated reason: a verification pattern built before the loop that runs it is a pattern the model must remember to follow. Both are the natural first work after this release. |
| **Raising `depth_cap`, `fan_out`, `session_strands`** | `orchestration-comparison.md` gap 5 | Nothing architectural blocks `depth_cap: 2`; `default_config` asks for evidence that grandchildren pay, and that is a reasonable thing to ask. |
| **#17 — `api.compact` / `api.navigate` and optional-brief `create_strand`** | spec-gaps WP-L 2, WP-L 3 | A duplication cleanup with no acceptance criterion behind it. WP-N reuses the `client/agency` closures as they stand. Take it when someone is already in `runtime/api`. |
| **#19 — the provider stubs** | spec-gaps WP-F 6, WP-F 7 | Neither half is named by an acceptance criterion in any row now in the release, and the pricing half feeds the token-budget work WP-N explicitly forbids building inside M4.5. The keychain backends are a deployment convenience the environment backend already covers. |
| **#12 — promoting the citation checker** | this plan, D2 | Answered, and nothing depends on the answer either way. |

---

## Where each orphan went

All twenty items in `spec-gaps.md`'s "Deferred work with no home" table, so
the owner can check nothing was dropped. GitHub numbers.

| Item | Goes to | Phase |
|---|---|---|
| WP-L 1 (production denial-raiser) | #4 | 1 |
| WP-J 15 (escalation widens nothing in code mode) | #24, moved out of #4 per D4 | 2 |
| WP-J 16 (one threaded `ExecIdentity`) | #22 | 2 |
| WP-E 8 (chaos tier) | #18 | 4 |
| WP-E 3 (application supervisor) | #8 | 1 |
| WP-G 9 (MCP adapter) | Not in the first release | — |
| WP-F 7 (keychain backends) | #19 — out | — |
| WP-F 6 (pricing tables) | #19 — out | — |
| WP-K 4 + WP-C-full 3 (canonical session id) | #15 | 3 |
| M2 integration 2 (`stream_options`) | #9 | 1 |
| WP-L 8 (per-identity model facts) | #14 | 3 |
| M3 runtime wave 13 (catalogue `thinking`) | #14 | 3 |
| WP-I 7 (tool timeout ceiling) | #9 | 1 |
| M2 integration 1 (one clock or era) | #9 | 1 |
| WP-K 1 (catch-up frontier rule) | #9 | 1 |
| WP-A 7 (decoder coverage criterion) | #9 | 1 |
| WP-L 2 (`api.compact` / `api.navigate`) | #17 — out | — |
| WP-L 3 (optional-brief `create_strand`) | #17 — out | — |
| WP-L 6 (queued vs placed acks) | #9 | 1 |

The eight items in the "Deferred work with a home" table now mostly have a
phase, because their homes came into the release:

| Item | Home | Phase |
|---|---|---|
| M2 integration 3 (provider surface for deferred polls and structural summaries) | summaries half → #3; deferred polls → #14's seam | 1, 3 |
| M3 runtime wave 11, 12 (fallback chain, role dispatch) | #14 | 3 |
| WP-J 5 (should a `cap/strand` exist) | answered yes → #23 | 2 |
| WP-J 14 (enforcement report in the outcome) | #5 | 1 |
| WP-A 3, WP-B/T 6 (pi `details`, JSONL import) | Part 5 track 6 | — |
| M3 messaging 2 (cross-node broadcast fan-out) | Part 5 track 4 | — |

---

## One item still unplaced

`docs/review/m5-agent-comms-judgment.md` closes with a designed-in hole it
declines to fix: a child strand cannot get an answer from its parent while
the parent is inside `agent_wait`, and `agent_send` to a *finished* parent
opens a fresh run — which is the exact property the design rejects
auto-enqueue over. The reviewer's instruction is "either bound that leg or
drop it from the rejection argument; as written the design contradicts
itself."

That is neither a bug nor scheduled work. It is a design document arguing
against itself, and the fix is one of two edits the owner must choose
between. The shipped behaviour is coherent; the *argument* for it is not.

It is worth re-reading before #23 lands, though. `cap/strand.send` puts the
same messaging leg behind a loop instead of behind a turn, which is where a
contradiction in the argument starts to cost something.
