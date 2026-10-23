# protocol-change/098: governed evolution on a remote workspace

**Status**: PROPOSED 2026-10-22 · **Affects**: the remote node vocabulary of
protocol-change/078 (`remote/protocol`, version 4 to 5), the execution ledger's
use, the census, the owner port's fact fence, and the evolution catalogue's
scope key · **Raised by**: the owner, after PR #824 landed evolution for a local
workspace only · **Implemented**: not yet; plan in
`docs/design-notes/remote-evolution.md`

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

| Function | Local implementation (today's code) | Remote implementation |
| --- | --- | --- |
| `identity()` | `evolution_identity.current(host)` | read from the census |
| `snapshot(directory, coordinates)` | `native.snapshot` | `EvolutionSnapshot` |
| `evaluate(candidate, coordinates)` | `native.evaluate_candidate` | `EvolutionEvaluate` |
| `stage(selection)` | `native.stage` | `EvolutionStage` |
| `run_program(selection, args, coordinates)` | `native.invoke_program` | `EvolutionRun` |
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
- `evolution/machine` (new), `evolution/native` (moved behind it), `serve`
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
