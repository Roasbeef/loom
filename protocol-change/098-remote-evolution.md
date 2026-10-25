# protocol-change/098: governed evolution on a remote workspace

**Status**: PROPOSED 2026-10-22 · **Affects**: the remote node vocabulary of
protocol-change/078 (`remote/protocol`, version 4 to 5), the execution ledger's
use, the census, the owner port's fact fence, and the evolution catalogue's
scope key · **Raised by**: the owner, after PR #824 landed evolution for a local
workspace only · **Implemented**: slice 3 at protocol version 5: the messages, the census field
and the host arms (PR #1092), the executor plane (`executor_evolution`, PR
#1113), the orchestrator's remote machine (`evolution/machine/remote`) with the
capability route that reaches it. The `sessions.move` refusal is step 6 of the
plan and is not in this line. Trials (slice 4) and core upgrades (slice 5) are not
implemented. Plan in `docs/design-notes/remote-evolution.md`

## Problem

PR #824 (protocol-change/068 and 069) lets an agent propose candidates (an
extension, a program, a prompt profile), run their checks in a jail, record
evidence, and have an operator approve and select a version, which the session
then serves. Its native half assumes the session's workspace is on the
orchestrator's machine. After the port onto main, `serve.evolution_wiring`
returns `None` for any session whose workspace half has no local code-mode host,
so a session on an executor or in a pool has no evolution at all.

The assumption is in specific places. Capturing a candidate runs a jailed `tar`
with the workspace as its working directory. The catalogue is opened with the
identity of the toolchain and seed that compile candidates. Staging a selection
compiles it offline and starts a persistent satellite, a hook bus and, for an
opted-in component, the state-migration machinery. Author tests run in a
satellite or through the code-mode pipeline. A selected program runs through
code mode. A prompt trial opens a whole fresh session with its own helpers. The
reviewed scratch upgrade acts on the session's scratch actor. Every one of these
needs the workspace's machine or, for trials, a machine with a jail; none of
them is available on an orchestrator that serves executor sessions, which may
have no helper or toolchain at all.

The authority half does not have this problem. The catalogue, approval,
selection and its generation fence, evidence records, the live owner's
bookkeeping, the hook and tool fold, traces, outcome marks, task admission and
prompt-profile composition in the provider gateway are plain data and closures
on the orchestrator, and they stay there.

There is also a defect this exposes. `system_prompt.pin_profiles` runs for every
session and pins an empty map when evolution is not wired, and
`pinned_profiles_in` reads `Some([])` as a durable choice. A session opened while
evolution was unavailable to it can therefore never adopt a selected profile.

## What was considered

**Run evolution's native half on the orchestrator anyway.** It would need a
helper, a seed and a toolchain on every orchestrator, and a candidate captured
from the executor's checkout would be compiled against a different toolchain
than the one that runs the session's code mode. It also contradicts the
placement rule protocol-change/078 established: effects run where the workspace
is.

**Move the whole evolution plane, catalogue included, to the executor.** The
catalogue is the approval authority. An executor is a pinned, trusted peer, but
it is not the party the operator authenticates to, and a pool session would see
a different catalogue on each executor it could have been placed on. Selection
and approval belong with the session, which belongs to the orchestrator.

**One generic "evolution RPC" message carrying an operation name and JSON.** It
would cross the same node boundary as typed messages without the compiler
checking either end, and every new operation would be a silent wire change. The
vocabulary is closed custom types everywhere else in 078; it stays that way.

**Forward the evolution tools to the executor as workspace tools.** The doors
need the catalogue for every call (lookup, selection, the generation fence),
which would make each call a round trip back to the owner. The doors stay owner
tools; only their native effects cross.

## Proposal

### The rule

Authority stays on the orchestrator; execution goes where the workspace is. For
a local workspace the two are the same machine, and the local path is the case
of the general one where every message is a function call.

### The seam

A new orchestrator-side module, `evolution/machine`, is a record of functions
standing for everything that needs the workspace's machine:

The table is the plan. The record as built in slice 2 is described in the
design note's "The seam as built": five functions, each taking the catalogue
as its first argument except `identity` and `snapshot`, with trials and `core`
outside the record for now.

