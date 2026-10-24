# Remote evolution, slice 3: the executor machine

Status: plan of record for slice 3 of [remote evolution](remote-evolution.md),
written 2026-10-23 and committed on 2026-10-24 as part of a handoff. Steps 1
(PR #1086), 2a (PR #1089), 2b (PR #1098) and 3 (PR #1092) are merged; step 4 is
in progress on the pushed branch `runtime/executor-evolution` (unfinished, see
[next.md](../next.md)); steps 5, 6 and 7 are not started.

The plan was written before steps 1 to 3 landed, so some signatures below are
older than the code. Where the two differ, the code and protocol-change 098's
"Addendum (slice 3 step 3, as built)" win. Line numbers were dropped from
the file citations when the plan was committed, because the code has moved
since; search for the named function instead. The differences already known:

- `Staged`, `Upgrade` and `PreparedStaged` live in `client/evolution/staged`,
  not `local`, to avoid an import cycle with `stateful` (PR #1098).
- `protocol.Coordinates` is `(key, strand, authority)`. It has no `grants`
  field, and `coordinates_of(session, ctx, authority)` takes the door call's
  stored `wiring.Authority`, because a `tool.Ctx` carries only consumed
  approvals (PR #1092 review, F1).
- `EvolutionSnapshot` has no separate `session` field; it uses
  `coordinates.key.session` (PR #1092).
- `EvolutionInventory` is fenced by `exec_ledger.current_incarnation` (no
  token); the other six unkeyed messages by `exec_ledger.current` (PR #1092).
- The evaluate and run doors are reached through `cap/evolution`, not six
  direct tools (PR #1091). A capability-originated operation keys by
  `(code_mode call key, cap, OwnerCapCall.ordinal)`; see 098's capability-call
  addendum.
- Section 4's decisions were taken during the autonomous run and are recorded
  as rulings in [next.md](../next.md): refuse the move, eight messages in
  version 5, drop ledger recovery for the doors, no output tail for remote
  checks, one catalogue for both placements.

`packages/client/src/client/` unless written in full.

## 0. What slice 3 has to deliver

After slice 3 a session registered on an executor (fixed or pooled) can
propose, test, approve, select and invoke extension and program candidates,
exactly as a local session can today. Trials (slice 4) and core upgrades
(slice 5) stay out. The pieces, in dependency order:

1. the orchestrator-side seam answers in plain data (today it answers
   `record.Evidence` after writing it, and `codemode_tool.Execution`);
2. the local machine is split into a catalogue-free core the executor can
   call and a catalogue-aware wrapper the orchestrator keeps;
3. the wire vocabulary (protocol version 5), the census identity, the host
   arms, and a plane field that refuses until the executor side exists;
4. the executor's evolution plane under custody;
5. `machine/remote`, the `ext/` fact fence, and the `serve` wiring, which is
   the step that first makes executor sessions able to use evolution;
6. the `sessions.move` refusal and the catalogue scope label;
7. the two-daemon acceptance and the documentation.

Steps 1 and 2 change no behaviour. Every step leaves `main` green on its own.

## 1. Second opinion: where 098 and the seam as built do not match the code

Each item states the claim, what the code shows, and the smallest fix. Items
marked **098** need an edit to `protocol-change/098-remote-evolution.md`
(still PROPOSED). Items marked **note** need the design note's "seam as
built" section updated.

### 1.1 `live.Generation` can be built over the wire, but `Staged` carries too little

Claim: a remote `stage` can return a `live.Generation` whose fields are built
on the orchestrator.

Checked: `live.Generation` (`evolution/live.gleam`) holds `selection`,
`mode`, `tools: List(tool.Tool)`, `hooks: Option(hooks.Bus)`, `retire`,
`validate`, `inventory`. None of these cross the wire; each is built on the
orchestrator from plain data:

- `tools`: `tool.Tool` is `tool.Described` plus `requirements` and `run`
  (`tools/tool.gleam`, `:579`). `requirements` is never consulted for a
  promoted tool, because `live.invoke` calls `declared.run(ctx, args)`
  directly (`live.gleam`), so a constant policy is correct. `run` sends
  `EvolutionRun`.
- `hooks`: the bus is an orchestrator actor started with
  `hooks.start([hooks.Extension(name, events, invoke)], logger)`
  (`extension/hooks.gleam`); `invoke` is
  `fn(String, String, MsgPackValue, Int) -> Result(MsgPackValue, HookFailure)`
  (`:347`), a closure that sends `EvolutionHook`. The fold, `gate`,
  `fold_tool_result` and `notice_sync` all run on the bus locally and never
  change.
- `mode`: `live.changing` (`live.gleam`) dispatches on `ReplacementOnly`
  versus `Stateful(prepare)`. A plain extension sent through `Stateful` would
  be refused by the executor's prepare (`stateful.gleam`, "requires an
  explicit compatible live contract") with no fallback to staging. So the
  orchestrator must know which mode to build.
- `retire`: `retirement.repeat` over `EvolutionRetire`. `inventory`:
  `EvolutionInventory`. `validate`: `store.authorized`, local.

The gap: 098's `Staged(handle, declarations, superseded)` omits three things
the orchestrator needs to build the generation: the extension's `name` (every
hook refusal is attributed to it, `hooks.Extension.name`), the hook `events`
the manifest declared (the bus skips undeclared events before any call), and
whether the generation admits an in-place upgrade.

**098**: `Staged(handle, name, tools: List(tool.Described), hooks: List(String),
activation: Activation, superseded: List(Handle))` with
`Activation = Replacement | InPlace`. `Prepared(successor: Handle, tools)`
likewise. Also admit `core/msgpack.MsgPackValue` to the plain-data list (hook
payloads and replies).

### 1.2 `tool.Ctx` maps to a `Coordinates` record, not to a `ToolRun`

Claim: the remote machine narrows `tool.Ctx` to coordinates the wire carries.

Checked: `tool.Ctx` (`tools/tool.gleam`) has four closures
(`clear_call`, `raise_refusal`, `observe_output`, `filesystem`) and six
machine-local fields (`workspace`, `base_policy`, `demand`, `env`, `clock`,
`blob_root`). The executor already rebuilds a `Ctx` from a `ToolRun` and a
`wiring.Authority` in `wiring.run_workspace_tool` (`wiring.gleam`):
`workspace_context` (`:1461`) takes the plain part from the run and the
machine part from `WorkspaceView`, then `directories.revalidate` and
`permissions.revalidate` check the stored authority against this machine's
filesystem before widening. That is exactly the revalidation 098 wants.

What the local machine reads from the door's `Ctx`: `op_id`, `step_id`,
`source_index` (directory names, `local.gleam`, `:656`), `strand`,
`grants`, `directory_access` (through `codemode_tool.request`), and the
machine-local fields. The plain part is `Key` + `strand` + `Authority(access,
standing)` + the consumed `grants`.

Two things 098 gets wrong here:

- `EvolutionRun(key, …, run: ToolRun, args, …)`: the promoted tool has no
  `ToolRun`. `live.invoke` is reached from the `evolution_invoke` door's
  `run(ctx, args)` (`serve.gleam`), and `Ctx` carries no call id. The
  door call's key is the natural ledger key, one promoted call per door call.
- `run_program` has no handle: programs are never staged
  (`local.invoke_program` compiles per call, `:640`).

**098**: replace `coordinates`/`run`/`authority` with one record,
`Coordinates(key: Key, strand: String, grants: List(policy.Grant),
authority: wiring.Authority)`, built by `protocol.coordinates_of(session,
ctx)`. `EvolutionRun(incarnation, token, coordinates, target: Target, args,
reply)` with `Target = Promoted(handle, tool: String) | Program(candidate:
record.Candidate)`; the ledger column is `evolution:<tool>` or
`evolution:program`. The executor synthesises the `ToolRun` that
`workspace_context` wants (call id `evolution/<step>/<index>`), builds the
`Ctx` through a new `wiring.context_for(view, refused, output, run, authority)`
(the first half of `run_workspace_tool`, extracted), and runs the check with
`tool.ignore_output()`: a remote check has no rolling tail. A local check's
tail today is the door call's, which the executor cannot name. The design
note should record that difference.

### 1.3 The executor has a code-mode host and a seed; the scratch needs its own mask

Claim: `executor_plane` can build `machine/local.Config`.

Checked: `executor_plane.attach_of` (`executor_plane.gleam`) sends the
finished `codemode_wiring.Config` to `configs`, and `start` keeps it as
`Built.code_mode: Option(…)` (`:526`); the seed comes from `seed_of`
(`:1153`), the same ladder a local daemon uses. The other `local.Config`
fields exist on the executor: `base` is `census.base_policy`, `secrets` is
`machine.secrets`, `namespace` is the scope's registry, `logger` is
`machine.logger`, `at` can be built from `root`, `census.base_policy`,
`machine.demand`, `census.env` (`serve.hook_coordinates`, `:5445`, is the
only builder today and takes `Settings`).

Two gaps:

- `memory: memory.Door`. Locally it is `extension_memory.for_session` over
  the runtime (`extension/memory.gleam`); the executor has no runtime.
  It has `spec.owner.facts` (`owner_services.FactAccess`, `:171`), whose
  `put_blind` is `api.put_reserved_fact` (`owner_services.gleam`), and
  `ext/` is a reserved prefix (`runtime/api.gleam`, `:2728`). A door
  over facts is six lines: `memory.over_facts(facts)`.
- The scratch directory. `local.private_base` lifts the protected entry that
  encloses the build directory with `codemode.reaching_socket(base, owned,
  directory)` (`codemode.gleam`), where `owned` is two levels above
  `config.scratch`. That only lifts entries *under* `owned`. Locally the
  masks are exactly `<state>/evolution`, `<state>/evolution/run/<session>`
  and `<state>/evolution-trials` (`serve.evolution_directories`). On the
  executor `protecting_state_root` masks named entries, not the root
  (`workspace_policy.gleam`, `:1443`), so `<state>/evolution` is not
  masked at all today and the lift would find nothing. The executor must add
  `<state>/evolution` to the scope's `where_maskable` masks and use
  `<state>/evolution/run/<session>` as the scratch, so `owned` is
  `<state>/evolution` as it is locally.

### 1.4 The executor cannot build a `machine.Machine`; it builds a `local.Config`

Claim (design note and 098): "`executor_plane` builds the same
`machine.local`".

Checked: every `Machine` function but `identity` and `snapshot` takes
`store.Store` first (`evolution/machine.gleam`), and `local.stage`,
`evaluate_candidate` and `invoke_program` read the candidate from it
(`store.approved`, `store.read_candidate`, `store.authorized`). `evaluate.
prepare_slot` (`evaluate.gleam`) and `evaluate.tested` (`:210`),
`program.test_execution` (`program.gleam`) and `stateful.prepare`
(`stateful.gleam`, `store.approved`) read it too. The executor has no
catalogue, so the "move, not rewrite" of slice 2 is not enough: the local
machine has to be split into a catalogue-free core that takes a
`record.Candidate`, and a wrapper that reads the candidate and checks
`approved`/`authorized`/`current` before calling it. The orchestrator sends
the candidate over the wire (`record.Candidate` is plain data, at most
`max_candidate_bytes`, 1 MiB).

The executor-side value a stage produces is also not a `live.Generation`:
its hook bus lives on the orchestrator (1.1), and its tools carry real
closures over the satellite. It is a new record, `local.Staged`, with the
pieces `assemble` (`local.gleam`) builds today.

**098** and **note**: "artifact" leaves every message; `EvolutionStage`,
`EvolutionEvaluate` and `Prepare` carry `candidate: record.Candidate`. The
executor builds `machine/local.Config` and calls the catalogue-free core;
`machine/local.new` is the orchestrator's wrapper. The seam record keeps its
`store.Store` arguments.

### 1.5 The census: one field, a two-variant type, computed per plane build

Checked: `remote_census.RemoteCensus` (`remote/remote_census.gleam`) is
plain data with one `Subject`; a test refuses function values
(`executor_plane_test`, `the_census_is_plain_data_with_no_function_values`).
The identity depends on the scope's seed (`seed_of(machine, root)`), so it
belongs to the per-scope census, not to a daemon-wide fact, and it costs one
`gleam --version` (5 s cap) and a hash of the seed's vendored sources
(`evolution/identity.gleam`) at every plane build. A rebound attach
reuses the plane's census (`host.place`, `:727`), so it pays nothing.
Constructors to touch: `executor_plane.plane_over` and the test support
`remote_orchestrator.census_over`.

**098**: `evolution: EvolutionCensus` with `Compiles(identity:
record.Identity) | Uncompiled(reason: String)`, not `Option(EvolutionCensus)`
with a reason inside.

### 1.6 The version bump is sound; split it by slice

Checked: `protocol.version = 4` (`remote/protocol.gleam`); the host
compares it before anything else (`host.gleam`) and `Attach` keeps its
seven fields. The reply type `Attached(census)` changes shape through the new
census field, which is fine because it is only sent after the check. 098 is
right that `Attach` keeps its v2 arity.

Recommendation: version 5 adds the eight slice-3 messages; `EvolutionTrial`
and `EvolutionCore` come with the slices that serve them, under their own
bumps. A constructor whose server-side arm can only refuse is a wire shape
nobody has exercised, and its fields will move when slice 4 decides whether
a trial is a full session (the note's "main open question"). Every bump
already requires both daemons to upgrade together, so the cost is the same
either way. **098**: say so, and keep the table in two parts.

### 1.7 Custody ranks are right; the cleanups list is fixed at build

Checked: `executor_plane.rank` puts `Evolution` at 2, after `ToolConfig` and
before `Services`, `Broker`, `Helpers` (`:995`); nothing files it today.
`retire` (`:962`) stops the language servers and the scope's supervised
children first, then runs the filed cleanups by rank. But the list is drained
once, at the end of `start` (`drain(filed, [])`, `:522`), so a generation
staged later cannot file itself. The plan files one cleanup at build time,
`#(custody.Evolution, fn() { evolution.retire_all() })`, closing over the
scope's evolution actor started in the build. A failed `retire_all` counts
as one failure, so the close is `UnknownCleanup` and the operator's
`loomd executor release` applies, as 078 intends. 098's custody paragraph
stands.

### 1.8 Admission by key: reuse the two existing answer kinds

Checked: `exec_ledger.admit` takes `tool` as a free string and
`admitted(session, tool)` lists by it (`storage/exec_ledger.gleam`,
`:999`), so `evolution:<name>` needs no schema change and never appears in
`running_executions` (`host.gleam` filters `execution_tool`). The host
stores bytes through `codec.encode_outcome` (a `ToolOutcome`) or
`codec.encode_execution` (a `JsonValue`) (`remote/codec.gleam`), one per
`CallKind`.

Rather than a third kind, `EvolutionEvaluate` replies `ExecutionAnswer`
with the report as JSON (`{verdict, reason, observation}`, under
`max_evidence_bytes` of 64 KiB, well inside the 1 MiB execution
reservation), and `EvolutionRun` replies `RunAnswer` with an
`effects.ToolOutcome`. The executor turns the generation's `tool.ToolOutcome`
into one with `tool.to_result_message` (`tools/tool.gleam`) and the
orchestrator turns it back with a new `tool.from_result_message`, the exact
inverse (`ToolResultMessage` keeps `content`, `details` and `is_error`;
`terminate` travels as the `ToolCompleted.terminate` flag). **098**: name the
two reply types.

The reconciler already settles such a row: `settled_by_kind`
(`remote/workspace.gleam`) treats any key whose step is not `async/` as a
tool call and acknowledges it once the door call's batch no longer lists it.

### 1.9 Drop "recover both evolution doors from the ledger in `Hands.recover`"

Claim (note, slice 3 list): recovery should ask the ledger by key for an
orphaned `evolution_test` or `evolution_invoke`.

Checked: both doors are `replay: tool.Never` (`tools/evolution.gleam`),
so after a runtime restart `recover_by_placement` (`remote/workspace.gleam:
772`) stages `OutcomeUnknown` and the model issues a new call under a new
key. The executor's host monitors the process that owned the request's
reply (`host.gleam`); a dead effect process is a `DOWN` that is not
`noconnection`, so the orphaned check is cancelled and its row marked
`Unknown`. No evidence is written for it, because evidence is written on the
orchestrator from a reply that never comes. Two checks never overlap and
nothing runs twice. Recovering the door's outcome from a stored evaluate
answer would need `remote/workspace` to know evolution's post-processing
(record evidence, then word the door's reply), for a restart in the middle of
a check that takes seconds. The rule that exists is enough. **098** and
**note**: remove the `Hands.recover` sentence; state the cancellation rule
instead.

### 1.10 `EvolutionHook.remaining_ms` needs no rebasing

Checked: the bus's `Invoker` already passes a duration (`deadline_ms`, used
as `within`, `extension/hosts.gleam`). The executor passes it to
`hosts.invoke_event(... within:)` unchanged. **098**: drop the rebasing
sentence.

### 1.11 `sessions.move`: refuse, for now

Checked: the orchestrator's custody closes `Evolution` (rank 2) before
`Workspace` (rank 6), so a stopped session has retired its generation
through `EvolutionRetire` before its scope closes, and a reopen at the next
incarnation retires a stale plane anyway (`host.place`, `:742`). The
executor never holds a generation the next orchestrator does not know about.
What a move loses is authority: the selection lives in the source
orchestrator's `<state>/evolution/evolution.db`, keyed by
`Session(session_id)` for extensions and by workspace for programs
(`client/evolution.gleam`), and `session_move.Manifest`
(`session_move.gleam`) carries none of it. The moved session opens with
an empty catalogue and silently loses its promoted extension.

Carrying rows would be sound, because the identity the target opens the
catalogue with comes from the same executor's census (1.5), but it is an
export and import of catalogue rows through the manifest. The smallest change
is a refusal in `manager.movable` (`daemon/manager.gleam`) when the
catalogue holds a selection scoped to the session, worded to name
`evolution revoke`. That needs one catalogue read that takes no identity:
`store.session_selections(root, session_id, clock)`, because `store.open`
stamps an identity that reads do not check (`store.gleam`, `:386`).
**Owner decision** (section 4).

### 1.12 The catalogue scope label

Checked: a program candidate's scope is `record.Workspace(origin.workspace)`
and `origin.workspace` is `ctx.workspace` (`serve.gleam`), which for a
registered session is `census.workspace`, the executor's absolute checkout
path. Two executors registering the same path would share one scope; a
session on the second would find the first's selection and be refused
`Changed` by `store.authorized` because the identities differ. Fails safe,
reads wrongly. 098's `executor:<node>/<name>` label is cheap: `open_evolution`
takes a `workspace_label` used for `Origin.workspace`, `store.Caller` and
`evolution_control.new`, the three places that hold the string. A local
session passes `settings.workspace`, unchanged.

### 1.13 Two more things the plan has to say

- `superseded` handles. The remote `stage` retires each superseded handle at
  once; an `UnknownCleanup` answer becomes a retry folded into the returned
  generation's `retire` task (`retirement.sequence`), so custody is kept
  without a new `live` API.
- A stage in progress outliving its waiters (098) means the executor's stage
  must not be a host job cancelled by the caller's `DOWN`. It runs under the
  scope's evolution actor as a managed task; a second `EvolutionStage` for
  the same `(candidate, generation)` joins the waiters.

## 2. The steps

### Step 1. Narrow the seam to plain data (no behaviour change)

Goal: `machine.Machine` answers plain data, and the evidence write and the
program-outcome mapping happen above the seam, so `machine/remote` has one
place to copy.

Files and functions:

- `evolution/evaluate.gleam`: new `pub type Report { Report(verdict:
  record.Verdict, observation: String) }`; `extension_owned` returns
  `Result(Report, Refusal)`; the `TestFailed -> Failed` and `Unavailable ->
  Inconclusive` arms move into `pub fn report_of(outcome: Result(#(Verdict,
  String), Refusal)) -> Result(Report, Refusal)`; new `pub fn record(
  catalogue, id, report) -> Result(record.Evidence, Refusal)` over
  `store.record_evidence(…, record.AuthorTests, …)`.
- `evolution/program.gleam`: `test_with` returns `Result(Report, Refusal)`
  through `report_of`; new `pub fn outcome(execution: codemode_tool.Execution)
  -> tool.ToolOutcome`, moved from `serve.evolution_program_outcome`.
- `evolution/machine.gleam`: `evaluate` returns `Result(evaluate.Report,
  Refusal)`; `run_program` returns `Result(tool.ToolOutcome, Refusal)`.
  Update the module doc.
- `evolution/machine/local.gleam`: `evaluate_candidate` and
  `invoke_program` follow; `invoke_program` applies `program.outcome`.
- `serve.gleam`: the `evaluate` closure in `open_evolution` (`:6718`) calls
  `evaluate.record(catalogue, id, report)` after `machine.evaluate`;
  `evolution_invoked` (`:7017`) drops the `|> result.map(
  evolution_program_outcome)`; delete `evolution_program_outcome`.

Out of scope: any wire type; the executor.

Tests: `test/client/evolution/evaluate_test.gleam` (three
`extension_owned` call sites) assert the `Report` and then `evaluate.record`
to assert the evidence as before; one new value-level test that `report_of`
maps the three outcome shapes. Acceptance: `make e2e-evolution` (all four
suites) unchanged.

Gates: `make check-client`, `make e2e-evolution`, `make doc-check`.

Risks: none to behaviour. The `local` module's `evaluate_kind` keeps
`prepare`-time identity checks inside `store` reads, which step 2 moves.

### Step 2a. A catalogue-free core for checks (no behaviour change)

Goal: every function the executor will call takes a `record.Candidate`, and
every catalogue read and identity check sits in the orchestrator's wrapper.

Files and functions:

- `evolution/evaluate.gleam`: `tested` takes `candidate: record.Candidate`;
  `extension_owned(candidate, directory, build, run, retire)`;
  `prepare_slot(candidate, directory, build, slot)` and `prepare` likewise.
  The `current(catalogue, candidate)` call leaves these; its one remaining
  caller is the wrapper.
- `evolution/program.gleam`: `test_execution(candidate, run)` and
  `test_with(candidate, run, retire)`; the `kind == Program && identity ==
  store.identity` check moves to the wrapper.
- `evolution/machine/local.gleam`: new `pub fn evaluate_candidate_of(config,
  ctx, candidate) -> Result(evaluate.Report, Refusal)` (today's
  `evaluate_kind` body); `evaluate_candidate(config, ctx, catalogue, id)`
  becomes `read_candidate`, `current`, then the core. New `pub fn
  invoke_program_of(config, candidate, ctx, input)`; `invoke_program` becomes
  `authorized`, kind check, then the core. `snapshot` is already
  catalogue-free.
- `evolution/stateful.gleam`: `Context.catalogue` removed; `Compiler` becomes
  `fn(record.Candidate, String, live_slots.Slot) -> Result(evaluate.Prepared,
  Refusal)`; the `store.approved` line in `prepare` leaves (step 2b moves the
  `validate` closure out with the rest of the `live.Generation` assembly).

Out of scope: the `Staged` split (2b); any wire type.

Tests: existing `evaluate_test`, `live_test`, `local_policy_test` adjusted
to the new signatures; `make e2e-evolution` unchanged. Add one value-level
test that `evaluate_candidate` refuses `Changed` for a candidate whose
identity is not the catalogue's, so the moved check is proved to still run.

Gates: as step 1.

Risks: the `stateful` suite is exercised only by `make e2e-evolution`'s
live-upgrade fixture (`support/live_upgrade`); run it on the signoff box
before merging.

### Step 2b. `local.Staged`, the plane opener and the context extraction (no behaviour change)

Goal: what `local.assemble` starts becomes a value with no orchestrator
parts in it, so the executor can hold it; the three helpers the executor
needs stop depending on `serve.Settings`.

Files and functions:

- `evolution/machine/local.gleam`:
  ```gleam
  pub type Staged {
    Staged(
      name: String,                       // the extension's manifest name
      selection: record.Selection,
      tools: List(tool.Tool),             // real run closures over the satellite
      events: List(String),               // the manifest's hook events
      invoke: fn(String, msgpack.MsgPackValue, Int) ->
        Result(msgpack.MsgPackValue, hosts.HookFailure),
      inventory: fn() -> Result(json.JsonValue, String),
      retire: retirement.Task,            // stop_host, then plane.close
      upgrade: Option(Upgrade),           // Some when the live contract opts in
    )
  }
  pub type Upgrade {
    Upgrade(prepare: fn(record.Selection, record.Candidate) ->
      Result(PreparedStaged, store.Refusal))
  }
  pub type PreparedStaged {
    PreparedStaged(successor: Staged, publish: fn() -> Result(Nil, store.Refusal),
      abort: fn() -> Result(Nil, store.Refusal))
  }
  pub fn stage_candidate(config, candidate, selection) -> Result(Staged, Refusal)
  pub fn generation_of(catalogue, logger, staged: Staged) -> Result(live.Generation, Refusal)
  pub fn open_plane(helper: String, base, scratch, clock) -> Result(Plane, Refusal)
  ```
  `stage(config, catalogue, selection)` becomes `approved`, `authorized`,
  `stage_candidate`, `generation_of`. `generation_of` starts the hook bus
  over `hooks.Extension(name, events, invoke: fn(_name, event, args, within)
  { staged.invoke(event, args, within) })`, builds `mode` from `upgrade`
  (wrapping `prepare` with `store.approved` and `authorized`, and
  `generation_of` for the successor), and `retire: sequence(repeat(close bus),
  staged.retire)`. The bus close moves from the inner task to the wrapper;
  the order (bus, host, plane) is unchanged.
  `open_plane` and `retire_effect_plane` move here from `serve.gleam`
  and `:6837` (they only use `workspace_plane.start_effect_plane`,
  `executor` and `exec`).
- `evolution/stateful.gleam`: `attach` returns `Option(Upgrade)` for a
  `Staged` instead of a `live.Generation`; `prepare` returns
  `PreparedStaged`; `with_mode` becomes the inventory decoration plus the
  `Upgrade`. `publish`, `publish_once`, `control` unchanged.
- `serve.gleam`: `open_evolution` passes `open: fn(policy) {
  evolution_machine_local.open_plane(settings.helper_path, policy, scratch,
  clock) }`; new `pub fn hook_coordinates_at(workspace, base, demand, env,
  seed, clock)` that `hook_coordinates` calls.
- `wiring.gleam`: new `pub fn context_for(view, refused, output, run,
  authority) -> Result(tool.Ctx, String)`, the revalidate-and-widen half of
  `run_workspace_tool`, which now calls it.

Out of scope: the wire, the executor, any `serve` wiring beyond the renames.

Tests: `live_test` and the four `make e2e-evolution` suites unchanged in
assertion; a new value-level `machine/local_test` that `generation_of` over a
hand-built `Staged` (fake `invoke`, `retire: done()`) yields a generation
whose bus names the extension and whose `retire` closes the bus first. A
`wiring_test` case that `context_for` refuses an authority whose directory no
longer exists, as `run_workspace_tool` did.

Gates: as step 1, plus `make e2e-evolution` on the signoff box (the
live-upgrade suite exercises `stateful`).

Risks: this is the largest refactor and the one most likely to move a
retirement step. The reviewer checks one thing: for each `Error` path in
`assemble`, the same resources are stopped in the same order as on main.

### Step 3. Protocol version 5, the census field and refusing host arms

Goal: both daemons speak the slice-3 vocabulary, every new message is served
by an arm, and nothing new runs yet.

Files, types and messages:

- `remote/protocol.gleam`: `version = 5` with a "Version 5 added …"
  paragraph on the doc comment. New types:
  ```gleam
  pub type Coordinates {
    Coordinates(key: Key, strand: String, grants: List(policy.Grant),
      authority: wiring.Authority)
  }
  pub type Handle { Handle(boot: BitArray, ordinal: Int) }   // boot: 16 strong bytes per actor start
  pub type Activation {
    Replacement
    InPlace
  }
  pub type Staged {
    Staged(handle: Handle, name: String, tools: List(tool.Described),
      hooks: List(String), activation: Activation, superseded: List(Handle))
  }
  pub type Prepared { Prepared(successor: Handle, tools: List(tool.Described)) }
  pub type TransitionStep {
    Prepare(handle: Handle, selection: record.Selection, candidate: record.Candidate)
    Publish(handle: Handle, successor: Handle)
    Abort(handle: Handle, successor: Handle)
  }
  pub type TransitionAnswer {
    TransitionPrepared(prepared: Prepared)
    TransitionPublished
    TransitionAborted
  }
  pub type Target {
    Promoted(handle: Handle, tool: String)
    Program(candidate: record.Candidate)
  }
  pub type EvolutionCensus {           // lives in remote_census.gleam
    Compiles(identity: record.Identity)
    Uncompiled(reason: String)
  }
  ```
  `Refusal` gains `UnknownHandle`, `AlreadyPublished`,
  `StaleGeneration(serving: Int)` and `NoEvolution(reason: String)`, with
  `describe` arms. `HostMessage` gains eight constructors:
  ```gleam
  EvolutionSnapshot(session, incarnation, token, coordinates: Coordinates,
    directory: String, reply: Subject(Result(archive.Tree, Refusal)))
  EvolutionEvaluate(incarnation, token, coordinates: Coordinates,
    candidate: record.Candidate, reply: Subject(ExecutionAnswer))      // keyed by coordinates.key
  EvolutionStage(session, incarnation, token, selection: record.Selection,
    candidate: record.Candidate, reply: Subject(Result(Staged, Refusal)))
  EvolutionRun(incarnation, token, coordinates: Coordinates, target: Target,
    args: JsonValue, reply: Subject(RunAnswer))                        // keyed by coordinates.key
  EvolutionHook(session, incarnation, token, handle: Handle, event: String,
    payload: MsgPackValue, within_ms: Int,
    reply: Subject(Result(MsgPackValue, hooks.HookFailure)))
  EvolutionTransition(session, incarnation, token, step: TransitionStep,
    reply: Subject(Result(TransitionAnswer, Refusal)))
  EvolutionRetire(session, incarnation, token, handle: Handle,
    reply: Subject(Result(CloseOutcome, Refusal)))
  EvolutionInventory(session, incarnation, handle: Handle,
    reply: Subject(Result(JsonValue, Refusal)))
  ```
  `pub fn coordinates_of(session: String, ctx: tool.Ctx) -> Coordinates`.
  `protocol` must not import `client/evolution/*` modules that pull in
  the broker or satellites; `record`, `archive`, `hooks.HookFailure`,
  `policy.Grant`, `msgpack` are all plain-data modules. Check the import
  graph with `gleam export package-interface` rather than assuming.
- `remote/remote_census.gleam`: `RemoteCensus.evolution: EvolutionCensus`.
- `remote/host.gleam`: `Plane.evolution: Option(Evolution)` with
  ```gleam
  pub type Evolution {
    Evolution(
      evaluate: fn(Coordinates, record.Candidate) -> JsonValue,              // keyed job, Execution kind
      run: fn(Coordinates, Target, JsonValue) -> effects.ToolOutcome,       // keyed job, ToolCall kind
      serve: fn(protocol.EvolutionRequest) -> Nil,                         // the six unkeyed ones
    )
  }
  ```
  and `protocol.EvolutionRequest` (`SnapshotRequest`, `StageRequest`,
  `HookRequest`, `TransitionRequest`, `RetireRequest`, `InventoryRequest`,
  each the message's fields minus the fence, with its reply subject).
  `handle_peer` arms: the two keyed ones go through `admit_call` with
  `Work(kind: Execution, tool: "evolution:test", reservation:
  execution_result_bytes, …)` and `Work(kind: ToolCall, tool: "evolution:" <>
  name, reservation: max_result_bytes, …)`; the six unkeyed ones check the
  scope with a new `exec_ledger.current(ledger, session, incarnation, token)`
  (a read over `require_current`, no schema change), then call
  `plane.evolution.serve(request)`, or answer `NoEvolution` when the field is
  `None`. `EvolutionInventory` carries no token because it changes nothing;
  it checks the incarnation only.
- `executor_plane.plane_over`: `evolution: None`, census
  `Uncompiled("the executor's evolution plane is not built yet")`.
- Test support: `remote_fixtures.factory` and `remote_orchestrator.census_over`
  gain the two fields.
- `docs/architecture/distributed.md` ("4 today").

Out of scope: `EvolutionTrial`, `EvolutionCore` (1.6); any serving code.

Tests (all value-level, `make check` on macOS): `host_test` cases that each
new arm answers `NoEvolution` on a plane without the field, `StaleToken`,
`StaleIncarnation` and `ScopeNotOpen` by content before the plane is asked,
and that `EvolutionRun` with a duplicate key joins the live run (the fake
plane's `Evolution.run` counts, as `fake_tool` does); `codec_test` round-trip
of a report JSON through `encode_execution`; `executor_plane_test`'s
plain-data census test now covers `EvolutionCensus`; a `protocol_test` that
`coordinates_of` carries the door's `op`, `step`, `source_index`, `strand`,
`grants` and `authority` and nothing else.

Gates: `make check-client`, `make check-storage`, `make doc-check`. The P
model needs no change: the eight constructors are the ones it models.

Risks: a v4 orchestrator against a v5 executor is refused at attach, which
is the designed behaviour and is covered by `host_test`'s version case.
Shipped two-daemon fixtures pin both daemons to one build, so none breaks.

### Step 4. The executor's evolution plane

Goal: the executor stages, runs, hooks, migrates, retires and inventories
generations, evaluates and snapshots candidates, and files it all under the
scope's custody. Reachable only by raw protocol messages until step 5.

Files and functions:

- New `client/executor_evolution.gleam`: one actor per scope (`weft/actor`),
  started in `executor_plane.start` when `code_mode` is `Some`.
  ```gleam
  pub type Config {
    Config(local: local.Config, owner: OwnerServices, view: wiring.WorkspaceView,
      clock: Clock, logger: Logger)
  }
  type Slot {
    Empty
    Staging(selection: record.Selection, task: weft.Managed, waiters: List(Subject(…)))
    Serving(handle: Handle, staged: local.Staged)
  }
  type Prepared {   // at most one
    Prepared(predecessor: Handle, successor: Handle, prepared: local.PreparedStaged, phase: Phase)
  }
  type Phase {
    Unpublished
    Published
  }
  type State {
    State(config: Config, boot: BitArray, next: Int, slot: Slot,
      prepared: Option(Prepared), superseded: List(#(Handle, local.Staged)))
  }
  pub fn start(config) -> Result(Plane, String)
  pub fn plane(subject) -> host.Evolution
  pub fn retire_all(subject) -> Result(Nil, String)   // the custody cleanup
  pub fn identity(config) -> Result(record.Identity, String)
  ```
  The rules, each one arm of the actor, are 098's: a stage for the serving
  `(candidate, generation)` answers its handle; a stage for the staging pair
  joins the waiters; a stage for an older generation than the serving or a
  superseded one answers `StaleGeneration`; otherwise it aborts an
  unpublished successor, starts `local.stage_candidate` as a managed `weft`
  task (so the actor keeps answering hooks and runs, and the task outlives a
  waiter that dies), and on completion stops the old serving generation into
  `superseded`, answers `Staged(…, superseded: handles)` to every waiter.
  `Prepare` on the serving handle aborts an unpublished successor and runs
  `upgrade.prepare` as a managed task; on a handle that is not serving it
  answers `UnknownHandle`. `Publish` for the held unpublished successor runs
  `publish`, moves the successor to serving and the predecessor to
  `superseded`; for a published one answers `Published` again; for any
  other successor `UnknownHandle`. `Abort` of the held unpublished successor
  runs `abort`; of a published one `AlreadyPublished`; otherwise `Aborted`.
  `Retire` of a serving or superseded handle performs its `retire` and
  answers `AllRetired` or `UnknownCleanup(1)` keeping the retry; of an
  unknown handle answers `AllRetired` (idempotent). `Hook` and `Inventory`
  of a serving handle call `staged.invoke` and `staged.inventory` in a
  detached run so a slow satellite does not hold the actor. `retire_all`
  aborts a prepared successor, retires serving and superseded, and answers
  the first failure. The two keyed functions build a `Ctx` with
  `wiring.context_for` over a synthesised `ToolRun` (call id
  `evolution/<step>/<index>`, `tool.ignore_output()`) and call
  `local.evaluate_candidate_of` (answering the report as JSON) or
  `local.invoke_program_of` and `tool.to_result_message`, or for a
  `Promoted` target look up the serving handle's tool and run it.
  `Snapshot` resolves `directory` under the workspace with
  `fs.resolve_real` and refuses an escape with `fs_read`'s wording, then
  `local.snapshot`.
- `executor_plane.gleam`: `start` builds the `local.Config` for the scope
  (`host: code_mode`, `base: census.base_policy`, `at:
  serve.hook_coordinates_at(root, base, machine.demand, census.env, seed,
  clock)`, `memory: extension_memory.over_facts(spec.owner.facts)`,
  `secrets`, `namespace`, `scratch: machine.state_root <> "/evolution/run/"
  <> session`, `open: local.open_plane(machine.helper_path, _, scratch,
  clock)`, `logger`), starts the actor, files `#(custody.Evolution, fn() {
  executor_evolution.retire_all(actor) })`, and computes the identity once
  for the census. The scope's base policy gains `<state>/evolution` in the
  `where_maskable` masks (`workspace_policy.protecting` beside
  `protecting_siblings`). `plane_over` fills `evolution: Some(plane)` and
  the census. A plane with no code mode files nothing and reports
  `Uncompiled(reason)` with the toolchain's reason.
- `extension/memory.gleam`: `pub fn over_facts(facts: owner_services.
  FactAccess) -> Door` (`remember` parses then `put_blind(key(cell),
  value)`; `recall` is `cell(key(cell))` rendered back; `FactFault` maps to
  `Unavailable`).
- `remote/owner_port.gleam`: `served_prefixes` gains `api.ext_fact_prefix`.
  (Part of this step so the executor-side door works when step 5 lands; it
  widens what a pinned peer may write by one reserved prefix, as 098 says.)

Out of scope: anything on the orchestrator beyond the fence; `machine/remote`.

Tests:

- `executor_evolution_test` (value-level, fake `local.Config`? No: the core
  needs a jail. Instead the actor is tested over a `Staged` built by hand
  with counting closures, through `pub fn start_over(fn(selection,
  candidate) -> Result(local.Staged, Refusal))` that the real `start`
  specialises): one serving generation at a time; a second stage for the
  same pair joins; an older generation is `StaleGeneration`; a stage
  supersedes an unpublished successor; prepare replaces an unpublished
  successor; publish is idempotent; abort after publish is
  `AlreadyPublished`; retire of an unknown handle is `AllRetired`;
  `retire_all` retires serving, superseded and prepared and reports the
  first failure; a waiter that dies does not cancel the stage. These are
  the P model's probes (`PTst/EvolutionProbes.p`) stated as Gleam tests, and
  they run in `make check` on macOS.
- `executor_plane_test` additions over the real factory, the real host and
  the fixture extension from `support/evolution`: send
  `EvolutionStage` with a `Selection` and `Candidate` built by the test,
  assert `Staged.tools` names `evolution_echo`; send `EvolutionRun` with
  `Promoted` and read `version-1:fresh`; send `EvolutionHook` for an event
  the fixture declares none of and read `Unhandled`; `EvolutionRetire`
  answers `AllRetired`; a `Close` after a stage without a retire still
  answers `AllRetired` (custody); `EvolutionEvaluate` answers a report with
  `passed`; a duplicate `EvolutionEvaluate` key joins. These run where
  `executor_plane_test` runs (helper and seed present) and skip otherwise.
- `owner_port_test`: `FactPutBlind` under `ext/` is served and under
  `agent/` is refused.
- `memory_test`: `over_facts` writes `ext/<name>/<key>` and reads it back
  through a fake `FactAccess`.

Gates: `make check-client`; `make executor-smoke`; `make doc-check`.

Risks: the mask and the lift (1.3): if `<state>/evolution` is not in the
protected list the candidate's build jail sees nothing and the stage fails
`WorkspaceSetupFailed`; `executor_plane_test`'s stage case is the proof.
The actor is the slice's one new process; the reviewer holds it to
`docs/weft.md` (managed tasks for stage and prepare, waiters flushed on
completion, no hand-rolled monitors).

### Step 5. `machine/remote` and the `serve` wiring

Goal: a registered session gets evolution wiring whose machine sends the
messages. **This is the step that first makes executor sessions able to
use evolution.**

Files and functions:

- `remote/surface.gleam`: `pub fn ask(surface, make: fn(Subject(reply)) ->
  HostMessage(census)) -> reply` (the `Forever` exchange) and `pub fn
  ask_within(surface, ms, make) -> Result(reply, Nil)`; `pub fn
  incarnation(surface) -> Int` and `pub fn token(surface) -> BitArray`.
  `exchange` itself stays private.
- New `evolution/machine/remote.gleam`:
  ```gleam
  pub type Link {
    Link(session: String, surface: surface.Surface(RemoteCensus),
      identity: record.Identity, logger: Logger)
  }
  pub fn new(link: Link) -> machine.Machine
  ```
  `Link` holds the opaque attached surface and the machine calls
  `surface.ask` and `surface.ask_within` on it, which is why those two are
  the only additions to `surface`. A record of one closure per reply type
  would be the alternative, but Gleam closures are monomorphic, so it would
  be eight fields for no gain. The test passes a surface attached to
  `remote_orchestrator`'s fake executor.
  The functions: `identity` answers `link.identity`; `snapshot` sends
  `EvolutionSnapshot(coordinates_of(session, ctx), directory)`; `evaluate`
  reads the candidate (`store.read_candidate`, the `Changed` check), sends
  `EvolutionEvaluate`, decodes the `ExecutionFinished` JSON into
  `evaluate.Report` (`ExecutionLost` is `Inconclusive(unknown_outcome_text)`,
  a refusal is `Unavailable(describe(refusal))`); `stage` does `approved`
  and `authorized`, sends `EvolutionStage`, retires every `superseded` handle
  at once (an `UnknownCleanup` becomes a `retirement.repeat` folded into the
  generation's `retire`), and builds the `live.Generation`: tools from
  `Described` with `run: fn(ctx, args) { run_remote(Promoted(handle, name),
  ctx, args) }` and a `requirements` that asks for no root (the shape the
  doors use, `tools/evolution.gleam`), the bus over
  `hooks.Extension(name, hooks, invoke: EvolutionHook)`, `mode` by
  `activation` (`InPlace` wraps `Prepare` with `approved` and `authorized`
  and builds the successor the same way, `publish`/`abort` send their steps;
  a `Publish` answered `UnknownHandle` is the "migration lost" case 098
  names), `validate: store.authorized`, `inventory: EvolutionInventory`,
  `retire: sequence(repeat(close bus), repeat(retire_remote))` where
  `retire_remote` is `ask_within(60_000, EvolutionRetire)`: `AllRetired` and
  no answer are `Ok`, `UnknownCleanup(_)` is `Error`; `run_program` does
  `authorized`, sends `EvolutionRun(Program(candidate))` and maps the
  `RunAnswer` back with `tool.from_result_message` (`RunLost` is a failure
  outcome with `unknown_outcome_text`).
- `tools/tool.gleam`: `pub fn from_result_message(message: AgentMessage,
  terminate: Bool) -> Result(ToolOutcome, Nil)`, the inverse of
  `to_result_message` (`harness/tool_table.terminates` is the Bool side).
- `remote/workspace.gleam`: `Hands` gains `evolution: Option(remote_machine.
  Link)`: `Some` when the census is `Compiles(identity)`, built over the
  attached surface; `None` with the reason logged once (`evolution.
  unavailable`, naming the executor).
- `serve.gleam`: `Half` gains `evolution_link: Option(remote_machine.Link)`
  (`there` fills it, `here` is `None`). `open_evolution` takes the machine
  and the workspace label instead of building the local machine itself:
  ```gleam
  fn open_evolution(settings, machine: evolution_machine.Machine, label: String,
    scratch: Option(String), agency_config, clock, logger, owner)
  ```
  with a new `fn local_evolution_machine(settings, host, base, namespace,
  environment, clock, logger) -> Machine` holding today's `Config` block.
  `assemble_in` (`:4101`) chooses: `Trial(_)` none; `Source` with a local
  host: local machine, `settings.workspace`, `Some(scratch)`; `Source` with
  `evolution_link: Some(link)`: `remote.new(link)`, label
  `"executor:" <> executor <> "/" <> settings.workspace`, no scratch;
  otherwise none. `evolution_root(settings)` already resolves to
  `<state>/evolution` for a registered session (it reads
  `settings.codemode_sockets`, the daemon's `<state>/run`); confirm in the
  test rather than by reading. `evolution_masks` is unchanged (`There`
  never prepares a local policy). `evolution_profiles`, `evolution_recover`,
  `close_evolution` and the hook wiring are unchanged: they hold a
  `Machine` and a `live.Live` and cannot tell which kind.
- `docs/architecture/distributed.md`, `multiplayer.md`: no change beyond
  the version line.

Out of scope: trials and profiles on executor sessions (slice 4: a
`Prompt` candidate's `evolution_test` on a registered session answers
`Authority("prompt trials run on a local workspace only")` from the
`evolution_compare` branch, one added guard on `settings.evolution_role`
and the placement); `sessions.move` (step 6).

Tests:

- `machine/remote_test` (value-level, `make check` on macOS) over
  `support/remote_orchestrator`: a fake executor whose factory's
  `Evolution.serve` answers scripted `Staged`/`Prepared`/`AllRetired`
  values and whose `run` records calls. Asserts: `stage` returns a
  generation with the described tools and a bus naming the extension;
  `tools[0].run` sends `EvolutionRun(Promoted)` with the door's key; the bus
  `invoke` sends `EvolutionHook` with the duration unchanged; `retire` is
  `Ok` on `AllRetired` and on no answer within the bound, `Error` on
  `UnknownCleanup`; a `superseded` handle is retired before `stage`
  returns and an unconfirmed one rides on the generation's `retire`; a
  `Publish` answered `UnknownHandle` surfaces as the migration-lost
  refusal; `evaluate` decodes the report and refuses `Changed` for a stale
  identity before sending.
- `tool_test`: `from_result_message(to_result_message(outcome, …), flag)
  == Ok(outcome)` for the four content shapes.
- `serve` wiring: `workspace_test`-style open of a registered session over
  `remote_orchestrator` with a `Compiles` census asserts the session
  registers the five `evolution_*` tools and the trace tools; with
  `Uncompiled` it registers none and logs the reason.
- Two-daemon acceptance: see step 7; the minimal form (one extension,
  author, test, approve, select, invoke on a registered session) lands in
  this PR as `make e2e-evolution-remote`, gated by
  `LOOM_BOOTSTRAP_E2E_SERVER` like `remote_pair.shipped`, so the step's
  claim is proved where it can be.

Gates: `make check-client`, `make e2e-evolution` (local path unchanged),
`make e2e-evolution-remote` on the signoff box, `make doc-check`.

Risks: the orchestrator's `EvolutionWiring.catalogue` is opened with the
executor's identity; a candidate proposed from a *local* session of the same
daemon carries the local identity, so one daemon's catalogue holds rows of
two identities. Reads filter by visibility and `authorized` refuses
`Changed`, so the mix is safe; the catalogue page will show the other
placement's candidates as not authorised. Acceptable for this slice; the
label (1.12) keeps program scopes apart.

### Step 6. Refuse `sessions.move` with a selection, and the scope label

Goal: a move cannot silently drop a promoted extension.

Files and functions:

- `evolution/store.gleam`: `pub fn session_selections(root: String,
  session_id: String, clock) -> Result(List(record.Selection), Refusal)`, a
  read that opens the database as `Owner` with the placeholder identity
  (reads never compare it) and returns the selections scoped
  `Session(session_id)`.
- `daemon/manager.gleam`: `movable` (`:4165`) gains a read through a new
  `Book` field `evolution_root: Option(String)` and refuses
  `AdminNotMovable("the session serves a selected extension; revoke the
  selection (evolution revoke) before moving it")` when the list is not
  empty.
- The label (1.12) is step 5's `label` argument; this step adds nothing
  unless step 5 lands without it.

Out of scope: carrying rows in the manifest.

Tests: `manager` unit test over a temporary catalogue: a session with a
`Session`-scoped selection is `not_movable`; one with only a `Workspace`
selection moves (programs recompile per call and nothing is held);
`store_test` for `session_selections`.

Gates: `make check-client`, `make doc-check`.

Risks: none; the read is one SQLite open.

### Step 7. Acceptance and documentation

Goal: the claim "programs, extensions and author tests work on executor
sessions" is proved by a shipped two-daemon fixture, and the records say
what was built.

- `test/client/evolution_remote_acceptance_test.gleam` over
  `support/remote_pair` and `support/provider_http`: reuses
  `evolution_acceptance_test`'s `author_script` and `invoke_script` (the
  scripted model writes `support/evolution.extension(n)` through the
  executor's filesystem tools, proposes, tests; the operator approves and
  selects through the control socket's `evolution` commands; the model
  invokes). Cases: a fixed executor; a pool of one; an executor restart
  with a selected extension, after which the reopened session serves it
  again (`Staged` joins nothing, a fresh stage); a program candidate
  (`support/evolution_program`). A link cut during staging and an
  orchestrator restart are slice 6.
- `Makefile`: `e2e-evolution-remote` beside `e2e-evolution`, needing
  `binaries codemode-seed`.
- `docs/design-notes/remote-evolution.md`: "The seam as built" gains the
  split of 1.4 and the differences of 1.2 and 1.9; the slice-3 entry says
  what landed.
- `protocol-change/098-remote-evolution.md`: the edits marked **098** above;
  status stays PROPOSED until slices 4 and 5, with an "Implemented: slice 3
  messages, protocol version 5" line.
- `docs/architecture/distributed.md` (version, the evolution path),
  `docs/architecture/executor.md` (the evolution plane under custody),
  `packages/client/CLAUDE.md` for `executor_evolution` and
  `machine/remote` (`make doc-check`), `docs/next.md`.

Gates: `make e2e-evolution-remote` on the signoff box, `make doc-check`,
`make check`.

## 3. Order, and what merges when

| Step | Behaviour change | First usable by | Merge after |
| --- | --- | --- | --- |
| 1 seam answers plain data | none | – | – |
| 2a catalogue-free core | none | – | 1 |
| 2b `local.Staged`, plane opener, `context_for` | none | – | 2a |
| 3 protocol v5, census field, refusing arms | version number only | – | 2b (uses `local.Staged` names in docs only; could land after 1) |
| 4 executor evolution plane | executor serves raw messages | tests only | 3 and 2b |
| 5 `machine/remote` and `serve` wiring | **executor sessions use evolution** | sessions | 4 |
| 6 move refusal | `sessions.move` refuses one more case | – | 5 |
| 7 acceptance and docs | none | – | 5 |

Steps 3 and 2b are independent of each other and can be worked in parallel
by two workers; step 4 needs both. Steps 6 and 7 are independent.

Each worker's brief should carry: the repo rules on weft, literate comments,
no naked `Bool`, R6 (none of this touches `core`/`machine`/`prompt`), the
sub-agent worktree isolation and the gate-by-exit-code rule from
`docs/execution.md` §4.

## 4. Decisions (taken; see the status note above)

1. **`sessions.move` with a selection: refuse (step 6) or carry the catalogue
   rows in the manifest.** Refusal is one read and one message; carrying
   rows is an export/import of candidates, evidence and selections and is
   sound because the identity is the executor's. The plan assumes refuse.
2. **Version 5 carries eight messages; trials and core get their own bumps**
   (1.6), or all ten now as 098 lists them.
3. **Drop the `Hands.recover`-by-key item** (1.9): orphaned checks are
   cancelled by the executor's caller monitor and the door's `replay:
   Never` already stages the unknown outcome. The plan assumes dropped.
4. **A remote check has no rolling output tail** (1.2): the executor runs
   evolution checks with `ignore_output()` because the door call's id is not
   on the wire. Accept, or add the call id to `tool.Ctx` (a `tools` change
   touching every `Ctx` constructor) so the tail can be attributed.
5. **One daemon, two identities in one catalogue** (step 5 risk): a daemon
   that serves both local and executor sessions keeps both placements'
   candidates in `<state>/evolution/evolution.db`. Accept for this slice, or
   key the catalogue directory by placement (`<state>/evolution/<label>`),
   which changes `serve.evolution_root` and the operator's `evolution` CLI
   paths.

## 5. Summary

Steps: (1) seam answers `evaluate.Report` and `tool.ToolOutcome`, evidence
written in `serve`; (2a) checks and `stateful` take a `record.Candidate`,
identity checks move to the wrapper; (2b) `local.Staged`,
`local.generation_of`, `local.open_plane`, `serve.hook_coordinates_at`,
`wiring.context_for`; (3) protocol version 5 with `Coordinates`, `Handle`,
`Staged`, `Target`, `TransitionStep`, `EvolutionCensus`, eight constructors,
four refusals, `host.Plane.evolution`, arms that refuse; (4)
`executor_evolution` actor under `custody.Evolution`, `memory.over_facts`,
the `ext/` fence, the `<state>/evolution` mask; (5) `machine/remote`,
`surface.ask`, `tool.from_result_message`, `Hands.evolution`, `serve`
choosing the machine and the scope label, the first remote acceptance; (6)
`sessions.move` refusal; (7) the two-daemon suite, 098 and the notes.

Decisions needed: move refusal versus carried rows; version 5 with eight
messages versus ten; dropping ledger recovery for the doors; no output tail
for remote checks; one catalogue for both placements.

098 edits (all marked above): `Staged` and `Prepared` shapes with `name`,
`hooks` and `activation`; `Coordinates` and `Target` replacing `run`/
`artifact`/`handle` on `EvolutionRun`; `candidate` on `EvolutionStage`,
`EvolutionEvaluate` and `Prepare`; `EvolutionCensus` as a two-variant type;
`ExecutionAnswer` and `RunAnswer` as the keyed replies; `MsgPackValue` in the
plain-data list; no rebasing of `within_ms`; the executor builds a
`local.Config`, not a `Machine`; the `Hands.recover` sentence replaced by the
cancellation rule; the version split by slice.

## Addendum from the #1092 review (step 4 must-fix)

The host's read-only `exec_ledger.current` check before `plane.evolution.serve`
is atomic against Close/Attach (all scope-state writers run in the host actor's
turn). The gap is after `serve` returns: a Close's custody `retire_all` comes
from another process, so step 4's evolution actor must make `retire_all`
terminal (refuse later stages) and cancel or await a stage in flight. Test it.
098 has since gained that slice-3 addendum (PR #1097), which supersedes
#1091's "node vocabulary unchanged" line.

## Addendum from the #1098 review (step 4 input)

A `Staged` value holds no catalogue, store, bus or orchestrator actor, so it
can live on an executor. One indirect capture remains: its tools and its
upgrade's `prepare` hold a `dispatch.Config` whose `memory` is
`extension_memory.for_session(agency_config)` (a door over the session
runtime) and whose `secrets` is a settings lookup. Both are `local.Config`
inputs, so the executor supplies its own: memory through
`extension_memory.over_facts(spec.owner.facts)` (written on the step 4 branch),
and secrets from the executor's own source, or a clear refusal when it has
none. Step 4 must say which.

## Step 4 acceptance, as briefed

These requirements were given to the step 4 worker on top of the plan above,
and the reviewer of step 4 should hold the PR to each one.

1. `retire_all` is terminal. After custody runs it, the actor refuses every
   later stage, prepare, run, hook and evaluate, and a stage or prepare task
   already in flight is cancelled through weft managed-task cancellation, or
   awaited, and whatever it built is retired rather than left serving. Tests
   cover a close that arrives before the stage completes and one that arrives
   after.
2. The executor supplies its own memory and secrets doors, as above.
3. The host's ledger fence from PR #1092 is not weakened.
4. The actor is built on weft (`weft/actor`, managed tasks for stage and
   prepare, waiters flushed on completion, no hand-rolled monitors), per
   `docs/weft.md`.
5. `<state>/evolution` is in the scope base policy's maskable list, or the
   candidate's build jail fails with `WorkspaceSetupFailed`. The
   `executor_plane_test` stage case is the proof.
