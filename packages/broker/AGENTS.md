# broker

## Purpose

The ToolBroker: the single door between the harness and the outside world.
It composes sandbox policy, refuses or narrows what it cannot enforce,
reserves pooled budget, mints a capability token, borrows a `loom-exec`
helper from the pool, dispatches the jailed execution, streams its output,
and settles. It also owns the broker side of the frozen effect-plane wire
protocol (spec Part 1.4). WP-G.

## Key Types

- `broker/broker.Broker` — opaque actor handle. `clear_call` is the whole
  story; `stdin`, `cancel`, `abort(op_id)`, `stop` round it out.
- `broker/broker.{CallSpec, CallHandle, CallEvent, CallOutcome, Refusal}` —
  the request, its handle, the streamed `CallOutput` / `CallSettled`
  events, and `CallExited(result)` versus `CallFailed(failure)`.
- `broker/policy.SandboxPolicy` — `SandboxPolicyV1` as a typed value:
  writable/readable/protected roots, `NetworkPolicy`, `Limits`,
  `env_allow`, `Scratch`. `compose` implements session base ⊕ tool
  requirements ⊕ escalation grants; `narrow_unenforceable` fails closed.
- `broker/token.{Token, Vault, Binding}` — 32 random bytes bound to
  `{op_id, step_id, policy, deadline}`, checked in constant time.
- `broker/budget.{Budget, Ledger}` — pure pooled accounting, one ledger per
  live `{op_id, step_id}`.
- `broker/exec.{Helper, Pool, ExecRequest, ExecResult, ExecFailure,
  EnforcementDemand, Transport}` — the helper actor, the pool, and the
  transport seam (`PortTransport` real, `ChannelTransport` for tests).
  `ExecResult.cancelled` says the helper truncated the run;
  `ExecResult.enforcement` is the ground truth `required_layers` and
  `unapplied_layers` check the policy's demands against.
- `broker/exec.{SpawnConfig, HostPlatform}` — how a real helper is
  started, and whether this host has a jail for it to build.
  `SpawnConfig.helper_args` carries the two things the helper can only
  learn from its command line (a delegated cgroup base, and
  `--allow-unenforced` on a platform with no jail), because an Erlang port
  cannot set its child's environment. `host_platform_for` is the pure
  decision and mirrors the helper's own `jail.PlatformFor`;
  `unenforced_helper_args` and `unjailed_skip_reason` are the only
  sanctioned answers to an unjailed host.
- `broker/framing.{Frame, Body, Deframer, Fault}` — the wire protocol with
  its pure incremental deframer.
- `broker/escalation.{Escalation, Denial, Event}` — denial → approval →
  single consume.

## Relationships

- **Depends on**: `core` (msgpack for the wire, ids for `OpId`,
  corruption), `gleam_erlang` + `gleam_otp` (the broker, helper, and pool
  are actors; ports carry the helper channel).
- **Depended on by**: `tools` (every jailed tool clears through
  `clear_call`), `conformance` (wiring and the jailed e2e).
- **FFI**: `broker/internal/ffi_crypto` — `crypto:strong_rand_bytes` and
  `crypto:hash_equals` for token entropy and constant-time comparison.
  `broker/internal/ffi_port` — port open/send/close, OS pid lookup and
  kill, and private-file writes for fd-3 policy delivery. Both are backed
  by `broker_ffi.erl`; the rest of the package takes them as injected
  function values, so pure logic stays testable with deterministic
  substitutes.
- **Counterpart**: `packages/sandbox` (Go) speaks the other end of
  `broker/framing`.

## Traffic

- **Actor messages**
  - `broker.Msg` — `ClearCall(spec, events, reply)`,
    `SendStdin(handle, data, eof)`, `CancelCall(handle)`, `AbortOp(op_id)`,
    `Settle(call_id)`, `RelayDown(down)`, `QueryRelay(handle, reply)`,
    `StopBroker`.
  - `exec.Msg` (per helper) — `AwaitReady(reply)`, `QueryStatus(reply)`,
    `Run(request, events, reply)`, `Stdin(data, eof)`, `CancelExec`,
    `CancelDeadline(exec_id)`, `HandshakeDeadline`, `HeartbeatTick`,
    `Heartbeat(reply)`, `Shutdown`, `FromWire(event)`.
  - `exec.PoolMsg` — `Checkout(reply)`, `Checkin(helper)`, `StopPool`.
  - Outbound to callers: `broker.CallEvent` (`CallOutput`, `CallSettled`)
    and `exec.ExecEvent` (`Output`, `Exited`, `Failed`).
- **Commits / registers**: none. The broker persists nothing; durability of
  escalation events is the runtime's job — it records each `escalation.Event`
  before acting on it.