| Function | Local implementation (today's code) | Remote implementation |
| --- | --- | --- |
| `identity()` | `evolution_identity.current(host)` | read from the census |
| `snapshot(directory, coordinates)` | `machine/local.snapshot` | `EvolutionSnapshot` |
| `evaluate(candidate, coordinates)` | `machine/local.evaluate_candidate` | `EvolutionEvaluate` |
| `stage(selection)` | `machine/local.stage` | `EvolutionStage` |
| `run_program(selection, args, coordinates)` | `machine/local.invoke_program` | `EvolutionRun` |
| `trial_workspace(fixture)`, `trial_files(paths)`, `trial_remove()` | a directory under `evolution_trials` | `EvolutionTrial` |
| `core(command)` | `upgrade/control` over the local scratch actor | `EvolutionCore` |

`stage` returns the existing `live.Generation`. On a remote session its fields
are stubs built on the orchestrator: each tool's run sends `EvolutionRun`, the
hook bus's `Invoker` sends `EvolutionHook`, `retire` sends `EvolutionRetire`,
`validate` reads the orchestrator's catalogue as it does today, `inventory` sends
`EvolutionInventory`, and a `Stateful` mode's `prepare`, `publish` and `abort`
send `EvolutionTransition` with the matching step. The live owner,
the store and the fold do not change.

`evolution_wiring` is built for every session. Its machine is `machine.local`
when the half has a local code-mode host and `machine.remote(hands)` when it is
on an executor. A session with neither (a local workspace on a host with no
toolchain) keeps today's `None`.

### Node vocabulary (protocol version 5)

All new messages are values of closed custom types holding the plain data 078
already admits: strings, integers, bit arrays, lists, `ToolRun`, `ToolOutcome`,
`JsonValue`, `Subject`s, and three evolution records that are already plain data:
`record.Selection`, `record.Evidence` and `archive.Tree`. No closure crosses.
Every message that acts on a scope carries `incarnation` and `token` and is
admitted only when both equal the scope's, exactly as `Run` is, so a dead open's
message cannot act on a live scope.

Orchestrator to executor, new `HostMessage` constructors:

| Message | Meaning |
|---|---|
| `EvolutionSnapshot(session, incarnation, token, directory, coordinates, reply)` | Capture a candidate's source from `directory` with the same jailed `tar` and bounds as today. The orchestrator checks only the shape of `directory` (relative, no `..`), because on a registered session it has no filesystem to resolve it against. The executor resolves it under its workspace with `resolve_real` before the `tar`, so a symlink that leaves the workspace is refused, with the wording `fs_read` uses. Read-only and repeatable; answered `Snapshotted(tree)` or a refusal. |
| `EvolutionEvaluate(session, incarnation, token, candidate, artifact, coordinates, reply)` | Compile `candidate` and run its author tests on the executor, and answer the evidence the local code would record. The orchestrator writes the evidence to its catalogue; the executor keeps nothing. Admitted in the execution ledger by call key exactly as `EvolutionRun` is, with the tool column `evolution:test`, so a re-send joins the run in progress or reads its stored outcome and two runs never overlap, as the local owner's `Busy` already guarantees. `Hands.recover` asks the ledger for an orphaned `evolution_test` or `evolution_invoke` call by key (`Query`, or `QueryOrFence` where the call is not replay-safe) instead of judging it by the owner-tool replay policy. |
| `EvolutionStage(session, incarnation, token, selection, artifact, reply)` | Build and start the generation for `selection`, the catalogue's current selection. A session has one executable slot, and the executor keeps that rule. If a serving generation exists for exactly `(selection.candidate_id, selection.generation)`, the stage answers its handle, so a re-send after a lost reply and a stage from a restarted runtime both join it. Otherwise the executor aborts any prepared transition whose successor is that pair, builds and starts the new generation, and answers `Staged(handle, declarations, superseded)`. `superseded` lists the handles of every older generation of the slot still live (serving, or superseded by a publish and not yet retired) and of any aborted successor whose teardown the executor could not confirm; an older serving generation stops serving, and the live owner treats each listed handle as a retire obligation. A stage for a generation older than a live serving or superseded one is refused `StaleGeneration`: the selection's generation only increases, so such a message is a dead runtime's arriving late under the same token, and serving it would put two generations in the slot. A stage never joins a prepared successor, which does not serve. A stage in progress outlives its waiters: the result is reusable by the next runtime, and the scope's custody bounds it. The executor never runs ahead of the catalogue, because the orchestrator stages only the current selection. |
| `EvolutionRun(key, incarnation, token, handle, run, args, authority, reply)` | Invoke one tool of a staged generation, or a selected program. Admitted in the execution ledger by `key`, exactly as `Run` is, with the tool column `evolution:<name>`, and answered as `Run` is (`RunFinished`, `RunLost`, `RunRefused`). |
| `EvolutionHook(session, incarnation, token, handle, event, payload, remaining_ms, reply)` | Deliver one promoted hook event and answer the handler's msgpack reply. Not ledgered: a hook answer is an advisory value the fold already treats as absent on failure. |
| `EvolutionTransition(session, incarnation, token, step, reply)` | One step of a stateful migration, with `step` a closed type: `Prepare(handle, selection, artifact)`, `Publish(handle, successor)` or `Abort(handle, successor)`. The three share one admission and act on one transition. `Prepare` on a serving `handle` aborts any unpublished transition on that handle and prepares a fresh successor from the handle's current state; it never joins an earlier one, so a re-send after a lost reply costs one more snapshot and publishes current state. A `handle` that is not serving is refused `UnknownHandle`. Answered `Prepared(successor_handle, declarations)`. `Publish` names its successor and is idempotent: a second publish of a published transition answers the same receipt. A publish for a successor the plane does not hold (aborted, replaced, or lost with a restart or a new incarnation) is refused `UnknownHandle`. `Abort` names its successor and is idempotent: an abort of a transition the plane does not hold does nothing, and an abort after publish is refused with `AlreadyPublished`. |
| `EvolutionRetire(session, incarnation, token, handle, reply)` | Stop a generation and answer `AllRetired` or `UnknownCleanup(n)`, the same verdict a scope close gives, so the live owner keeps its existing rule that an unconfirmed retirement keeps cleanup custody. Admitted like the rest, so a dead runtime's retire is refused `Stale` and cannot retire a generation the next runtime joined. |
| `EvolutionInventory(session, incarnation, handle, reply)` | The generation's bounded helper census. |
| `EvolutionTrial(session, incarnation, token, trial, step, reply)` | One step of a trial workspace's life, with `step` a closed type: `Prepare(fixture)` creates a fresh workspace under the executor's state, installs `fixture` into it and answers its registered name; `Files(paths)` reads the expected files back after the trial session retired, bounded as today's scoring is; `Remove` deletes the workspace and is idempotent. `trial` is the trial session's id, minted by the orchestrator (see "Trials"). |
| `EvolutionCore(session, incarnation, token, command, reply)` | Relay an operator's `core_status`, `core_upgrade` or `core_downgrade` to the executor's upgrade controller over the session's scratch actor. |

There is no new executor-to-orchestrator message. A satellite's owner-bound
capability calls already cross as `Capability`. The one change on that side is
the owner port's fact fence: `FactAccess` serves `client/working_directory/` and
`job/` today, and gains `ext/`, the prefix an extension's `remember` and
`recall` write under, so a promoted extension on an executor keeps its memory in
the session's store.

`Attach` keeps its version-2 arity, so a peer of another version is still
refused by value.

### Where each part runs on the executor

`executor_plane` builds a `machine.local` beside the workspace it serves, over
its own code-mode host, helper pool and seed, and `remote/host.Plane` gains an
`evolution` field. Generations, prepared transitions and trial workspaces are
filed under the scope's custody (`custody.Evolution` already ranks between
`ToolConfig` and `Services` in `executor_plane.rank`), so a scope close, a new
incarnation or an executor restart retires them. An executor never holds a
generation the orchestrator has not asked for in the current incarnation.

