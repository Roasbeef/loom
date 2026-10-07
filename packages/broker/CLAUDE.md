# broker

## Exact command offers

`command.CommandOffer` is an opaque bounded proposal beneath the complete
`core/command.CommandRef`. Its ordered `RegionMapping` list uses closed
Workspace, Toolchain, Build, Artifact, Channel and Scratch purposes with
exact absolute roots. `CommandData` retains argv, environment, cwd and every
`policy.SandboxPolicy` field. An offer grants no authority. The owner still
has to derive its closed compile or launch expectation from retained service
input, trusted enrollment and independently admitted resources before
clearance. This codec performs no enrollment, resource preparation or launch.

`command.offer` caps argv at 128, environment pairs at 64 and every other
list at 128. Writable, readable, mount and scratch access paths also share a
128-path bound. It checks counts by bounded prefix traversal and string
bytes before converting policy trees, then counts exact canonical encoded
bytes and nodes before encoding. It refuses duplicate environment names,
duplicate mappings, NULs, noncanonical absolute paths and invalid complete
policies without rewriting any data. Path validation is lexical; trusted
executor provisioning still owns filesystem canonicalization.

`command.decode` applies `core/bounded_msgpack.decode` before term decoding:
256 KiB total, 2,048 nodes, depth 16, 128 array elements/map entries, 8 KiB
strings and 128 KiB binaries. Policy is an embedded MessagePack value decoded
through `policy.from_msgpack` and validated through the same constructor.
The complete reference occupies a canonical core JSON string bounded to
8 KiB; its JSON parser and closed identity decoder validate that header
separately. The outer node count treats the header as one string.
Re-encoding must reproduce the entire original frame, including the header,
so alternate encodings and trailing data are refused. These are logical data
bounds, not a resident-memory claim. SHA-256 remains at existing owner and
executor boundaries over the returned canonical bytes.

## Dispatch origin

`dispatch.Dispatch.context` carries `CallContext(operation, step, origin)` from
the actual cleared call. `clear_call_from` supplies an opaque remote child
origin; ordinary `clear_call` supplies `None`. Congestion retries preserve the
origin. It binds the original tool or named system invocation to its durable
physical child request, including derived build steps and detached jobs.
Provenance grants no authority and does not change pooled budget accounting.

A remote adapter requires that origin before reserving its stable request ID.
Sequence numbers, PIDs, tokens and connection generations cannot reconstruct
it. Internal local step names remain unchanged; the remote boundary validates
them with `core/workspace.step`. Protocol 067 records the interface additions.


`clear_system_call_from` derives the origin from an opaque `SystemReservationRef`
and threads that same value through internal `Dispatch.system_reservation`.
Ordinary Dispatch construction supplies `None`; `CallSpec` stays unchanged.
Only known outstanding-budget-cap refusals retry this system call, preserving
its original deadline and exact reference. There is no new Broker instance.

The ref contains the original typed owner subject, fresh BEAM reference, direct
system origin and UUID. It has no durable codec. `ReserveSystem` carries the
actual cleared command projection and full native envelope; `CancelSystem`
closes that exact original ref. `SystemCommandDeclaration` captures the original
owner, operation, step, ordered argv/env, cwd and absolute deadline. These
messages use the existing bounded internal call primitive; they grant no
history-derived execution permission.


## Remote native admission

`executor.dispatcher_with_native_deadline` checks that the unchanged native
wall policy fits the remaining admitted deadline after helper checkout.
`exec.run_before` carries that same clock and deadline into the helper actor,
which checks again when it consumes the queued request. A delayed request
cannot receive a fresh wall allowance. Finite admission requires a positive
wall limit; session admission requires an explicit zero-wall policy.

An expired checkout returns its idle helper without starting a relay. Expiry
at the helper actor sends no native start frame and settles through the
existing relay. The relay still owns cancellation at the aggregate deadline;
cleanup grace and proof of native retirement remain separate obligations.
These checks do not promise hard real-time execution across BEAM suspension
or native port delivery. The ordinary local dispatcher retains its existing
aggregate-deadline behavior.

`exec.RemoteOutcomeUncertain` names an exchange without definitive remote
outcome evidence. Callers reconcile the retained identity rather than retrying
under a new one. It proves neither non-execution nor native retirement.

## Purpose

The ToolBroker: the single door between the harness and the outside world.
It composes sandbox policy, refuses or narrows what it cannot enforce,
reserves pooled budget, mints a capability token, hands the cleared call
to a dispatcher that borrows a `loom-exec` helper from the pool and runs
the jailed execution, streams its output, and settles. It also owns the broker side of the frozen effect-plane wire
protocol (spec Part 1.4). WP-G.

## Key Types

- `broker/broker.Broker` — opaque actor handle. `clear_call` is the whole
  story; `stdin`, `cancel`, `abort(op_id)`, `abort_step(op_id, step_id:)`
  and `stop` round it out.
- `broker/broker.{CallSpec, CallHandle, CallEvent, CallOutcome, Refusal}` —
  the request, its handle, the streamed `CallOutput` / `CallSettled`
  events, and `CallExited(result)` versus `CallFailed(failure)`.