- **Wire** — `frame := u32_be length ++ msgpack(map)` with keys
  `"v":1, "id":u64, "kind":str, "body":map`. Kinds: `hello`, `exec_start`,
  `exec_stdin`, `exec_out`, `exec_exit`, `cap_call`, `cap_result`,
  `cancel`, `heartbeat`, `error`. `protocol_version` is 1;
  `max_frame_bytes` is 16 MiB. The base policy additionally travels on
  fd 3 at spawn (see below).

## Invariants

- **Every inbound frame is data.** Decoding is total: a malformed frame is
  a value describing the fault — the caller closes the channel and settles
  the effect in-band per spec §3.3 invariant 6 — never a crash. An unknown
  but well-formed kind is reported *separately* so the caller answers with
  an in-band `error` frame and keeps the channel (forward compatibility,
  mirroring the helper). Frame boundaries never depend on transport
  chunking.
- **Budget is pooled per execution, not per call — a decision, not a
  default.** A token is valid for exactly one `{op_id, step_id}`, so that
  pair *is* the execution identity and the broker holds one
  `budget.Ledger` per live pair. The first clearance opens the ledger;
  later clearances reserve against the stored budget, which their own
  budget field cannot widen. This closes the amplification hole: 10,000
  polite parallel reads share one `max_outstanding` cap and one aggregate
  wall deadline — which a per-call cap could not do, since 10,000
  *separate* calls each within its own cap sails straight through it.
  `docs/adr/005-budget-pooling-granularity.md` records this against the
  concrete case that put it in question (`grep`'s `Concurrent` tag
  contradicting a `bash`-sized `max_outstanding: 1`, issue #50): the
  keying stays `{op_id, step_id}`, the fix was the tool's own declared
  budget. Read it before threading a new identity through this key
  (issue #22) or stacking a further cap on top of it (issue #23).
- **Reservations cannot leak.** They are released on settlement, freed
  wholesale on `abort`, and reclaimed when a call's relay process dies
  unsettled (every relay is monitored). Releases are generation-checked, so
  a stale settlement from before an abort never frees a later ledger's
  budget.
- **Tokens are single-use and unforgeable.** 32 bytes of injected entropy,
  bound to `{op_id, step_id, policy, deadline}`, transmitted only over the
  channel they authorize, revoked at settlement. `abort` revokes every
  token of an operation and kills the OS process group through the helper's
  cancel ladder. Presented bytes are compared in constant time and the
  check scans every entry without early exit, so a match's position leaks
  nothing either.
- **Unenforceable policy narrows, never widens.** The egress proxy sidecar
  does not exist, so `narrow_unenforceable` downgrades `NetworkProxy` to
  `NetworkOff` and reports it as an ordinary `Narrowing` before every
  dispatch. Under `RefuseNarrowed` the caller gets a structured denial
  naming the unenforceable grant; under `ProceedNarrowed` the execution
  runs with no network at all. Nothing ever claims a proxy allowlist was
  enforced.
- **`validate` refuses a scratch of the literal host root** (issue #59,
  `PolicyError.ScratchIsRoot`). Landlock has no deny rules — its grants
  only ever union — so a host-path `scratch: "/"` would reach the Go
  helper's `internal/llock` as `RWDirs("/")` with nothing able to carve a
  hole back out of it, whatever the mount layer does. `broker.gleam`
  calls `validate` on every composed policy right before dispatch
  (`authorize`), which is also therefore the one place that shuts this
  off before any policy carrying it ever reaches the wire. See
  `packages/sandbox/CLAUDE.md`'s Landlock layering note for the other
  half: the mount layer stays free to bind exactly what the policy says
  (4b4983d) because the policy itself can no longer say this.
- **Composition is most-restrictive-wins except explicit grants.** Roots
  compose prefix-aware (`/work` covers `/work/sub`); env allowlists
  intersect as exact strings; proxy-vs-proxy meets intersect allowlists and
  always keep the base's harness-owned proxy address.
- **Escalation approval is bounded and single-shot.** Approval accepts only
  grants drawn from the denial's wanted diff; exactly one re-execution runs
  under the widened policy and a second consume is refused. Widening the
  session base is the caller applying approved grants explicitly — never
  silently, and never by this package.
- **One helper runs one execution at a time**; a second `exec_start` gets a
  `busy` error. Concurrency lives in the pool by running more helpers,
  which keeps "the pgroup" in the cancel contract unambiguous.
- **The cancel ladder's rungs have different addressees, and the grace is
  real on both sides of the jail.** `cancel` is `TERM` → 2 s grace →
  `KILL`, but `TERM` is addressed to the payload and everything it
  spawned, found by descent from the jail's supervisor, and spares that
  supervisor and bwrap's PID-namespace init; only `KILL` takes the whole
  pgroup. Signalling the group at the TERM rung kills the bwrap
  supervisor, and `--die-with-parent` then SIGKILLs the namespace and
  everything in it — which collapsed the grace to under a millisecond and
  delivered a SIGKILL to a payload nothing had asked to stop.
  `cancel_grace_ms` (3 s) must still exceed the helper's 2 s ladder. The
  reach of the TERM rung is **complete under bwrap and best-effort
  without it**: the PID namespace is what makes the descendant walk
  exhaustive, and in degraded mode a payload that calls `setsid(2)` is
  out of reach until the KILL rung's group sweep. See
  `packages/sandbox/internal/jail/cancel.go`.
- **A truncated execution is not a `Completed` one, and only the helper
  can say so.** `ExecResult.cancelled` (protocol-change/006) reports that
  the helper stopped the execution rather than watching it end. Nothing
  else in the result carries that: a cancelled run whose payload had
  backgrounded its work reported `code: 0, signal: 0` — a clean success
  for a forcibly truncated run, in 3 of 3 measured runs — and `code: 143`
  is what `sh -c 'exit 143'` reports with no cancel at all, so it is a
  byte three causes share rather than evidence of a TERM (#53). A test
  that asserts the *property* asserts `cancelled`; the exit status is a
  detail of the payload under test.
- **Read `ExecResult.code`, not `ExecResult.signal`, for how a payload
  ended.** The helper waits on its direct child. Unjailed that is the
  payload, so a TERM-killed payload reports `signal: 15, code: 143`.
  Jailed it is the bwrap supervisor, which outlives the payload and relays
  a signalled payload by exiting 128+signal itself: `signal: 0, code:
  143`. `signal` therefore distinguishes jailed from unjailed rather than
  signalled from not, and a test that asserts `signal != 0` after a cancel
  is asserting "no jail was engaged". `code` means the same thing in both
  environments, and unlike `signal != 0` it also separates the TERM rung
  (143) from the KILL rung (137).
- **The fd-3 policy file is unlinked on every reachable path.** Erlang
  ports cannot map arbitrary descriptors, so the policy is written
  mode-0600 inside a mode-0700 directory and the helper is spawned through
  `/bin/sh -c 'exec 3<"$2" "$1"'`. Unlinking happens in-actor (hello,
  channel death, `Shutdown`), in `spawn_helper`'s failure branches, and via
  a janitor process that monitors the helper actor for deaths the actor
  never sees. Only an unclean VM death leaks the file — a disk-space leak,
  never a disclosure, since the directory is mode-0700. The per-exec
  `exec_start.policy` remains authoritative; fd 3 only seeds the helper.
- **Helper failure of any kind settles in-band** as an `ExecFailure` — a
  refusal, a channel death, degraded enforcement, cancel escalation — never
  a crash of the caller.
- **`FullEnforcement` demands presence, not the absence of complaints.**
  It refuses degraded helpers at dispatch from `hello.features` *and*
  fails executions whose `exec_exit` falls short in any of three ways:
  the `degraded` bool, any `skip:` entry in the structured `enforcement`
  list, **or a layer the policy called for that the list never mentions**.
  The third is the one that was missing. "No `skip:` entries" is a test a
  *silent* helper passes: a stage 2 that died before writing fd 4
  produced `enforcement: ["bwrap"]`, which contains no skip and therefore
  satisfied the demand with the whole inner report absent (#54).
  `required_layers` derives the demanded set from the policy —
  `bwrap`, `mounts`, `landlock` and `no-new-privs` unconditionally, plus
  `seccomp-net` under a network-off or proxy policy, `cgroup-v2` under a
  memory or pid ceiling, and `rlimit-cpu` / `rlimit-fsize` under theirs —
  and `unapplied_layers` names what is missing. An entry's layer is its
  tag up to the first `:` or `=`, so `landlock:abi=5` and
  `mounts:ro=2,rw=1,…` answer for their layers. With no per-exec policy
  the execution runs under the helper's fd-3 base, whose conditional
  layers this actor cannot see, so only the unconditional four are
  required.
- **`--allow-unenforced` is for an unsupported platform, never a degraded
  one.** A Linux host missing bwrap or Landlock still enforces something
  and reports what it could not; that report is what `FullEnforcement`
  exists to act on, and passing the flag there would replace a decision
  with a silence. A build with no jail at all is a different thing, and
  `unenforced_helper_args` is the only place that difference is decided.

## Deep Docs

- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  the one door, the wire, the jail, enforced versus reported.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-G (`broker`)":
  fd-3 delivery, port ownership, `step_id` typing, `cap_result` shape,
  nil-vs-empty arrays, degraded refusal, grant bounds, the deferred MCP
  adapter.
- [packages/sandbox/CLAUDE.md](../sandbox/CLAUDE.md) — the other end of the
  wire.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