The executor's census gains `evolution: Option(EvolutionCensus)`: the compile
identity (`record.Identity`) and the reason it is absent, when the executor has
no seed or toolchain. The orchestrator opens the catalogue with this identity. A
session is bound to one executor for its life (a pool chooses once, at first
open), so one session's candidates always compile under one identity.

### Trials

A prompt trial is a whole session, and the rollout drives its runtime directly
(`rollout_host.Running.runtime`), so a trial's conversation stays on the
orchestrator, as today. Its workspace is what moves: for an executor session the
orchestrator asks the executor for a fresh trial workspace, then opens the trial
session as a registered session on the same executor, through the existing
remote-workspace path, with that workspace. The trial's provider calls go
through the orchestrator's guarded gateway, so the request guard, the exact
target and the conservative debits stay orchestrator authority. After the
trial session retires, the orchestrator reads the expected files back and scores
them, then removes the workspace. The orchestrator needs no helper or toolchain.

A trial workspace is not a configured `[workspaces.<name>]` row. The
orchestrator mints the trial session's id first, and `EvolutionTrial` with step
`Prepare` binds the workspace to that id under
`<state>/evolution-trials/<parent session>/<trial session>`. The executor admits
`Attach(trial session, <minted name>)` only while the parent scope is attached at
the incarnation that minted it, and files the trial scope under the parent's
custody, so a parent close or reopen retires it. It refuses an attach that names
a trial workspace bound to another trial id. `executor_plane.factory` resolves a
minted name without a `[workspaces.<name>]` row, and the name satisfies
`catalogue.is_workspace_name`, which the create path checks.