- `broker/dispatch.{Dispatcher, Dispatch, Execution, ExecutionId,
  StartRefusal, Terminal, Chunk, Eof}` — the seam between the broker and
  whatever owns a helper while a call runs. The broker decides whether a
  call may run (policy, budget, token, abort epochs); a `Dispatcher` is a
  record holding one function, `start`, that carries the cleared call out.
  `Dispatch` is what the broker hands over: the request, the wall
  deadline and clock, the caller's pid, a `seq` for the identity, and two
  closures the broker built — `deliver` for each output chunk and `settle`
  for the one terminal verdict, called exactly once per started execution.
  `start` answers with an `Execution` or a `StartRefusal` (`NoHelper(error)`
  maps to exactly what a failed checkout always did; `NotStarted` is
  `BrokerUnavailable`). An `Execution` is `{id, guarantor, cancel, stdin,
  release, abandon}`: closures are the broker's only way to reach the
  helper, and the broker holds no `Helper`. `guarantor` is the process
  whose unsettled death means `settle` never runs; the broker monitors it.
  On `Settle` it demonitors and calls `release` (return what was lent); on
  an unsettled guarantor death it calls `abandon` (stop the execution and
  return what was lent). Exactly one of the two runs, because only the
  `Settle` path demonitors. `ExecutionId` is
  opaque, `{incarnation, seq}`. `broker.start_dispatching(entropy:, clock:,
  dispatcher:)` takes any dispatcher. `broker.start(config)` is the same
  over an executor service it starts itself on the `checkout` and `checkin`
  seams of a `BrokerConfig` (no custody query and no pool to close), for the
  callers that hold a pool and no session: the tests of every package that
  runs a tool and the M3 demo. `broker/direct`, the per-call relay the broker
  once carried inline, was deleted with the lane comparison that kept it (issue
  #696 follow-up): production, the tests and the demo run one execution model.
- `broker/execution.{Core, step, Event, Effect, Mode, Output, Truncation}` —
  the pure core of one execution's relay, and the only place its decisions
  live. `step(core, event) -> #(core, effects)` takes one of eight events
  (`ExecOutput`, `ExecExited`, `ExecFailed`, `CancelRequested`, `CallerDown`,
  `HelperDown`, `DeadlineReached`, `GraceExpired`) and answers effects
  (`Deliver`, `SendCancel`, `EnterDraining`, `Settle`). It imports no
  process library, so `execution_test` runs 600 seeded random sequences
  against it. `Core.settled` is absorbing: after `Settle` every event
  answers `[]`, which is what makes at-most-one settlement a property of
  the function. `CancelRequested` is the broker's cancel, which the service
  has already forwarded to the helper, so the core records it, sends
  nothing and does not enter `Draining`. `HelperDown` settles
  `Failed(ExecutionLost(HelperActorDown))` in either mode. The module doc
  carries the checked `Mode` transition table.
- `broker/relay.{start, Config, Link, Permission, Relay}` — the per-execution
  `weft/state_machine` shell around `execution.step`. State is
  `execution.Mode` and carries nothing (rule 1 of `docs/weft.md`);
  `Streaming`'s state timeout is the wall deadline that remains when the
  relay starts (none for `deadline_ms: 0`) and `Draining`'s is
  `dispatch.relay_grace_ms`. Its message type is `execution.Event`: the
  `exec_events` subject (owned by the relay, created in its initialiser, so
  `start` returns the subject only once the relay listens), the caller's
  monitor, the helper actor's monitor and the service's control subject all
  select into it. Effects: `Deliver` calls the dispatch's closure,
  `SendCancel` calls `Link.cancel` (a bounded ask, `relay.cancel_wait_ms`, that
  returns once the service has sent the cancel), `EnterDraining` transitions, and
  `Settle` asks `Link.may_settle(Verdict)` first, the verdict carrying the final
  `Progress` (mode, output counters, cancel state). A third closure,
  `Link.progress`, is a cast sent on a change of mode or cancel state, on the
  first chunk and on every `relay.progress_chunks` (16) chunks after, never per
  chunk. The relay never imports the service and never casts to a helper: all
  three ways back are closures the service builds. Unlinked from its starter.
- `broker/census.{Census, Skew, service_version, local, skew}` — the pure
  version census: `service` (the `Dispatcher` contract's own version, a
  constant here), `exec_proto` (`framing.exec_protocol_version`), `policy_v`
  (`policy.version`) and the hello `features`. `skew(ours, theirs)` names
  every mismatched version and ignores features, which are capability and
  are reported, never refused. No process, no FFI.
- `broker/executor.{start, dispatcher, pid, snapshot, census, close,
  ExecutorConfig}` — the service's one process per session, a
  `weft/state_machine` with phases `Serving | Closing(closer) |
  Closed(outcome)` (the pool's shape, with a state timeout in `Closing` for
  the drain budget). `ExecutorConfig` is closures over the pool
  (`checkout`, `checkin`, `custody`, `close_helpers`) plus an `incarnation`
  and a `log` (`telemetry/log.Logger`; `log.discard()` for a service nobody
  observes).
  `dispatcher(service)` is the `Dispatcher` `broker.start_dispatching`
  takes. State is a `Dict(seq, Row)` with a row only while the service holds
  a helper for it, so it is bounded by the pool. A `Row` is `Live` or
  `Granted(closure)` and keeps the helper, the relay (pid, events, control
  subject), the service's monitor on the relay, the broker's `settle` closure,
  and only what an observer reads of the request (enforcement demand, deadline,
  session clock, start times, the relay's last `Progress`). Argv, environment,
  working directory, policy and token are never kept after dispatch.
  `snapshot` answers an `executor_view.Snapshot` (below). The service
  answers an `executor_view.Observation` (its own rows and books, no pool);
  the caller reads the pool's custody from a closure the `Executor` handle
  keeps and joins the two with `executor_view.completed`, so a slow pool
  holds the observer and no settlement. The halves are not one instant. The
  census does the same with `QueryPhase`.
- `broker/executor_view.{Snapshot, LiveView, Settled, Failure, Metrics,
  LatencySummary, Outcome, Books, ring_size}` — the operator surface, pure.
  `Snapshot` is the incarnation and phase, the live rows (at most the pool
  size), the pool's `PoolCustody`, `Metrics`, `recent` (the last
  `ring_size` = 64 settlements, newest first) and `last_failure`. `Outcome`
  is `Completed(code)`, `Failed(kind)` (the constructor name only) or
  `Lost(cause)`. `Metrics` is counters (starts, settlements by class,
  refusals split `all_busy | pool_unavailable | spawn_failed | not_started`,
  output bytes, truncated) and p50/p95/max over the last 64 samples of launch
  latency (time inside `start`), execution latency (start to settlement) and
  cancel-to-settle. No type here can hold argv, environment, working
  directory, policy, token or output bytes; `executor_snapshot_test` plants a
  marker in a request and searches the rendered snapshot and the log lines.
  "Queue age" has no referent: nothing queues, so `all_busy` counts the
  congested refusals instead.
  `census(service, waiting:)` answers a `broker/census.Census`: when the
  pool has heard a hello, the features are the newest helper's, read from
  `pool_custody` (`HelperView.features`); it borrows and spawns nothing.
  Empty features mean unknown: no helper has said hello yet, the pool did
  not answer, or the service is closing.
- `broker/dispatch.relay_grace_ms` — the drain grace of a relay's `Draining`
  mode, kept in the seam module so the relay and the tests name one figure.
- `broker/policy.SandboxPolicy` — `SandboxPolicyV1` as a typed value:
  writable/readable/protected roots, `NetworkPolicy`, `Limits`,
  `env_allow`, `Scratch`, and `mounts`. `compose` implements session base ⊕
  tool requirements ⊕ escalation grants; `narrow_unenforceable` fails
  closed.
- `broker/policy.{session_lease, LeaseOutput}` — the base a session-lived
  jailed process clears under: `wall_s` and `cpu_s` zeroed on the *base*
  (a zero requirement against a non-zero base is a narrowing
  `RefuseNarrowed` refuses), and a finite 64 MiB per-stream output allowance
  for `OutputIsWire`. An extension host's stdout is a log and keeps its cap; a
  language server's stdout is its JSON-RPC wire (ADR-015). The lease's
  real bound is the pooled budget deadline the relay enforces.
- `broker/policy.{Mount, MountAccess, MountRequirement}` — one explicit
  bind of a host path into the jail, at policy version 2
  (`protocol-change/004`). `MountRequired` asks the helper to refuse an
  execution whose source path is missing rather than run a jail the caller
  believes has it.
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
  `HelperStatus.StatusBusy` (handshake done, an execution in flight:
  `Running` or `Cancelling`) is not ready: `helper_ready` lends only on
  `StatusReady`, so a helper checked in mid-execution (a relay crash)
  is retired rather than re-lent, at the cost of one lazy respawn.
  `ExecResult.cancelled` says the helper truncated the run;
  `ExecResult.enforcement` is the ground truth `required_layers` and
  `unapplied_layers` check the policy's demands against.
- `broker/exec.ExecFailure.ExecutionLost(cause: LossCause)` with
  `LossCause = HelperActorDown | RelayDown | ExecutorClosing` — the one
  failure that says the execution **may have started** and its outcome is
  unknown. It must never be read as "nothing ran" and must never be
  replayed automatically; `broker.denial_for_failure` answers `None` for it
  (an approval would invite the replay) and `tools/tool.exec_failure_text`
  says plainly that the command may have run.
- `broker/exec.{pool_census, PoolCensus}` — the pool actor's own count of
  its inventory by custody (`available`, `borrowed`, `draining`, `retiring`,
  `unconfirmed`, beside the configured `size`, and the lifetime churn
  counters `spawned` and `retired`), answered in every `PoolPhase` and never
  postponed. A gone pool is `PoolUnavailable`.
- `broker/exec.{pool_custody, PoolCustody, HelperView, Lending, Custody}` —
  the census and one view per inventoried helper from the same instant: pid,
  spawn `ordinal` (introspection, not a fence), the hello `features` the
  pool received at the handshake (empty = unknown), `Lendable | Lent |
  Withdrawn`, and custody `Held | Retiring | Retired | CleanupUnconfirmed(
  reason) | ProofLost`, derived from the pool's books without asking a
  helper. `NoNativeResource` is not a pool-level state (the pool begins a
  helper as it inventories it) and the native exit status behind `Retired`
  is not kept; both are named in the type's doc.
- `broker/exec.{close, close_pool, RetirementFailure}` separates shutdown
  requests from retirement proof. `Ok(Nil)` requires a selected native exit
  status followed by the original normal BEAM monitor event: status 0 after
  a shutdown, or any status after a kill or an unasked death that left no
  live jail (`Exposure`), or one that did on a helper whose hello advertised
  `bwrap` (see "A kill keeps its witness" below). A timeout, lost port,
  nonzero status after a shutdown, live-jail death without bwrap, or dead
  owner remains unconfirmed. A parked owner can also confirm that
  it never acquired a native transport; that result still requires normal
  BEAM retirement.
- `broker/exec.{prepare, prepare_helper, begin}` stages acquisition. The
  prepared helper owns no transport or policy file. A pool records its
  handle and original monitor before `begin`, then waits the configured
  handshake budget plus 1 second. The daemon's native factory is
  `prepare_helper`, so failed handshakes remain in the pool inventory.
  Weft's parent-exit policy also stops the owner when its preparer returns
  normally, including before `begin`. This lifetime bound is not native
  retirement proof; callers that lose the owner retain an unconfirmed result.
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
  its pure incremental deframer. `Body` additionally carries the one pair
  that flows the *other* way, harness → satellite and back
  (`protocol-change/012`): `HookCall(token, kind, name, args, deadline_ms)`
  asks a session-lived extension satellite to answer one invocation, and
  `HookResult(outcome)` is its answer, correlated by the frame `id`.
  `HookResult` mirrors `cap_result` minus `usage` — an invocation reserves
  no budget of its own, because everything it spends it spends through the
  `cap_call`s it makes under the invocation's token — and both share
  `outcome_entries`/`decode_outcome_error` with `cap_result` so the two
  result kinds cannot drift into two spellings of one shape.
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
  `weft/state_machine`, for the two state timeouts below), `telemetry` (a
  leaf over `core`: the executor service writes its settlement and close
  lines through an injected `Logger`, and nothing else in the package logs).
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
    `SendStdin(handle, data, eof: dispatch.Eof)`, `CancelCall(handle)`,
    `AbortOp(op_id)`, `AbortStep(op_id, step_id)`, `Settle(call_id)`,
    `GuarantorDown(down)`, `QueryRelay(handle, reply)` (answers the
    execution's guarantor, which is the relay),
    `QueryEpochs(reply)`, `StopBroker`. The last two are `@internal`
    observability, reached only by `relay_pid` and `abort_epoch_count`.
    `Settle` is sent by a call's `settle` closure, from the dispatcher's
    settling process, immediately before the caller's `CallSettled`; the
    broker handles it by calling the execution's `release`.
  - `executor.Msg` — `Start(request, reply)` (a synchronous call from the
    dispatcher's `start`, budget 22 000 ms = checkout's 15 000, the relay's
    1 000 to start, run's 5 000 and 1 000 of slack, as `start_budget_ms`
    sums them), `Cancel(id)`, `CancelAsk(id, reply)` (the relay's own cancel,
    answered after `exec.cancel` was sent), `Stdin(id, data, eof)`,
    `MaySettle(id, verdict, reply)`, `Progress(id, progress)` (a relay's cast;
    never answered), `Release(id)`, `Abandon(id)`, `RelayDown(down)`,
    `Observe(reply)`, `QueryPhase(reply)`, `Close(draining, helpers, reply)`,
    `DrainDeadline`. The `Execution` closures the
    broker holds are casts of `Cancel`, `Stdin`, `Release` and `Abandon`
    naming the execution by `ExecutionId`. `MaySettle` is the relay's
    bounded call (`relay.settle_wait_ms`). Every phase and message pair is
    written; the messages that mean the same in every phase bind the phase
    to a name, so a new message is still a compile error.
  - `relay` messages are `execution.Event`: the helper's `exec.ExecEvent`
    mapped by `from_exec`, `CallerDown`, `HelperDown`, `CancelRequested`
    (from the service) and the two state timeouts.
  - `exec.Msg` (per helper) — `AwaitReady(reply)`, `QueryStatus(reply)`,
    `Run(request, events, reply)`, `Stdin(data, eof)`, `CancelExec`,
    `CancelDeadline`, `HandshakeDeadline`, `HeartbeatTick`,
    `Heartbeat(reply)`, `Shutdown`, `AwaitRetirement(reply)`,
    `ForgetRetired`, `FromWire(event)`. The helper is a
    `weft/state_machine`, not a `gleam/otp/actor`: its state is
    `exec.Phase` — `Prepared | AwaitingHello | Idle(features) | Running(features,
    exec) | Cancelling(features, exec) | Dead(failure, retirement)` — and everything
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
  - `exec.PoolMsg` includes checkout/checkin, stop, retirement queries,
    helper retirement reports, and original helper monitors. The pool is a
    Weft state machine with `PoolLive`, `PoolClosing`, and
    `PoolFinished(outcome)` phases. Its single inventory retains idle,
    borrowed, draining, and unconfirmed helpers. A late checkout reply
    still leaves the helper in that inventory. Retirement queries are
    postponed while draining and replayed when the outcome is available.
  - Outbound to callers: `broker.CallEvent` (`CallOutput`, `CallSettled`)
    and `exec.ExecEvent` (`Output`, `Exited`, `Failed`).
- **Commits / registers**: none. The broker persists nothing; durability of
  escalation events is the runtime's job — it records each `escalation.Event`
  before acting on it.
- **Wire** — `frame := u32_be length ++ msgpack(map)` with keys
  `"v":1, "id":u64, "kind":str, "body":map`. Kinds: `hello`, `exec_start`,
  `exec_stdin`, `exec_out`, `exec_exit`, `cap_call`, `cap_result`,
  `hook_call`, `hook_result`, `cancel`, `shutdown`, `heartbeat`, `error`.
  `shutdown` carries an empty map after hello, only on the exec channel
  (`protocol-change/014-helper-shutdown-witness.md`). The helper sends no
  acknowledgement: it cancels and joins its jail, then exits. The BEAM
  drains stdout and retains the port until `exit_status`.
  `envelope_version` (the `v` key) is 1; `exec_protocol_version` (the
  `hello.proto` value) is 4; `max_frame_bytes` is 16 MiB. **A
  `protocol-change` that adds, removes, or makes-required a key on a
  frame the exec helper sends or receives — or adds a kind to that
  channel — bumps `exec_protocol_version` and the Go
  `framing.ExecProtocolVersion` in the same commit** (the addendum to
  `protocol-change/006` is the ruling; the constants' doc comments carry
  the mapping, and `protocol_version_test` reads the Go source so the two
  literals cannot drift). The envelope version stays fixed while the
  container's shape does, which is what lets a stale helper's `hello`
  still decode and the failure name both numbers. The base policy
  additionally travels on fd 3 at spawn (see below). **`hook_call` and
  `hook_result` never cross the exec channel**: they belong to the
  capability socket between the harness and a persistent satellite, so the
  Go helper neither sends nor parses them, and `broker/exec` marks a helper
  that sends either one dead with a `ProtocolViolation` naming the kind —
  exactly as it does for a helper that sends a `cap_call`.

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
  `checkout` seam synchronously inside its own message handler (through the
  dispatcher's `start`) and a helper only returns to the pool when the
  broker releases a settled execution or abandons an unsettled one, so a broker (or a
  queueing pool it blocks on) would be waiting for a resource that only
  its own message loop can release. Nothing is held across the wait —
  the checkout-failure path releases the budget slot and revokes the
  token before answering — so progress depends only on running
  executions ending, which their wall deadlines guarantee. `AllBusy(size:
  0)` is not congestion and never waits: `size` counts the entries that
  can still return to lending, so zero means a pool that lends nothing or
  one whose every slot is held by an unconfirmed retirement, and neither
  has anything to check back in.
- **Executor service: the service is the helper's only sender.** Every `Run`,
  `Stdin` and `CancelExec` an execution causes is sent by `broker/executor`.
  The relay asks for a cancel (`Link.cancel` is a bounded call of
  `CancelAsk(id)`, answered after the service sent the helper its cancel); it
  never casts to the helper. Erlang orders one sender's messages to one
  receiver, so a cancel sent for an execution reaches the helper before any
  `Run` the service sends for the next execution on it, and `exec.run` is
  sent before `start` replies so stdin (sent after the reply) follows its
  `Run`. The other half of the fence is the row: a message for an execution
  whose row is gone or `Granted` is dropped. There is no generation counter
  and none is needed while those two hold. A real relay never produces a
  stale cancel, because the absorbing core never cancels after settling, so no
  test of the real path could fail if the fence went. `cancel_fence_test`
  makes one by hand: a helper runs an execution that ends by itself, is
  returned and runs a second that sleeps, and then the first execution's
  relay link (`executor.relay_link`, `@internal`) is asked to cancel, late.
  Through the service's link the second execution is untouched; through a
  link whose cancel is `exec.cancel(helper)` (the control) it is cancelled.
  Sending directly from `link_over` fails the first test (recorded in the
  commit). The limit that remains is the test's own premise: the stale cancel
  is injected, not produced by a relay, and the helper is a fake, so it shows
  what the row and the single sender prevent and not that a scheduler delay
  can happen.
- **Executor service: settled exactly once through `MaySettle`.** The relay may
  report only after the service answers `Granted`, which it does once, for a
  `Live` row, and which turns the row `Granted`; any other ask is
  `AlreadySettled` and the relay stays silent. The service settles a row
  itself when it is `Live` and the relay died (its own monitor) or the
  service is closing (`ExecutorClosing`), and on the broker's `Abandon`
  whatever the row's status (`RelayDown`; whichever of monitor and
  `Abandon` arrives first wins, the other finds no row). The status does
  not decide the `Abandon` case because of send order: `broker.settle_to`
  sends the broker `Settle` before anything else and a process's messages
  reach the broker before its own death notice, so a relay that ran
  `settle` at all is seen as settled and never abandoned; `Abandon` proves
  the relay sent nothing and the caller has heard nothing. The service's own
  monitor firing on a `Granted` row has no such proof (the relay may have
  reported), so it neither settles nor cancels and waits for the broker's
  `Release` (it saw the settlement) or `Abandon` (it did not).
  A service that is gone or silent cannot forbid a report, so the relay
  reports anyway (`ServiceSilent`); a dead service settles nothing, and a
  live one answers late into a row it has by then either granted or
  removed. The caller therefore always hears a settlement in this lane,
  including when the relay dies. The helper is checked in by `Release`,
  which the broker casts while processing the relay's `Settle`.
- **Executor service: the relay's cancel starts its grace when the cancel was
  sent (issue #696, F4).** A relay cancels for its own reasons (caller gone,
  wall deadline) and its `Draining` grace is `dispatch.relay_grace_ms`. A
  cast would start that clock while the cancel sat unread behind a service
  blocked in a `start` (a checkout waiting on the pool), so the relay could
  report `CancelEscalated` for a helper never told. `Link.cancel` is
  therefore `call.try_call(CancelAsk, relay.cancel_wait_ms)`: the service
  replies after `exec.cancel`, and the relay enters `Draining` only after
  the reply. On no reply (service wedged or dead) it drains anyway, because
  the grace is then the only bound on the relay, and a service that wakes
  later still forwards the cancel in its mailbox. No call cycle: the service
  never waits on a relay. Pinned by `executor_test`'s
  `a_relays_own_cancel_starts_its_grace_when_the_cancel_is_sent`; reverting
  the closure to a cast makes it settle `CancelEscalated`.
- **Executor service: closing is a transition.** `executor.close(draining:,
  helpers:)` refuses new starts with `NoHelper(PoolUnavailable)`
  (deliberately not `AllBusy`, so callers stop polling), cancels every live
  row, waits `draining` (`executor.drain_ms`, 2 000) for live rows to be
  granted, settles the rest `ExecutionLost(ExecutorClosing)` (relay killed,
  helper checked in busy so the pool retires it), then returns
  `close_helpers(helpers)`. The pool keeps its whole budget
  (`executor.helpers_ms`, 5 000, what `close_pool` is given when called
  alone) however long the drain took (F5); an earlier single `waiting` split
  in half left the pool 2.5-5 s and made `RetirementPending` likelier at
  shutdown. The call blocks at most
  `draining + helpers + 1 000` (8 s with the constants), the figure a
  teardown step that funds it should assume. `instance_owner`'s cleanup
  steps have no overall deadline (its `close(within_ms)` bounds only the
  waiting caller and answers `StillClosing`), so 8 s fits; serve's custody
  hook and `close_instance` both pass the constants. `Ok` ends
  the service; an `Error` keeps it alive in `Closed(outcome)` answering the
  same verdict, because custody that could not be shown retired is not
  dropped by exiting. A helper's `Release` never comes once the broker has
  stopped, which custody does first, so `Granted` rows do not delay a close.
  Close is not a double-close hazard in the session wiring (F6): the owned
  path closes only through the custody `Helpers` step, the ownerless path
  only through `close_instance`, never both. A second `close` answers the
  stored verdict while the service is alive (`Closed(Error)`, or postponed
  during `Closing`). The stored verdict is frozen: `close` never re-asks the
  pool, so a retirement that finished after an `Error` cannot improve it, and
  a caller retrying custody goes to `exec.close_pool` directly. After a clean close the service is gone
  and it answers `RetirementOwnerGone`, as `close_pool` does after a clean `close_pool`.
  Worst-case blocking of `close_instance`: 8 s (`close` above), pinned in
  `executor_test`.
- **Executor service: seeded interleavings hold the same invariants.**
  `executor_property_test` draws plans from `support/seeded` (the generator
  `machine` and `execution_test` use): a pool size and a list of steps
  (starts of four kinds, broker and caller cancels, caller death, helper
  crash, pause, a close mid-run), performed in order by a driver against a
  real broker over fake helpers. Every plan keeps: each live caller hears
  exactly one settlement and no trailing events; the inventory drains and every
  relay dies; with the service open nothing is borrowed and held slots are
  bounded by the faults; a quiet plan (no crash, no cancel-ignoring start)
  closes `Ok`; a second `close` replays the stored verdict. A seed reproduces
  the plan, printed whole in every failure, and not the schedule.
  `LOOM_EXECUTOR_PROPERTY_SEEDS` (default 12) and
  `LOOM_EXECUTOR_PROPERTY_ONLY=<seed>` size and replay a run;
  `leak_census_test` takes `LOOM_LEAK_CENSUS_SEEDS` and
  `LOOM_LEAK_CENSUS_ONLY`. Mutation checks recorded in the commit: releasing a
  row without checking its helper in, replaying a recomputed instead of the
  stored close verdict, and leaving a released row on the books each fail it.
  `fake_helper.ByArgv` gained `flood` (two hundred chunks, then runs until
  cancelled) for it.
- **Executor service: the failure matrix is pinned, case by case.**
  `test/broker/failure_matrix_test.gleam` runs each fault through a real
  broker over fake helpers and asserts one settlement (or one refusal), the
  right outcome, a balanced pool census and an empty inventory. A helper
  actor killed mid-run settles `ExecutionLost(HelperActorDown)` at once (pool
  slot left `unconfirmed`, since a killed actor cannot attest to its jail),
  with no deadline needed to notice. A dead caller
  hears nothing, so those cases assert the books balance and the next call
  runs. `close` during output delivers the real exit when the helper honours
  cancel and `ExecutionLost(ExecutorClosing)` when it does not, never both,
  and a row already `Granted` is never turned into a loss by a later close.
  **A service killed mid-run** (unlinked first, as custody does): a broker
  cancel is a cast to a dead process and is lost; the wall deadline's
  relay cancel cannot reach the helper, so the relay reports
  `CancelEscalated` after its grace and nobody reports `Completed`; the
  helper stays borrowed in the pool and is never lent again; new calls are
  `BrokerUnavailable`; `executor.close` answers `RetirementOwnerGone` and
  `exec.close_pool` answers for itself. `test/broker/leak_census_test.gleam`
  runs a hundred mixed endings (success, cancel, caller death, helper crash,
  escalation) and checks pool census, inventory, relay liveness, the VM
  process count and one settlement per hearing caller.
- **Executor service: the snapshot is bounded, true and carries no request.**
  (Issue #696, S3.) Live rows are at most the pool size; the `recent` ring
  and each latency series are trimmed to `executor_view.ring_size` (64) on
  every push, so nothing grows with the session. A row's mode, cancel state
  and output counters are the relay's last cast `Progress`, thinned to the
  first chunk and every 16th, with exact totals arriving in the verdict the
  relay asks to report; the service never waits on a relay to answer a
  snapshot (a relay can be blocked asking the service). A settlement is
  recorded once, where a row's life ends: at `Release` for a granted row, at
  `lose_row` for a loss (including an abandoned granted row, which the caller
  hears as lost), and at close for a granted row that will never be released.
  A `Live` row released (the silent-service case) is not recorded: the
  service never learned its verdict. Each recording writes one
  `executor.settled` line (Info for a completion, Warning otherwise, fields:
  `execution` and `incarnation` as `Ident`, outcome class and detail, cancel
  cause, counts of duration, bytes and chunks) and the close writes
  `executor.closed`. Latencies are measured on weft's monotonic clock, never
  the session clock, which tests fix. **Not built:** cancellation to
  *native exit* of a helper. The pool records only the retirement verdict,
  and carrying a duration through `AwaitRetirement`, `HelperRetired` and the
  pool entry is more than a small change; cancel-to-settle covers the
  execution's cancel and `PoolCensus.retired` and `unconfirmed` cover helper
  churn. There is no operator verb: every daemon command rides the
  authenticated control protocol, so `executor.snapshot` plus the log lines
  are the surface, and `docs/architecture/executor.md` says what
  protocol-change/062 would have to carry. Pinned in `executor_snapshot_test`
  (rows, thinning, the 64 bound, last failure, refusal counts, and a marker
  planted in argv, environment, working directory and token that must not
  appear in any snapshot or line).
- **Executor service: a slow consumer is bounded by the helper, not the BEAM.**
  The relay's delivery is a send; nothing waits on the caller's mailbox and
  there is no BEAM-side buffer or backpressure (a ruled cut). What bounds
  the backlog is the helper's per-stream `output_bytes` cap. The real-helper
  test `a_caller_that_stops_reading_cannot_slow_a_cancel` runs `yes` at a
  1 MiB cap with a caller that reads nothing for 2 s: the mailbox received
  exactly 1 MiB in 34 events and the cancel settled in 3 ms. Production
  caps: `policy.workspace_default` sets 4 MiB (`policy.gleam`), hooks and
  goal checks 1 MiB, and a protocol wire lease 64 MiB per stream. The
  `a_wire_lease_bounds_a_nonreading_consumer` regression exercises that actual
  lease allowance with a flooding producer and unread consumer. LSP treats
  truncated stdout as a fatal stream and cancels it. This lifetime quota
  bounds payload reaching the final mailbox; it is not flow control.
  `twenty_sequential_runs_on_one_real_helper_see_no_busy_window` pins that
  back-to-back runs on a pool of one never meet `HelperBusy` in this lane.
- **Executor service: an orphaned `start` costs a slot and cannot wedge.** The
  broker spends a call id on every start attempt, answered `Ok` or refused
  (`Dispatch.seq` promises a number is never offered twice), so a service
  that overruns its start budget (`checkout 15 s + relay init 1 s + run 5 s
  + 1 s slack`, summed from named constants in `start_budget_ms`) and
  goes on to hold a row the broker never received leaves one orphan and
  nothing else: the next call has a new number, the orphan's late
  settlement names a call the broker no longer has and is ignored, and its
  helper stays held until the service closes or S2's late-`Run` fence stops
  such a run being dispatched. The service still refuses a `start` whose
  sequence number is in its table. Through the broker that is unreachable;
  it guards other callers of the dispatcher against overwriting a live row.
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
- **An unresponsive helper retains capacity until retirement is proved.**
  The readiness probe returns `StatusUnresponsive` without faulting the
  pool. The pool stops lending that helper and requests shutdown once.
  It releases the slot only after a native exit that counts (status 0
  after a shutdown, or the exit of a killed or dead helper that left no
  live jail, or whose live jail was bwrap's) and normal BEAM exit; an unconfirmed helper stays in the inventory and is never probed
  again.
- **A kill keeps its witness.** Every failure that finds a helper's port
  open (cancel escalation, handshake deadline, heartbeat miss, framing
  fault, protocol violation or version mismatch, an unencodable frame)
  sends SIGKILL to the port's OS pid and **retains the port**, leaving the
  machine `Dead(failure, PendingExit(AfterKill(exposure)))`. Erlang delivers
  `{exit_status, 137}` to the owner of a port whose child was signalled,
  and only while the port is open, so closing the port first (which this
  once did) threw the proof away and cost the pool a slot for good. The
  port's pid is the helper itself because the fd-3 shell `exec`s it. The
  exit then becomes `NativeExit(status, awaited)`, and `native_verdict`
  alone decides what it proves. After a shutdown only status 0 does. After
  a kill, or an exit nobody asked for (`Unprompted`), it depends on the
  `Exposure` of the phase the helper died in: `NoJail` (`AwaitingHello`:
  the helper writes hello before reading, and no `exec_start` precedes
  `Idle`) and `SettledJail` (`Idle`: `Settle` killed the last jail before
  the `exec_exit` that made the helper idle) retire on **every platform**;
  `LiveJail` (`Running`, `Cancelling`) retires only when the accepted
  hello advertised `bwrap`, because `--die-with-parent` and `--unshare-pid`
  make the helper's death the jail's. A live jail without bwrap (degraded
  Linux, where a payload can `setsid` away; Darwin, whose descendant
  tracker lives inside the killed helper) stays
  `Unconfirmed(RetirementExit(status))`. That last rule is weaker than the
  status-0 witness (the payload may run a couple of wakeups past the
  verdict; the per-exec cgroup directory is not removed); see the addendum
  to protocol-change/014. A write that fails is the one case where the port
  is already closed, but its status may not be lost: a port delivers
  `{exit_status, S}` and then closes, so a helper that died on its own
  and then met a write has its status queued in the actor's mailbox
  behind the failure. `mark_gone` (and `handle_shutdown`'s send-failure
  arm) therefore wait as well, `Dead(failure, PendingExit(Unprompted(
  exposure)))` with nothing to kill, and the same `kill_witness_ms`
  timeout turns a status that never comes into `LostExit`. `Unprompted`
  and not `AfterShutdown` for the shutdown arm, because a shutdown frame
  that was never delivered cannot have been acknowledged by a join. A fake
  `ChannelTransport` cannot fail a write, so
  `real_helper_failed_write_keeps_a_queued_status_test` suspends the actor
  with `sys:suspend`, queues a request, kills a real helper and resumes,
  and `real_helper_failed_write_loses_the_proof_test` closes a real
  helper's port from outside (no status ever comes) and sees `LostExit`
  after the witness window. The pool's existing path frees the slot with no
  change: `retire_entry` parks the dead helper's `AwaitRetirement`, the
  status replays it, `record_retirement` marks `RetiringActor`, and
  `ForgetRetired` stops the actor on the same `Ok` verdict. Nothing waits
  for ever: callers' own deadlines bound `close` and `close_pool`, which
  answer `RetirementPending` with custody intact. The settlement of the
  execution itself is unchanged (`CancelEscalated` and so on) and the dead
  helper keeps the failure it died with after its exit arrives.
  `hello_features` lives in `Data` for the verdict's sake; the phases that
  carry features are gone by then.
- **A `Run` the caller gave up on is fenced, not withdrawn.** `run` uses
  `try_call`, so a timed-out caller leaves its `Run` queued, and
  `HelperUnresponsive` therefore does **not** mean "nothing was
  dispatched". `handle_run` refuses with `NotReady` any `Run` whose
  `events` subject has no living owner (`subject_owner` and `is_alive`, no
  clock), which is the case that matters: the broker's relay dies with its
  call. A caller that is alive but gave up is not caught and must treat the
  outcome as unknown.
- **`exec_stdin` frames carry ids of their own, never the execution's.**
  The helper answers a refused stdin write (`stdin already closed`, or the
  payload's end of the pipe gone) with `error{no_exec}` under the *stdin
  frame's* id, and uses a stdin id for nothing else. `settle` treats an
  error under the execution's own id as that execution's refusal, so a
  stdin frame sent with `exec.id` made a refused write settle a running
  payload `Failed(RefusedByHelper)` and send the machine `Idle` while the
  helper still ran it: the real `exec_exit` was dropped and the next `Run`
  got a Go `busy`. A fresh id from `fresh_id` makes the error correlate to
  nothing. `cancel` cannot hit the same trap: the helper never answers a
  `cancel` with an error. This changes an id value, not the frame's shape,
  kind, keys or version.
- **Pool close includes borrowed helpers.** `close_pool` stops admissions
  before requesting each helper's shutdown. Native proof is recorded
  before `ForgetRetired` asks the helper actor to stop. The original
  monitor must then report normal exit before the inventory entry is
  removed. The caller's timeout only bounds its wait; it does not discard
  the port, stop the pool, or erase unresolved entries. The final pool
  reply is followed by a normal pool monitor event before `Ok(Nil)`.
  This proof covers the helper's existing jail cleanup, not arbitrary
  detached descendants on Darwin or remote effects.
- **No exchange on the clearance path may fault where a refusal is
  owed.** The broker calls the dispatcher's `start`, which borrows a
  helper and dispatches to it synchronously inside the broker's own
  message handler, so a
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
  wholesale on `abort`, and reclaimed when a call's guarantor process
  dies unsettled (every guarantor is monitored; it is the relay). Releases are generation-checked, so
  a stale settlement from before an abort never frees a later ledger's
  budget.
- **Tokens are single-use and unforgeable.** 32 bytes of injected entropy,
  bound to `{op_id, step_id, policy, deadline}`, transmitted only over the
  channel they authorize, revoked at settlement. `abort` revokes every
  token of an operation and kills the OS process group through the helper's
  cancel ladder; `abort_step` does the same for one `{op_id, step_id}` and
  leaves the operation's other steps alone. Presented bytes are compared in constant time and the
  check scans every entry without early exit, so a match's position leaks
  nothing either.
- **A sweep reaches exactly one scope, and the caller chooses which.**
  `abort(op_id)` empties an operation; `abort_step(op_id, step_id:)`
  empties one step of it — its tokens, its actives, its ledger — and
  nothing else. Both exist because two different callers own two
  different things. An *operator* aborting a strand means the operation,
  jobs it started included. A code-mode teardown owns only its own step:
  it reaps its satellite on every execution, the successful ones
  included, and a background job started by the program clears under the
  sibling step `{op_id, "job/" <> id}` and is meant to outlive it. Using
  the operation there cancelled the job the instant the program returned
  (ADR-005's third addendum).
- **A clearance cannot resume across a sweep.** Neither kind of abort is
  a verdict that an operation is over — a strand goes on clearing calls
  under the same key afterwards, and blanket-refusing an aborted
  operation would brick every strand after its first `code_mode`. What
  must not survive is a clearance that *began before* a sweep and
  finished after it: since `clear_call` waits out a congested pool, a
  retry could otherwise compose a fresh policy, open a fresh ledger, mint
  a token the sweep never saw, and start the one jailed execution it
  could not reach. So the broker counts sweeps per operation *and* per
  `{op_id, step_id}`; a clearance is judged against the sum of the two,
  a retry states the sum it last saw, and a mismatch is
  `OperationAborted`. A first attempt carries no count and is judged on
  its own merits. The sum is a faithful composite because both counters
  only ever increase, and the step needs a counter of its own because a
  step sweep that bumped the operation's would refuse a resumed
  clearance of every sibling step — including the job it just spared.
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
  makes retention affordable is the growth law, which is the same for
  both tables: one entry per key *ever swept*, not one per sweep — repeat
  sweeps upsert the counter, so code mode's teardown, the one routine
  caller, costs one step entry per `{op_id, step_id}` that ran a program
  at all. At ~110 bytes an entry, in a
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
- **Mounts intersect by exact path, and no grant adds one.** A mount is one
  bind rather than a subtree, so composition matches paths exactly and never
  by prefix; an entry survives only when both sides name it, at the weaker
  of the two accesses and the stronger of the two requirements. There is no
  `GrantMount`, so `wanted_grants` returns nothing for a `NarrowedMount` and
  the list it returns can be shorter than the list it was given. That is the
  point: a grant reaches the approval path, where #243 has not settled which
  principal a prompt goes to under a shared daemon, and a session's
  filesystem reach is decided before it starts. `protocol-change/004` has
  the argument.
- **A mount overlapping a protected entry is refused, and so is a repeated
  or uncanonical mount path.** `validate` runs on the *composed* policy, so
  it is the one place that sees a base carrying a mount and a requirement
  carrying a protected entry over the same region. Both directions of the
  overlap are refused (`MountOverlapsProtected`), because neither platform
  can carry out both: on Linux the mount lands on the read-only tmpfs the
  mask installed and bubblewrap exits 1 saying only `Read-only file
  system`, and on Darwin the trailing deny wins, so the same document
  meant different things on the two platforms. `DuplicateMount`,
  `MountPathTrailingSlash` and `MountPathParentSegment` refuse the three
  spellings of one region named twice; `meet_mounts` finds a path's entry
  exactly because of them, and the Go emitters carry no tie-break. The
  helper's decoder makes the same refusals at the wire
  (`policy.checkMounts`).
- **A read-only mount at or above a writable root is refused**
  (`MountShadowsWritableRoot`, `protocol-change/057`). Every explicit
  mount is emitted after every grant, so on Linux the read-only bind
  lands on the writable one and the root comes out read-only — and a
  mount of `/` binds the host's `/proc` and `/dev` back over the fresh
  ones — while on Darwin the allow rules union and the root stays
  writable. Only that direction: a read-only mount *under* a writable
  root, and a read-write mount above one, stay valid. Because `validate`
  runs on the composed policy, it also refuses a grant of a writable
  root under a region the base mounts read-only, which used to be
  granted and then silently unwritable. The helper's decoder refuses the
  same pair in the same words, and `jail.AuditMounts` reports it as a
  `skip:mounts:` if it ever gets past both.
- **The policy wire is version 2 on both sides.** The `mounts` field could
  not be added compatibly, because both decoders refuse unknown keys and
  refuse any `v` but their own, so the two halves of `protocol-change/004`
  had to move together: a v2 harness against a v1 helper fails at the
  handshake with `policy: unknown keys [mounts]`. Both halves have landed
  and the three `sandbox_policy_*` fixtures decode on both sides.
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
  a crash of the caller. `ProtocolVersionMismatch(helper:, broker:)` is
  the handshake's own: it carries both version numbers so the rendering
  can say which build is behind, and it is distinct from
  `ProtocolViolation` because nothing was violated — the peer spoke its
  protocol correctly and it was the wrong one.
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

**The enforcement tag vocabulary is pinned by a test, not generated.**
`test/broker/enforcement_tags_test` reads the non-test Go in
`../sandbox/internal/jail` and asserts that every tag `broker/exec` names
occurs there as a quoted literal. The set is collected by calling
`required_layers_for` over both platforms with a maximal policy, plus a
short hand-listed remainder (`degraded`, `darwin-process-lifecycle`), so a
tag the matrix starts requiring is pinned without being added anywhere.
It also pins `exec.skip_prefix` (`"skip:"`, the one constant every `skip:`
check in `exec` uses) and the `landlock:abi=` form. It proves a spelling
exists in Go, not per-platform emission; the fixture and real-helper tests
prove that. ADR-018 records why this beat a shared generated file.

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

## Explicit session-lifetime background jobs

Protocol-change/058 records the lifetime contract. Finite jobs retain their
existing default and fixed deadline. Bash `mode: "background", lifetime:
"session"` and `cap/job.start_for_session` explicitly request no wall deadline.
Code-mode callers declare `permissions.wall_s: 0`; the launching action must
receive the missing wall grant before execution, and the job captures it.
Zero job wall/deadline denotes this authorized lifetime. Clearance and drain
remain bounded, other resource limits remain active, and session shutdown,
owner kill or originating-operation abort cancels the execution. Quiet waiting
has no completion or heartbeat wake unless the caller explicitly asks for the
existing idle heartbeat. A VM restart loses the job and never replays it.

## Exact command enrollment

`broker/enrollment` is pure configuration and metadata. Plain `NativeFacts`
uses the existing `core/workspace.Scope`; `CodeModeFacts` names the workspace,
build/channel areas, executables, seed, toolchain roots, host mounts and PATH.
The opaque `SessionEnrollment` constructor bounds every list and string before
building an encoded tree, validates the full sandbox policy and refuses
allocation regions overlapping ordinary workspace writable authority. Broad
native working roots can still cover those regions. Seed, toolchain and PATH
regions have no overlapping writable root, scratch or read-write mount; code-mode
host mounts must be exact read-only entries of the native ceiling.

`matches` compares every original field, even when Scope and supplied digest
claims agree. Registration and contract claims use `core/command.digest` and
require trusted authentication and pinning; this module computes no digest.
Concrete source/prelude/seed association remains a physical-assembly obligation.
`encode` nests the complete `policy.to_msgpack` value. `decode` uses the fixed
`core/bounded_msgpack` raw preflight, reconstructs through the smart constructor,
and refuses noncanonical bytes. Bounds are 16 working/toolchain roots and
mounts, 32 policy path entries per list, 64 environment names, 4-KiB paths,
8-KiB PATH and 192-KiB aggregate text within the existing metadata frame.

`compile_path` and `launch_paths` require the original ServiceKey's exact Scope,
registration/contract claims and closed role. The original canonical UUID is
the sole dynamic component; launch uses fixed `s` and `cap-token` basenames and
checks the 100-byte socket budget. These are lexical locations, not leases or
permission to create them. Trusted executor assembly still owes filesystem
canonicalization, durable allocation custody and exact owner-call narrowing.

## Raw terminal envelopes

`framing.decode_raw_envelope` returns an opaque `RawEnvelope` after checking the
original header through the same validator used by ordinary `decode_payload`.
`raw_kind` selects the owning body decoder; `raw_body` returns the original
encoded bytes. The scan substitutes an empty map only in the temporary header
used for validation. No caller may treat that placeholder as the original body.

This boundary lets the foreground satellite host apply terminal report budgets
before allocating the outcome tree. It preserves the existing transport header
semantics, including arbitrary field order and nonminimal encodings. Body
semantics remain the caller's obligation. Ordinary capability frames retain
their existing typed decoder.

## Exact original Launch helper retirement

`exec.prepare_borrowed_retirement(pool, helper, completed)` registers one original
Borrowed inventory entry before dispatch. Its opaque `BorrowedRetirement` carries
the same pool, helper and registration door into `exec.retire_borrowed`. Missing,
foreign, stale and duplicate registration refuses; a lost registration reply
withdraws the original borrow without dispatch or checkin. The completion
callback runs only after the existing positive native boundary and the original
helper owner's normal monitor exit. Abnormal exit retains uncertainty.

`executor.start_with_retirement(config, seam)` supplies this additive seam without
changing `ExecutorConfig`. `dispatcher_retiring_with_native_deadline` selects it
for validated Launch; ordinary and Compile dispatch retain reuse. A retiring
executor Row keeps its exact helper, relay and original caller monitor through
Release, Abandon, relay loss and caller death. It cannot return that helper to
Available between settlement and retirement. Pool scope closure preserves the
same observer and proof grade.

The native protocol is unchanged. Each Launch retires one helper and therefore
pays for one helper restart. This adds no stronger descendant-containment or
cgroup guarantee. See [exact-helper retirement](../../docs/architecture/launch-native-retirement.md).


## Credited helper foundation

Protocol 078's encoding uses body protocol four, envelope one, and negotiated
`protocol-credit-v1`. `framing.ProtocolMode` fixes `ServerProtocol` versus
`FiniteCollected`; named `InputEnd`, `OutputDisposition`, `InputRefusal` and
`ProtocolDisposition` types decode their closed wire vocabulary. Input binds
original execution id, ordinal and frame id. Output has one shared ordinal
credit and retains the ordinary cumulative per-stream `bytes` semantics.
Ordinary frame content and `ExecEvent` remain unchanged. Credited terminal
reports add `protocol` to `exec_exit` through opaque `ProtocolTerminal`.

`exec.run_protocol` reserves one original id without effects, then submits Run
under its unchanged native clock/deadline. It returns opaque
`ProtocolExecution` or `ProtocolRunFailure`: explicit `ProtocolRunRefused`, or
`ProtocolRunUnknown(original, failure)` after a possibly-started reply was
lost. Reservation never substitutes a new id after uncertainty. Exact
`protocol_execution_id` exposes that immutable wire id for retained command
association. Input submission returns no native acceptance witness;
`ProtocolInputAccepted` arrives separately after queue admission.

`ProtocolEvent` is separate from ordinary output journals: exact input
acceptance/refusal, consumed output offers, native/protocol terminal, delivered
reusable witness, and protocol failure. `protocol_output_consumed` returns
credit only after final bounded admission. `Finishing` remains `StatusBusy`
after terminal and after delivered `ProtocolReusable`. Only explicit
`protocol_reusable_consumed` on that original finite handle enters Idle.
`defer_protocol_checkin` retains one immutable original callback; a conflicting
second association refuses. Wrong/missing/late witnesses cannot invoke it, and
ServerProtocol cannot use this finite transition.

A direct helper owner may consume finite reuse before registering checkin.
Admission of an ordinary successor clears that completed protocol association;
the original late checkin callback then refuses instead of attaching to new work.

The executor installs two trusted constructors:
`dispatcher_collected_with_native_deadline` and
`dispatcher_protocol_retiring_with_native_deadline`. The second requires the
existing installed `RetirementSeam` and pre-dispatch exact borrowed retirement.
No cleared request carries a peer role selector. `ProtocolDispatch` preserves
seq, cleared request, original clock/deadline, consumed event subject and local
custodian. `start_protocol` returns an opaque exact execution or
`ProtocolStartFailure`: `ProtocolNotStarted`,
`ProtocolStartUnknown(original, failure)`, or `ProtocolStartReplyLost` requiring
reconciliation at its original retained command address.

Protocol feed, consumed output/reuse, cancel and release are serialized through
the executor owner. Each control compares both its table slot and original
opaque helper execution, so late controls cannot affect a successor. Finite
release defers the original checkin until consumed reuse. Server release uses
`exec.retire_borrowed` and retains the row until the exact original retirement
callback. Custodian death cancels that original execution; pool closure still
joins all borrowed helpers. Unknown start retains the original row and borrow
rather than interpreting timeout as definite absence.

Dedicated controls hold the original owner Down after native exit, and a real
helper test crosses the production port/codec/pool to exact joined retirement.

The next dependency wave must install the validated ServerLeaseClaim and real
bounded consumed transport, commit/read back terminal and matching reusable
under the original native/command association before consuming the witness,
and retain exact retirement separately. This foundation supplies no owner
checkout fallback and does not establish registered LSP end-to-end acceptance.

## Registered ServerProtocol elapsed authority

`exec.protocol_native_wall_fits` checks both scoped pre-dispatch and the actual
original helper Run. A ServerProtocol Session keeps its owner-cleared zero CPU
and wall policy. Zero wall requires a nonzero original elapsed deadline with
positive remaining time no greater than twelve hours; it never rewrites policy
or derives a fresh deadline. Positive ServerProtocol wall policies retain their
existing maximum of twelve hours and enough original remaining time. Finite
collection still requires positive wall time no greater than sixty seconds.
Ordinary `native_wall_fits` behavior remains unchanged. Output, network,
enforcement demand, original token and exact retirement checks still apply.
The helper frame has no clock authority, so the broker owns the elapsed check.

## Original collected pool return

`executor.start_registered_protocol_pool` derives its unchanged legacy config
and targeted retirement seam from one privately retained original `exec.Pool`.
Only its finite collected branch installs the new local return registration.
`exec.reserve_protocol` retains the helper's actual opaque reservation before
`prepare_collected_return` registers one immutable observer on the exact borrowed
pool entry. `run_reserved_protocol` then submits that original reservation.
Ordinary `run_protocol` composes the same reserve and Run steps in their existing
order. Legacy executor constructors and the frozen `ExecutorConfig` are unchanged.

A pool entry holds either targeted retirement or collected return custody.
Registration verifies the complete Helper and its currently reserved helper id;
foreign, duplicate and incompatible registrations refuse. Lost registration
reply withdraws the same proposed registration through existing pool retirement.
Definite Run refusal withdraws the installed original; unknown Run and owner loss
retain its borrow. Legacy checkin of an observed borrow withdraws it instead of
making it lendable. Retirement failure remains charged by the existing pool.

`executor.release_collected` installs one final original receiver before requesting
`exec.defer_collected_return`. The actual helper reducer runs its callback only
after the exact finite reusable witness is consumed. That callback sends one
original return request; uncertainty never retries it. The pool compares the
retained registration, checks original Borrowed custody and helper readiness,
and emits opaque `exec.CollectedReturnProof` from its actual Available transition.
An old registration cannot return a successor borrow. Server protocols remain on
the distinct targeted retirement path and cannot yield this proof.

The native executor retains its `ProtocolRow` until that exact ACK is verified.
`executor.CollectedReturnProof` also binds the original executor subject, sequence
and helper execution. `verify_collected_return` compares those originals without
asking pool census or inferring success from a Nil release, deleted row or current
availability. Completed proof remains historical evidence if the helper is later
borrowed. Explicit close still joins actual original pool retirement separately.
The receiver and pool entry are bounded existing custody, without a waiter list,
a replacement lookup, a lifecycle actor or a new dependency.

The synthetic controls use actual pool, executor and helper reducers while their
wire peer supplies native events. The held-ACK control suspends the original
helper and executor with existing OTP system controls, resumes both before every
assertion, and distinguishes the actual pool transition from native ACK handling.
The separate real-helper control requires this checkout's normal helper build;
it exercises both release/consumption orders, actual output and empty EOF,
waitDone/reusable, historical original proof and another command on that same
helper. This broker boundary does not assemble Service finite collection, owner
clearance, Prepare readiness or the complete registered LSP runtime.
