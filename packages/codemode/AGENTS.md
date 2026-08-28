# codemode

## Purpose

Code mode: a model writes a *program*, not a tool call, and the program
runs once in a disposable jailed BEAM whose only reachable effect is one
capability channel back to the broker. This package is the whole harness
side of that — vet, compile, launch, host — and it never runs
model-influenced code itself (Rule Zero). WP-J, and WP-N for the
orchestration seam.

There are **two seams over one pipeline**, and a submission is vetted
against exactly one of them (`vet/policy.Seam`). The *workspace* seam is
`cap/{fs, proc, net, git, lsp, report, task, actor, kv}`, routed by
`satellite.default_router` for the jailed `proc.run` and by
`codemode/workspace` for the harness-side `fs.read`, `fs.list` and
`kv.*`. The *orchestration* seam is `cap/strand` + `cap/report` and
nothing else, routed by `codemode/orchestration` onto the Agency closures
the `agent_*` tools call. `report.emit` is the one capability **both**
seams service, by one mechanism (`codemode/artifact`), because
`cap/report` is the one module both allowlists carry. Which capabilities travel
together is the whole of what the separation buys: a compromised
orchestration program can spawn and message within the lineage its own
strand roots, and can reach neither the disk, the network, nor a process.

## Key Types

- `codemode/codemode.{Execution, ExecOutcome, ExecConfig}` — `execute`
  threads source through vet → compile → run, short-circuiting at the
  first refusal, and returns an `Execution`: the outcome, what the
  kernel enforced on both jailed stages, and what an approved escalation
  widened. Every stage's failure is a
  value: `VetRejected`, `CompileFailed`, `RunFailed`,
  `Ran(source, artifact, outcome)`. `ExecConfig.identity` is the one
  place in the pipeline an operation, a step, a budget *or an approval's
  grants* can be written.
- `codemode/identity.{ExecIdentity, PhaseIdentity, Phase, BuildLedger,
  for_execution, with_own_build_ledger, under_budget, widened_by,
  build_phase, run_phase, grants, ledger_keys}` — the identity one
  execution runs under, the approval that widens it, and
  the phases derived from both. Both types are opaque: `for_execution` is
  the only way to mint an `ExecIdentity`, and `build_phase` / `run_phase`
  — which take one — are the only ways to obtain a `PhaseIdentity`.
  `BuildLedger` (`BuildSharesLedger` | `BuildHasOwnLedger`) is the whole
  of the choice an execution has about its ledger count, and
  `ledger_keys` reads that count off the identity value before anything
  runs. `widened_by` attaches an approved escalation's grants and
  `grants` reads back what a phase carries — the run phase's, and empty
  for a build phase whatever the execution holds.
- `codemode/enforcement.{Report, Enforcement, Widening, of_call,
  of_result, layers, widened, unspent, grant_label}`
  — what a jailed stage's helper reported, or why no report exists, and
  what an approval relaxed before it was asked to.
  `Reported(entries, degraded)` is `exec_exit`'s ground truth with the
  broker's own degraded rule applied (any `skip:` entry counts);
  `Unreported(reason)` is never a claim of confinement. `layers` splits
  applied layers from skipped ones so no renderer can confuse them.
  `Widening` is a peer of `Enforcement` rather than a field in it —
  `Reported.entries` is the helper's verbatim ground truth, and folding a
  harness-side decision into it would put a claim about what Loom did
  where a reader expects one about what the kernel did. Two states and no
  third: `Widened(grants)` for a run phase that composed them,
  `NotWidened(reason)` for both of the ways that does not happen.
  `grant_label` renders one grant as a diff line an operator can read.
- `codemode/vet.{VetResult, Vetted, Rule, Rejection}` + `vet/policy.{VetPolicy,
  Seam, for_seam, default, orchestration, default_cap_modules,
  orchestration_cap_modules, harness_only_cap_modules,
  default_stdlib_modules}` — the pure import/`@external`
  lint and the two allowlists it is parameterized by. The four list
  functions are public so the confinement can be asserted as a property
  rather than as a snapshot, and so `scripts/gen-prelude.sh --check` can
  read them with no toolchain. `Vetted` is opaque,
  so only linted source can reach a build. `Seam` is closed at two
  variants, so "which capabilities travel together" is a decision this
  package owns and a host selects from rather than assembles.