A handle is unique per executor VM boot (a reference, or a counter qualified by
a boot id), so a restarted plane cannot answer an old handle by accident.

### Recovery and custody

The live owner's cleanup obligations are its memory for one open. They are not
stored in the catalogue. The next open learns the previous open's generations
through `Staged.superseded`, and anything left when a scope closes is settled by
the close verdict: `UnknownCleanup(n)` is what 078 already turns into the
operator's `loomd executor release`.

A new open always stages the catalogue's selection. It does not try to finish a
migration: the catalogue's request receipt holds the request signature and the
selection, with no handle and no published phase, and executor handles do not
survive a VM restart. A publish answered `UnknownHandle` ends the transition; the
owner records the outcome mark "migration lost; selection staged" through the
`evolution_trace` door and stages the selection. The loss is visible, not silent.

The remote `retire` stub treats an unanswered `EvolutionRetire` (link down) as
success for custody, as `plane.close` does for the scope, and only
`UnknownCleanup(n)` becomes `CleanupUnconfirmed`. Otherwise a partition at
session close would leave `custody.Evolution` holding a reservation the scope
close settles.

The owner port's `ext/` fence is per session, where the local `dispatch` binds
the `ext/<name>/` subtree from the install record. That is wider than the local
binding. It is acceptable between pinned peers and relies on the executor's
router composing the key.

`EvolutionHook` carries `remaining_ms`, which the orchestrator rebases on the
executor's clock as it does for escalations.

### Catalogue scope

Program selections are scoped to a canonical workspace. For an executor session
the workspace is a registered name, which two executors may share, so the scope
key becomes `executor:<node>/<name>` for a registered workspace and the
canonical path for a local one. A local session's existing catalogue rows keep
their scope unchanged.

### The empty pin

`pin_profiles` stops pinning when evolution is not wired for the session, and a
session that already holds an empty pin and now has evolution is re-pinned from
the catalogue once at its next open. A non-empty pin is never rewritten, so an
existing session keeps the profiles it pinned.

As implemented in slice 2: an empty pin written with wiring is a durable choice
of no profiles (the acceptance suite asserts it), so the pin cannot simply stop
being empty. `evolution_profiles` answers `Some` for a trial (its
`evolution_role` is `Trial(profiles)`, which always counts as a choice, and a
trial has no evolution wiring), `Some` for a `Source` session with a pin or
wiring, and `None` for a `Source` session with no pin and no wiring. `serve`
pins only on `Some`. The pin encoding is
unchanged. No release ever wrote an empty pin for an unwired session, because
this feature is unreleased, so there is no legacy reading. Sessions booted
unwired from the unmerged evolution branch already hold a `Some([])` pin and
will not adopt a profile. Open a fresh session or delete the
`prompt/evolution-profiles` register; there is no migration code.

## Impact

- `remote/protocol`: version 5; ten `HostMessage` constructors, two of which
  (`EvolutionTransition`, `EvolutionTrial`) carry a closed step type; reply types
  `Snapshotted`, `Staged` (with `superseded`), `Prepared`, `TrialWorkspace`; three
  refusals, `AlreadyPublished`, `UnknownHandle` and `StaleGeneration`; one census field.
- `remote/host`: an `evolution` field on `Plane`; admission of the new messages
  under the existing scope checks; `EvolutionRun` through `admit_call` with its
  own tool column, so the reconciler, acknowledgement and tombstone rules apply
  unchanged.
- `executor_plane`: builds the executor's `machine.local`, files its parts under
  custody, mints trial workspaces.
- `evolution/machine` (new), `evolution/native` (moved behind it as `evolution/machine/local`), `serve`
  (wiring for every placement), `system_prompt` (the pin), `owner_services` (the
  fact fence), `evolution/store` (the scope key).
- The P model in `protocol/models/remote-execution` gains the evolution path.
- No Part 1 interface moves. No catalogue or ledger schema change.

## What it costs

Each extension tool call and promoted hook on an executor session is one more
node round trip, the same cost a workspace tool already pays. A prompt trial on
an executor session opens a second registered session, which takes one of the
executor's scope slots (16 by default) for the trial's life; a comparison runs
its arms one at a time, so it holds at most one extra slot. A stateful upgrade's
two-phase transaction now spans the network. A lost reply to the selection
compare-and-set is resolved by the catalogue's existing request receipt, which
says whether it committed; a lost publish reply is answered by sending the
publish again. An owner that dies between the compare-and-set and the publish
loses the migrated state, and the next open stages the selection fresh, as a
local session does today (`serve.evolution_recover` stages the durable selection
and keeps no handle). A lost abort leaves the predecessor serving and the
prepared successor in place until the next stage of that selection, which aborts
it, or the scope closes, which retires both.

