# Design note: the harness playbook, read against Loom

Status: **note, not a work package.** A reading of Can Bölük's *The
Harness Playbook* (2026-09-02, the omp² postmortem) against the tree as
it stands on `main` at `b81a4d3`. Every claim about Loom below was
checked against the code rather than the docs, with the file cited. The
gaps it names are filed as issues under the `agent-parity` label; this
note carries the argument, the issues carry the work.

The short version: the post's three hardest chapters (the runtime
boundary, the kill boundary, the small stable tool roster) are Loom's
founding doctrine, and in two places Loom is ahead of what the post
proposes. Where Loom falls short it's mostly packaging: the right
primitive exists in one place and has been hand-copied elsewhere. The one
structural gap is a job primitive. And two of the post's biggest bets, an
in-process Bash interpreter and Python for extensions, we should reject
here on Rule Zero grounds.

## What the post argues

The post's frame is that a harness is systems software, not a while loop
around a fetch, and that the complexity has to have an owner. It picks
four operating modes as architecture tests (a multiplexed local
workspace, a remote driver, a spectator, and an autonomous "Factorio"
against hostile input) and derives five consequences: one authoritative
session, a trusted control plane with only a bounded stub in the sandbox,
bounded and cancellable work, explicit model/provider compatibility, and
views as pure projections. The chapters then work through state, runtime,
control plane, inference, the tool surface, the interface and the stack.

Those four modes are Loom's own tests under different names. The remote
driver and spectator are the thin-client doctrine (`docs/loom-design.md`
§8.5), and Factorio is Rule Zero. So the question isn't whether we agree
with the envelope, it's whether the tree actually delivers each
consequence.

## Where Loom is already right

**The runtime boundary (ch. 3).** The post's whole argument builds to
"put a single obedient stub inside the VM and keep everything else out".
That is what `packages/sandbox` is. The Go helper total-decodes a policy
(an unknown key is an error, never a guess, `internal/policy/policy.go`),
applies it to itself, and execs. Policy composition, refusal, budgets,
escalation and journaling all live host-side in `packages/broker`. Every
frame is capped at 16 MiB in both directions
(`internal/framing/framing.go`, `broker/framing.gleam`), the output cap
is enforced inside the jail with a discard-and-drain so a capped child
can't wedge (`internal/jail/run.go`), and the enforcement report is
judged on the host, so a degraded jail fails a full-enforcement demand
rather than passing quietly. The one piece of "decision logic" in the
jail is the TERM-to-KILL timer, which has no policy authority.

**The kill boundary.** The post says cancellation must be a runtime
contract, not every tool author's good behaviour. Loom's is token
revocation (`broker.abort` revokes every token of an operation, and a
token is 32 random bytes bound to `{op_id, step_id, policy, deadline}`),
then TERM-then-KILL addressed to the payload subtree by descent rather
than by pgroup, because `setsid(2)` defeats pgroup selection
(`internal/jail/cancel.go`, `docs/architecture/effects.md`), with a
cgroup under it on Linux. A satellite's wall deadline calls the same
abort and closes the cap socket, and an unlinked janitor re-runs the
teardown if the host dies first. This is the strongest part of the tree
and the post has nothing to teach it.

**Approval at the capability boundary.** The post's motivation for
interpreting Bash in-process is that nobody reads a 12-line shell string,
so approval should happen when execution reaches `ln`, not at the
string. Loom gets that property by a different route: the kernel denies,
the broker settles the refusal in band with the exact wanted grants, and
`client/escalate` files a record whose id digests the wanted diff *and*
the call's canonicalised effective arguments. An approval for one command
cannot be spent by a different one. That is the post's "capability
approver" without a parser.

**State (ch. 2).** The post's central claim is that if authoritative
state can't be derived from the journal, rewind, fork and resume are
lies, and its evidence is that only two of seventeen stateful pi
extensions got this right. Loom's answer is the three stores plus the
total program counter. Everything with a PC is in `op.state`
(`machine/operation.gleam`), including retry counters and the captured
context window. The tool roster and model are `strand.config`. The
subagent registry is `lineage/` facts, escalations are `escalation/`
facts, schedules are `schedule/config/` facts, and the system prompt
text itself is pinned as `prompt/system` (`client/system_prompt.gleam`).
Recovery boots every strand from the store, "last" is per leaf, and
there is no todo, plan-mode or hashline cache living in a closure
anywhere. The client is a pure projection: `packages/tui` imports
nothing from `session` or `storage`. And a fork is a strand spawn, which
is the post's "controller and actor" split done with processes.

