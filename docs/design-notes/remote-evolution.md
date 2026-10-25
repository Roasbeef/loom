# Governed evolution for sessions on an executor

Status: plan, written 2026-10-22. Follows PR #824 (governed evolution, ported
onto main as `runtime/self-extension`), which wires evolution only for a local
workspace. This note says how the same lifecycle works for every placement: a
local workspace, a fixed executor (`sessions.create{executor}`) and a pool
(`sessions.create{pool}`). It is the plan of record for the follow-up PR and
the basis of protocol-change/098.

## The rule

Authority stays on the orchestrator; execution goes where the workspace is.

- **Orchestrator (unchanged location):** the candidate catalogue
  (`evolution/store`, under the owner's state root), approval, selection and its
  generation fence, evidence records, the live owner's generation bookkeeping
  (`evolution/live`), the hook and tool fold (`evolution/hook.wire`), traces and
  outcome marks, task admission, prompt-profile selection and composition in the
  provider gateway, and the operator commands.
- **Workspace machine:** snapshotting a candidate's source, compiling it,
  running author tests, the persistent extension satellites, program runs, trial
  sessions, and the reviewed scratch-component upgrade (it acts on the scratch
  actor, which lives in the workspace plane).

For a local workspace both are the same machine, so the local path is the
special case of the general one, not a second implementation.

## What the port does today, and why each part fails remotely

`serve.evolution_wiring` returns `None` when the session's half has no local
`code_mode_host`, which is every executor session. The machine-bound calls, as
mapped on the port:

| Call | Needs | Why it cannot run on the orchestrator |
| --- | --- | --- |
| `candidate.capture_with` → `machine/local.snapshot` | jailed `tar` with `cwd: ctx.workspace` on a plane broker | the workspace path names the executor's disk |
| `evolution_identity.current(host)` | `gleam --version`, the seed manifest and vendored sources | the identity must be the compiling machine's |
| `machine/local.stage` | offline compile with the seed, persistent satellite, hook bus, `stateful.attach` | satellites run beside the workspace |
| `machine/local.evaluate_candidate` | extension tests in a satellite, program test through `pipeline.execute` | same |
| `machine/local.invoke_program`, `live.invoke` | code mode / satellite | same |
| `evolution_trial` (`open_instance` over a fresh fixture) | a local jail and toolchain, not the session's workspace | the orchestrator may have no helper or toolchain |
| `upgrade/controller` | the scratch actor's pid, `sys` code change | the scratch actor is the executor's |
| `machine/local.open_plane` (`start_effect_plane`) | `settings.helper_path` on this machine | same |

A latent bug the remote case exposes: `system_prompt.pin_profiles` runs for
every session and pins `[]` when there is no wiring, and `pinned_profiles_in`
reads `Some([])` as a durable choice. A session created without evolution can
therefore never adopt a profile later. The fix is part of slice 2:
`serve.evolution_profiles` reads `Settings.evolution_role`. A `Trial(profiles)`
role is always a choice, a wired `Source` session uses its pin and then the
catalogue's selections (possibly `Some([])`), and an unwired `Source` session
returns `None` and pins nothing.

## Design

### One seam: `evolution/machine`

A record of functions the orchestrator-side code calls for everything in the
second column, replacing the closures `machine/local.Config` builds today:

- `identity() -> Identity`
- `snapshot(directory, ctx facts) -> archive.Tree`
- `evaluate(candidate, task facts) -> Evidence data`
- `stage(selection) -> GenerationHandle` and `retire(GenerationHandle)`
- `invoke(GenerationHandle, tool, args, coordinates) -> ToolOutcome` and the
  hook calls the fold makes
- `run_program(selection, args, coordinates) -> Execution`
- `trial(request) -> Running` (opens and retires a trial session)
- `core(command) -> Receipt` (status, upgrade, downgrade)

`machine/local.new(...)` is today's `native` code over `open_plane`, moved, not
rewritten. `machine.remote(hands)` sends the calls to the executor. The live
owner, the store and the fold never learn which one they hold.

### The seam as built (slice 2)

The record has five functions, not the eight listed above. `identity`,
`snapshot`, `evaluate`, `stage` and `run_program` are machine operations.
`invoke`, the hook calls and `retire` are fields of the `live.Generation` that
`stage` returns (`tools`, `hooks`, `retire`, with `inventory` and a stateful
`mode`), so they never needed to be machine functions: a remote `stage` returns
a generation built over messages and the live owner and the fold are unchanged.
`trial` and `core` stay outside. A trial opens a fresh session from `serve`'s
assembly, which a record over the catalogue cannot stand in for, and the core
upgrade already has its own seam, `evolution/control.Seam`. Slice 4 and slice 5
decide whether they join the record.

No function holds the catalogue. Each takes it as its first argument (except
`identity` and `snapshot`, which do not read it), because the catalogue is the approval
authority and stays on the orchestrator, and because the catalogue is opened with
the identity the machine reports, so the machine must exist first. `snapshot`,
`evaluate` and `run_program` still take a `tool.Ctx`; the remote machine narrows
that to the coordinates the wire carries.

Both answers are plain data (slice 3, step 1). `evaluate` answers an
`evaluate.Report`, a verdict and its observation, and writes nothing; `serve`'s
`evaluate` closure records it with `evaluate.record`, the one author-test
evidence write, after the machine has retired its executor. `run_program`
answers the `tool.ToolOutcome` the door returns, so the mapping from an
execution to a success or failure (`program.outcome`) also sits below the seam
and a remote machine copies neither it nor the evidence write. The mapping from
a check's result to its verdict is `evaluate.report_of`, shared by extension
and program checks.

### The seam as built (slice 3)

The remote machine is `evolution/machine/remote`, a `Machine` over the
`Link` a registered session's attach returns (`Hands.evolution`, either
`Reachable(Link)` or `Withheld(reason)`). Each function sends one of the eight
version 5 messages and answers the same plain data the local machine does, so
the live owner, the store and the fold are the code a local session runs.
`serve` chooses the machine by placement, and a `Withheld` session gets refusing
doors in the usual cell and no catalogue. The step 3 text is corrected in
protocol-change/098's two addenda: the executor builds a `local.Config` and
calls the catalogue-free core, and a capability call is keyed `(code_mode call
key, cap, ordinal)`.