What this does not do: installed extensions stay refused on executor sessions.
The executor-side satellite registry this adds is the piece they lack, so
enabling them is a later and smaller change.

## Addendum, 2026-10-23: the evolution operations arrive as capability calls

This note was written when the six operations were model tools, and it names
them that way: `evolution_test` and `evolution_invoke` are the calls whose
admission and recovery it describes. The owner has since ruled that governed
evolution is reachable only through code mode. The six direct tools are removed
and the operations are the capabilities of `cap/evolution` (`evolution.propose`,
`evolution.test`, `evolution.inspect`, `evolution.catalogue`, `evolution.invoke`
and `evolution.trace`), answered by `codemode/evolution` on the owner. The node
vocabulary above is unchanged. This addendum states what the new route does to
the two sentences that assumed a tool call. The status stays PROPOSED.

**Admission keys on the capability call.** A tool call had its own
`{operation, step, source_index}`, so "admitted in the execution ledger by call
key exactly as `Run` is" named one operation. A capability call shares its
`code_mode` call's key. The key for `EvolutionEvaluate` and `EvolutionRun` is
therefore `(code_mode call key, cap, OwnerCapCall.ordinal)`, the same device
`strand.spawn` uses to keep two calls of one program apart. The local route
already folds the capability's slot and ordinal into the context's source index
for the same reason (`client/evolution/capability.call_index`), so two calls of
one execution never share a scratch directory.

**Recovery follows the `code_mode` call.** `Hands.recover` does not look for an
orphaned `evolution_test` or `evolution_invoke` call by name, because none can
exist. A cap-originated operation is recovered under the policy of the
`code_mode` call that made it, which is `replay: Never`: the call is fenced and
the model re-submits, and the ordinal makes a re-submission a new operation
rather than a duplicate of the admitted one.

**Placement is owner-bound.** The catalogue and the live owner are the
orchestrator's, so `cap_placement` already lists the six names among the owner's
capabilities. On an executor session each operation travels as
`Capability(OwnerCapCall)` to the owner, which then sends
`EvolutionSnapshot`, `EvolutionEvaluate` or `EvolutionRun` back to the
executor and answers the program: two node round trips where the direct tool
needed one. Every owner-bound capability already pays the first hop. The
`tool.Ctx` the local route rebuilds from the request is the same narrowing slice
3 plans for `snapshot`, `evaluate` and `run_program`, so one door implementation
serves both placements.

**Candidates cannot import the module.** A candidate is vetted under the
extension seam, which never admits `cap/evolution`, and a program candidate is
vetted and run under the host with the evolution door withdrawn, so the
allowlist that `evolution/identity` hashes excludes it. A selected program
cannot propose, test or invoke another candidate from inside its own run.

**The build identity resets.** `identity.build` hashes the vendored prelude, so
adding `cap/evolution` changes it, and every candidate and evidence envelope
retained before this change is refused `Changed` with "candidate or evaluator
identity changed". That is acceptable because governed evolution has not shipped
in a release: `v0.3.2` (2026-10-12) is the latest tag, it contains no
`client/evolution` and the release notes do not mention it, so no operator holds
a retained candidate. A later prelude addition resets the catalogue the same
way, and this note is where that cost is recorded.

## Addendum (slice 3 step 3, as built), 2026-10-23

PR #1092 landed the version 5 vocabulary in `remote/protocol`, the census field
in `remote/remote_census`, two read functions in `storage/exec_ledger`, and host
arms that fence every evolution message and refuse it with `NoEvolution` because
no plane yet carries an evolution machine. The executor plane and the
orchestrator machine are steps 4 and 5. This addendum records the shapes as
they were built. It does not edit the text above. Where the code and an earlier
sentence disagree, the code is what shipped and this section is the correction.
The status stays PROPOSED until step 5 lands.

### What this addendum supersedes

1. The Implemented line in the header, which read "not yet". The line now
   reflects slice 3 as merged.
2. The sentence in the first addendum, "The node vocabulary above is
   unchanged". It was true of the capability-call route, which adds no message,
   and is false of the vocabulary as built. The table in "Node vocabulary
   (protocol version 5)" differs from the code in the rows listed below.
3. The plain-data list in "Node vocabulary", which names `ToolRun`,
   `ToolOutcome`, `record.Selection`, `record.Evidence` and `archive.Tree`. No
   evolution message carries `ToolRun` or `record.Evidence`. The messages carry
   `record.Selection`, `record.Candidate`, `archive.Tree`, `JsonValue`,
   `MsgPackValue`, `tool.Described`, `wiring.Authority` and `hooks.HookFailure`,
   and the census carries `record.Identity`.