- `codemode/orchestration.{Orchestration, router, ceilings, serviced_caps,
  refusal_code, default_spawn_ceiling, send_ceiling, note_ceiling,
  notes_ceiling, spawn_ceiling_code, admission_ceiling_code, emit_cap}` —
  the orchestration seam's capability router. It decodes a `strand.*`
  frame into `tools/agent`'s vocabulary, hands it to one of the six
  `Agency` closures under a `Caller` derived from the threaded
  `PhaseIdentity`, and carries the answer — or the refusal, under the
  tools' own name — back. Its seventh arm is `report.emit`, over the same
  `codemode/artifact` closure the workspace seam holds (issue #91 item 1:
  `cap/report` was on this allowlist and `serviced_caps` omitted `emit`,
  so the module's one effectful function was advertised and refused).
  It builds **no `broker.CallSpec`**: every plan it returns is
  `satellite.ServedHere`, so it cannot state coordinates at all.
- `codemode/workspace.{Workspace, DirEntry, FsRefusal, KvRefusal, routing,
  ceilings, serviced_caps, unserviced_caps, max_list_entries, fs_denial,
  kv_denial}` — the workspace seam's *harness-side* capability router
  (issue #16). A record of six injected closures — `fs_read`, `fs_list`,
  `kv_get`, `kv_set`, `kv_delete`, `emit` — wrapped in front of an inner
  router, the same shape `client/mcp.routing` has. Every plan is
  `satellite.ServedHere`: a workspace read, a process-local store write
  and a blob mint leave no VM, so there is nothing a jail could contain
  and a composed `SandboxPolicy` would have no enforcer. It builds **no
  `broker.CallSpec`** and holds **no path logic** — containment is
  `tools/fs.resolve_real`'s and the large-file guard is
  `fs.read_text_file`'s, called by the injected closures
  `client/codemode.workspace_seam` builds. `fs.write` and `fs.edit` have
  no slot in the record and are refused by name: write waited on the
  protected-path check (#105) and edit is an open contract question, the
  satellite side carrying neither anchors nor a digest.
- `codemode/artifact.{Artifact, Emit, EmitRefusal, plan, answer, ceiling,
  emit_cap, max_emit_bytes, default_emit_ceiling, emit_ceiling_code}` —
  the `report.emit` mechanism, shared by both seams. One byte bound per
  emission (1 MiB, refused in band — the 16 MiB frame cap is the wrong
  number because a frame is transient and an artifact is a durable mint),
  one lifetime admission ceiling (64, because every call writes something
  that outlives the execution), one content address. Its own module
  rather than a member of either seam's, so neither seam module imports
  the other for it.
- `codemode/compile.{Artifact, CompileError, BuildProducts, Built,
  Compiled, Builder, Dependency, CompileConfig, generated_path}` — the
  hermetic compile service. `Builder` is
  `fn(PhaseIdentity, String, List(#(String, String))) -> Built`: the
  build phase and the generated capability modules both arrive per build
  from the pipeline, so a builder holds neither coordinates nor a
  configuration of its own. Writes the program under the pinned
  `program_module`, generates `entry_module`, and pins exactly
  `default_dependencies()`. `CompileConfig.generated` is the
  `cap/mcp/<server>` façades this execution's program imports, as
  `#(module name, source)`; `generated_path` says where one lands, which
  is *inside* the vendored prelude, because a façade calls
  `cap/internal/mcp` and Gleam admits an internal module only to its own
  package. `compile` returns a `Compiled`: the artifact or its error, and
  the build jail's enforcement report.
- `codemode/seed` — the pre-resolved package cache a hermetic build is
  cloned from. `prepare` lays one out, `verify` refuses a stale or
  differently-pinned one, `main` is `gleam run -m codemode/seed`.
- `codemode/build.BuildConfig` — the production `Builder`: `gleam build
  --warnings-as-errors` inside a network-off jail, then the flattened
  `.beam` set and its content address. Carries no operation, step,
  budget or grants.
- `codemode/launch.LaunchConfig` — the production `satellite.Launcher`:
  the AF_UNIX cap socket, then a jailed `erl` dispatched under the host's
  own `{op_id, step_id}`.
- `codemode/satellite.{Run, RunError, Outcome, SatelliteConfig,
  LaunchSpec, CapConnection, Launcher, WireIn, CapRouter, CapRequest,
  CapPlan, CapDenial}` — the in-harness host: the broker end of the cap
  channel, the deadline, the teardown. `run` takes the run phase's
  `PhaseIdentity`; `SatelliteConfig` carries none, and `LaunchSpec` and
  `CapRequest` carry the derived identity rather than a loose
  `{op_id, step_id, budget}` triple. `run` returns a `Run`: the
  program's outcome and the node's enforcement report, which
  `CapConnection.destroy` hands back. `Msg` is opaque so no forged
  settlement can be injected. `CapPlan` has two shapes — `ClearedCall`
  (a jailed `broker.clear_call`) and `ServedHere` (a request the harness
  answers itself, on a process of its own) — and `CapCeiling(cap,
  admissions, code)` is a lifetime cap on one capability's admissions
  within one execution, carrying the in-band code its refusal travels
  under so the host stays generic over capability names.

## Relationships

- **Depends on**: `broker` (`clear_call`, `framing`, `policy`, `token`,
  `budget`, `exec`), `core` (msgpack, ids, clock), `tools` (`tool.Collected`
  and the `blob` content address; `codemode/workspace` additionally names
  `tools/fs`'s `PathError` and `ReadError` so a refusal keeps the
  harness's own vocabulary), `glance` + `glexer` (vetting parses and
  token-scans), `simplifile` + `filepath`, `gleam_erlang`, `gleam_otp`.
- **Deliberately does not depend on `cap`.** `cap` is the prelude compiled
  *into* the satellite; linking it into the harness would put
  model-facing code in the harness VM. Shared names (`LOOM_CAP_SOCK`,
  `LOOM_CAP_TOKEN_FILE`, the `outcome` frame kind) are restated here and
  pinned by tests.
- **Depended on by**: nothing yet — the runtime wiring that persists a
  `Ran` outcome as a durable entry is still owed.
- **FFI**: `codemode/internal/ffi_unix` — `gen_tcp` listen/accept/recv/
  send/close for the AF_UNIX cap socket, backed by `codemode_ffi.erl`.
  Test-only externals (a client end of the socket, `os:cmd`, the wall
  clock) live in `test/support/internal/ffi_peer` and
  `test/codemode_test_ffi.erl`.
- **Counterpart**: `packages/cap` runs inside the satellite and speaks the
  other end of the cap channel; `packages/sandbox` is the jail both the
  build and the node run in.

## Traffic

- **Actor messages** — `satellite.Msg` (opaque): `FromWire(event)`,
  `Connected(send, destroy, ack)`, `CapStarted(id, handle)`,
  `CapDone(id, outcome)`, `Deadline`, `Stop`. `satellite.WireIn`
  (`WireBytes`, `WireClosed`) is what a launcher delivers.
- **Wire (cap channel)** — the frozen Part 1.4 framing over one AF_UNIX
  stream: `cap_call`/`cancel`/`heartbeat` in, `cap_result` out, plus the
  one terminal `outcome` frame (`{v:1, id:0, kind:"outcome", body}`) that
  `broker/framing` does not know and the host decodes itself.
- **Broker** — on the workspace seam every `cap_call` becomes a
  `broker.clear_call` under one pooled `{op_id, step_id}`; so do the
  jailed build and the node itself, on both seams. Every one of those keys
  is derived from `ExecConfig.identity`; see the identity invariant below
  for what an execution may spend. An orchestration `cap_call` reaches no
  clearance at all — it is a `ServedHere` plan answered by the Agency, on
  a process the host spawns and monitors, bounded by `call_timeout_ms`.
- **Agency** (orchestration seam only) — the six `tools/agent.Agency`
  closures, judged against a `Caller` whose strand is the dispatching
  one and whose operation is the threaded identity's. Commits, register
  reads and the lineage ledger are all `client/agency`'s; this package
  makes the call and carries the answer.
- **Commits / registers**: none. `execute` returns the source and artifact
  for the runtime to persist; this package writes no entries.

## Invariants

- **Vetting is the gate on what a program may ask for; the broker decides
  per call what it gets.** The allowlist is byte-identical membership
  behind an ASCII grammar gate, so no homoglyph is ever a member.
- **A capability on no allowlist is a decision, not an absence.** The
  filter fails closed, so a `cap` module nobody allowlisted simply never
  reaches a description and any program importing it is rejected — which
  is right for `cap/runtime` and indistinguishable from an oversight for
  anything else. `harness_only_cap_modules` is where that exclusion is
  written down, and `scripts/gen-prelude.sh --check` holds all three lists
  against the modules `packages/cap` actually ships: every module must be
  on a seam or on that list, and every listed name must be a module that
  exists (issue #95). Both directions self-test.
- **The two seams are confined by one rule read in two directions.** An
  import outside the allowlist the submission is judged against is
  rejected, so an orchestration program reaching for `cap/fs` and a
  workspace program reaching for `cap/strand` are refused by the same
  code — and both as the structured `ImportNotAllowed` rejection the model
  repairs in band. What the two directions rest on is that
  `orchestration_cap_modules` and `default_cap_modules` share no entry but
  `cap/report`; widen either and both rejections stop meaning anything, so
  the disjointness is pinned as an **intersection over those two lists**
  rather than as a literal snapshot of one side. A snapshot catches a
  capability *moved* between the seams and misses one *added to both* —
  and the door for that is `default_stdlib_modules`, which both seams
  append, so a second test asserts that list holds no `cap/*` entry at all
  (issue #90).
- **The admission ceilings are the host's, not the router's, and they
  cover every call that mints.** A call is throttled by turn cost — the
  model pays a round trip per call — and a program's loop pays nothing, so
  replacing the turn with a loop removes an implicit throttle and has to
  add an explicit one. The test is whether a call *mints something that
  outlives the execution*, which four of the six meet: `strand.spawn`
  (32), `strand.send` (128 — a durable commit, and to an idle descendant
  it starts a run), `strand.note` (256 — a durable write-once register
  under a program-chosen key) and `strand.notes` (64 — a full prefix scan
  per call). `strand.wait` and `strand.roster` have none: a wait's whole
  cost is time, which the per-call clamp and the wall deadline bind, and a
  roster is bounded by `session_strands`. **`note` and `notes` are one
  decision** — a note/notes loop is quadratic in harness work and the
  quadratic needs both factors unbounded, so relaxing either alone
  restores it; the alternative, a size-charged read or a work budget, is
  the model-readable budget #23 forbids arriving by the side door. Each is
  a *lifetime* cap on admissions, distinct from the pooled
  `max_outstanding` (in flight at once) and from the Agency's
  `fan_out`/`session_strands` (live at once), which a spawn-join-spawn
  loop passes forever. Refused *at* the ceiling, in band, naming the
  capability and the number and saying that waiting will not free a slot:
  a spawn under the shipped `spawn_ceiling` code, the other three under
  one generic `admission_ceiling`, because a program at any of them does
  the same thing and the message says which. Only the spawn number is
  configurable (`Orchestration.spawn_ceiling`); the rest are the seam's
  constants.
- **The unit is the execution, and that is the replacement for the
  turn.** One host per `run`, one `run` per `execute`, one `execute` per
  tool call — so K `code_mode` calls in one message get K tallies. What
  the turn cost throttled was zero-marginal-cost *iteration*, not turns:
  inside one execution a loop is free, while a second `code_mode` call
  costs an authored program, a hermetic build, a node launch and its own
  deadline, so its marginal cost is spawn-shaped. Per turn would not be a
  boundary anyway — a model that can put K executions in one message can
  put K in K messages. The host is also the only place the tally can be
  keyed honestly: it holds the one `PhaseIdentity` derived from the one
  `ExecIdentity` a caller may mint, and a router, which a caller could
  build twice, never holds it. A lifetime spawn count per *batch*, if it
  is ever wanted, is a fold over the durable lineage ledger's
  `minted_by: CallSite(operation, step_id, source_index)` rather than a
  new mechanism — and it generalises to none of the other three, since
  nothing durable records a note, a read or a send by call site.
- **A code-mode spawn says who minted it, in a field of its own.** A
  child's name is minted from `{parent, purpose slug, call-site digest}`,
  and a whole execution is one planned tool call — so every spawn in a
  program arrives under one `{operation, step_id, source_index}` and
  would otherwise mint one name repeatedly, the second reconciling onto
  the first child. `CapRequest.ordinal` separates them and travels as
  `agent.Minter.Program(ordinal:)`; `Caller.source_index` stays the
  *dispatching* `code_mode` call's own index. Two fields for two facts,
  because they answer different questions and each is load-bearing on its
  own: the ordinal separates one program's spawns from each other, and
  the source index separates this execution from every other call in its
  batch — an `agent_spawn` at index 0 and, decisively, a second
  `code_mode` call, which shares this one's operation, step and ordinal
  tally alike. The predecessor spent `source_index` on the ordinal and
  distinguished the rest with a `-program` suffix on the step; the suffix
  reached no name at all, because the name slugged the step and the slug
  cap is shorter than a step id. The *operation* is threaded through
  untouched, which is what keeps a run end reaping what the program
  spawned.
- **A program's module name is chosen by the compile service, never by the
  source.** `program_module` is a path, and a Gleam module is named by its
  path, so prelude shadowing is structurally impossible.
- **Generated capability modules scale with a program's imports, not
  with a host's configuration.** A host may have generated one
  `cap/mcp/<server>` module per configured MCP server (issue #106);
  `execute` narrows that table to the *vetted* program's own import list
  before `compile` sees it, so a program that named one server pays for
  one and a program that named none pays for nothing. It is a cost
  filter and not an authorization one — what a program may import is the
  vetting allowlist's decision, made before this runs, and a module
  written into a build nobody imports is dead source. The write itself
  belongs to the **builder**, after the seed clone: `clone_seed` replaces
  `vendor/` wholesale, so a module written before it would be deleted,
  and the dependency table `seed.verify` compares is untouched either
  way.
- **The build is pinned and offline.** Exactly one stdlib version and the
  prelude vendored *inside* the build root — a range cannot be resolved
  with the network off, and an absolute or out-of-root path sends Gleam
  back to resolution and so to Hex. The builder refuses a seed whose
  dependency table is not byte-identical to the generated one.
- **`--warnings-as-errors` is load-bearing.** It turns Gleam's transitive
  dependency import warning into a compile error, so `gleam/erlang/*`,
  `gleam/otp/*` and `core/*` are closed by the compiler and not only by
  the vetting allowlist. The cost — ordinary warnings failing the build —
  is paid deliberately.
- **The cap socket exists before the node does.** The launcher listens,
  then dispatches; the satellite's connect cannot lose that race.
- **Inbound bytes and the close come from one process, in stream order.**
  A satellite that writes its terminal `outcome` and exits can never have
  its death overtake its result. The node's exit status arrives by another
  path and only *enriches* a close the reader already saw.
- **Teardown does not depend on the host surviving to run it.** The host
  cleans up on every exit path it takes itself, and `launch.start_janitor`
  spawns an unlinked process monitoring the host that runs the same
  teardown when it dies however it died — the broker's fd-3 safety net in
  miniature. A host killed from outside leaves no node running, no socket
  bound, and no token file on disk.
- **Every outcome carries both stages' enforcement reports.** The
  build's rides in `compile.Compiled`, the node's in `satellite.Run`, and
  `codemode.Execution` carries both as a two-field record, so an outcome
  cannot exist without them. The node's comes from
  `CapConnection.destroy`, which the host calls *before* it reports its
  outcome; the launcher's holder cancels the node's clearance whichever
  way teardown and clearance race, and a cancelled execution still
  answers with `exec_exit`. A stage that genuinely made no report says
  why, which is a different value from one whose report was lost
  (issue #5, spec-gaps WP-J 14).
- **The wall deadline is armed on `Connected`, not on launch.** A timer
  armed up front could stop the host before the launch delivered its
  connection, leaving the node's `destroy` handle undelivered;
  `hand_over` monitors the host so a connection arriving after its death
  is destroyed rather than dropped.
- **One threaded `ExecIdentity`, from which the build phase is derived.**
  The invariant is *not* "one identity ever": the build/run split is
  legitimate — a different jail under a different policy with its own
  enforcement report — and `make e2e-codemode` and the migration sample
  both rely on accounting the build separately. What is typed is that the
  build phase is *derived*, never assembled beside the run's. `ExecConfig`
  has exactly one identity field; `compile.CompileConfig`,
  `build.BuildConfig`, `satellite.SatelliteConfig` and
  `launch.LaunchConfig` have no operation, step or budget at all, and
  `codemode.execute` hands each injected seam the phase it derived. Both
  identity types are opaque, so a `PhaseIdentity` cannot exist without an
  `ExecIdentity` to come from, and `BuildLedger`'s two variants are the
  whole of the choice — there is no way to spell a third ledger.
  `identity.ledger_keys` is therefore a function of the identity value
  alone, answering one or two before anything runs (issue #22, spec-gaps
  WP-J 16, `docs/adr/005-budget-pooling-granularity.md`). **`{op_id,
  step_id}` is the batch identity, not the execution identity**:
  `code_mode` is `tool.Exclusive`, which forbids a concurrent start and
  nothing more, so one batch may hold two `code_mode` calls that run back
  to back sharing the pair. `{op_id, step_id, source_index}` is the
  execution identity, `client/codemode.exec_root` digests that triple so
  each execution's build root, cap socket and token file are its own, and
  the ledger keys on the pair deliberately (ADR-005, "Two programs in one
  batch"). The source index is **not** a fourth field on `ExecIdentity`
  and must not become one: what this value exports feeds ledger keys and
  `CallSpec`s, so a per-call coordinate stored here would sit one
  field-read from the budget key, where "completing" it would mint one
  ledger per call in a batch the model authored (issue #87). The limit of the
  claim: `broker.CallSpec` is a public record shared with `tools` and
  `client`, so an injected router or launcher could still hand-write a
  clearance under coordinates it invented — closing that needs an opaque
  `CallSpec` in the broker, which has callers outside this package. What
  is closed is the case that happened: a *configuration* carrying its own
  copy of the identity fields.
- **An approval widens the run phase and never the hermetic build.** An
  approved escalation's grants ride the same threaded `ExecIdentity`
  (`identity.widened_by`), for the same reason the budget does: four
  configuration records able to hold a widening is four places a caller
  could write a *different* one. `run_phase` carries them and
  `build_phase` **drops** them, so the four clearances that used to pass
  `grants: []` now all read `identity.grants(phase)` and the build's is
  empty by construction rather than by remembering. That asymmetry is a
  decision, not a convenience: `policy.compose` applies grants *after*
  the meet, so a `GrantNetwork` reaching the build call would put the
  network back on inside a build whose whole security property is that it
  is pinned and offline — and nothing a submitted program says changes
  what the build asks for anyway, so a build refused on policy is an
  operator's misconfiguration rather than a decision about this program.
  Grants move no ledger key, so an approval buys a widening and never a
  second pooled cap. `codemode.Execution.widening` says which grants a
  run composed, or which of the two ways it composed none — an approval
  that is spent, and one that is carried and never reached, are different
  facts and an operator auditing approvals needs both (issue #24,
  spec-gaps WP-J 15, design §5.3).
- **The grants an execution carries are attributed to it, or there are
  none.** There is no session-wide grant list anywhere below
  `ExecConfig` — the same absence `client/wiring` keeps for the tool
  path — so an approval that cannot be attributed to one execution
  widens nothing. Composition is the only place grants act, and it is
  still `base ⊕ requirements ⊕ grants`: a grant that does not cover a
  shortfall leaves the refusal exactly where it was, which is what keeps
  a yes given for one want from being spendable on another. What binds
  an approval to *this* program is upstream of this package — the action
  digest of the `code_mode` call's effective arguments, which include
  the submitted source (issue #65) — and this package must not have a
  second door that skips it.
- **The node runs under the host's own `{op_id, step_id}`.** That is what
  makes `broker.abort` at the deadline actually kill it, and what pools
  the budget across the whole execution — fan-out buys parallelism, not
  extra resources. The node itself holds one outstanding effect, so a
  pooled cap below two is refused.
- **The cap token authenticates the channel; it does not confine an
  escaped `.beam`.** The token file is readable inside the jail by
  necessity. What confines a hostile `.beam` is the kernel jail and the
  broker's per-call policy check. Do not write it the other way round.
  Both halves of that sentence are now observed rather than argued. The
  broker's half is in `satellite_test.gleam`: an unauthenticated
  `cap_call` denied, and the genuine token presented against a
  policy-forbidden call and refused. The kernel's half is the sandbox
  self-test's `unvetted beam denied host write, secret, and network`
  probe — a hand-written Erlang module, never vetted, never built by the
  compile service, never touching the cap channel, loaded straight into a
  node inside the jail and calling `file:write_file/2`,
  `file:read_file/1` and `gen_tcp:connect/4` for itself. Confined it gets
  `erofs`, `enoent` and `eperm`; with the same three policy mechanisms
  granted instead of withheld it reaches all three, which is what keeps
  the first result from being three failures in a row that mean nothing.
  What is *not* claimed is "reaches nothing on the filesystem": the
  helper's base view ro-binds the whole host filesystem, so an
  unprotected host path is still readable from inside the jail
  (`protocol-change/004-sandbox-policy-explicit-mounts.md`).
- **Reachability is checked, not assumed.** `SandboxPolicyV1` has no
  "bind this path" verb, so the launcher expresses the socket and token as
  readable roots *and* refuses the two cases the vocabulary cannot state:
  a path under a `protected` entry, and a path under the scratch tmpfs
  mount. See `protocol-change/004-sandbox-policy-explicit-mounts.md`.
- **The orchestration router builds no clearance.** Every plan it returns
  is `ServedHere`, so the `CallSpec` boundary `codemode/identity`'s module
  doc names — a public record an injected router could fill with invented
  coordinates — is untouched by this seam rather than widened by it. The
  `{op_id, step_id}` it hands the Agency come off the threaded
  `PhaseIdentity`; the one thing it derives is the call site's `Minter`,
  and that never becomes a ledger key.
  It follows that **a grant has nothing to widen on this seam**, and that
  is the answer rather than an omission. A grant is a `policy.Grant`; it
  composes into a `SandboxPolicy`; a `ServedHere` plan builds no policy,
  reserves no budget and enters no jail. What bounds an orchestration
  call instead is the Agency's own authorization — the descendant-only
  addressing rule, `depth_cap`, `fan_out`, `session_strands` — plus this
  package's spawn ceiling, and **none of those is widenable by an
  approval**. They are structural bounds on a lineage rather than
  per-call sandbox policy an operator would authorize one re-execution
  of, and routing grants at them would be a second widening path beside
  composition. The satellite *node* on this seam is still a jailed
  clearance under the run phase, so an orchestration execution is
  widened exactly where a workspace one is and nowhere else. The
  affordance that would change this is "approve similar for this
  session" (§5.3, filed as #79), which is a session-policy change and
  not a grant.
- **The default router refuses what it does not service, and its doc
  table says who does.** `proc.run` is the only capability it maps: it is
  the one that becomes a jailed clearance. `fs.read`, `fs.list`, `kv.*`
  and `report.emit` are `codemode/workspace`'s and `codemode/artifact`'s,
  wrapped in front of it by `client/codemode`; `mcp.<server>` is
  `client/mcp`'s. **`git.*` is nobody's and never will be** — `cap/git`
  composes `proc.run` inside the satellite, so there is no `git.*` name
  for any router to map, and the table promising one as pending
  over-counted the bridge by a whole module (issue #16's scoping). What
  is genuinely owed is `net.request` (the egress proxy), `lsp.*` (#25),
  and `fs.write`/`fs.edit`. Even within `proc.run`, a
  call carrying `cwd`, `stdin`, `env`, or `timeout_ms` is denied in band
  rather than run without them, and output is rendered as msgpack *text*
  because `cap/proc` decodes it into a `String`.

## Deep Docs

- [docs/architecture/code-mode.md](../../docs/architecture/code-mode.md) —
  the three layers, the pipeline, and what each one actually confines.
- [docs/design-notes/orchestration-comparison.md](../../docs/design-notes/orchestration-comparison.md)
  — "The verdict: connect them, through a second seam": why the
  orchestration seam is a second allowlist rather than a tenth capability,
  and why Rule Zero closes the trusted-interpreter alternative.
- [docs/examples/fan_out_review.gleam](../../docs/examples/fan_out_review.gleam)
  — the orchestration sample, run verbatim by
  `test/codemode/orchestration_sample_test.gleam`.
- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  the one door, the wire, the jail, Rule Zero.
- [docs/review/m4-triage.md](../../docs/review/m4-triage.md) — the review
  wave this package's current shape answers.
- [packages/broker/CLAUDE.md](../broker/CLAUDE.md) — the broker end.
- [packages/sandbox/CLAUDE.md](../sandbox/CLAUDE.md) — the jail.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules. `make
  codemode-seed` prepares the offline package cache; `make e2e-codemode`
  runs the jailed acceptance against it.
