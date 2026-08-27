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
`satellite.default_router`. The *orchestration* seam is `cap/strand` +
`cap/report` and nothing else, routed by `codemode/orchestration` onto the
Agency closures the `agent_*` tools call. Which capabilities travel
together is the whole of what the separation buys: a compromised
orchestration program can spawn and message within the lineage its own
strand roots, and can reach neither the disk, the network, nor a process.

## Key Types

- `codemode/codemode.{Execution, ExecOutcome, ExecConfig}` — `execute`
  threads source through vet → compile → run, short-circuiting at the
  first refusal, and returns an `Execution`: the outcome plus what the
  kernel enforced on both jailed stages. Every stage's failure is a
  value: `VetRejected`, `CompileFailed`, `RunFailed`,
  `Ran(source, artifact, outcome)`. `ExecConfig.identity` is the one
  place in the pipeline an operation, a step or a budget can be written.
- `codemode/identity.{ExecIdentity, PhaseIdentity, Phase, BuildLedger,
  for_execution, with_own_build_ledger, under_budget, build_phase,
  run_phase, ledger_keys}` — the identity one execution runs under, and
  the phases derived from it. Both types are opaque: `for_execution` is
  the only way to mint an `ExecIdentity`, and `build_phase` / `run_phase`
  — which take one — are the only ways to obtain a `PhaseIdentity`.
  `BuildLedger` (`BuildSharesLedger` | `BuildHasOwnLedger`) is the whole
  of the choice an execution has about its ledger count, and
  `ledger_keys` reads that count off the identity value before anything
  runs.
- `codemode/enforcement.{Report, Enforcement, of_call, of_result, layers}`
  — what a jailed stage's helper reported, or why no report exists.
  `Reported(entries, degraded)` is `exec_exit`'s ground truth with the
  broker's own degraded rule applied (any `skip:` entry counts);
  `Unreported(reason)` is never a claim of confinement. `layers` splits
  applied layers from skipped ones so no renderer can confuse them.
- `codemode/vet.{VetResult, Vetted, Rule, Rejection}` + `vet/policy.{VetPolicy,
  Seam, for_seam, default, orchestration}` — the pure import/`@external`
  lint and the two allowlists it is parameterized by. `Vetted` is opaque,
  so only linted source can reach a build. `Seam` is closed at two
  variants, so "which capabilities travel together" is a decision this
  package owns and a host selects from rather than assembles.
- `codemode/orchestration.{Orchestration, router, ceilings, serviced_caps,
  refusal_code, default_spawn_ceiling}` — the
  orchestration seam's capability router. It decodes a `strand.*` frame
  into `tools/agent`'s vocabulary, hands it to one of the six `Agency`
  closures under a `Caller` derived from the threaded `PhaseIdentity`, and
  carries the answer — or the refusal, under the tools' own name — back.
  It builds **no `broker.CallSpec`**: every plan it returns is
  `satellite.ServedHere`, so it cannot state coordinates at all.
- `codemode/compile.{Artifact, CompileError, BuildProducts, Built,
  Compiled, Builder, Dependency, CompileConfig}` — the hermetic compile
  service. `Builder` is `fn(PhaseIdentity, String) -> Built`: the build
  phase arrives per build from the pipeline, so a builder holds no
  coordinates of its own. Writes the program under the pinned `program_module`,
  generates `entry_module`, and pins exactly `default_dependencies()`.
  `compile` returns a `Compiled`: the artifact or its error, and the
  build jail's enforcement report.
- `codemode/seed` — the pre-resolved package cache a hermetic build is
  cloned from. `prepare` lays one out, `verify` refuses a stale or
  differently-pinned one, `main` is `gleam run -m codemode/seed`.
- `codemode/build.BuildConfig` — the production `Builder`: `gleam build
  --warnings-as-errors` inside a network-off jail, then the flattened
  `.beam` set and its content address. Carries no operation, step or
  budget.
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
  answers itself, on a process of its own) — and `CapCeiling` is a
  lifetime cap on one capability's admissions within one execution.

## Relationships

- **Depends on**: `broker` (`clear_call`, `framing`, `policy`, `token`,
  `budget`, `exec`), `core` (msgpack, ids, clock), `tools` (`tool.Collected`
  and the `blob` content address), `glance` + `glexer` (vetting parses and
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
- **The two seams are confined by one rule read in two directions.** An
  import outside the allowlist the submission is judged against is
  rejected, so an orchestration program reaching for `cap/fs` and a
  workspace program reaching for `cap/strand` are refused by the same
  code — and both as the structured `ImportNotAllowed` rejection the model
  repairs in band. What the two directions rest on is that
  `orchestration_cap_modules` and `default_cap_modules` share no entry but
  `cap/report`; widen either and both rejections stop meaning anything, so
  the disjointness is pinned by its own test.
- **The spawn ceiling is the host's, not the router's.** `agent_spawn` is
  throttled by turn cost — the model pays a round trip per spawn — and a
  program's loop pays nothing, so replacing the turn with a loop removes
  an implicit throttle and has to add an explicit one. It is a *lifetime*
  cap on admissions, distinct from the pooled `max_outstanding` (in flight
  at once) and from the Agency's `fan_out`/`session_strands` (live at
  once), which a spawn-join-spawn loop passes forever. It lives in the
  host because one host is stood up per execution holding the one
  `PhaseIdentity` a caller may mint, so the tally is keyed to that
  identity by construction; a router, which a caller could build twice,
  never holds it. Refused *at* the ceiling, in band, naming the number and
  saying that joining will not free a slot.
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
  WP-J 16, `docs/adr/005-budget-pooling-granularity.md`). The limit of the
  claim: `broker.CallSpec` is a public record shared with `tools` and
  `client`, so an injected router or launcher could still hand-write a
  clearance under coordinates it invented — closing that needs an opaque
  `CallSpec` in the broker, which has callers outside this package. What
  is closed is the case that happened: a *configuration* carrying its own
  copy of the identity fields.
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
- **The default router refuses what it does not service.** `proc.run` is
  the only capability it maps today; every other `cap` name comes back
  `unsupported_cap` until the harness-side tool bridge lands, and a caller
  holding that bridge injects a fuller router. Even within `proc.run`, a
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