4. The sentence "Every message that acts on a scope carries `incarnation` and
   `token` and is admitted only when both equal the scope's, exactly as `Run`
   is". Only `EvolutionEvaluate` and `EvolutionRun` are admitted, because only
   they write a ledger row. The other six are fenced by a read of the same
   comparison that writes nothing, and `EvolutionInventory` carries no token.
5. The `EvolutionSnapshot` row, in its field order and in "answered
   `Snapshotted(tree)`".
6. The `EvolutionEvaluate` row, in its fields, its answer, and the claim that it
   is admitted "exactly as `EvolutionRun` is".
7. The `EvolutionStage` row, in its `artifact` field and in the `Staged` reply.
8. The `EvolutionRun` row, in its fields and its authority.
9. The `EvolutionHook` row's `remaining_ms`, and the sentence under "Recovery
   and custody" that the orchestrator rebases it on the executor's clock.
10. The `EvolutionTransition` row's `artifact` field and the `Prepared` reply.
11. The `EvolutionRetire` row's "refused `Stale`".
12. The `EvolutionTrial` and `EvolutionCore` rows, which are not in version 5.
13. Two sentences of "Where each part runs on the executor": the one that says
    `executor_plane` builds a `machine.local` and the one that gives
    `Plane.evolution` and the census field their shapes.
14. The first two bullets of "Impact", which count constructors, reply types and
    refusals and describe host admission.

The seam table and the `machine.remote(hands)` sentence are not superseded.
They describe the orchestrator side, which is step 5, and that step amends them
if it changes them.

### The messages as built

There are eight `HostMessage` constructors where the proposal listed ten. The
trial and core messages are left to the slices that serve them, under their own
version bumps, so the table splits in two: this one, and a later one for those
slices.

| Message | Fields | Answer |
|---|---|---|
| `EvolutionSnapshot` | `incarnation, token, coordinates, directory, reply` | `Result(archive.Tree, Refusal)`. There is no `Snapshotted` constructor. The session is `coordinates.key.session`, so the message carries no separate session field that could disagree with the key. |
| `EvolutionEvaluate` | `incarnation, token, coordinates, candidate: record.Candidate, reply: Subject(ExecutionAnswer)` | `ExecutionFinished(report)`, where `report` is the check's report as a JSON value. The executor keeps nothing, and the orchestrator turns the report into evidence and records it. There is no `artifact` field. |
| `EvolutionStage` | `session, incarnation, token, selection, candidate, reply` | `Result(Staged, Refusal)`. |
| `EvolutionRun` | `incarnation, token, coordinates, target: Target, args: JsonValue, reply: Subject(RunAnswer)` | The `RunAnswer` a `Run` gives. The call key is `coordinates.key`. |
| `EvolutionHook` | `session, incarnation, token, handle, event, payload, within_ms, reply` | `Result(MsgPackValue, hooks.HookFailure)`. |
| `EvolutionTransition` | `session, incarnation, token, step, reply` | `Result(TransitionAnswer, Refusal)`. |
| `EvolutionRetire` | `session, incarnation, token, handle, reply` | `Result(CloseOutcome, Refusal)`. |
| `EvolutionInventory` | `session, incarnation, handle, reply` | `Result(JsonValue, Refusal)`. |

`EvolutionStage` returns `Staged(handle, name, tools: List(tool.Described),
hooks: List(String), activation: Activation, superseded: List(Handle))`, with
`Activation = Replacement | InPlace`. The proposal's `declarations` is split
into these fields because the orchestrator builds the hook bus from `name` and
`hooks`, builds each tool's run closure from `tools`, and chooses the
`live.Generation` mode from `activation`. A generation that did not opt in to
in-place upgrade is `Replacement`, and sending it through the stateful path
would be refused by the executor.

`EvolutionRun` runs a `Target`, which is `Promoted(handle, tool: String)` or
`Program(candidate: record.Candidate)`. A program is compiled for each call and
never staged. The ledger tool column is `evolution:<tool>` for a promoted tool
and `evolution:program` for a program.

`EvolutionEvaluate` is admitted as a background execution is, not as a `Run`
is: kind `Execution`, reservation `execution_result_bytes`, tool column
`evolution:test`. A re-send with the same key joins the live check or reads the
stored report. Because the row's kind is `Execution`, `running_executions`
excludes it from `Unacked.executions`. `EvolutionRun` is admitted as a `Run`
is: kind `ToolCall`, reservation `max_result_bytes`. Both go through
`admit_call`, so the reconciler, acknowledgement and tombstone rules apply
unchanged.

