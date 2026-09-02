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
- `broker/exec.{default_pool_size, pool_size_for, min_pool_size,
  max_pool_size}` — the default helper-pool ceiling and the pure
  derivation behind it (schedulers online, clamped).
- `broker/internal/call.{try_call, CallFault}` — `process.call` without
  the panic: `NoReply` on a timeout, `CalleeGone` on a dead or ownerless
  callee. Every exchange on the clearance path now goes through it (the
  congestion loop, the pool checkout, and the four helper-actor calls);
  what is left on `process.call` is the two `@internal` test accessors,
  whose callers do want the crash.
- `broker/exec.{Helper, Pool, ExecRequest, ExecResult, ExecFailure,
  EnforcementDemand, Transport}` — the helper state machine, the pool,
  and the transport seam (`PortTransport` real, `ChannelTransport` for
  tests).
  Three of those types carry a variant for a peer that answered
  nothing: `CheckoutError.PoolUnavailable`,
  `ExecFailure.HelperUnresponsive`, and `HelperStatus.StatusUnresponsive`
  — separate facts from `AllBusy`, `ChannelClosed` and `StatusDead`,
  which are things a live peer said.
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
- `broker/egress.{Policy, Request, Response, Refusal, Method, Redirects,
  Trust, Secret}` — the broker's outbound HTTP surface. `request(policy,
  request, secrets:)` performs one HTTPS request on the host under caps
  the caller cannot widen; `one_host` is the install-fetch policy
  (ADR-007); `describe` renders a refusal. `Secret` binds an environment
  variable *name* to one header and one origin, and the value is read
  through the injected `secrets` function at request time.

## Relationships

- **Depends on**: `core` (msgpack for the wire, ids for `OpId`,
  corruption), `gleam_erlang` + `gleam_otp` (the broker and pool are
  actors; ports carry the helper channel), `weft` (the helper is a
  `weft/state_machine`, for the two state timeouts below).
- **Depended on by**: `tools` (every jailed tool clears through
  `clear_call`), `conformance` (wiring and the jailed e2e).
- **FFI**: `broker/internal/ffi_crypto` — `crypto:strong_rand_bytes` and
  `crypto:hash_equals` for token entropy and constant-time comparison.
  `broker/internal/ffi_os` — `os:type/0` for the host platform and
  `erlang:system_info(schedulers_online)` for the default pool size.
  `broker/internal/ffi_port` — port open/send/close, OS pid lookup and
  kill, and private-file writes for fd-3 policy delivery.
  `broker/internal/ffi_egress` — one HTTPS hop over `httpc` on the
  broker-private `loom_egress` profile, plus the monotonic clock the
  egress deadline is measured against. All are backed by
  `broker_ffi.erl`; the rest of the package takes them as injected
  function values, so pure logic stays testable with deterministic
  substitutes.
- **Counterpart**: `packages/sandbox` (Go) speaks the other end of
  `broker/framing`.

## Traffic

- **Actor messages**
  - `broker.Msg` — `ClearCall(spec, events, reply)`,
    `SendStdin(handle, data, eof)`, `CancelCall(handle)`, `AbortOp(op_id)`,
    `Settle(call_id)`, `RelayDown(down)`, `QueryRelay(handle, reply)`,
    `QueryEpochs(reply)`, `StopBroker`. The last two are `@internal`
    observability, reached only by `relay_pid` and `abort_epoch_count`.
  - `exec.Msg` (per helper) — `AwaitReady(reply)`, `QueryStatus(reply)`,
    `Run(request, events, reply)`, `Stdin(data, eof)`, `CancelExec`,
    `CancelDeadline`, `HandshakeDeadline`, `HeartbeatTick`,
    `Heartbeat(reply)`, `Shutdown`, `FromWire(event)`. The helper is a
    `weft/state_machine`, not a `gleam/otp/actor`: its state is
    `exec.Phase` — `AwaitingHello | Idle(features) | Running(features,
    exec) | Cancelling(features, exec) | Dead(failure)` — and everything
    else the process carries is `exec.Data`. `handle` is one exhaustive
    `case phase, message` matrix; `entered` is where each state's
    deadline is armed.
    Two of those messages are delivered by **state timeouts** rather than
    by anyone: `HandshakeDeadline` is armed on entering `AwaitingHello`
    and `CancelDeadline` on entering `Cancelling`, and each is cancelled
    by the move out of the state that armed it. That is why
    `CancelDeadline` carries no execution id and neither handler
    re-checks whether it is still relevant — reaching `Idle` or `Dead`
    *is* the cancellation, and a fire that raced the move is dropped by
    weft's timer book. `HeartbeatTick` is the third kind, a **periodic
    timeout**: it fires every `heartbeat_interval_ms` regardless of
    activity, which is what a liveness probe means and what neither a
    state timeout (dies with its state) nor an event timeout (measures
    quiet, so a chatty helper is never probed) says. It is armed in
    `entered` on the way out of `AwaitingHello` and only there — arming
    on every entry to `Idle` would make a helper that settles executions
    faster than the interval push its own probe out for ever — and
    cancelled on the way into `Dead`. That is why the `AwaitingHello,
    HeartbeatTick` and `Dead(..), HeartbeatTick` arms are unreachable by
    construction: a tick in flight at either boundary carries a stale
    generation stamp and dies in the timer book. An interval of `0`
    disables the probe, so nothing is armed at all.
    An `AwaitReady` asked during `AwaitingHello` is parked with weft's
    `postpone` rather than a hand-rolled list: the `AwaitingHello,
    AwaitReady` arm answers `keep(data) |> postpone`, and weft replays
    the event, in arrival order, exactly once, on the next change of
    state — the hello's move to `Idle` or a death's move to `Dead` —
    where the ordinary `Idle`/`Running`/`Cancelling` and `Dead` arms
    answer it with that state's outcome. No queue is threaded through
    `Data`, and no settle site has to remember to flush one.
    A state's payload is immutable for the life of that state. A state
    timeout dies only on a move to a state that compares *unequal*, so
    per-frame bookkeeping (the deframer, the id counter,
    `tick_outstanding`) lives in `Data` — putting any of it in `Phase`
    would have an ordinary inbound chunk restart the cancel escalation.
  - `exec.PoolMsg` — `Checkout(reply)`, `Checkin(helper)`, `StopPool`.
    `Checkout` answers immediately, `AllBusy` included: it never defers a
    reply, because its one run-time borrower is the broker actor. It can
    still answer *late* — spawning runs in the pool actor — and a
    borrower that gave up by then leaves that helper counted as lent
    with nobody to check it in. Bounded by the pool's size; see the
    checkout invariant below.
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
  pair is the *batch* identity the broker pools on, and it holds one
  `budget.Ledger` per live pair. The execution identity is
  `{op_id, step_id, source_index}` — two programs in one batch share the
  ledger and take separate paths, deliberately (ADR-005's addendum). The first clearance opens the ledger;
  later clearances reserve against the stored budget, which their own
  budget field cannot widen. This closes the amplification hole: 10,000
  polite parallel reads share one `max_outstanding` cap and one aggregate
  wall deadline — which a per-call cap could not do, since 10,000
  *separate* calls each within its own cap sails straight through it.
  `docs/adr/005-budget-pooling-granularity.md` records this against the
  concrete case that put it in question (`grep`'s `Concurrent` tag
  contradicting a `bash`-sized `max_outstanding: 1`, issue #50): the
  keying stays `{op_id, step_id}`, the fix was the tool's own declared
  budget. Read it before threading a new identity through this key or
  stacking a further cap on top of it (issue #23). The one caller that has
  threaded an identity through it, `codemode`, preserves the keying: its
  `codemode/identity.ExecIdentity` is opaque, derives the build and run
  phases rather than letting a caller assemble them, and answers
  `ledger_keys` — one key per execution, or two where the hermetic build
  is deliberately accounted separately, never one per call (issue #22).
  That same value now also carries the grants an approved escalation
  attributed to the execution, and deliberately without touching this
  key: a widening buys a wider policy at `compose`, never a second ledger
  with a second `max_outstanding` and a second wall deadline (issue #24).
  The `CallSpec.grants` a code-mode clearance passes come off the *run*
  phase, so the hermetic build's clearance is structurally unwidenable —
  which matters here because `compose` applies grants after the meet and
  would otherwise let one overrule the build's own `network: NetworkOff`.
- **`broker/egress` is not the egress proxy `policy.narrow_unenforceable`
  fails closed on, and does not revive it.** `NetworkProxy` still becomes
  `NetworkOff` on every clearance and the jail's network namespace stays
  empty. Egress is the other shape ADR-007 chose: the harness makes the
  request and hands back the response, so no socket ever exists in the
  jail and the operator's key never leaves the host. Its own rules, each
  gated by a test in `test/broker/egress_test.gleam`: `https` only;
  origins matched exactly, case-insensitively, with `:443` and an absent
  port the same origin and any other explicit port needing an allowlist
  entry that names it; userinfo in the URL refused as malformed; the
  method, the origin and the scheme re-judged on **every** hop, because a
  redirect is a new request; a bound credential injected only for the
  origin it names; `Host`, `Content-Length`, `Transfer-Encoding`,
  `Connection` and every bound secret's header reserved to the client;
  every header — the caller's and the injected credential's alike —
  scanned before it can reach the socket for CR, LF and NUL (which would
  end it early on the wire) and for anything above latin-1 (which `httpc`
  refuses in a way that renders the *value* into the error term), over
  **code points** rather than substrings because `string.contains` works
  on grapheme clusters and CRLF is one, so a substring scan misses the
  exact sequence an injection uses; a
  redirect followed only under `SameHost(n)`, only within the origin, at
  most `n` times, with 303 becoming a bodyless `GET`; one deadline for
  connect, every hop and the body; TLS always `verify_peer` with
  hostname verification and no path to `verify_none`, in tests included —
  the suite runs a real loopback TLS origin whose chain is generated by
  `public_key:pkix_test_data/1` and pins its root. Neither HTTP
  connections nor TLS sessions are reused, and the second matters more
  than the first: `ssl`'s client session cache is node-global and keyed
  on host and port alone, and a resumed TLS 1.2 handshake carries no
  certificate, so without `reuse_sessions: false` a session established
  by another policy — or by the provider's client, which shares the node
  — would carry a request past the roots it was held to. The test for it
  runs against a TLS 1.2 origin on purpose: 1.3 resumes through tickets,
  which OTP's client has off by default, so a 1.3 origin would make the
  test pass whatever the client did. Two limits are honest
  rather than hidden: `httpc` streams only 200 and 206, so on any other
  status the size cap is a check after receipt rather than a brake (a
  declared `Content-Length` over the cap is still refused first), and a
  streamed response reports 200 unless it carries `Content-Range`,
  because `httpc`'s stream messages carry no status line.
- **A full pool is congestion, and the wait for one happens in the
  borrower's process.** `clear_call` retries a `NoHelper(AllBusy(..))`
  clearance within the caller's own `waiting` budget instead of handing
  it back, so a tool batch wider than the pool queues rather than
  failing. The wait cannot move inside the broker: the broker calls its
  `checkout` seam synchronously inside its own message handler and only
  reaches `checkin` from `Settle` / `RelayDown`, so a broker (or a
  queueing pool it blocks on) would be waiting for a resource that only
  its own message loop can release. Nothing is held across the wait —
  the checkout-failure path releases the budget slot and revokes the
  token before answering — so progress depends only on running
  executions ending, which their wall deadlines guarantee. `AllBusy(size:
  0)` is not congestion and never waits: a pool that lends nothing has
  nothing to check back in.
- **Every waiter leaves within its own budget *and with a verdict*.**
  The second half is not free. The loop reserves `min_retry_window_ms`
  of the caller's budget for its last attempt rather than issuing
  exchanges with a nap's worth of window left, because the broker is
  serial and a clearance it grants blocks it for a relay handshake, a
  helper handshake and a checkout seam. And the exchange is
  `internal/call.try_call`, not `process.call`: the latter panics on a
  timeout and on a dead callee, and the caller is a strand effect
  process whose death becomes a synthetic zero-usage abort in place of
  the in-band refusal the model can act on. A broker slower than the
  caller's whole budget, or one stopped underneath a parked waiter,
  answers `BrokerUnavailable`.
- **A helper the pool cannot get an answer out of is retired, not
  fatal.** `helper_ready` probes an idle helper before lending it, from
  inside the pool actor — so a probe that faulted on a timeout would take
  the pool down, and the broker with it, since the broker borrows through
  a call of its own. That is what makes the cost accounting true: one
  timeout per wedged helper, paid once, because the helper is shut down
  and never probed again. The probe used to be a private `try_call`
  because the public `exec.status` panicked; `status` now answers
  `StatusUnresponsive` instead, so there is one probe and
  `helper_ready` is the policy on its answer — only a helper that says
  it is ready gets lent.
- **No exchange on the clearance path may fault where a refusal is
  owed.** The broker calls its checkout seam and dispatches to the
  borrowed helper synchronously inside its own message handler, so a
  pool that stopped, or a helper that died in the microseconds between
  the borrow and the dispatch, was the broker's death rather than one
  call's refusal — and a broker's death is every in-flight strand's
  verdict, each settling as a synthetic zero-usage abort instead of an
  error the model can route around. `checkout` answers
  `PoolUnavailable`; `run`, `await_ready` and `heartbeat` answer
  `HelperUnresponsive`; a dispatch refusal still settles in band as the
  call's one `CallSettled`. `PoolUnavailable` is deliberately not
  `AllBusy`: `congested` waits out a full pool and refuses an
  unanswering one at once, because napping on a pool that says nothing
  spends the caller's whole clearance budget to reach the same answer.
  The cost of not crashing is a late `Ok(helper)` sent to a subject
  nobody is selecting on, leaving that helper counted as lent — bounded
  by the pool's size, requiring a pool that blocked past a whole window
  and then recovered, and strictly better than a dead broker, which
  strands the same helpers and loses everything else besides.
- **The pool size is a resource budget, not a policy dial.** Every
  helper is an OS process running bwrap and a jail.
  `exec.pool_size_for` clamps the node's scheduler count to `[4, 16]`
  and `client/serve` lets `LOOM_HELPER_POOL` override it; the pool is
  the ceiling on real parallelism, while the pooled `max_outstanding`
  below is the anti-amplification cap. They answer different questions
  and neither substitutes for the other.
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
- **A clearance cannot resume across an abort.** `abort` is a *scoped*
  cancel, not a verdict that an operation is over: code mode runs its
  satellite under the strand's own `{op_id, step_id}` precisely so
  `abort` reaches it, and calls it on every teardown including the
  successful one — so a strand goes on clearing calls under the same key
  afterwards, and blanket-refusing an aborted operation would brick every
  strand after its first `code_mode`. What must not survive is a
  clearance that *began before* the sweep and finished after it: since
  `clear_call` waits out a congested pool, a retry could otherwise
  compose a fresh policy, open a fresh ledger, mint a token `revoke_all`
  never saw, and start the one jailed execution the abort could not
  reach. So the broker counts aborts per operation, a retry states the
  epoch it last saw, and a mismatch is `OperationAborted`. A first
  attempt carries no epoch and is judged on its own merits.
- **That epoch table is never pruned, and the bound is measured rather
  than mechanised** (issue #104). A missing key reads as epoch 0, which
  is exactly what a waiter that started before any abort of its
  operation holds — so dropping an entry does not fail closed, it
  *admits* the retry the epoch exists to refuse, silently. (A waiter
  that started after two aborts holds `Some(2)` and takes the opposite
  spurious refusal, so pruning is unsafe in both directions at once.)
  `release_slot` may delete a ledger with nothing outstanding because
  absence and emptiness mean the same thing there; absence here means
  "never aborted", which is the one thing a pruned entry is not. What
  makes retention affordable is the growth law: one entry per operation
  *ever aborted*, not one per abort — repeat aborts upsert the counter,
  and code mode, the only production caller of `abort`, aborts the
  strand's own operation on every teardown. At ~110 bytes an entry, in a
  broker that lives exactly as long as one `loomd` process serving
  one session (its death is fatal to the server and nothing restarts
  it), ten thousand such operations cost about a megabyte beside a
  conversation store holding durable rows for every one of those turns.
  The alternative was a retention window the broker would have to take
  as configuration, whose too-short value is not a crash but a silent
  hole in the confinement above. `broker.abort_epoch_count` is
  `@internal` and exists so a test can pin that law.
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
  `/bin/sh -c 'exec 3<"$2" "$1"'`. Unlinking happens in-machine (hello,
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
  `required_layers_for_features` derives the demanded set from both the
  helper's hello and the policy. Linux requires `bwrap`, `mounts`, `landlock`
  and `no-new-privs`, plus `seccomp-net` for restricted networking and
  `cgroup-v2` for memory or pid ceilings. Darwin requires `seatbelt`,
  `seatbelt-fs`, `seatbelt-net`, and the requested rlimit tags. Both require
  `rlimit-cpu` / `rlimit-fsize` under their policies. Selecting from the
  helper's hello rather than the broker VM also keeps remote/fake backends
  honest. `unapplied_layers` names what is missing. An entry's layer is its
  tag up to the first `:` or `=`, so `landlock:abi=5` and
  `mounts:ro=2,rw=1,…` answer for their layers. With no per-exec policy
  the execution runs under the helper's fd-3 base, whose conditional layers
  this actor cannot see, so only that backend's unconditional layers are
  required. Darwin also reports `skip:darwin-process-lifecycle` on every
  execution: Seatbelt follows forks, but sampled descendant cleanup cannot
  guarantee ownership after rapid reparenting. The ordinary "any skip"
  ground-truth check therefore refuses `FullEnforcement` even when every
  requested filesystem, network, and rlimit tag is present.
- **`PlatformEnforcement` is strict about the platform's real boundary.**
  It is the production default and remains identical to `FullEnforcement`
  on Linux. On Darwin it accepts only ADR-006's
  `rlimit-address-space`, `rlimit-processes`, and
  `darwin-process-lifecycle` gaps. Each tag must still appear as applied or
  `skip:`. A degraded helper, missing Seatbelt layer, unexpected skip, or
  silent report fails the execution. `FullEnforcement` remains the explicit
  demand for Linux-equivalent containment on every platform.
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
