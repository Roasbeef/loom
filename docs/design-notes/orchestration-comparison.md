# Design note: orchestration compared

Status: **note, not a work package.** Research only; nothing here is
built, and nothing here changes a frozen interface. It measures Loom's
multi-agent orchestration against two systems that solve a nearby
problem, and ends with a verdict on the one structural question the
comparison keeps returning to: whether code mode should be able to reach
the subagent plane.

External claims are sourced. Where a source is marketing copy, or where
the code and the copy disagree, the disagreement is written down rather
than smoothed over.

## The three systems, at the level of mechanism

### Loom: strands over a durable tree

A subagent in Loom is a **strand** — the same driver code as the main
conversation, with its own cursor into a shared write-once conversation
tree and its own model config. The model reaches strands through six tools
in `packages/tools/src/tools/agent.gleam`, wired to a live runtime by
`packages/client/src/client/agency.gleam`:

- `agent_spawn(purpose, brief, tools?, within_ms?, context?, detach?)`
  mints a child and returns a handle rendered `{strand}#{operation}`.
  `tools` may only *narrow* the caller's own set. `context` is `fresh`
  (the child sees its brief and nothing else) or `my_conversation` (fork
  at the caller's leaf, copying its whole context window).
- `agent_wait(handles, within_ms?)` takes a **list** of handles against
  one shared deadline and answers one result per handle: `Ready(outcome,
  report, notes)` or `Pending(waited_ms)`. Pending is an answer, not a
  failure.
- `agent_send(strand, message)` delivers one attributed message, landing
  as `Steered` on an open run or `Started` as a fresh one.
- `agent_note` / `agent_notes` are a durable blackboard, every key forced
  under `agent/{caller}/`.
- `agent_roster` reads the lineage ledger — durable state, not process
  state, so it still answers after compaction has erased every handle
  from the model's context.

Addressing is descendant-only: a strand may wait only on what it spawned,
and speak only to a parent or a descendant. That is what keeps the wait
graph acyclic, and it fails closed — a strand with no lineage cell is
`NotAddressable`, never "unknown, allow."

The transport is the point. Strands never message through BEAM mailboxes,
because a mailbox lives in a process heap and a supervisor restart
vaporizes whatever was sitting unread in it. Every payload travels in a
commit; only after it is durable does the sender ring a **nudge**, a
contentless doorbell asking the target to re-plan now. A lost doorbell
costs one poll interval. A lost payload cannot happen
(`docs/architecture/messaging.md`).

The shipped caps are deliberately small: `depth_cap: 1` — only the strand
a human is talking to may spawn, so there are no grandchildren —
`fan_out: 8` live children per strand, `session_strands: 16`, and a
30-second ceiling on one `agent_wait`. The depth cap is enforced
structurally as well as numerically: a child simply does not receive
`agent_spawn` in its tool set.

A child's result is its last assistant message, a `String`, with its
blackboard notes attached. There is no structured-report format.

Alongside this sits **code mode** (`docs/architecture/code-mode.md`): the
model writes a Gleam program, a lint bounds its capability set by the
transitive closure of its imports plus its own `@external` declarations,
the program compiles hermetically, and it runs in a jailed satellite BEAM
node whose only reachable effect is one capability channel back to the
broker. The capabilities are exactly `cap/{fs, proc, net, git, lsp,
report, task, actor, kv}`. `cap/task` gives `parallel_map`
(order-preserving), `race`, `both`, and `all`; when `race` picks a winner
the losers are *killed*, which makes the channel emit a `cancel` frame,
which makes the broker revoke the effect and kill its executor process
group. `cap/actor` gives typed, program-scoped actors with bounded
mailboxes that die with the satellite. The jail is Landlock, seccomp,
cgroup v2, bwrap namespaces, `no_new_privs`, and rlimits, and `make
selftest` reports which of those the running kernel actually provides.

No capability is agent-shaped. A code-mode program cannot spawn a strand
and cannot message one. The nearest thing to a shared surface is
`cap/kv`, which is session-scoped — but it is explicitly ephemeral, may
be evicted between calls, and its own module doc says to treat it as a
cache and never a database. It is not a transport.

### Claude Code: subagents, and a script that runs them

A Claude Code subagent is a markdown file with YAML frontmatter in
`.claude/agents/`. The frontmatter carries `name`, `description`,
`tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`,
`skills`, `mcpServers`, `memory`, `background`, `isolation`, and hooks;
the body is the system prompt. Non-fork subagents start with fresh,
isolated context — the parent's conversation history is not inherited —
and results return as the `Agent` tool's return value, or as a completion
notification for a background subagent. `SendMessage` resumes one with
its full history intact. Default depth is three layers, and up to twenty
subagents run concurrently. Subagent output is scanned before the parent
reads it: instruction-like text is escaped and marked, not removed
([sub-agents docs][cc-subagents]).

That is the model-driven half, and it is structurally close to Loom's:
the parent decides, turn by turn, what to spawn next, and every result
lands in a context window.

The half Loom has no analogue for is **dynamic workflows**. Claude writes
a JavaScript orchestration script, a runtime executes it in an isolated
environment separate from the conversation, and intermediate results live
in script variables instead of context. The documented primitives are
`agent(prompt, opts)` — with an optional JSON `schema` that forces
structured output, and a `label` — and `pipeline(items, ...stages)`,
where each item flows through all stages independently rather than
waiting at a barrier. The docs' own summary of the difference is exact:
with subagents "Claude, turn by turn" decides what runs next; with a
workflow, "the script" does ([workflows docs][cc-workflows]).

The runtime's constraints tell you what kind of thing it is: no
filesystem or shell access from the script itself, no module loading (a
script containing `import()` fails before the run starts), sixteen
concurrent agents, a thousand agents per run, and resumability within the
same session. The bundled `/deep-research` workflow fans searches across
angles, cross-checks sources, votes on each claim, and filters out claims
that did not survive — marking claims it could not check as unverified
rather than refuted.

Three further primitives — `parallel(thunks)` as a barrier, `phase(title)`
for progress grouping, and a queryable token `budget` the script uses to
scale its own depth — are described in this note's commissioning brief as
factual. The public workflows page documents only `agent()` and
`pipeline()` and defers "the full set of options" to the Agent SDK
reference, which I fetched and which contains no Workflow tool entry.
**I could not verify those three from public documentation** and take
them on the brief's word.

### Prime Agent: a REPL that spawns REPLs

Prime Intellect open-sourced Prime Agent in August 2026 under MIT
([repository][pa-repo]; [paper][pa-arxiv]). It is a TypeScript host with
a Python runtime, and the claims below come from reading its source tree
and its own `packages/coding-agent/docs/` at `main`, not from press
coverage — which turns out to matter.

The model gets **one** tool: a persistent IPython kernel. Files, shell
commands, skills, subagents, and compaction all happen as Python code
inside it. Python state survives across tool calls and across compaction.
This is the Recursive Language Model idea: context as a variable,
delegation as a function call ([RLM blog][pi-rlm]).

Subagents are spawned with `await rlm("subtask", name=..., model=...,
thinking=...)`. The call travels over a Jupyter comm named `host.request`
to the TypeScript host, which starts a child `AgentSession` with its own
context, session directory, and kernel.

And here is the mechanism the coverage gets wrong. Press summaries say
`rlm(...)` "returns their results programmatically." The source docs say
the opposite, twice, in the same words: the call "returns over the comm
immediately after task admission with a child handle; it never waits for
or returns the child's answer. Results arrive only through explicit
`agent_message` replies or files"
(`packages/coding-agent/docs/rlm-runtime.md`). The returned
`RLMSpawnHandle` carries `rlm_child_id`, `name`, `session_dir`, and
`model` — "It confirms admission only and never contains the child's
answer." The docs' own guidance is to spawn and then *end the turn*.

The reason is structural rather than philosophical: IPython processes
shell messages serially, so a cell that blocked awaiting a child's answer
on the shell channel would deadlock the kernel that must deliver it.
Admission replies ride the control channel to dodge exactly that.

Agents then talk. `agent_message.send(text, receiver_role="parent" |
"child" | "sibling", receiver_name=..., mode="auto" | "steer" |
"follow_up")` routes through the daemon supervisor and returns a receipt
that is `delivered` (it reached an idle target's context) or `queued`.
Broadcast is family-roster-scoped. The daemon derives sender identity and
enforces size, rate, and pending-queue limits. Default recursion depth is
two, so a root may have children and grandchildren.

Durability is real and process-shaped: append-only JSONL transcripts,
per-session artifact directories, a `kernel-state.dill` namespace
snapshot, process-safe leases keyed by canonical transcript path, and
scheduled ticks claimed *before* delivery so a crash does not replay an
uncertain prompt. After a worker crash, recovery "reaps its old process
group and tracked detached bash trees, appends a visible recovery marker
to the transcript, restores the root under the same active-session ID,
and does not replay uncertain side effects"
(`packages/coding-agent/docs/daemon.md`). The parent-scoped child
registry survives kernel restart, compaction, and parent restore.

The **Continual Harness** is the second headline idea: a persisted ledger
(`harness/harness_state.json`) of supplemental prompts, memories, skill
descriptions, and reusable subagent specs. `/refine` reviews the current
trajectory and applies small create/update/delete edits with recorded
before/after snapshots for rollback. The base system prompt is immutable;
refinements are supplemental.

On isolation, Prime Agent is refreshingly blunt and says the same thing
in four separate places: the IPython kernel "executes model-generated
Python and shell-magics with the worker's OS permissions… The kernel
boundary isolates protocol and lifecycle concerns; **it is not a security
sandbox**." Workers and kernels are separate processes "for lifecycle and
failure containment, not security sandboxes."

On purpose: the paper describes "an open-source harness for long-horizon
evaluation and coding-agent workflows," reporting ARC-AGI-3 RHAE Best@1
rising from 30% to 95.5%. (The widely repeated framing that 95.4% is the
human-expert baseline comes from press coverage, not the abstract — I did
not verify it.) Prime Intellect is an RL company and ships `prime-rl` and
`verifiers` separately, and the RLM blog argues the next gain comes from
training models to manage their own context; but Prime Agent itself is
presented as evaluation and coding infrastructure, not a training loop.

## Where the comparison is not apples to apples

Three differences matter enough that a single scorecard would lie.

**Different threat models.** Loom's first design priority is security and
isolation; Prime Agent states plainly that it has no security boundary
and tells you to supply one externally. Scoring Prime Agent's sandbox as
"missing" reads a scope decision as a failure. Its isolation is aimed at
*fault* containment — a worker crash takes down one root tree — and by
that measure it works.

**Different products.** Claude Code workflows run on a hosted runtime
behind a metered plan. The thousand-agent cap and the large-run warning
are cost controls for a service, not architectural limits. Loom is a
harness you run yourself.

**Different maturity.** Loom's `depth_cap: 1` is a milestone-scoped
choice with a written rationale — "the value of grandchildren is unproven
and the cost of unbounded recursion is not." Comparing it to a shipped
product's depth of three compares a scope decision with a product
decision.

## Where Loom is ahead

**Durable payloads.** All three persist transcripts. Only Loom makes the
*message* a commit and the wake signal disposable, so that losing the
signal costs latency and can never cost data. Prime Agent is closer than
Claude Code — the daemon issues `delivered`/`queued` receipts and claims
scheduled ticks before delivery — but its docs describe message *routing*
and never state that the payload is durable before the receipt, which for
schedules they do state. Loom's guarantee is stated, tested (there are
doorbell-loss tests that prove a run completes on the poll alone), and
falls out of the same single-writer commit that records everything else.
The difference is degree and where the guarantee is written down, not
durable versus not.

**Cancellation that reaches the kernel.** When Loom's `race` picks a
winner, the losers are killed, the channel emits a `cancel` naming the
in-flight call, the broker revokes the effect and kills its executor
process group. Prime Agent reaps process groups during crash recovery and
cancels descendants on parent teardown, but has no in-language race whose
losers' side effects are revoked. In a Claude Code workflow, stopping an
agent makes `agent()` resolve to `null`; nothing documented revokes work
already dispatched.

**Kernel-enforced isolation.** This is the clearest gap and the only one
both competitors concede outright. Loom bounds a program's capability set
by reading its source — no reflection, no `eval`, no dynamic module
lookup, so the import closure is a real upper bound — and then runs it
behind Landlock, seccomp, and cgroups anyway. Honesty requires the
caveat: `docs/spec-gaps.md` item 14 records that the satellite's
enforcement report is usually lost on the happy path, so a green
code-mode run does not currently *prove* the layers applied. The
mechanism is there; the evidence that it engaged is racing a teardown.

**Typed, compiled orchestration.** Claude Code's orchestrator is
JavaScript evaluated at run time; Prime Agent's is Python in a REPL.
Loom's is Gleam, type-checked before a single capability call — the
compile error doubles as the capability-argument validator, so a mistyped
`proc.run` never reaches a node.

That last advantage comes with the punchline of this whole note: it does
not currently apply to agent orchestration at all, because the language
it applies to cannot reach an agent.

## Where Loom is behind

**Gap 1 — control flow is a model decision.** Every Loom fan-out is N
`agent_spawn` calls plus an `agent_wait`, each a tool call, each a turn,
each occupying context. The plan exists only as a sequence of decisions
the model made; it cannot be read, diffed, or rerun. A Claude Code
workflow moves the loop into a script whose intermediate results never
enter a context window, and writes that script to a file you can open.

The honest ranking here is not the obvious one. Prime Agent's headline is
"programmatic sub-agent calling," but because `rlm()` composes at
*admission* rather than at *completion*, its Python cannot express a
barrier either: you spawn, end the turn, and the answers arrive later as
messages the model reads. Its control flow is model-driven across turns
in the same way Loom's is; what it makes cheap is the spawn, not the
join. On deterministic orchestration the ordering is Claude Code
Workflows well ahead, with Loom and Prime Agent behind it and close to
each other — and Loom's `agent_wait` over a list against one deadline is
a real join, which Prime Agent does not have.

**Gap 2 — no structured result.** `Waited.Ready` carries `report:
String`. A parent that wants a file list must ask for one in prose and
parse prose. Claude Code's `agent(prompt, {schema})` forces JSON matching
a caller-supplied schema, so the parent branches on `found.files`
directly. Loom is half-way there already: `agent_note` writes typed
`JsonValue` cells and `Ready` carries them back. What is missing is the
parent stating the shape up front and the child being held to it.

**Gap 3 — no budget the model can see.** Loom exposes wall-clock
`within_ms` and nothing else. The broker has budgets, but they are effect
budgets — `max_outstanding`, `deadline_ms` — and the model cannot read
them. Prime Agent has `goal.create(..., token_budget=...)`, autonomous
limits on turns, tokens, and wall clock, and folds each child's usage
into the parent turn that launched it with a persisted
`child_usage_attributed` entry that is reapplied on reload. A workflow
that can query its remaining budget can decide to run three verifiers
instead of seven; Loom's model can only guess.

**Gap 4 — no verification patterns as primitives.** Adversarial
verification, perspective-diverse verifiers, judge panels, loop-until-dry
— Loom has every part these need (fan-out, a one-deadline join, a durable
blackboard) and none of them as something you invoke rather than
describe. Claude Code ships one of them as `/deep-research` and documents
the family.

**Gap 5 — scale.** `depth_cap: 1`, `fan_out: 8`, `session_strands: 16`
against a documented three levels and twenty concurrent subagents, or a
workflow's sixteen concurrent and a thousand per run. For a 500-file
migration these numbers, not the architecture, are the binding
constraint. They are a deliberate scope choice, but the choice costs a
use case.

## What closing each gap would take

**Gap 2, structured results — small, and do it first.** Add an optional
`result_schema` to `SpawnRequest`, carry it into the child's brief and
its terminal validation, and give `Waited.Ready` a
`Result(JsonValue, String)` beside the prose `report`. The blackboard
already proves JSON crosses this seam intact, and `tools/agent` plus
`client/agency` are the only two modules that change. It is worth doing
on its own merits, and it is the precondition for everything else:
deterministic orchestration over a `String` result is a script that
regexes prose, which is worse than a model reading it.

**Gap 3, token budget — medium, and it lands in the durability plane, not
in tools.** Loom would need per-strand token accounting rolled up the
lineage ledger and surfaced through `agent_roster` or the system prompt.
Prime Agent's design is the one to copy: attribute a child's usage to the
parent turn that launched it, persist the attribution as its own entry,
and reapply it on reload so tree-wide totals stay reconcilable. Loom's
write-once store is already the right shape for an entry like that. Worth
it once anything runs unattended; premature before that.

**Gap 4, verification primitives — cheapest, and do it last.** These are
briefs and prompts, not mechanisms; Loom could ship an adversarial-verify
brief today. What is missing is not the pattern but the deterministic
loop that runs it N times and counts. Gap 4 is downstream of gap 1.
Building it first produces a pattern the model has to remember to follow,
which is the thing the pattern exists to stop relying on.

**Gap 5, scale — raise the numbers when there is evidence, not before.**
Nothing architectural blocks `depth_cap: 2`; the note in
`default_config` asks for evidence that grandchildren pay, and that is a
reasonable thing to ask.

**Gap 1, deterministic orchestration — the real question.** Two routes
look distinct and turn out not to be.

The first is to give code mode a `cap/strand`. The second is to build a
separate, trusted orchestration script interpreter over the existing
`Agency` seam — which is tempting, because the seam is already exactly
the right shape: six total closures, every one judged against a `Caller`,
every failure a `Refusal` rather than a crash. An orchestrator needs to
call those six and nothing else. It needs no `cap/fs`, no `cap/proc`, no
satellite.

But a script the model authors is model-influenced execution, and Rule
Zero says model-influenced execution never runs in the harness VM. So the
"trusted interpreter in the harness" route is closed, which means the
script runs outside, which means it needs a channel back to the broker —
and that is `cap/strand` again, just with a much smaller capability set.
The two routes converge on mechanism. Where they stay different is
policy, and that difference is the whole design.

## The verdict: connect them, through a second seam

The question is whether a code-mode program should be able to spawn and
message strands. `docs/spec-gaps.md` item 5 defers it deliberately, and
its reasoning deserves to be taken seriously rather than argued past.

**The case for keeping them apart.** The messaging plane's durability
rule — if the recipient would act differently for having received it, it
goes through a commit — is a correctness rule written for *trusted*
participants. `messaging.md` says so outright: sibling strands are
trusted harness code, and the model influences their content, never their
code. A code-mode program inverts that: it *is* untrusted model-written
code. A messaging capability would let it write into the plane the
harness trusts, under a trusted strand's name, from a jailed node.
Attribution gets muddier: `agent_send`'s payload passes through a trusted
tool that can bound it, where a `cap/strand.send` payload arrives over a
wire. And rate is the sharpest edge: `agent_spawn` is throttled by turn
cost, because the model pays a round trip per spawn. A program with a
loop pays nothing, so `fan_out` and `session_strands` — numbers chosen
for a human-paced model — become the only brake.

**The case for connecting them.** Loom has already built the expensive
half. A vetted, typed, compiled, jailed program with real cancellation is
precisely the substrate a deterministic orchestrator wants, and the only
reason it cannot orchestrate is that nobody wrote an agent-shaped module.

And the untrusted-writer objection proves less than it appears to. The
satellite already holds `cap/proc`, which runs arbitrary commands in the
workspace, and `cap/fs`, which writes files a sibling strand will later
read. Measured against those, "may send text to a descendant it spawned"
is a *smaller* authority, not a larger one. If untrusted-writer were
decisive, `cap/fs` would have failed it first. So the objection is really
about the durable store's integrity specifically — and integrity is
defensible with the technique used everywhere else in Loom. A cap call is
not a write; it is a request the trusted broker services under policy.
`cap/strand.spawn` would be serviced by the same `Agency` closures the
tool uses, judged against the same `Caller`. The refusals already exist
and are already total: `NotADescendant`, `DepthCapReached`,
`FanOutCapReached`, `UnknownTool`, `ParentRunEnded`. The authorization
model does not need inventing. It needs reusing.

Note also what Rule Zero does and does not say. It forbids
model-influenced execution *in the harness VM*. It does not forbid
model-influenced code from *causing* a harness commit — every tool call
already does that. Reading Rule Zero as a ban on `cap/strand` overreads
it; what it actually bans is the shortcut of running the orchestrator in
the harness, which is why the seam has to exist at all.

**The verdict.** Connect them — but not by adding a tenth capability to
the existing nine.

A code-mode program today is a *workspace* program: it holds fs, proc,
git, and lsp, and it orchestrates effects. An orchestration program is a
different animal, and should be a different seam holding `cap/strand` and
`cap/report` and nothing else. A compromised orchestrator could then
spawn and message within its own lineage and could not touch the disk,
the network, or a process. This costs almost nothing to build: the
vetting lint is already an allowlist parameterized per submission
(`seam.allowed_imports`), so two prelude sets over one pipeline is a
configuration of machinery that exists, not a new mechanism.

Give that seam its own tighter caps, aimed at the two properties that
actually change when a loop replaces a turn: a hard ceiling on spawn
admissions per execution, and the existing rule that a program may only
wait on and message within the lineage its own strand roots.

Sequence matters, and the sequence is not the interesting part first:

1. **Structured results (gap 2).** Without them the orchestrator parses
   prose and buys much less than it looks.
2. **Honest enforcement reporting (`spec-gaps.md` item 14).** An
   orchestration seam is the first thing anyone will run unattended, and
   "we could not confirm the jail applied" is not an acceptable answer
   for the unattended case.
3. **The orchestration seam** — `cap/strand` plus `cap/report`, its own
   caps, its own allowlist.
4. **Token budget (gap 3),** so a program can size its own fan-out.
5. **Verification briefs (gap 4),** which become worth writing only once
   something deterministic runs them.

The separation is load-bearing in one specific sense and not in the
general one. It is load-bearing as a rule about *which capabilities
travel together*: an orchestrator that can also write files is a
materially worse thing to hand a model than one that cannot. It is not
load-bearing as a rule that untrusted code may never reach the durable
plane, because the broker is exactly the apparatus for letting untrusted
code reach a trusted plane under policy, and Loom already runs every
other capability through it.

## What I could not determine

- **`parallel()`, `phase()`, and `budget()` in Claude Code workflows.**
  The public workflows page documents `agent()` and `pipeline()` and
  defers the rest to the Agent SDK TypeScript reference, which contains
  no Workflow tool entry. Taken from this note's brief, not verified.
- **Whether Prime Agent's `agent_message` payload is durable before its
  receipt.** The docs describe receipts, routing, and limits, and are
  explicit that scheduled ticks are claimed before delivery — but say
  nothing equivalent for messages. Unknown, not absent.
- **The 95.4% ARC-AGI-3 human-expert baseline.** Press coverage only; the
  arXiv abstract reports the 30% → 95.5% improvement and no baseline.
- **Whether any model has now been trained around Prime Agent.** A
  fetched summary of the launch blog quotes "currently no model has been
  trained around Prime Agent"; I did not confirm the sentence against the
  page itself, and it may have aged.
- **Runtime behaviour of either external system.** Every mechanism claim
  about Prime Agent comes from its source tree and its own docs at `main`
  as of 2026-08-25; every claim about Claude Code comes from its public
  documentation. I ran neither.

[cc-subagents]: https://code.claude.com/docs/en/sub-agents
[cc-workflows]: https://code.claude.com/docs/en/workflows
[pa-repo]: https://github.com/PrimeIntellect-ai/prime-agent
[pa-arxiv]: https://arxiv.org/abs/2608.23552
[pi-rlm]: https://www.primeintellect.ai/blog/rlm