`EvolutionHook` carries `within_ms`, the duration the hook bus already passes.
The executor uses it unchanged, because it is a remaining duration and not a
deadline. The sentence about rebasing it on the executor's clock is withdrawn.

`EvolutionTransition` carries a `TransitionStep`, which is
`Prepare(handle, selection, candidate)`, `Publish(handle, successor)` or
`Abort(handle, successor)`. The answer is a `TransitionAnswer`:
`TransitionPrepared(Prepared(successor, tools: List(tool.Described)))`,
`TransitionPublished`, which a repeated publish answers again, or
`TransitionAborted`, which is also the answer for a successor the plane does not
hold. The semantics of the three steps in the table above are unchanged.

`EvolutionRetire` is refused `StaleToken` or `StaleIncarnation` when its fence
fails. There is no `Stale` refusal. A handle the executor does not hold answers
`AllRetired`, so a retry after a lost reply is safe.

### Coordinates and authority

`Coordinates(key, strand, authority)` carries the call's ledger key, the strand
that dispatched it, and the door call's stored `wiring.Authority`. It is built
by `protocol.coordinates_of(session, ctx, authority)`. An earlier form of the
type also carried a `grants` list copied from the context. That field is
removed, so `authority` is the only carrier of grants.

The removal settles a design question the review of #1092 raised. The context
holds only the grants of consumed escalation approvals, and the session's
standing network grants are folded into its base policy, which does not cross
the node boundary. An authority built from the context would therefore drop the
standing grants from a remote check. The authority is instead read from the
session's store, as `surface` reads it for a `Run` (`read_authority`), and step
5 obtains it the same way before it calls `coordinates_of`. The executor
revalidates it against its own filesystem before widening the call's policy, as
it does for a `Run`.

### The fence as built

The host judges every evolution message against the scope before it reaches the
plane. A `Writer` fence requires the scope's incarnation and current attach
token, and a `Reader` fence requires only that the scope is open at the
incarnation. `EvolutionEvaluate` and `EvolutionRun` are fenced by admission.
`EvolutionSnapshot`, `EvolutionStage`, `EvolutionHook`, `EvolutionTransition`
and `EvolutionRetire` are fenced by `exec_ledger.current`, which makes
`admit`'s check as a read and writes no row. `EvolutionInventory` is a `Reader`
and is fenced by `exec_ledger.current_incarnation`, because it changes nothing
and a read against a scope that a newer runtime of the same incarnation took
over is still a true read. The two reads are the only additions to
`storage/exec_ledger`, and neither changes the schema. They answer `admit`'s
refusals (`NoSuchScope`, `ScopeNotOpen`, `StaleIncarnation`, `StaleToken`), but
they do not validate a negative incarnation or an empty token first, so a
malformed request answers a stale refusal where `admit` would answer `Invalid`.
Peers built from one source do not send such a request.

The fence is judged in the host's turn, and a scope's close is also a host turn,
so the fence and the call into the plane are atomic with respect to `Close` and
`Attach`. What the host cannot order is the plane's own work after `serve`
returns. A scope close retires the evolution plane through custody, from a
different process than the one that served the request. Step 4 must therefore
make the plane's retirement terminal: after `retire_all`, the plane refuses
every later request and cancels or awaits a stage in flight before it answers.
The refusal after retirement belongs to the plane, not the host.

A hook that is refused by the fence is answered `hooks.Gone`, because a hook
has no refusal to carry and a scope that cannot be asked has no extension left
to answer. The only transient refusal, `PlaneBuilding`, occurs for a scope whose
plane is being built at a new incarnation, and the generation the hook names no
longer exists at that incarnation, so `Gone` is the true answer.

### The plane and the census as built

`Plane` gains `evolution: Option(host.Evolution)`, where `Evolution(evaluate,
run, serve)` is what the host calls. `evaluate` and `run` return their answers
and run in a process the host owns and may kill, so the host keeps admission,
waiters, cancellation and the commit. `serve` takes an `EvolutionRequest`, which
has one constructor for each of the six requests that write no call row, and
answers on the reply subject the request carries. `None` answers every
evolution message `NoEvolution(reason)`. This is a fourth refusal beside
`UnknownHandle`, `AlreadyPublished` and `StaleGeneration(serving)`. In this
change every plane is built with `None`.

The census field is `evolution: EvolutionCensus`, which is not an `Option`. It
is the two-variant type `Compiles(identity: record.Identity)` or
`Uncompiled(reason: String)`. It is computed when the scope's plane is built,
because the identity depends on the scope's seed, and a rebound attach reuses
it. The orchestrator opens the catalogue with the identity when the variant is
`Compiles`.

