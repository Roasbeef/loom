# codemode

## Purpose

Code mode: a model writes a *program*, not a tool call, and the program
runs once in a disposable jailed BEAM whose only reachable effect is one
capability channel back to the broker. This package is the whole harness
side of that — vet, compile, launch, host — and it never runs
model-influenced code itself (Rule Zero). WP-J.

## Key Types

- `codemode/codemode.{Execution, ExecOutcome, ExecConfig}` — `execute`
  threads source through vet → compile → run, short-circuiting at the
  first refusal, and returns an `Execution`: the outcome plus what the
  kernel enforced on both jailed stages. Every stage's failure is a
  value: `VetRejected`, `CompileFailed`, `RunFailed`,
  `Ran(source, artifact, outcome)`.
- `codemode/enforcement.{Report, Enforcement, of_call, of_result, layers}`
  — what a jailed stage's helper reported, or why no report exists.
  `Reported(entries, degraded)` is `exec_exit`'s ground truth with the
  broker's own degraded rule applied (any `skip:` entry counts);
  `Unreported(reason)` is never a claim of confinement. `layers` splits
  applied layers from skipped ones so no renderer can confuse them.
- `codemode/vet.{VetResult, Vetted, Rule, Rejection}` + `vet/policy.VetPolicy`
  — the pure import/`@external` lint. `Vetted` is opaque, so only linted
  source can reach a build.
- `codemode/compile.{Artifact, CompileError, BuildProducts, Built,
  Compiled, Builder, Dependency, CompileConfig}` — the hermetic compile
  service. Writes the program under the pinned `program_module`,
  generates `entry_module`, and pins exactly `default_dependencies()`.
  `compile` returns a `Compiled`: the artifact or its error, and the
  build jail's enforcement report.
- `codemode/seed` — the pre-resolved package cache a hermetic build is
  cloned from. `prepare` lays one out, `verify` refuses a stale or
  differently-pinned one, `main` is `gleam run -m codemode/seed`.
- `codemode/build.BuildConfig` — the production `Builder`: `gleam build
  --warnings-as-errors` inside a network-off jail, then the flattened
  `.beam` set and its content address.
- `codemode/launch.LaunchConfig` — the production `satellite.Launcher`:
  the AF_UNIX cap socket, then a jailed `erl` dispatched under the host's
  own `{op_id, step_id}`.
- `codemode/satellite.{ExecId, Run, RunError, Outcome, SatelliteConfig,
  LaunchSpec, CapConnection, Launcher, WireIn, CapRouter, CapRequest,
  CapPlan, CapDenial}` — the in-harness host: the broker end of the cap
  channel, the deadline, the teardown. `run` returns a `Run`: the
  program's outcome and the node's enforcement report, which
  `CapConnection.destroy` hands back. `Msg` is opaque so no forged
  settlement can be injected.

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
- **Broker** — every `cap_call` becomes a `broker.clear_call` under one
  pooled `{op_id, step_id}`; so do the jailed build and the node itself.
- **Commits / registers**: none. `execute` returns the source and artifact
  for the runtime to persist; this package writes no entries.

## Invariants

- **Vetting is the gate on what a program may ask for; the broker decides
  per call what it gets.** The allowlist is byte-identical membership
  behind an ASCII grammar gate, so no homoglyph is ever a member.
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
- **The node runs under the host's own `{op_id, step_id}`.** That is what
  makes `broker.abort` at the deadline actually kill it, and what pools
  the budget across the whole execution — fan-out buys parallelism, not
  extra resources. The node itself holds one outstanding effect, so a
  pooled cap below two is refused.
- **The cap token authenticates the channel; it does not confine an
  escaped `.beam`.** The token file is readable inside the jail by
  necessity. What confines a hostile `.beam` is the kernel jail and the
  broker's per-call policy check. Do not write it the other way round.
- **Reachability is checked, not assumed.** `SandboxPolicyV1` has no
  "bind this path" verb, so the launcher expresses the socket and token as
  readable roots *and* refuses the two cases the vocabulary cannot state:
  a path under a `protected` entry, and a path under the scratch tmpfs
  mount. See `protocol-change/004-sandbox-policy-explicit-mounts.md`.
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
- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  the one door, the wire, the jail, Rule Zero.
- [docs/review/m4-triage.md](../../docs/review/m4-triage.md) — the review
  wave this package's current shape answers.
- [packages/broker/CLAUDE.md](../broker/CLAUDE.md) — the broker end.
- [packages/sandbox/CLAUDE.md](../sandbox/CLAUDE.md) — the jail.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules. `make
  codemode-seed` prepares the offline package cache; `make e2e-codemode`
  runs the jailed acceptance against it.