**The tool surface (ch. 6).** The post measured that a 23-definition
roster costs nearly 2x wall-clock over a 5-tool one, and concludes the
permanent grammar should be tiny and the long tail should sit behind a
stable surface. Loom's roster is five to seventeen definitions, gated by
exactly that arithmetic, and the argument is written in the code
(`client/contributions.gleam`: "a permanently-refusing definition would
be paid for on every request of every strand for the life of the
session"). MCP sits behind code mode as generated per-server modules and
there is no dynamic roster. The post's own rule, "an open-ended
operation set wants a code surface", is `code_mode`.

**Inference quirks are confined (ch. 5).** The post's before/after is
an 880-line builder of provider-name booleans. Loom has two adapters
behind one `ProviderRequest`, one dispatch branch in
`provider/gateway.attempt_one`, and no provider-name branches at call
sites.

**Extensions (ch. 3 and 8).** The post chose Python so a `@remote`
attribute can ship a function into the sandbox. Loom's extension design
(`extension-architecture.md`, ADR-007) puts the tool body in the jail by
default and serves `net.request` from the broker with secret bindings.
On the property the post itself names for the Factorio case, that the
key never enters the jail, this is stronger: there is no key in the
extension's environment to leak, and no frame on the channel carries it.

## Where the post is right and Loom has a gap

Ranked by how much the fix buys. Each row is an issue.

**1. A job primitive. (#183)** The post's best observation is that a background
shell, a subagent, a dev-server daemon, a remote function, and an
ordinary call that ran past its budget are all the same object: a job
with stdin, stdout, an exit status and a signal handle, and that without
one primitive every tool grows its own spawn, poll, message, kill and
list. Loom has three lifecycle owners today and none of them is a job.
`bash` is foreground only and a call past its budget returns
`[command timed out]` as text (`tools/bash.gleam`). Subagents are a
six-tool surface with no `agent_kill`, only whole-operation abort.
Satellites (`codemode/launch`), the MCP stdio client and the planned LSP
peer each own their own lifecycle, and `docs/next.md`'s phase 5 would
add a fourth. What the agent can't do today is start the test suite,
keep working, and come back for the result. The fix is one weft-managed
job actor (spawn, poll, send, kill, list) with a durable `job/` fact per
job so a restart re-adopts or reaps it, and a tool surface of roughly
`job_start`/`job_poll`/`job_kill`. The `agent_*` tools become one client
of it, and a foreground call that exceeds its blocking budget becomes a
job rather than a timeout. Do this before phase 5, or LSP becomes a
fourth owner.

**2. Volatile session settings, and branch-blind marks. (#184)** The post's
state chapter has two failure shapes Loom shares. First, `set_config`
for queue mode and tool execution rewrites gateway memory only
(`client/gateway.gleam`'s `set_queue_mode` and `set_tool_execution`
update `state.runtime.settings`), so a restart resets them to defaults;
and `strand.config` is a register overwrite with no history, so a
setting change is not rewindable. Second, the operator config that
shapes a run (the catalogue, routes, `[[rule]]`, `[[schedule]]`, the
base policy, the assembled system prompt) is read at boot and never
digested into the tree, so a replay under an edited `loom.toml` is
silently a different program. And rule and schedule fired-marks are
keyed `(strand, name)` (`client/rules.fired_key`), so a rewind past a
fire leaves the mark and the rule never fires again on the new branch.
That is the post's "state outside the tree" bug in Loom's clothes. Fix:
make session-wide settings a register write, journal a per-run digest of
prompt, catalogue, routes and config, and key marks on the entry they
fired at.

**3. Limits are per-tool. (#185)** The post says truncation and blocking caps
belong in the library layer once, with opt-out, not as a helper each
tool remembers to call. Loom's byte cap is central and the `truncated`
flag crosses the wire structurally, and then each tool appends its own
prose notice (`bash.gleam` "[stdout truncated at the output cap]",
`grep.gleam` a different string). Spill-to-disk (`blob.bound`, 64 KiB)
is called at three sites; `fs_read`, `fs_edit`, `agent_*`, `schedule`
and `history` don't. Timeouts are per-tool constants. Fix: apply the
spill and the truncation diagnostic once in the runtime's `run_tool`
seam, with a per-tool opt-out, and give `ToolOutcome` a structured
diagnostics list beside `details` so the model can tell data from
harness commentary. The code-mode argument in the post is the one that
bites us: a program composing tool output through `cap/proc` cannot
rely on the output because a notice may be inside it.

**4. Tool output isn't streamed to clients. (#186)** The helper streams 32 KiB
chunks and the broker relays each as `CallOutput`, and then every caller
collapses the stream in `tool.collect_events` and returns on
`CallSettled`. Nothing reaches the event bus or the TUI until the call
settles; TUI streaming is provider tokens only. The wire already does
the hard part. Forward `CallOutput` to the bus as a bounded output
event.

**5. Loop ownership is a single slot. (#187)** The post's Director is a
journaled stack of behaviours that see a candidate yield before the
user does (plan mode, goal mode, a todo reminder, force-tool), each
answering pass, continue, yield, push, done or fail. Loom's
`before_run_end` is one closure returning an optional follow-up
(`runtime/effects.gleam`), composed by manual record wrapping in
`client/serve`. It works, but whoever wraps must remember to call the
inner hook, there is no ordering discipline, and rewind can't remove a
behaviour. Follow-ups drain before the run-end hook fires, so the shape
is expressible today; it just isn't packaged. Fix: a `director/` fact
prefix holding an ordered stack, folded rather than wrapped, with the
six verdicts. #142's todo capability is the first client.

**6. No forced tool call. (#188)** `ProviderRequest` has no `tool_choice`,
`response_format` or beta-header slot, so the post's honest-forcing
ladder (soft prompt always, native flag only when it's free, bounded
retries, then escalate) can't be built. The compaction doc already wants
a request-level flag for a different reason (suppressing the 5-minute
cache mark on the summary request). One field, one policy.

**7. A malformed tool argument kills the turn. (#189)** Both adapters
`json.parse` the accumulated `arguments_json` at settlement, and a
failure fails the whole stream as `MalformedStream`, which `retry`
classifies as `Terminal`. One bad brace from the model ends the turn
with no in-band correction. Settle it as an `is_error` tool result the
model can fix. The post's charitable coercion (a comma-joined string for
a string array) is optional; not killing the turn is not.

**8. Compaction blocks at the threshold. (#190)** Loom has three ways in
(threshold, overflow-and-retry, manual) and all three block the strand
while the summary round-trips. The post's speculative design fits the
tree unusually well: at ~90% of the window spawn the summarizer against
the current leaf, commit the checkpoint parented off that leaf, and when
the threshold arrives splice rather than summarise. The write-once tree
makes "branch, summarise, splice" three commits. A "shake" stage (drop
heavy tool results before summarising) is a cheaper first step.

**9. Contract hygiene. (#191)** No tool carries a version and none takes an
intent argument. Loom already has `prompt_snippet` and `details`, so
the shape is there; add `version` to `tool.Tool` and an optional `intent`
to every schema so the journal and the TUI can show what the model
thinks it's doing while arguments stream.

**10. Two smaller ones. (#192, #193)** `fs_read` handles text files only, and a scheme
resolver for Loom's own durable objects (`history://`, `agent://`, an
`ArtifactRef`) is worth more than PDF support. Subagents share the
parent's workspace outright with no copy-on-write view, a known and
unmitigated collision.

## Where to push back

**The session DOM.** The property the post wants is "no run-influencing
state outside the journal", and Loom has it with typed registers, total
decoders and ownership baked into register keys instead of XML.
Rewind-as-DOM-diff is elegant, but our answer to "what does rewind
reconcile" is that owned registers don't need reconciling. Don't adopt
a DOM. Close the two honesty holes in gap 2 instead.

**Bash as an in-process interpreter.** Reimplementing Bash and coreutils
inside the trusted VM to interpret a model-written string is
model-influenced execution in the harness VM. Rule Zero forbids it, and
it would be the largest TCB addition in the project's history. Loom gets
the approval granularity the post wants from the kernel plus the action
digest. The Windows argument is real, and it is a phase 7 sandbox
driver, not a parser.

**Python for extensions.** Loom's vetting theorem is that a Gleam
program's capability set is computable from its source. Python's AST
introspection buys the `@remote` ergonomics and loses that theorem
entirely. The extension note already answers the post's "two
filesystems" complaint differently: the tool body runs in the jail and
the broker serves effects, so there is only one filesystem to see.

**Convars as a console language.** Declaring a setting once with flags
for scope, persistence, inheritance and replication is the right idea,
and it maps onto a registers namespace. The `cfg`, `bind` and `alias`
half is a client concern, and Loom's TUI is a separate process over a
frozen gateway. Take the flags, leave the console.

**The mega-Read tool.** The post's own rule is that open-ended operation
sets want a code surface, and Loom has one; directories and URLs are
already `cap/fs.list` and `cap/net.fetch`. Grow `fs_read` by a scheme
resolver for Loom objects and stop there.

**Rendering and the transcript proof.** The TUI already renders typed
spans over the gateway stream and has a real tmux harness
(`client/test/support/terminal.gleam`). The exactly-once scrollback
discipline the post proves in TLA+ matters for an inline TUI; Loom's is
alt-screen with an anchored offset, and the design priorities put this
last. Note it, don't build it.

**Small local models.** The `Summarize` role is the seam. Nothing to
build until a classification task exists.

## The distillation

Five rules, each of which a lint or a test could hold:

1. No run-influencing value lives outside the store without a digest in
   the tree.
2. Limits are applied at the runtime seam, and a tool opts out rather
   than in.
3. One job primitive for everything with stdin, stdout and a kill handle.
4. Loop ownership is a journaled stack, never a closure.
5. A capability record says unknown when it doesn't know; it never says
   false.

The post's "Read is complicated so reading isn't" is the same move as
Ousterhout's deep modules and as `docs/weft.md`'s "one owner per race".
Loom already believes it. The issues under `agent-parity` are the places
where the tree has not yet finished acting on it.