`executor_plane` will build a `machine/local.Config` and call the catalogue-free
core of `machine/local`, not a `machine.local`, which is an orchestrator-side
value. That is step 4.

A generation handle is `Handle(boot: BitArray, ordinal: Int)`, where `boot` is
sixteen random bytes drawn when the scope's evolution actor starts. It is the
concrete form of the proposal's rule that a handle is unique per executor boot.

### Impact, as built

- `remote/protocol`: version 5. Eight `HostMessage` constructors, one closed
  step type (`TransitionStep`), the reply types `Staged`, `Prepared` and
  `TransitionAnswer`, and the existing `ExecutionAnswer` and `RunAnswer` for the
  two keyed calls. Four new refusals: `UnknownHandle`, `AlreadyPublished`,
  `StaleGeneration(serving)` and `NoEvolution(reason)`. One census field. The
  module now imports `client/extension/hooks` to name `hooks.HookFailure`. That
  module is the hook bus and not a plain-data module, and moving the failure
  type to a leaf module is left open.
- `remote/host`: an `evolution` field on `Plane`. `EvolutionEvaluate` and
  `EvolutionRun` go through `admit_call`. The other six go through
  `exec_ledger.current`, or `current_incarnation` for `EvolutionInventory`. No
  schema change.
- The version 4 to 5 step changes the census an `Attached` carries as well as
  adding messages. A version 4 attach is refused `VersionMismatch(supported: 5)`
  and the host stays up. `Attach` keeps its version 2 arity.
- Unchanged: `executor_plane`, `evolution/machine`, `serve`, `system_prompt`,
  `owner_services`, `evolution/store` and the P model. These belong to steps 4
  and 5 and later slices.

## Addendum (slice 3 steps 4 and 5, as built), 2026-10-25

The executor plane and the orchestrator's machine are built, and a shipped
two-daemon test (`evolution_remote_acceptance_test`) proves the lifecycle on a
fixed executor. This addendum records where they differ from the text above and
from the step 3 addendum. The status stays PROPOSED until slices 4 and 5.

**The executor builds a `local.Config`, as the step 3 addendum said it would.**
`executor_plane` assembles one from the machine's own inputs and calls the
catalogue-free functions of `machine/local`. The proposal's `machine.local`,
an orchestrator-side value, is not built on the executor. The `Config` is held
by `executor_evolution`, one actor for each scope, which is filed in custody as
`custody.Evolution`.

**`Hands.evolution` has two variants.** The orchestrator's view of the executor
is `Reachable(Link)` when the census says `Compiles(identity)` and
`Withheld(reason)` when it says `Uncompiled(reason)`. A `Reachable` link carries
the surface the remote machine sends through, the session's stored authority and
the patience a retire or an inventory has. A `Withheld` session has no machine,
no catalogue and no plane. It still registers the evolution cell over doors that
refuse every operation with the executor's reason, so a program that imports
`cap/evolution` reads why there is no plane and not a sentence about a plane
that is not open.

**A capability call is keyed `(code_mode call key, cap, ordinal)`.** An
`EvolutionEvaluate` or `EvolutionRun` sent for a call of `cap/evolution` carries
the `code_mode` call's key, with the capability name and the call's
`OwnerCapCall.ordinal` folded into the key's source index by
`capability.call_index`, so two capability calls of one program are two ledger
rows and a repair that resends one finds its row. The step 3 addendum's
`Coordinates` carry that key. The authority in the coordinates is the call
door's stored `wiring.Authority`, which the executor revalidates against its own
filesystem before it widens a policy.

**The machine resolves a directory.** The model names a candidate's source
directory in the workspace's own terms. `EvolutionSnapshot` carries it as named,
and the machine that holds the workspace resolves it: `serve` for a workspace in
this VM, with the catalogue's root as an extra protected path, and the executor
for a registered session. An earlier cut resolved it on the orchestrator first,
which sent the executor an absolute path built from an empty workspace.

**A hook that cannot reach the executor is skipped.** The remote machine answers
`Refused` for a hook whose wait for the executor ran out, not `Gone`. The hook
bus drops a handler that answers `Gone` for the rest of the session, and a link
cut is not the end of the extension. `Gone` is kept for the host's own refusals
that say the generation no longer exists.

**`sessions.move` and a selection.** The catalogue stays on the orchestrator
that holds the session and does not travel in the move manifest, so a moved
session would find its selection gone while the executor still served the
generation. The plan refuses the move for a session with a selection; that
refusal is step 6, built separately, and this addendum does not record it as
done.
