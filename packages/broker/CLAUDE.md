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
- **Budget is pooled per execution, not per call.** A token is valid for
  exactly one `{op_id, step_id}`, so that pair *is* the execution identity
  and the broker holds one `budget.Ledger` per live pair. The first
  clearance opens the ledger; later clearances reserve against the stored
  budget, which their own budget field cannot widen. This closes the
  amplification hole: 10,000 polite parallel reads share one
  `max_outstanding` cap and one aggregate wall deadline.
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
- **`FullEnforcement` checks ground truth, not just advertisement.** It
  refuses degraded helpers at dispatch from `hello.features` *and* fails
  executions whose `exec_exit` reports `degraded`.

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