Two defects were found only by running the lifecycle across two daemons. The
orchestrator resolved a candidate's directory with its own empty workspace
before sending it, so the executor refused every proposal as escaping its
workspace; the machine now resolves it. And the recovery of a selected
extension ran before the Agency's holder started, so a session with a selection
could not be opened again, locally or on an executor; recovery now runs once the
services are up. A third, found in review, is that a hook which could not reach
the executor answered `Gone` and so removed the handler; it now skips the event.

### The executor side

`executor_plane` builds the same `machine.local` beside the workspace it serves,
over its own code-mode host, helper pool and seed, and exposes it as a new field
of `remote/host.Plane`. Its generations, trial sessions and upgrade controller
are filed under the scope's custody (`custody.Evolution` already ranks between
`ToolConfig` and `Services` in `executor_plane.rank`), so a scope close or a new
incarnation retires them, and an executor restart leaves nothing running that the
orchestrator believes live.

The executor's census carries its compile identity, so the orchestrator opens the
catalogue with the identity of the machine that will build the candidates. A
session is bound to one executor for life (a pool chooses once, at first open), so
one session's candidates always build on one identity. The catalogue does not move
with a session. `serve.evolution_root` is `<state>/evolution`, a daemon-wide
directory, `store.open` opens `evolution.db` under it, and
`session_move.Manifest` carries no evolution rows. A session moved to another
orchestrator keeps its executor but finds an empty catalogue, so its selection
is gone while the executor still holds the generation until the old scope
closes. Slice 3 refuses `sessions.move` for a session that serves a
`Session`-scoped selection whose approval still stands (`daemon/server.selections_stay_behind`,
read outside the registry turn, in both places `serve.evolution_root` can put the
catalogue). Carrying the rows in the manifest was not built.

### Protocol (protocol-change/098, remote protocol version 5)

Ten new `HostMessage` constructors, each fenced by the scope token and
incarnation like `Run`: `EvolutionSnapshot`, `EvolutionEvaluate`,
`EvolutionStage`, `EvolutionRun`, `EvolutionHook`, `EvolutionTransition`
(`Prepare`, `Publish` and `Abort` steps), `EvolutionRetire`,
`EvolutionInventory`, `EvolutionTrial` (`Prepare`, `Files` and `Remove` steps)
and `EvolutionCore`. `EvolutionEvaluate` and `EvolutionRun` are keyed in the
execution ledger. Rules carried over from 078: a lost connection is repaired and
the same request re-sent; `noconnection` never cancels; an answer is committed on
the executor before it is sent. A stage answers the handle of a serving
generation of the same `(candidate, generation)`, and otherwise supersedes the
slot's older generation and any prepared successor, so a session keeps one
executable slot. A prepare replaces an unpublished transition and never joins
it. Evidence is recorded only on the orchestrator, from the executor's
answer, so the executor holds no authority. The orchestrator's live owner keeps
its existing rule that an unconfirmed retirement retains cleanup custody.

`Attach` keeps its v2 arity so an older peer is still refused by value.

### Trials

A remote session's trials run on its own executor, in fresh fixture directories
under the executor's state, so an orchestrator needs no toolchain. The trial's
provider calls still go through the orchestrator's guarded gateway (the request
guard, the exact target and the conservative debits are orchestrator authority):
the trial session on the executor is a registered-workspace session whose model
calls are the orchestrator's. The orchestrator mints the trial session's id
before it asks for the workspace, and the executor binds the workspace to that id
under the parent scope's custody. Whether that is a full second session or a
narrower runner is the main open question of slice 4.

### Installed extensions

The executor-side satellite registry this adds is the piece remote installed
extensions also lack (`serve.remote_extension_refusals`). It is built so that
enabling installed extensions remotely is a later, small change, but that change
is not in this plan.

## Slices

1. **Design and protocol.** This note, protocol-change/098, the P model
   extension (stage, the two-phase migration and retire under link loss,
   executor restart, open and runtime restarts, with mutants for each rule). Fable
   review of the design, whose findings are folded into 098 and the model.
2. **The seam, locally.** Introduce `evolution/machine`, move `native` behind
   `machine/local`, fix the empty-pin bug, no behaviour change otherwise. Gate:
   the existing evolution suites unchanged. Done; see "The seam as built".
3. **Executor machine.** Done. `executor_plane` builds a `local.Config` and `executor_evolution`
   serves the new messages; `machine.remote` on the orchestrator; census
   identity; custody. A shipped fixture proves an extension, a program and a
   restart (`make e2e-evolution-remote`); a pool of one and a link cut during
   staging are not covered. Programs, extensions and author tests work on executor sessions. Also
   in this slice: `sessions.move` is refused for a session that serves a
   selection (see "The executor side"); admit
   `EvolutionEvaluate` by call key and recover both evolution doors from the
   ledger in `Hands.recover`; resolve a snapshot's directory on the executor.
   The first step moved the evidence write above the seam (done; see "The seam
   as built"). `machine.evaluate` answers an `evaluate.Report` and `serve`
   records it, so the verdict mapping exists in one place before
   `remote.evaluate` is written.
4. **Trials and profiles remotely.** Trials on the executor through the
   orchestrator's guarded gateway; prompt-profile evaluation and selection for
   executor sessions.
5. **Core upgrades remotely.** `EvolutionCore` relays the operator's commands to
   the executor's controller; the executor fetches and verifies the release
   artifact by the same manifest and digests.
6. **Acceptance.** Shipped two-daemon tests over `support/remote_pair` for each
   artifact kind on a fixed executor and on a pool, an executor restart with a
   selected extension, a link cut during staging, and an orchestrator restart
   that recovers the selection onto a new incarnation. The fixed executor with
   an extension and a program, and the executor restart, are done in slice 3
   (`evolution_remote_acceptance_test`).

Each slice is done by Sonnet workers and reviewed by a Fable agent; the design
in slice 1 is reviewed before any code.
