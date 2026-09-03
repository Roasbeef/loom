//// The ExecPool: supervised lifecycle of `loom-exec` sandbox helpers.
////
//// Each helper is one OS process speaking the Part 1.4 framing protocol
//// on stdio, running **one execution at a time** (the helper answers a
//// second `exec_start` with a `busy` error); concurrency lives here, in
//// the pool, by running more helpers. A broker-side `Helper` machine
//// owns each helper's channel: it performs the hello handshake, deframes
//// inbound bytes with the pure `broker/framing` deframer, streams
//// output events to the caller, heartbeats the helper while idle, and
//// mirrors the cancel escalation (the helper TERMs the payload and then
//// KILLs its pgroup within 2s of `cancel`; if no `exec_exit` arrives
//// within the grace period the machine kills the whole helper — belt and
//// braces). The two rungs are addressed differently under a jail, and
//// what the exit reports differs with them: see `cancel` below.
////
//// ## The helper's lifecycle is a `weft/state_machine`
////
//// `AwaitingHello → Idle → Running → Cancelling → Idle`, with `Dead` as
//// the absorbing state every failure settles into. Those five are the
//// `Phase` type — the machine's *state* — and everything else the
//// process carries is its *data*. The split is what makes both of the
//// helper's deadlines structural rather than guarded by hand: the
//// handshake window is a **state timeout** on `AwaitingHello` and the
//// cancel grace is a **state timeout** on `Cancelling`, so each dies
//// with the state that armed it. No handler re-checks whether its own
//// timer is still relevant, no settle site remembers to cancel one, and
//// no timer message carries an execution id for the sole purpose of
//// recognising a stale fire. Reaching `Idle` or `Dead` *is* the
//// cancellation.
////
//// The idle heartbeat is the third, and it is a **periodic timeout**:
//// it must fire every N ms regardless of activity, which is what a
//// liveness probe means and what neither a state timeout (dies with its
//// state) nor an event timeout (measures quiet, so a chatty helper is
//// never probed) says. It is armed on the way out of `AwaitingHello`
//// and cancelled on the way into `Dead`, so the two arms that used to
//// absorb a tick arriving in a phase with nothing to probe are now
//// unreachable rather than merely unlikely.
////
//// ## Policy delivery (the fd-3 gap)
////
//// The helper requires its base `SandboxPolicyV1` on fd 3 at spawn, but
//// Erlang ports cannot map arbitrary file descriptors. Resolution: the
//// policy is written to a mode-0600 file inside a mode-0700 directory,
//// and the helper is spawned through `/bin/sh -c 'exec 3<"$2" "$1"'`
//// so the shell opens the file as fd 3 before exec-ing the helper. The
//// file is unlinked as soon as the helper's hello arrives (proof the
//// policy was read). Recorded in `docs/spec-gaps.md` territory: the
//// per-exec `exec_start.policy` override remains the authoritative
//// policy for each execution; the fd-3 file only seeds the helper.
////
//// Unlinking is guaranteed on every reachable path: in-actor (hello,
//// channel death, `Shutdown`, which covers pool retirement),
//// `spawn_helper`'s own failure branches (unopenable port, actor start
//// failure, handshake failure), and — for deaths the actor never sees,
//// like a supervisor's brutal kill — a janitor process spawned by
//// `spawn_helper` that monitors the helper actor and deletes the file
//// when it goes down, however it went down (`watch_cleanup`; deletion
//// is idempotent, so overlapping with the in-actor unlink is
//// harmless). The one genuinely uncoverable path is the whole VM dying
//// uncleanly (SIGKILL, kernel panic): no process survives to unlink,
//// and the file leaks until the OS or the operator clears `tmp_dir` —
//// a disk-space leak only, never a disclosure, since the file sits in
//// a mode-0700 directory.
////
//// ## Transports
////
//// The channel is a seam: `PortTransport` is the real OS helper;
//// `ChannelTransport` lets tests drive the same machine with an
//// in-process fake speaking the same bytes. Helper failure of any kind
//// settles in-band as an `ExecFailure` event — never a crash of the
//// caller.

import broker/framing.{type Fault, type Frame, type OutputStream}
import broker/internal/call
import broker/internal/ffi_crypto
import broker/internal/ffi_os
import broker/internal/ffi_port
import broker/policy.{type SandboxPolicy}
import core/msgpack
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/pair
import gleam/result
import gleam/string
import weft/state_machine

/// How strictly the caller demands kernel enforcement for an execution.
pub type EnforcementDemand {
  /// Refuse degraded helpers before dispatch and refuse results whose
  /// `exec_exit` reports degraded enforcement — the ground-truth check
  /// the contract requires beyond hello features. Ground truth is the
  /// structured `enforcement` list, not just the `degraded` bool (which
  /// tracks only the bwrap layer): any `skip:` entry means a layer the
  /// policy called for was not applied, and the result is refused even
  /// when the bool stayed false.
  FullEnforcement

  /// Require every kernel boundary the selected platform promises, and
  /// refuse degraded helpers, missing mandatory layers, silent reports,
  /// and unexpected skips. On Darwin only, the three gaps ADR-006 proves
  /// the platform cannot close are accepted when they are reported
  /// explicitly: address-space rlimits, account-wide process rlimits,
  /// and descendant lifecycle containment. This is the production
  /// default: usable on macOS without turning a missing Seatbelt layer
  /// into an accepted best-effort execution.
  PlatformEnforcement

  /// Accept whatever the helper could enforce (development containers,
  /// self-tests). The enforcement report still reaches the caller.
  BestEffort
}

/// One execution request.
pub type ExecRequest {
  ExecRequest(
    /// The program and arguments. Invariant: non-empty.
    argv: List(String),
    /// The child environment (allowlist-constructed by the caller).
    env: List(#(String, String)),
    /// Working directory inside the jail.
    cwd: String,
    /// Per-exec policy override; `None` runs under the helper's fd-3
    /// base policy.
    policy: Option(SandboxPolicy),
    /// The capability token bytes clearing this execution.
    token: BitArray,
    /// Enforcement strictness for this execution.
    demand: EnforcementDemand,
  )
}

/// A completed execution, mirroring the helper's `exec_exit` report.
/// `enforcement` is ground truth for what was actually applied.
pub type ExecResult {
  ExecResult(
    code: Int,
    /// The signal that killed the process the helper waited on, or `0`.
    ///
    /// Under a jail that process is the bwrap supervisor, not the
    /// payload, and it relays a signalled payload by exiting 128+signal
    /// rather than dying of it — so a jailed exec reports `signal: 0`
    /// even when the payload was signalled. Read `code` for the
    /// cross-environment answer; see `cancel`.
    signal: Int,
    stdout_bytes: Int,
    stderr_bytes: Int,
    stdout_truncated: Bool,
    stderr_truncated: Bool,
    enforcement: List(String),
    degraded: Bool,
    wall_ms: Int,
    timed_out: Bool,
    /// The helper stopped this execution rather than the execution
    /// ending of its own accord — the broker's `cancel`, or the policy's
    /// wall-clock deadline, which climbs the same ladder (`timed_out`
    /// separates the two causes).
    ///
    /// Nothing else in this record can say it. A cancelled run whose
    /// payload had backgrounded its work reports `code: 0, signal: 0` —
    /// a clean success for an execution that was truncated — and
    /// `code: 143` is produced by `sh -c 'exit 143'` with no cancel at
    /// all, so it is a byte three different causes share rather than
    /// evidence of a TERM. Only the helper knows, and this is where it
    /// says so (protocol-change/006).
    cancelled: Bool,
  )
}

/// Events streamed to the subject a caller passes to `run`. Exactly one
/// terminal event (`Exited` or `Failed`) arrives per accepted `run`.
pub type ExecEvent {
  /// One chunk of child output; `total_bytes` is cumulative per stream.
  Output(
    stream: OutputStream,
    data: BitArray,
    total_bytes: Int,
    truncated: Bool,
  )

  /// The execution completed and passed the enforcement check.
  Exited(result: ExecResult)

  /// The execution settled as an in-band failure.
  Failed(failure: ExecFailure)
}

/// Every way an execution or helper interaction settles as a failure.
/// Always a value, never a crash.
pub type ExecFailure {
  /// The helper has not completed its handshake (or is dead).
  NotReady

  /// The handshake did not complete within the configured timeout.
  HandshakeTimeout

  /// This helper is already running an execution.
  HelperBusy

  /// The helper's hello reports degraded enforcement and the request
  /// demanded `FullEnforcement`.
  DegradedHelper(features: List(String))

  /// The execution ran but its `exec_exit` reports degraded enforcement
  /// against a `FullEnforcement` demand — the `degraded` bool was set,
  /// or the `enforcement` list carries a `skip:` entry for a layer that
  /// was not applied. The result is attached but must not be trusted as
  /// jailed.
  DegradedExecution(result: ExecResult)

  /// The helper answered the dispatch with a protocol error frame
  /// (busy, bad_policy, spawn_failed, malformed...).
  RefusedByHelper(code: String, message: String)

  /// The inbound byte stream broke the framing protocol; the channel
  /// was closed (spec §3.3 invariant 6).
  ChannelFault(fault: Fault)

  /// The helper process exited with this OS status.
  ChannelClosed(status: Int)

  /// The helper sent a frame kind that never flows helper-to-broker;
  /// the channel was closed.
  ProtocolViolation(kind: String)

  /// Writing to the helper's stdin failed (helper died mid-frame).
  SendFailed

  /// A cancel was not answered by `exec_exit` within the grace period;
  /// the helper was killed outright.
  CancelEscalated

  /// The idle heartbeat went unanswered; the helper was declared dead.
  HeartbeatMissed

  /// The helper *actor* did not answer within the caller's window, or
  /// was not alive to be asked. Distinct from every failure above,
  /// which are things the actor told us: this is the actor itself out
  /// of reach, so nothing is known about the helper process behind it
  /// and no execution was dispatched.
  HelperUnresponsive
}

/// A helper's observable lifecycle position.
pub type HelperStatus {
  /// Handshake still in flight.
  StatusStarting

  /// Handshake done; these are the helper's hello features.
  StatusReady(features: List(String))

  /// The channel is gone; the actor answers every request with this
  /// failure until shut down.
  StatusDead(failure: ExecFailure)

  /// The actor did not answer the question, or was not alive to be
  /// asked. Not a position the helper reported — the absence of one.
  StatusUnresponsive
}

/// How to reach one helper process. A seam: production uses
/// `PortTransport`; tests drive the same actor through
/// `ChannelTransport` with an in-process fake.
///
/// The port itself is opened *inside* the helper actor (ports deliver
/// their messages to the process that opened them), which is why this
/// is a spawn spec rather than an open port.
pub type Transport {
  /// A real OS helper: `executable` is spawned with `args` as an
  /// Erlang port owned by the actor. `cleanup` is called once the
  /// handshake proves the fd-3 policy file was read (and again on
  /// death — it must be idempotent).
  PortTransport(executable: String, args: List(String), cleanup: fn() -> Nil)

  /// An in-process peer: outbound bytes go to `send`; inbound bytes
  /// arrive on the helper's wire subject (see `wire`).
  ChannelTransport(send: fn(BitArray) -> Nil, close: fn() -> Nil)
}

// The resolved runtime channel held in actor state.
type Wire {
  WirePort(port: Port, os_pid: Option(Int), cleanup: fn() -> Nil)
  WireChannel(send: fn(BitArray) -> Nil, close: fn() -> Nil)
}

/// Configuration for one helper actor.
pub type HelperConfig {
  HelperConfig(
    /// The channel to the helper process.
    transport: Transport,
    /// How long the hello exchange may take before the helper is
    /// declared dead.
    handshake_timeout_ms: Int,
    /// How long after `cancel` to wait for `exec_exit` before killing
    /// the helper outright. The helper's own TERM-to-KILL ladder is 2s;
    /// this must exceed it.
    ///
    /// The helper's 2s is a real grace jailed as well as unjailed — a
    /// payload with `SIG_IGN` on TERM outlives it and is ended by the
    /// KILL rung. See `cancel` for who each rung is addressed to.
    cancel_grace_ms: Int,
    /// Idle liveness probe interval; `0` disables.
    heartbeat_interval_ms: Int,
  )
}

/// A `HelperConfig` with contract-derived defaults: 5s handshake, 3s
/// cancel grace (above the helper's 2s ladder), 30s heartbeats.
pub fn default_config(transport: Transport) -> HelperConfig {
  HelperConfig(
    transport:,
    handshake_timeout_ms: 5000,
    cancel_grace_ms: 3000,
    heartbeat_interval_ms: 30_000,
  )
}

/// Bytes arriving from the helper (used directly by fake transports;
/// the port transport produces these internally).
pub type WireEvent {
  /// Raw protocol bytes from the helper's stdout.
  WireBytes(data: BitArray)

  /// The helper process is gone, with this exit status.
  WireClosed(status: Int)
}

/// A handle to one broker-side helper actor.
pub opaque type Helper {
  /// Invariant: `commands` and `wire` are subjects of the same actor
  /// process `pid`.
  Helper(commands: Subject(Msg), wire: Subject(WireEvent), pid: Pid)
}

/// The helper machine's message type: every event it dispatches on,
/// whether it came from a caller, from the wire, or from one of the two
/// state timeouts. Opaque; constructed only through this module's API.
pub opaque type Msg {
  AwaitReady(reply: Subject(Result(List(String), ExecFailure)))
  QueryStatus(reply: Subject(HelperStatus))
  Run(
    request: ExecRequest,
    events: Subject(ExecEvent),
    reply: Subject(Result(Nil, ExecFailure)),
  )
  Stdin(data: BitArray, eof: Bool)
  CancelExec

  /// The cancel grace expired. Carries no execution id, because the
  /// state timeout on `Cancelling` that delivers it dies with that
  /// state — and leaving `Cancelling` is the only way the execution it
  /// speaks for can settle.
  CancelDeadline

  /// The handshake window expired. A state timeout on `AwaitingHello`,
  /// so reaching `Idle` or `Dead` cancels it.
  HandshakeDeadline

  /// The idle liveness probe came round. Carries no execution id and no
  /// generation stamp: it is a periodic timeout armed under one name, so
  /// weft's timer book drops a tick that raced its own cancellation and
  /// nothing here has to recognise a stale one.
  HeartbeatTick

  Heartbeat(reply: Subject(Result(Nil, ExecFailure)))
  Shutdown
  FromWire(event: WireEvent)
}

/// Where the helper is in its lifecycle: the machine's *state* in
/// `weft/state_machine`'s sense, which is what makes both deadlines
/// structural instead of guarded by hand.
///
/// `Idle`, `Running` and `Cancelling` are the three ways to be past the
/// handshake, and each carries the hello features so a status query is
/// answered from the state alone. The two busy ones additionally carry
/// the execution in flight, which is how a settlement knows who to tell.
///
/// **A state's payload must not change while the machine is in it.** A
/// state timeout is cancelled by a move to a state that compares
/// *unequal*, and a `transition` to an equal value is not a move at all
/// — so re-entering `Cancelling` with a mutated payload would silently
/// restart the escalation deadline, and re-entering it with an equal one
/// is a no-op that looks like a move. Every field here is fixed at the
/// moment its state is entered: `features` at hello, `RunningExec` at
/// dispatch. Anything that moves per frame belongs in `Data`.
type Phase {
  /// The hello exchange is in flight. Entering this state arms the
  /// handshake deadline.
  AwaitingHello

  /// Handshake done, nothing running.
  Idle(features: List(String))

  /// One execution in flight, running normally.
  Running(features: List(String), exec: RunningExec)

  /// One execution in flight that has been told to stop. Entering this
  /// state arms the cancel-escalation deadline; settling back to `Idle`
  /// is what disarms it.
  Cancelling(features: List(String), exec: RunningExec)

  /// The channel is gone. Absorbing: every request is answered with this
  /// failure until the machine is shut down, and no second failure
  /// re-notifies anyone.
  Dead(failure: ExecFailure)
}

/// The execution a `Running` or `Cancelling` state carries. Immutable
/// for the life of that state — see `Phase`.
type RunningExec {
  RunningExec(
    id: Int,
    events: Subject(ExecEvent),
    demand: EnforcementDemand,
    /// The layer tags this execution's policy calls for, computed at
    /// dispatch and checked against the `exec_exit` report. Held here
    /// because the report arrives long after the request that named
    /// them, and "what was asked for" is half of the check.
    required: List(String),
    /// Platform-known gaps that may be reported as skipped for this
    /// execution. Every one must still appear in the report, either as
    /// applied or as `skip:`; silence is not tolerance.
    tolerated: List(String),
  )
}

/// Everything the machine carries *across* states: the channel, the
/// deframer, and the bookkeeping that belongs to no single phase.
///
/// The split from `Phase` is weft's, and it is load-bearing rather than
/// tidy. Data may change on every frame without disturbing a state
/// timeout; a change of state cancels one. So the deframer, the id
/// counter and the outstanding-tick flag live here — putting any of them
/// in the state would make an ordinary inbound chunk cancel the cancel
/// escalation. The heartbeat itself is in neither: it is a periodic
/// timeout, which belongs to the machine rather than to a phase, and
/// what stays here is only the one-deep record of whether the last probe
/// was answered.
type Data {
  Data(
    config: HelperConfig,
    wire_out: Wire,
    deframer: framing.Deframer,
    next_id: Int,
    pending_heartbeats: List(#(Int, Subject(Result(Nil, ExecFailure)))),
    tick_outstanding: Bool,
    cleaned: Bool,
  )
}

/// A phase and its data in one value, for the inbound-frame path.
///
/// One deframed chunk can carry several frames and any of them may move
/// the machine — a hello to `Idle`, an `exec_exit` to `Idle`, a frame the
/// helper had no business sending to `Dead`. Folding over them needs both
/// halves in hand, so the fold threads this and the dispatch arm turns
/// the result back into a step with `advance`.
type Machine {
  Machine(phase: Phase, data: Data)
}

// --- helper lifecycle ---------------------------------------------------

/// Starts a helper state machine over a transport. The handshake runs
/// asynchronously; use `await_ready` (or `spawn_helper`, which does) to
/// learn the features or the failure.
///
/// The return type is `gleam/otp/actor`'s own `StartError`, which is
/// what `weft/state_machine.start` reports: a weft machine is
/// indistinguishable from an upstream actor to whatever starts it, so
/// `spawn_helper`'s `InitFailed` translation below still reads.
pub fn start(config: HelperConfig) -> Result(Helper, actor.StartError) {
  state_machine.new_with_initialiser(5000, fn(commands) {
    let wire = process.new_subject()
    let base =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, FromWire)

    // The port must be opened by this process: port messages are
    // delivered to the opener, and the opener is where the selector
    // lives.
    use #(wire_out, selector) <- result.try(open_transport(
      config.transport,
      base,
    ))

    // The handshake deadline is not armed here. It belongs to
    // `AwaitingHello`, so `entered` arms it on the initial enter call
    // weft makes for the starting state — which is what lets the move to
    // `Idle` or `Dead` cancel it with nobody cancelling a timer.
    let data =
      Data(
        config:,
        wire_out:,
        deframer: framing.deframer(),
        next_id: 1,
        pending_heartbeats: [],
        tick_outstanding: False,
        cleaned: False,
      )
    state_machine.initialised(AwaitingHello, data)
    |> state_machine.selecting(selector)
    |> state_machine.returning(#(commands, wire))
    |> Ok
  })
  |> state_machine.on_event(handle)
  |> state_machine.on_enter(entered)
  |> state_machine.start
  |> result.map(fn(started) {
    let #(commands, wire) = started.data
    Helper(commands:, wire:, pid: started.pid)
  })
}

// Opens the resolved runtime channel for a transport spec. The port
// case must run in the calling (actor) process: port messages are
// delivered to the opener, and the opener is where the selector lives.
fn open_transport(
  transport: Transport,
  base: process.Selector(Msg),
) -> Result(#(Wire, process.Selector(Msg)), String) {
  case transport {
    ChannelTransport(send:, close:) -> Ok(#(WireChannel(send:, close:), base))
    PortTransport(executable:, args:, cleanup:) ->
      case ffi_port.open_helper(executable, args) {
        Error(Nil) -> Error(port_open_failure)
        Ok(opened) -> {
          let os_pid = option.from_result(ffi_port.port_os_pid(opened))
          let selector =
            process.select_record(
              base,
              tag: opened,
              fields: 1,
              mapping: fn(message) { FromWire(port_wire_event(message)) },
            )
          Ok(#(WirePort(port: opened, os_pid:, cleanup:), selector))
        }
      }
  }
}

// The initialiser failure message for an unopenable port; spawn_helper
// translates it back into a structured SpawnError.
const port_open_failure = "helper port could not be opened"

fn port_wire_event(message: Dynamic) -> WireEvent {
  case ffi_port.port_event(message) {
    ffi_port.PortBytes(data:) -> WireBytes(data:)
    ffi_port.PortClosed(status:) -> WireClosed(status:)

    // Not a port message shape; treat as an empty chunk (harmless).
    ffi_port.PortJunk -> WireBytes(data: <<>>)
  }
}

/// Blocks until the handshake settles, returning the helper's hello
/// features. Bounded by the config's handshake timeout — and by
/// `timeout` for the actor's answer, which an actor wedged in a channel
/// write can miss even though its own deadline fired: that is
/// `HelperUnresponsive` rather than a dead caller, because the one
/// production caller is asking this in order to *report* on the helper
/// (`client/serve.degraded`), and a probe that answers with its
/// caller's death has answered nothing.
pub fn await_ready(
  helper: Helper,
  waiting timeout: Int,
) -> Result(List(String), ExecFailure) {
  or_unresponsive(call.try_call(
    helper.commands,
    waiting: timeout,
    sending: AwaitReady,
  ))
}

/// The helper's current lifecycle position, or `StatusUnresponsive`
/// when the actor does not answer within `timeout` or is not alive to
/// be asked.
///
/// This used to be an ordinary `process.call`, which panics on both.
/// The contract was defensible for a caller whose next step needs the
/// answer, and indefensible for the callers this actually has: every
/// one of them is asking whether a helper is fit to use, and the pool
/// had to grow a private `try_call` probe of its own rather than call
/// it, because inside the pool actor that panic is not a retired helper
/// but a dead pool — and a dead pool takes the broker with it. There is
/// now one probe, and `helper_ready` is a policy on top of it.
pub fn status(helper: Helper, waiting timeout: Int) -> HelperStatus {
  case call.try_call(helper.commands, waiting: timeout, sending: QueryStatus) {
    Ok(position) -> position
    Error(call.NoReply) | Error(call.CalleeGone) -> StatusUnresponsive
  }
}

/// Dispatches an execution. On `Ok`, events stream to `events` and end
/// with exactly one `Exited` or `Failed`; an `Error` is a dispatch-time
/// refusal and nothing was sent to the helper.
///
/// An actor that does not answer the dispatch is `HelperUnresponsive`,
/// not a fault: the broker calls this from inside its own message
/// handler, on a helper it borrowed a few microseconds earlier and
/// which is free to have died in between, and a dispatch that killed
/// the broker would take every other strand's verdict with it. The
/// refusal settles in band like any other dispatch-stage failure.
pub fn run(
  helper: Helper,
  request: ExecRequest,
  events events: Subject(ExecEvent),
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  or_unresponsive(
    call.try_call(helper.commands, waiting: timeout, sending: fn(reply) {
      Run(request:, events:, reply:)
    }),
  )
}

/// Sends a chunk of stdin to the running execution; `eof: True` closes
/// the child's stdin after `data`. Ignored when nothing is running.
pub fn stdin(helper: Helper, data data: BitArray, eof eof: Bool) -> Nil {
  process.send(helper.commands, Stdin(data:, eof:))
}

/// Cancels the running execution. Idempotent. If `exec_exit` still does
/// not arrive within the grace period the actor kills the helper process
/// outright and settles the execution as `Failed(CancelEscalated)`.
///
/// ## What the ladder actually addresses
///
/// `TERM` → grace → `KILL`, but the two rungs are not sent to the same
/// set of processes, and the difference is what makes the grace mean
/// anything inside a jail.
///
/// `TERM` goes to the **payload** — the command the broker addressed and
/// whatever it spawned inside the jail — and deliberately spares the
/// jail's own scaffolding. Under bwrap the helper's direct child is a
/// supervisor process that is also the process-group leader, and it is
/// spawned `--die-with-parent`; TERMing the group therefore kills the
/// supervisor, whose death SIGKILLs the PID namespace's init and every
/// process in that namespace with it. That collapsed the grace to under a
/// millisecond and delivered a SIGKILL to a payload nothing had asked to
/// stop. `KILL` does go to the whole group, because by then demolishing
/// the cage is the point. See `packages/sandbox/internal/jail/cancel.go`.
///
/// ## What the exit reports, and why `signal` is not the field to read
///
/// Unjailed, the payload is the helper's direct child: a TERM-compliant
/// payload dies of the signal and `ExecResult` carries `signal: 15`,
/// `code: 143`.
///
/// Jailed, the helper's direct child is the supervisor, which outlives
/// the payload and relays a signalled payload by *exiting* 128+signal
/// itself. `signal` is then `0` — not because nothing was signalled, but
/// because the process the helper waited on was not the one signalled.
/// `code` is 143 either way.
///
/// So `code` is the field that means the same thing on both sides of the
/// jail boundary; `signal` distinguishes them and must not be read as
/// "the payload was/was not signalled".
pub fn cancel(helper: Helper) -> Nil {
  process.send(helper.commands, CancelExec)
}

/// A protocol-level liveness probe: sends `heartbeat` and waits for the
/// echo. An actor that does not answer is `HelperUnresponsive` — the
/// answer to "is this helper alive?" is never the questioner's death.
pub fn heartbeat(
  helper: Helper,
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  or_unresponsive(call.try_call(
    helper.commands,
    waiting: timeout,
    sending: Heartbeat,
  ))
}

// An exchange with the helper actor that produced no reply is a helper
// failure like any the actor could have reported, and every caller of
// these three settles one in band. The distinction the fault carries —
// timed out versus never alive — is not one any of them can act on:
// the actor is out of reach either way and nothing was dispatched.
fn or_unresponsive(
  attempt: Result(Result(a, ExecFailure), call.CallFault),
) -> Result(a, ExecFailure) {
  case attempt {
    Ok(answer) -> answer
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(HelperUnresponsive)
  }
}

/// Stops the helper actor, closing the channel (which orders the helper
/// process to reap any running jail and exit).
pub fn shutdown(helper: Helper) -> Nil {
  process.send(helper.commands, Shutdown)
}

/// The actor's pid, for monitoring.
pub fn pid(helper: Helper) -> Pid {
  helper.pid
}

/// The subject on which the transport delivers inbound bytes. Only fake
/// (`ChannelTransport`) peers send to it; the port transport bypasses
/// it via the port selector.
pub fn wire(helper: Helper) -> Subject(WireEvent) {
  helper.wire
}

// --- machine internals --------------------------------------------------

/// The machine's event handler: one exhaustive matrix over phase and
/// message.
///
/// Every pair is written out, including the ones that cannot happen, and
/// that is the point of the port. Adding a phase or a message makes the
/// compiler name each combination nobody has thought about, where the
/// actor this replaces answered several of them with a guard the handler
/// had to remember to write — `state.phase` re-checked inside the
/// handshake deadline, an execution id carried on the cancel deadline so
/// its handler could recognise its own fire.
fn handle(
  phase: Phase,
  data: Data,
  message: Msg,
) -> state_machine.Next(Phase, Data, Msg) {
  case phase, message {
    // Inbound bytes are deframed in every phase. `apply_inbound` asks
    // the phase question once per frame rather than once per chunk,
    // because a chunk can carry the frame that kills the channel and
    // the frames behind it.
    phase, FromWire(WireBytes(data: bytes)) ->
      advance(handle_bytes(Machine(phase:, data:), bytes))

    phase, FromWire(WireClosed(status:)) ->
      die(Machine(phase:, data:), ChannelClosed(status:))

    // The status query reads the phase alone, which is why the hello
    // features are carried by the three live states rather than beside
    // them.
    phase, QueryStatus(reply:) -> {
      process.send(reply, status_of(phase))
      state_machine.keep(data)
    }

    // Shutdown settles what is in flight before the machine stops, so a
    // caller whose execution is still running learns why it ended
    // instead of watching its events subject go quiet.
    phase, Shutdown -> handle_shutdown(Machine(phase:, data:))

    // The handshake has not settled, so the asker is parked. `postpone`
    // re-queues this exact event; weft replays it, in arrival order,
    // exactly once, on the next change of state — the hello's move to
    // `Idle` or a death's move to `Dead` — where the arms below answer
    // it with that state's outcome. Invariant: every `AwaitReady` asked
    // during the handshake is answered exactly once with the outcome of
    // the next state.
    AwaitingHello, AwaitReady(..) ->
      state_machine.keep(data) |> state_machine.postpone

    Idle(features:), AwaitReady(reply:)
    | Running(features:, ..), AwaitReady(reply:)
    | Cancelling(features:, ..), AwaitReady(reply:)
    -> {
      process.send(reply, Ok(features))
      state_machine.keep(data)
    }

    Dead(failure:), AwaitReady(reply:) -> {
      process.send(reply, Error(failure))
      state_machine.keep(data)
    }

    // A dispatch is answered now or never: nothing is postponed here,
    // because a caller that cannot run holds a budget reservation and a
    // deadline, and would rather be refused than parked.
    Dead(failure:), Run(request: _, events: _, reply:) ->
      refuse_run(data, reply, failure)

    AwaitingHello, Run(request: _, events: _, reply:) ->
      refuse_run(data, reply, NotReady)

    // One helper runs one execution at a time, and a cancel in flight is
    // still an execution in flight.
    Running(..), Run(request: _, events: _, reply:)
    | Cancelling(..), Run(request: _, events: _, reply:)
    -> refuse_run(data, reply, HelperBusy)

    Idle(features:), Run(request:, events:, reply:) ->
      handle_run(data, features, request, events, reply)

    // Stdin follows the execution rather than the phase: a payload that
    // has been TERMed but has not exited may still be reading.
    Running(exec:, ..) as phase, Stdin(data: bytes, eof:)
    | Cancelling(exec:, ..) as phase, Stdin(data: bytes, eof:)
    ->
      send_or_die(
        Machine(phase:, data:),
        framing.Frame(id: exec.id, body: framing.ExecStdin(data: bytes, eof:)),
      )

    AwaitingHello, Stdin(..) | Idle(..), Stdin(..) | Dead(..), Stdin(..) ->
      state_machine.keep(data)

    // The TERM goes out and the machine moves to `Cancelling`, whose
    // enter call arms the escalation deadline. Arming it there rather
    // than here is what makes a write that fails on the way — landing in
    // `Dead` instead — leave no deadline running against a machine that
    // has already settled.
    Running(features:, exec:), CancelExec ->
      send_or_die(
        Machine(phase: Cancelling(features:, exec:), data:),
        framing.Frame(id: exec.id, body: framing.Cancel),
      )

    // Idempotent: `keep` is not a state change, so the first cancel's
    // deadline keeps running rather than being restarted by the second.
    Cancelling(..), CancelExec -> state_machine.keep(data)

    AwaitingHello, CancelExec | Idle(..), CancelExec | Dead(..), CancelExec ->
      state_machine.keep(data)

    // The helper missed its own 2s TERM-to-KILL ladder. Belt and braces:
    // demolish the channel and settle the execution in band.
    Cancelling(..) as phase, CancelDeadline -> {
      kill_transport(data.wire_out)
      die(Machine(phase:, data:), CancelEscalated)
    }

    // Unreachable by construction. The escalation deadline is a state
    // timeout on `Cancelling`, so any move out of that state cancels it
    // and a fire that raced the move is dropped by weft's timer book
    // before it reaches this handler. The arm exists because the matrix
    // is exhaustive, not because the case can arise.
    AwaitingHello, CancelDeadline
    | Idle(..), CancelDeadline
    | Running(..), CancelDeadline
    | Dead(..), CancelDeadline
    -> state_machine.keep(data)

    AwaitingHello, HandshakeDeadline ->
      die(Machine(phase: AwaitingHello, data:), HandshakeTimeout)

    // Unreachable for the same reason the stale `CancelDeadline` is:
    // reaching `Idle` or `Dead` cancels the handshake deadline, and this
    // is where the actor's `case state.phase` guard used to live.
    Idle(..), HandshakeDeadline
    | Running(..), HandshakeDeadline
    | Cancelling(..), HandshakeDeadline
    | Dead(..), HandshakeDeadline
    -> state_machine.keep(data)

    Idle(..) as phase, HeartbeatTick
    | Running(..) as phase, HeartbeatTick
    | Cancelling(..) as phase, HeartbeatTick
    -> handle_heartbeat_tick(Machine(phase:, data:))

    // Unreachable by construction, and written out because weft's
    // exhaustiveness is what proves it: the probe is armed on the way
    // out of `AwaitingHello` and cancelled on the way into `Dead`, and a
    // tick in flight at either boundary is flushed by the timer book.
    AwaitingHello, HeartbeatTick | Dead(..), HeartbeatTick ->
      state_machine.keep(data)

    Idle(..) as phase, Heartbeat(reply:)
    | Running(..) as phase, Heartbeat(reply:)
    | Cancelling(..) as phase, Heartbeat(reply:)
    -> send_heartbeat(Machine(phase:, data:), reply)

    AwaitingHello, Heartbeat(reply:) -> {
      process.send(reply, Error(NotReady))
      state_machine.keep(data)
    }

    Dead(failure:), Heartbeat(reply:) -> {
      process.send(reply, Error(failure))
      state_machine.keep(data)
    }
  }
}

/// The deadline each state owns, armed by every path into it — including
/// the initial entry into `AwaitingHello`, which weft makes for the
/// starting state on the far side of the start acknowledgement.
///
/// This callback is where the port's whole benefit is concentrated. Both
/// deadlines were hand-rolled `send_after` timers whose handlers had to
/// re-establish their own relevance: the handshake one re-read
/// `state.phase`, the cancel one compared an execution id it carried for
/// no other purpose, and three settle sites had to remember to cancel the
/// timer they had armed. As state timeouts they are cancelled by the move
/// out of the state that armed them, so the guards are deleted rather
/// than relocated.
///
/// Arming here rather than at the transition site matters for
/// `Cancelling`: the transition and the TERM write are one step, and a
/// write that fails lands in `Dead` instead. Only a machine that really
/// reached `Cancelling` gets the deadline.
fn entered(
  from: Phase,
  to: Phase,
  data: Data,
) -> state_machine.Enter(Phase, Data, Msg) {
  case to {
    AwaitingHello ->
      state_machine.keep(data)
      |> state_machine.with_state_timeout(
        after: data.config.handshake_timeout_ms,
        sending: HandshakeDeadline,
      )

    Cancelling(..) ->
      state_machine.keep(data)
      |> state_machine.with_state_timeout(
        after: data.config.cancel_grace_ms,
        sending: CancelDeadline,
      )

    // The probe starts when the handshake finishes, and the move out of
    // `AwaitingHello` is the only path that arms it. Arming on every
    // entry to `Idle` would turn a liveness probe into an idle timeout:
    // a helper settling executions faster than the interval would push
    // the next tick out for ever and never be probed at all.
    Idle(..) ->
      case from {
        AwaitingHello -> arm_heartbeat(data)
        Idle(..) | Running(..) | Cancelling(..) | Dead(..) ->
          state_machine.keep(data)
      }

    // Nothing left to probe. Cancelling rather than letting the ticks
    // arrive and be ignored is what makes the `Dead(..), HeartbeatTick`
    // arm in `handle` unreachable: a tick already in flight when the
    // machine dies carries a stale generation stamp and dies in weft's
    // timer book instead of reaching the handler.
    Dead(..) ->
      state_machine.keep(data)
      |> state_machine.cancel_timeout(name: heartbeat_timer)

    Running(..) -> state_machine.keep(data)
  }
}

// The name the idle liveness probe is armed under.
//
// A periodic timeout shares weft's named-timeout name space, so one
// constant is what keeps the arm in `entered` and the cancel in `Dead`
// talking about the same timer rather than about two.
const heartbeat_timer = "helper.heartbeat"

// Arms the idle liveness probe, unless the configuration disables it.
//
// The zero guard survives the port and is not a leftover: `0` means "do
// not probe", and a periodic timeout armed for zero milliseconds is a
// spin rather than a disabled probe.
fn arm_heartbeat(data: Data) -> state_machine.Enter(Phase, Data, Msg) {
  case data.config.heartbeat_interval_ms > 0 {
    True ->
      state_machine.keep(data)
      |> state_machine.with_periodic_timeout(
        name: heartbeat_timer,
        every: data.config.heartbeat_interval_ms,
        sending: HeartbeatTick,
      )

    False -> state_machine.keep(data)
  }
}

// Hands a phase-and-data pair back to weft as a step.
//
// A `transition` to the phase the machine is already in is not a state
// change — weft compares states structurally — so this arms nothing,
// cancels nothing and runs no enter call when the work left the phase
// alone. When the work did move the machine, the same call is the move,
// and it takes the old phase's deadline with it. That equivalence is why
// the frame path can be written as `Machine -> Machine` and turned into
// a step in one place.
fn advance(machine: Machine) -> state_machine.Next(Phase, Data, Msg) {
  state_machine.transition(to: machine.phase, data: machine.data)
}

// The lifecycle position a `status` query reports. `Running` and
// `Cancelling` are both "ready" to an outside observer: the helper
// answered its hello and is doing what it was asked.
fn status_of(phase: Phase) -> HelperStatus {
  case phase {
    AwaitingHello -> StatusStarting
    Idle(features:) | Running(features:, ..) | Cancelling(features:, ..) ->
      StatusReady(features:)
    Dead(failure:) -> StatusDead(failure:)
  }
}

// Settles everything in flight in band, then closes the channel — which
// orders the helper process to reap any running jail and exit — and
// stops. The settlement precedes the close so that a caller learns why
// its execution ended rather than inferring it from silence.
fn handle_shutdown(machine: Machine) -> state_machine.Next(Phase, Data, Msg) {
  let data = notify_death(machine, ChannelClosed(status: 0))
  close_transport(data.wire_out)
  let _ = run_cleanup(data)
  state_machine.stop()
}

// The idle liveness probe. A tick still outstanding when the next one
// comes round is the helper having stopped speaking altogether, which is
// a death rather than one dropped frame.
fn handle_heartbeat_tick(
  machine: Machine,
) -> state_machine.Next(Phase, Data, Msg) {
  case machine.data.tick_outstanding {
    True -> die(machine, HeartbeatMissed)
    False -> send_heartbeat_tick(machine)
  }
}

// Writes this tick's probe; the next one is weft's to arm.
//
// A periodic timeout re-arms itself once this handler has returned, so
// the ordering the hand-rolled version had to arrange by hand — arm
// before the write, so a write that kills the channel leaves no gap —
// comes for free and is now stronger. A write that kills the channel
// lands in `Dead`, whose enter callback cancels the series, so there is
// no tick scheduled for a machine with nothing left to probe.
fn send_heartbeat_tick(
  machine: Machine,
) -> state_machine.Next(Phase, Data, Msg) {
  let #(data, id) = fresh_id(machine.data)
  let data = Data(..data, tick_outstanding: True)
  send_or_die(
    Machine(..machine, data:),
    framing.Frame(id:, body: framing.Heartbeat),
  )
}

// A caller's `heartbeat` probe. The echo is correlated by frame id, so
// several probes and the idle tick can be in flight at once without any
// of them answering for another.
fn send_heartbeat(
  machine: Machine,
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  let #(data, id) = fresh_id(machine.data)
  let data =
    Data(..data, pending_heartbeats: [#(id, reply), ..data.pending_heartbeats])
  send_or_die(
    Machine(..machine, data:),
    framing.Frame(id:, body: framing.Heartbeat),
  )
}

// The one dispatch path: `Idle`, with a helper whose hello features the
// request's demand can live with. Every other phase was refused in
// `handle`, so this only has to weigh degradation.
fn handle_run(
  data: Data,
  features: List(String),
  request: ExecRequest,
  events: Subject(ExecEvent),
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  case request.demand, degraded_features(features) {
    FullEnforcement, True -> refuse_run(data, reply, DegradedHelper(features:))
    PlatformEnforcement, True ->
      refuse_run(data, reply, DegradedHelper(features:))
    _, _ -> dispatch_exec(data, features, request, events, reply)
  }
}

// The shared shape of every dispatch-time refusal: answer the caller and
// keep the machine where it is, with no execution recorded.
fn refuse_run(
  data: Data,
  reply: Subject(Result(Nil, ExecFailure)),
  failure: ExecFailure,
) -> state_machine.Next(Phase, Data, Msg) {
  process.send(reply, Error(failure))
  state_machine.keep(data)
}

// Records the execution in the state and writes the `exec_start`.
//
// The caller is answered before the write, which is the order the
// contract needs: `run` returning `Ok` promises exactly one terminal
// event on the events subject, and a write that fails settles the
// execution with one — so the acknowledgement must already be out.
//
// Everything the settlement will need is fixed here and never touched
// again, which is what lets `RunningExec` sit inside the state. See
// `Phase` for why a mutable payload there would silently disarm the
// escalation deadline.
fn dispatch_exec(
  data: Data,
  features: List(String),
  request: ExecRequest,
  events: Subject(ExecEvent),
  reply: Subject(Result(Nil, ExecFailure)),
) -> state_machine.Next(Phase, Data, Msg) {
  let #(data, id) = fresh_id(data)
  let frame =
    framing.Frame(
      id:,
      body: framing.ExecStart(
        argv: request.argv,
        env: request.env,
        cwd: request.cwd,
        policy: request.policy,
        token: request.token,
        limits: None,
      ),
    )
  let exec =
    RunningExec(
      id:,
      events:,
      demand: request.demand,
      required: required_layers_for_demand(
        request.policy,
        features,
        request.demand,
      ),
      tolerated: tolerated_layers_for_demand(
        request.policy,
        features,
        request.demand,
      ),
    )
  process.send(reply, Ok(Nil))
  send_or_die(Machine(phase: Running(features:, exec:), data:), frame)
}

// A helper advertising "degraded" (bwrap unavailable) cannot provide
// full enforcement. Per-exec ground truth is additionally checked on
// exec_exit.
fn degraded_features(features: List(String)) -> Bool {
  list.contains(features, "degraded")
}

/// The layer tags an execution under `policy` must be able to show as
/// applied. Exported for the enforcement report the caller renders.
///
/// This is the half of the check that #54 was missing. "No `skip:`
/// entries" is a test a *silent* helper passes: a stage 2 that died
/// before writing fd 4 produced `enforcement: ["bwrap"]`, which contains
/// no skip and so satisfied a full-enforcement demand with the whole
/// inner report — Landlock, seccomp, no_new_privs, the rlimits — absent.
/// A layer that says nothing is not a layer that was applied.
///
/// Linux requires `bwrap`, `mounts`, `landlock`, and `no-new-privs`.
/// macOS requires `seatbelt` and `seatbelt-fs`. The rest are asked for by
/// the policy itself, and each platform names its actual mechanism:
///
/// | policy                    | tag            |
/// |---------------------------|----------------|
/// | Linux network off/proxy   | `seccomp-net`  |
/// | macOS network off/proxy   | `seatbelt-net` |
/// | Linux memory/pids > 0     | `cgroup-v2`    |
/// | macOS memory > 0          | `rlimit-address-space` |
/// | macOS pids > 0            | `rlimit-processes` |
/// | `cpu_s` > 0               | `rlimit-cpu`   |
/// | `fsize_bytes` > 0         | `rlimit-fsize` |
///
/// With no per-exec policy the execution runs under the helper's fd-3
/// base, whose conditional layers this actor cannot see; only the
/// unconditional four are required then.
pub fn required_layers(policy: Option(SandboxPolicy)) -> List(String) {
  required_layers_for(policy, ffi_os.os_name())
}

/// The enforcement matrix selected by the helper that will execute the
/// request. Tests and remote helpers may not run the same backend as the
/// broker VM, so the hello frame, not the VM's operating system, chooses it.
pub fn required_layers_for_features(
  policy: Option(SandboxPolicy),
  features: List(String),
) -> List(String) {
  let os_name = case list.contains(features, "seatbelt") {
    True -> "darwin"
    False -> "linux"
  }
  required_layers_for(policy, os_name)
}

// The mandatory half of a demand. PlatformEnforcement keeps the Darwin
// resource layers out of this list because ADR-006 proves they are not
// platform guarantees; `tolerated_layers_for_demand` still requires an
// explicit applied-or-skipped report for each one.
fn required_layers_for_demand(
  policy: Option(SandboxPolicy),
  features: List(String),
  demand: EnforcementDemand,
) -> List(String) {
  let required = required_layers_for_features(policy, features)
  let tolerated = tolerated_layers_for_demand(policy, features, demand)
  list.filter(required, fn(layer) { !list.contains(tolerated, layer) })
}

// Darwin's documented gaps are tolerated only by PlatformEnforcement and
// only when the report names them. Linux has no corresponding relaxation:
// its platform-strict demand is byte-for-byte as strict as full enforcement.
fn tolerated_layers_for_demand(
  policy: Option(SandboxPolicy),
  features: List(String),
  demand: EnforcementDemand,
) -> List(String) {
  case demand, list.contains(features, "seatbelt") {
    PlatformEnforcement, True -> {
      let resource = case policy {
        None -> []
        Some(policy) ->
          list.flatten([
            optional_layer(policy.limits.mem_bytes > 0, "rlimit-address-space"),
            optional_layer(policy.limits.pids > 0, "rlimit-processes"),
          ])
      }
      list.append(resource, ["darwin-process-lifecycle"])
    }
    _, _ -> []
  }
}

/// `required_layers` with an explicit OS name, so both platform matrices are
/// testable on either CI host.
pub fn required_layers_for(
  policy: Option(SandboxPolicy),
  os_name: String,
) -> List(String) {
  let base = base_layers_for(os_name)
  case policy {
    None -> base
    Some(policy) ->
      list.flatten([
        base,
        network_layers_for(policy.network, os_name),
        resource_layers_for(policy.limits, os_name),
        optional_layer(policy.limits.cpu_s > 0, "rlimit-cpu"),
        optional_layer(policy.limits.fsize_bytes > 0, "rlimit-fsize"),
      ])
  }
}

fn base_layers_for(os_name: String) -> List(String) {
  case os_name {
    "darwin" -> ["seatbelt", "seatbelt-fs"]
    "linux" -> ["bwrap", "mounts", "landlock", "no-new-privs"]
    _ -> []
  }
}

fn network_layers_for(
  network: policy.NetworkPolicy,
  os_name: String,
) -> List(String) {
  case network {
    policy.NetworkOff | policy.NetworkProxy(..) ->
      case os_name {
        "darwin" -> ["seatbelt-net"]
        "linux" -> ["seccomp-net"]
        _ -> []
      }
    policy.NetworkFull -> []
  }
}

fn resource_layers_for(limits: policy.Limits, os_name: String) -> List(String) {
  case limits.mem_bytes > 0 || limits.pids > 0 {
    False -> []
    True ->
      case os_name {
        "darwin" ->
          list.flatten([
            optional_layer(limits.mem_bytes > 0, "rlimit-address-space"),
            optional_layer(limits.pids > 0, "rlimit-processes"),
          ])
        "linux" -> ["cgroup-v2"]
        _ -> []
      }
  }
}

fn optional_layer(enabled: Bool, layer: String) -> List(String) {
  case enabled {
    True -> [layer]
    False -> []
  }
}

/// The layers `required` asked for that `enforcement` does not show as
/// applied. Empty is the only acceptable answer to a `FullEnforcement`
/// demand; the entries are what a refusal names.
pub fn unapplied_layers(
  enforcement: List(String),
  required: List(String),
) -> List(String) {
  let applied =
    enforcement
    |> list.filter(fn(entry) { !string.starts_with(entry, "skip:") })
    |> list.map(layer_tag)
  list.filter(required, fn(layer) { !list.contains(applied, layer) })
}

// The layer a report entry speaks for, stripped of its detail: the tag
// runs to the first ":" or "=", so "landlock:abi=5" is the landlock
// layer and "mounts:ro=2,rw=1,..." is the mount layer, while a plain
// "seccomp-net" is its own tag.
fn layer_tag(entry: String) -> String {
  let head =
    string.split_once(entry, ":")
    |> result.map(pair.first)
    |> result.unwrap(entry)
  string.split_once(head, "=")
  |> result.map(pair.first)
  |> result.unwrap(head)
}

// Whether an exec_exit's enforcement report falls short of what the
// policy called for: the helper set the degraded bool (bwrap absent),
// any `skip:` entry says a layer was not applied, or a required layer
// is simply absent from the list. The list, not the bool, is the ground
// truth a FullEnforcement demand trusts — and absence counts against it
// exactly as a skip does.
fn degraded_report(
  enforcement: List(String),
  degraded: Bool,
  required: List(String),
) -> Bool {
  degraded
  || list.any(enforcement, fn(entry) { string.starts_with(entry, "skip:") })
  || unapplied_layers(enforcement, required) != []
}

// Platform enforcement is strict about the platform's real boundary and
// permissive only about the exact Darwin gaps ADR-006 names. A tolerated
// layer must still speak: accepting an omitted report would recreate #54's
// silent-stage-2 hole under a different demand.
fn platform_degraded_report(
  enforcement: List(String),
  degraded: Bool,
  required: List(String),
  tolerated: List(String),
) -> Bool {
  degraded
  || list.any(enforcement, fn(entry) {
    string.starts_with(entry, "skip:")
    && !list.contains(tolerated, report_layer_tag(entry))
  })
  || unapplied_layers(enforcement, required) != []
  || unreported_layers(enforcement, tolerated) != []
}

fn unreported_layers(
  enforcement: List(String),
  expected: List(String),
) -> List(String) {
  let reported = list.map(enforcement, report_layer_tag)
  list.filter(expected, fn(layer) { !list.contains(reported, layer) })
}

// `layer_tag` deliberately sees a skip as the `skip` tag because the full
// demand removes skipped entries before calling it. Platform enforcement
// also needs the name *inside* a skip so it can compare that name with its
// narrow tolerated set.
fn report_layer_tag(entry: String) -> String {
  case string.starts_with(entry, "skip:") {
    True -> layer_tag(string.drop_start(entry, 5))
    False -> layer_tag(entry)
  }
}

// Pushes one inbound chunk through the pure deframer and applies
// whatever whole frames came out of it.
//
// The fault is weighed after the frames rather than before them: bytes
// that arrived ahead of the corruption are real and their frames are
// acted on, which is how a helper that dies mid-frame still delivers the
// `exec_exit` it managed to write.
fn handle_bytes(machine: Machine, bytes: BitArray) -> Machine {
  let framing.Pushed(deframer:, inbound:, fault:) =
    framing.push(machine.data.deframer, bytes)
  let machine = Machine(..machine, data: Data(..machine.data, deframer:))
  let machine = list.fold(inbound, machine, apply_inbound)
  case fault, machine.phase {
    _, Dead(_) -> machine
    None, _ -> machine
    Some(fault), _ -> mark_dead(machine, ChannelFault(fault:))
  }
}

// Applies one deframed item to the machine. Once the channel is dead
// further inbound items are dropped rather than acted on.
fn apply_inbound(machine: Machine, item: framing.Inbound) -> Machine {
  case machine.phase {
    Dead(_) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) ->
      case item {
        framing.Known(frame:) -> handle_frame(machine, frame)
        framing.UnknownInbound(id:, kind:) ->
          // Well-formed but unknown: answer in-band, keep the channel
          // (forward compatibility, mirrors the helper).
          send_frame(
            machine,
            framing.Frame(
              id:,
              body: framing.ErrorBody(code: "unknown_kind", message: kind),
            ),
          )
      }
  }
}

// Handles one well-formed frame. Returns the next machine;
// channel-fatal conditions mark it dead via `mark_dead`.
fn handle_frame(machine: Machine, frame: Frame) -> Machine {
  case frame.body {
    framing.Hello(proto:, peer: _, features:) ->
      handle_hello(machine, proto, features)
    framing.ExecOut(stream:, data:, bytes:, truncated:) ->
      handle_exec_out(machine, frame.id, stream, data, bytes, truncated)
    framing.ExecExit(
      code:,
      signal:,
      stdout_bytes:,
      stderr_bytes:,
      stdout_truncated:,
      stderr_truncated:,
      enforcement:,
      degraded:,
      wall_ms:,
      timed_out:,
      cancelled:,
    ) -> {
      let result =
        ExecResult(
          code:,
          signal:,
          stdout_bytes:,
          stderr_bytes:,
          stdout_truncated:,
          stderr_truncated:,
          enforcement:,
          degraded:,
          wall_ms:,
          timed_out:,
          cancelled:,
        )
      handle_exec_exit(machine, frame.id, result)
    }
    framing.Heartbeat -> handle_heartbeat_frame(machine, frame.id)
    framing.ErrorBody(code:, message:) ->
      handle_error_frame(machine, frame.id, code, message)

    // These kinds never flow helper-to-broker; a peer sending them is
    // broken or hostile, and the channel dies (spec §3.3 invariant 6).
    framing.ExecStart(..) ->
      mark_dead(machine, ProtocolViolation(kind: "exec_start"))
    framing.ExecStdin(..) ->
      mark_dead(machine, ProtocolViolation(kind: "exec_stdin"))
    framing.CapCall(..) ->
      mark_dead(machine, ProtocolViolation(kind: "cap_call"))
    framing.CapResult(..) ->
      mark_dead(machine, ProtocolViolation(kind: "cap_result"))

    // The hook pair belongs to the capability channel between a harness
    // and a persistent satellite (protocol-change/012); it never crosses
    // the exec channel in either direction, so a helper that sends one
    // is as broken as one that sends a `cap_call`.
    framing.HookCall(..) ->
      mark_dead(machine, ProtocolViolation(kind: "hook_call"))
    framing.HookResult(..) ->
      mark_dead(machine, ProtocolViolation(kind: "hook_result"))
    framing.Cancel -> mark_dead(machine, ProtocolViolation(kind: "cancel"))
  }
}

// The hello is legal exactly once, in exactly one state. A second one —
// or one in any state past the handshake — is a peer that has lost the
// protocol, and the channel dies.
fn handle_hello(
  machine: Machine,
  proto: Int,
  features: List(String),
) -> Machine {
  case machine.phase {
    AwaitingHello ->
      case proto == framing.protocol_version {
        False -> mark_dead(machine, ProtocolViolation(kind: "hello"))
        True -> complete_handshake(machine, features)
      }
    Idle(..) | Running(..) | Cancelling(..) | Dead(..) ->
      mark_dead(machine, ProtocolViolation(kind: "hello"))
  }
}

// Answers the helper's hello, unlinks the fd-3 policy file (proof it was
// read), and releases anything blocked on `await_ready`.
//
// The move to `Idle` at the end is also what retires the handshake
// deadline: it is a state timeout on `AwaitingHello`, so leaving that
// state is the cancellation and a fire that raced this transition is
// dropped by weft's timer book rather than handled.
fn complete_handshake(machine: Machine, features: List(String)) -> Machine {
  // Contract: the broker's hello precedes any other frame it sends. The
  // helper has proven it read the fd-3 policy, so the temp file can be
  // unlinked now.
  let #(data, id) = fresh_id(machine.data)
  let machine =
    send_frame(
      Machine(..machine, data:),
      framing.Frame(
        id:,
        body: framing.Hello(
          proto: framing.protocol_version,
          peer: "broker",
          features: [],
        ),
      ),
    )

  // A hello the channel refused to carry has already settled every
  // waiter and closed the transport. Promoting that to `Idle` would
  // resurrect a helper with no channel behind it, and the pool would
  // lend it out.
  //
  // Any `AwaitReady` postponed during the handshake replays against this
  // move to `Idle` — weft delivers it ahead of the mailbox, after this
  // function returns — and the `Idle(..), AwaitReady` arm in `handle`
  // answers it with `features`. Nothing here has to flush a queue.
  case machine.phase {
    Dead(_) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) -> {
      let data = run_cleanup(machine.data)
      Machine(phase: Idle(features:), data:)
    }
  }
}

fn handle_exec_out(
  machine: Machine,
  id: Int,
  stream: OutputStream,
  data: BitArray,
  bytes: Int,
  truncated: Bool,
) -> Machine {
  case running_with_id(machine.phase, id) {
    Some(exec) -> {
      process.send(
        exec.events,
        Output(stream:, data:, total_bytes: bytes, truncated:),
      )
      machine
    }

    // Stale output from a settled or unknown execution: dropped.
    None -> machine
  }
}

fn handle_exec_exit(machine: Machine, id: Int, result: ExecResult) -> Machine {
  use exec <- settle(machine, id)

  // The enforcement report is ground truth: a degraded run against a
  // FullEnforcement demand settles as a failure even though the helper
  // looked healthy at hello. `skip:` entries count as degradation
  // whatever the bool says — the bool only tracks the bwrap layer — and
  // so does a required layer the report never mentions, which is how a
  // dead stage 2 used to pass (#54).
  case
    exec.demand,
    degraded_report(result.enforcement, result.degraded, exec.required),
    platform_degraded_report(
      result.enforcement,
      result.degraded,
      exec.required,
      exec.tolerated,
    )
  {
    FullEnforcement, True, _ -> Failed(failure: DegradedExecution(result:))
    PlatformEnforcement, _, True -> Failed(failure: DegradedExecution(result:))
    FullEnforcement, False, _ -> Exited(result:)
    PlatformEnforcement, _, False -> Exited(result:)
    BestEffort, _, _ -> Exited(result:)
  }
}

fn handle_heartbeat_frame(machine: Machine, id: Int) -> Machine {
  case list.key_pop(machine.data.pending_heartbeats, id) {
    Ok(#(reply, pending_heartbeats)) -> {
      process.send(reply, Ok(Nil))
      Machine(..machine, data: Data(..machine.data, pending_heartbeats:))
    }

    // Not a caller probe: it answers the idle tick.
    Error(Nil) ->
      Machine(..machine, data: Data(..machine.data, tick_outstanding: False))
  }
}

fn handle_error_frame(
  machine: Machine,
  id: Int,
  code: String,
  message: String,
) -> Machine {
  use _exec <- settle(machine, id)
  Failed(failure: RefusedByHelper(code:, message:))
}

// Settles the running execution with `event` and returns the machine to
// `Idle`, if `id` is the execution's own.
//
// This is where a cancel escalation is called off, and it does so by
// arriving at `Idle` rather than by cancelling anything: the deadline is
// a state timeout on `Cancelling`, so the state change *is* the
// cancellation, and a deadline that fired into the mailbox a moment
// before is recognised as stale and dropped. The hand-rolled
// `cancel_pending_timer` this replaces had to be remembered at all three
// settle sites, and the timer's own message had to carry an execution id
// so its handler could tell a stale fire from a live one.
//
// An id that correlates to nothing is dropped: stale output from a
// settled execution, or the id 0 that usually precedes a channel close,
// where the close itself settles what is left.
fn settle(
  machine: Machine,
  id: Int,
  event: fn(RunningExec) -> ExecEvent,
) -> Machine {
  case machine.phase {
    Running(features:, exec:) | Cancelling(features:, exec:) ->
      case exec.id == id {
        True -> {
          process.send(exec.events, event(exec))
          Machine(..machine, phase: Idle(features:))
        }
        False -> machine
      }
    AwaitingHello | Idle(..) | Dead(..) -> machine
  }
}

// The running execution, when `id` correlates to it. `Cancelling` counts:
// output keeps arriving between the TERM and the exit that answers it.
fn running_with_id(phase: Phase, id: Int) -> Option(RunningExec) {
  case phase {
    Running(exec:, ..) | Cancelling(exec:, ..) ->
      case exec.id == id {
        True -> Some(exec)
        False -> None
      }
    AwaitingHello | Idle(..) | Dead(..) -> None
  }
}

fn fresh_id(data: Data) -> #(Data, Int) {
  let id = data.next_id
  #(Data(..data, next_id: id + 1), id)
}

// --- sending and death --------------------------------------------------

// Encodes and writes one frame; on any write failure the channel is
// declared dead in the returned machine.
fn send_frame(machine: Machine, frame: Frame) -> Machine {
  case framing.encode(frame) {
    // Unencodable frames are broker bugs (ids are minted positive,
    // bodies are typed); settle as SendFailed rather than crash.
    Error(_) -> mark_dead(machine, SendFailed)
    Ok(bytes) ->
      case transport_send(machine.data.wire_out, bytes) {
        Ok(Nil) -> machine
        Error(Nil) -> mark_dead(machine, SendFailed)
      }
  }
}

// Writes a frame and hands the machine back to weft as a step.
//
// `advance` is what makes a failed write terminal without a second code
// path: a successful write leaves the phase alone, so the step is not a
// state change and every armed deadline survives it, while a failed one
// has already moved the phase to `Dead` and the same call is that move.
fn send_or_die(
  machine: Machine,
  frame: Frame,
) -> state_machine.Next(Phase, Data, Msg) {
  advance(send_frame(machine, frame))
}

fn transport_send(wire_out: Wire, bytes: BitArray) -> Result(Nil, Nil) {
  case wire_out {
    WirePort(port:, os_pid: _, cleanup: _) -> ffi_port.port_send(port, bytes)
    WireChannel(send:, close: _) -> {
      send(bytes)
      Ok(Nil)
    }
  }
}

fn close_transport(wire_out: Wire) -> Nil {
  case wire_out {
    WirePort(port:, os_pid: _, cleanup: _) -> ffi_port.close_port(port)
    WireChannel(send: _, close:) -> close()
  }
}

// Last-resort kill: close the channel and SIGKILL the OS process.
fn kill_transport(wire_out: Wire) -> Nil {
  case wire_out {
    WirePort(port:, os_pid:, cleanup: _) -> {
      ffi_port.close_port(port)
      case os_pid {
        Some(pid) -> ffi_port.kill_os_process(pid)
        None -> Nil
      }
    }
    WireChannel(send: _, close:) -> close()
  }
}

fn run_cleanup(data: Data) -> Data {
  case data.cleaned {
    True -> data
    False -> {
      case data.wire_out {
        WirePort(port: _, os_pid: _, cleanup:) -> cleanup()
        WireChannel(send: _, close: _) -> Nil
      }
      Data(..data, cleaned: True)
    }
  }
}

// Marks the helper dead and settles everything in flight in-band. The
// machine stays alive answering requests with the failure, so callers
// racing the death get errors, not crashed calls; the pool retires it.
//
// `Dead` is absorbing, and the first arm is what makes it so: a second
// failure arriving behind the first — a channel close chasing a framing
// fault — must not re-notify callers who have already been told.
fn mark_dead(machine: Machine, failure: ExecFailure) -> Machine {
  case machine.phase {
    Dead(_) -> machine
    AwaitingHello | Idle(..) | Running(..) | Cancelling(..) -> {
      let data = notify_death(machine, failure)
      close_transport(data.wire_out)
      Machine(phase: Dead(failure:), data: run_cleanup(data))
    }
  }
}

// `mark_dead` as a step. The move to `Dead` is a real state change, so
// it takes whichever deadline the phase being left had armed with it.
fn die(
  machine: Machine,
  failure: ExecFailure,
) -> state_machine.Next(Phase, Data, Msg) {
  advance(mark_dead(machine, failure))
}

// Tells everything waiting on this helper that it has failed, and
// returns the data with those queues emptied.
//
// The execution in flight needs no timer cancelled on its way out. It
// lives in the state, and the caller's move to `Dead` is what takes a
// pending cancel escalation with it — the deletion this port is for.
//
// An `AwaitReady` postponed during the handshake needs no flush here
// either: this move to `Dead` is exactly the state change weft replays
// it against, and the `Dead(..), AwaitReady` arm in `handle` answers it
// with `failure`.
fn notify_death(machine: Machine, failure: ExecFailure) -> Data {
  case machine.phase {
    Running(exec:, ..) | Cancelling(exec:, ..) ->
      process.send(exec.events, Failed(failure:))
    AwaitingHello | Idle(..) | Dead(..) -> Nil
  }
  list.each(machine.data.pending_heartbeats, fn(pending) {
    process.send(pending.1, Error(failure))
  })
  Data(..machine.data, pending_heartbeats: [])
}

// --- what this host's helper can be asked to do --------------------------

/// Whether `loom-exec` has a jail for the operating system it will run
/// on. Not a probe of the kernel: the question is whether Loom has a
/// confinement implementation for this OS at all, which is a fact about
/// the helper build and mirrors its own `jail.PlatformFor`.
pub type HostPlatform {
  /// Loom has a jail here. The helper serves with no extra argument,
  /// and a missing kernel layer is reported as a skip, not a refusal.
  JailedHost

  /// Loom has no jail here (the Windows sandbox is WP-H phase 3 and remains
  /// unbuilt). `loom-exec` refuses to serve without `--allow-unenforced`, and
  /// with it confines nothing at all.
  UnjailedHost(os_name: String)
}

/// The platform this VM — and therefore the helper it spawns — runs on.
pub fn host_platform() -> HostPlatform {
  host_platform_for(ffi_os.os_name())
}

/// The pure decision, taking `os:type/0`'s name so the answers no Linux
/// host can reach are still testable from Linux. Kept deliberately in step
/// with the helper's own `PlatformFor`: Linux is phase 1, macOS is phase 2,
/// and Windows remains unimplemented phase 3.
pub fn host_platform_for(os_name: String) -> HostPlatform {
  case os_name {
    "linux" | "darwin" -> JailedHost
    other -> UnjailedHost(os_name: other)
  }
}

/// The extra helper arguments that let `loom-exec` serve on a platform
/// with no jail — and `[]` everywhere else.
///
/// This is the only place `--allow-unenforced` should come from. The
/// flag is not a degraded-mode switch: on a host where Loom *has* a
/// jail, a missing bwrap or Landlock is reported honestly and the
/// broker's own `FullEnforcement` demand decides what to do about it.
/// Passing the flag there would silence a report instead of a refusal.
pub fn unenforced_helper_args(platform: HostPlatform) -> List(String) {
  case platform {
    JailedHost -> []
    UnjailedHost(..) -> ["--allow-unenforced"]
  }
}

/// The marker every declared platform skip carries. `.github/declared-skips`
/// matches on it, so a suite that stops needing to skip stops matching
/// and fails the census — which is the point.
pub const unjailed_skip_marker = "no loom-exec jail for this platform"

/// Why a suite that spawns a real helper must skip rather than run, or
/// `None` when it may run.
///
/// Running under `--allow-unenforced` is the other option and is not
/// what these suites should do: they exercise the sandbox, and a run
/// with nothing enforced would report success for a jail that was never
/// built. Skipping with a reason a machine can check is the honest half
/// of that trade.
pub fn unjailed_skip_reason(platform: HostPlatform) -> Option(String) {
  case platform {
    JailedHost -> None
    UnjailedHost(os_name:) ->
      Some(
        unjailed_skip_marker
        <> " ("
        <> os_name
        <> "): loom-exec refuses to serve without --allow-unenforced, and "
        <> "running unenforced would prove nothing about a jail that does "
        <> "not exist",
      )
  }
}

// --- spawning the real helper -------------------------------------------

/// Configuration for spawning a real `loom-exec` helper process.
pub type SpawnConfig {
  SpawnConfig(
    /// Absolute path to the `loom-exec` binary.
    helper_path: String,
    /// The POSIX shell used for the fd-3 redirection (usually
    /// "/bin/sh").
    shell_path: String,
    /// The base policy delivered on fd 3.
    base_policy: SandboxPolicy,
    /// Extra arguments appended to the helper's own command line, after
    /// the fd-3 redirection is in place. Almost always `[]`.
    ///
    /// Two things need it and neither can go through the environment: a
    /// delegated cgroup base (`--cgroup-base DIR`), and, on a platform
    /// `loom-exec` has no jail for, the `--allow-unenforced` opt-out
    /// without which the helper refuses to serve at all. Erlang ports
    /// cannot set a child's environment, so the command line is the only
    /// channel the broker has.
    ///
    /// `--allow-unenforced` belongs here only on an *unsupported*
    /// platform, never on a merely degraded one: a Linux host missing
    /// bwrap still enforces something and could enforce the rest, while
    /// a build with no jail enforces nothing. `unenforced_helper_args`
    /// draws that line; do not hand-roll it.
    helper_args: List(String),
    /// Directory for the transient mode-0600 policy file (created
    /// mode 0700).
    tmp_dir: String,
    /// See `HelperConfig`.
    handshake_timeout_ms: Int,
    /// See `HelperConfig`.
    cancel_grace_ms: Int,
    /// See `HelperConfig`.
    heartbeat_interval_ms: Int,
  )
}

/// Why spawning a helper failed.
pub type SpawnError {
  /// The base policy could not be encoded.
  PolicyUnencodable(error: msgpack.EncodeError)

  /// The transient policy file could not be written.
  PolicyFileFailed

  /// The OS process could not be started.
  PortOpenFailed

  /// The broker-side actor failed to start.
  ActorFailed(error: actor.StartError)

  /// The helper started but its handshake failed.
  HandshakeFailed(failure: ExecFailure)
}

/// Spawns a real helper: writes the base policy to a private temp file,
/// starts `loom-exec` through `/bin/sh -c 'exec 3<"$2" "$1"'` so the
/// policy arrives on fd 3, and waits for the handshake. The temp file
/// is unlinked as soon as the helper's hello arrives.
pub fn spawn_helper(config: SpawnConfig) -> Result(Helper, SpawnError) {
  use policy_bytes <- result.try(
    policy.encode(config.base_policy)
    |> result.map_error(fn(error) { PolicyUnencodable(error:) }),
  )
  let file_name =
    "policy-"
    <> bit_array.base16_encode(ffi_crypto.strong_random_bytes(8))
    <> ".msgpack"
  use policy_path <- result.try(
    ffi_port.write_private_file(config.tmp_dir, file_name, policy_bytes)
    |> result.replace_error(PolicyFileFailed),
  )
  let cleanup = fn() { ffi_port.delete_file(policy_path) }

  // $0 is a display name; $1 the helper binary; $2 the policy file;
  // everything after that is the helper's own arguments. Positional
  // parameters avoid every quoting pitfall in the paths, and `shift 2`
  // leaves "$@" holding exactly the extra arguments — empty when there
  // are none, which expands to nothing rather than to an empty word.
  let args =
    list.append(
      [
        "-c",
        "helper=$1; policy=$2; shift 2; exec 3<\"$policy\" \"$helper\" \"$@\"",
        "loom-exec",
        config.helper_path,
        policy_path,
      ],
      config.helper_args,
    )
  let transport = PortTransport(executable: config.shell_path, args:, cleanup:)
  let helper_config =
    HelperConfig(
      transport:,
      handshake_timeout_ms: config.handshake_timeout_ms,
      cancel_grace_ms: config.cancel_grace_ms,
      heartbeat_interval_ms: config.heartbeat_interval_ms,
    )
  case start(helper_config) {
    Error(actor.InitFailed(message)) if message == port_open_failure -> {
      cleanup()
      Error(PortOpenFailed)
    }
    Error(error) -> {
      cleanup()
      Error(ActorFailed(error:))
    }
    Ok(helper) -> {
      // The actor unlinks the file itself on every death it can see;
      // the janitor covers the deaths it cannot (brutal kill before or
      // after hello). Deletion is idempotent, so both firing is fine.
      watch_cleanup(pid(helper), cleanup)
      case await_ready(helper, waiting: config.handshake_timeout_ms + 1000) {
        Ok(_features) -> Ok(helper)
        Error(failure) -> {
          shutdown(helper)
          Error(HandshakeFailed(failure:))
        }
      }
    }
  }
}

/// Spawns a janitor process that runs `cleanup` when `pid` dies, for
/// whatever reason — including a brutal kill that skips every in-actor
/// path. `cleanup` must be idempotent: the watched process usually also
/// cleans up itself on its graceful paths. A whole-VM SIGKILL still
/// skips this (nothing survives to run it); see the module doc.
@internal
pub fn watch_cleanup(pid: Pid, cleanup: fn() -> Nil) -> Nil {
  process.spawn_unlinked(fn() {
    let monitor = process.monitor(pid)
    let _down =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive_forever
    cleanup()
  })
  Nil
}

// --- the pool -----------------------------------------------------------

/// A fixed-size pool of helpers with checkout/checkin semantics. One
/// checkout maps to one helper, which runs one execution at a time —
/// the helper contract is enforced structurally. Dead helpers are
/// retired at checkout/checkin and capacity is respawned lazily on the
/// next checkout.
pub opaque type Pool {
  Pool(subject: Subject(PoolMsg))
}

/// The pool actor's message type. Opaque.
pub opaque type PoolMsg {
  Checkout(reply: Subject(Result(Helper, CheckoutError)))
  Checkin(helper: Helper)
  StopPool
}

/// Why a checkout was refused.
pub type CheckoutError {
  /// Every helper slot is lent out.
  AllBusy(size: Int)

  /// A fresh helper could not be spawned.
  SpawnFailed(error: SpawnError)

  /// The pool itself did not answer, or was not alive to be asked. It
  /// is deliberately not `AllBusy`: a full pool is congestion that
  /// clears as running executions end, and waiting is the right
  /// response to it, while this clears only if the pool recovers and
  /// waiting on it spends a caller's whole budget to learn nothing. A
  /// borrower that cannot tell the two apart cannot choose.
  PoolUnavailable
}

type PoolState {
  PoolState(
    size: Int,
    spawn: fn() -> Result(Helper, SpawnError),
    idle: List(Helper),
    lent: Int,
  )
}

/// The pool ceiling a host gets when it names no other: the node's
/// scheduler count, clamped by `pool_size_for`. Every helper is an OS
/// process running bwrap and a jail, so this is a real resource limit
/// rather than a policy dial — but it is also the ceiling on how wide a
/// parallel tool batch can actually run, so `2` was never a considered
/// value for it.
pub fn default_pool_size() -> Int {
  pool_size_for(schedulers: ffi_os.schedulers_online())
}

/// The default pool ceiling for a node with `schedulers` schedulers
/// online: the scheduler count, floored at four and capped at sixteen.
///
/// The floor is the point of the derivation. A helper spends nearly all
/// its life blocked on a child process rather than on a scheduler, so
/// scheduler count is a proxy for how big the machine is, not for how
/// much work the pool can carry — a single-core CI box still wants room
/// for a batch of a few concurrent reads. The cap is the other half:
/// sixteen simultaneous jails is already far more memory and pid
/// pressure than any batch we have seen ask for, and a 96-core build
/// server should not silently offer ninety-six.
///
/// ## Examples
///
/// ```gleam
/// assert exec.pool_size_for(schedulers: 1) == 4
/// assert exec.pool_size_for(schedulers: 8) == 8
/// assert exec.pool_size_for(schedulers: 96) == 16
/// ```
///
pub fn pool_size_for(schedulers schedulers: Int) -> Int {
  int.clamp(schedulers, min: min_pool_size, max: max_pool_size)
}

/// The smallest default pool: enough for a handful of concurrent reads
/// even on a one-scheduler node.
pub const min_pool_size = 4

/// The largest default pool. See `pool_size_for`.
pub const max_pool_size = 16

/// Starts a pool of up to `size` helpers, spawned lazily with `spawn`
/// (a seam: production passes `exec.spawn_helper` applied to a
/// `SpawnConfig`; tests pass a fake-transport spawner).
///
/// Spawning runs inside the pool actor, which is deliberate rather than
/// merely tolerated: the pool has exactly one borrower at run time —
/// the broker's `checkout` seam — and the broker is a serial actor, so
/// there is never a second checkout in flight to be delayed behind a
/// spawn. (`client/serve.degraded` borrows once more, at boot, before
/// the broker serves anything.) What growing the pool *does* cost is
/// paid by the broker: it blocks for one helper handshake per slot the
/// pool has not filled yet, so the first wide batch of a session
/// dispatches behind a short series of spawns. Pre-warming is the fix
/// if that ever shows up in a trace; it has not.
pub fn start_pool(
  size size: Int,
  spawn spawn: fn() -> Result(Helper, SpawnError),
) -> Result(Pool, actor.StartError) {
  actor.new(PoolState(size:, spawn:, idle: [], lent: 0))
  |> actor.on_message(handle_pool)
  |> actor.start
  |> result.map(fn(started) { Pool(subject: started.data) })
}

/// Borrows a ready helper, spawning one if the pool is under capacity.
/// The borrower must `checkin` when done, whatever happened.
///
/// A pool that does not answer within `timeout`, or is not alive to be
/// asked, is `PoolUnavailable` rather than a fault. The borrower this
/// exists for is the broker, calling it from inside its own message
/// handler, so a panic here is not one failed clearance but every
/// in-flight strand's verdict — the very failure the pool's readiness
/// probe was moved onto `try_call` to avoid, one level up.
///
/// The cost is real and worth naming: a pool that answers *after* the
/// window sends `Ok(helper)` to a reply subject nobody is selecting on,
/// and that helper stays counted as lent with no borrower to check it
/// in. It is bounded by the pool's own size — once `lent` reaches
/// `size` every later checkout is `AllBusy` — and it needs a pool that
/// was blocked past a borrower's whole window and then recovered.
/// Against it stands a dead broker, which strands those same helpers
/// and loses everything else besides.
pub fn checkout(
  pool: Pool,
  waiting timeout: Int,
) -> Result(Helper, CheckoutError) {
  case call.try_call(pool.subject, waiting: timeout, sending: Checkout) {
    Ok(outcome) -> outcome
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(PoolUnavailable)
  }
}

/// Returns a borrowed helper. Dead helpers are retired (their slot
/// respawns lazily); live ones rejoin the idle set.
pub fn checkin(pool: Pool, helper: Helper) -> Nil {
  process.send(pool.subject, Checkin(helper:))
}

/// Stops the pool actor and shuts down every idle helper. Lent helpers
/// are the borrowers' to shut down via `checkin` having no pool — in
/// practice `stop_pool` runs at session close, after all strands quiesce.
pub fn stop_pool(pool: Pool) -> Nil {
  process.send(pool.subject, StopPool)
}

fn handle_pool(
  state: PoolState,
  message: PoolMsg,
) -> actor.Next(PoolState, PoolMsg) {
  case message {
    Checkout(reply:) -> {
      let #(state, outcome) = next_helper(state)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Checkin(helper:) -> handle_checkin(state, helper)
    StopPool -> {
      list.each(state.idle, shutdown)
      actor.stop()
    }
  }
}

// Returns a borrowed helper. Dead ones rejoin as `helper_ready` refuses
// them; live ones fall through to `Checkin`'s ordinary bookkeeping.
fn handle_checkin(
  state: PoolState,
  helper: Helper,
) -> actor.Next(PoolState, PoolMsg) {
  let lent = case state.lent > 0 {
    True -> state.lent - 1
    False -> 0
  }
  case helper_ready(helper) {
    True ->
      actor.continue(PoolState(..state, lent:, idle: [helper, ..state.idle]))
    False -> {
      shutdown(helper)
      actor.continue(PoolState(..state, lent:))
    }
  }
}

fn next_helper(
  state: PoolState,
) -> #(PoolState, Result(Helper, CheckoutError)) {
  case state.idle {
    [helper, ..idle] ->
      case helper_ready(helper) {
        True -> #(PoolState(..state, idle:, lent: state.lent + 1), Ok(helper))
        False -> {
          shutdown(helper)
          next_helper(PoolState(..state, idle:))
        }
      }
    [] ->
      case state.lent < state.size {
        False -> #(state, Error(AllBusy(size: state.size)))
        True -> spawn_new(state)
      }
  }
}

fn spawn_new(state: PoolState) -> #(PoolState, Result(Helper, CheckoutError)) {
  case state.spawn() {
    Ok(helper) -> #(PoolState(..state, lent: state.lent + 1), Ok(helper))
    Error(error) -> #(state, Error(SpawnFailed(error:)))
  }
}

// Whether an idle helper is still fit to lend. The probe round-trip
// runs inside the pool actor, so its timeout is time the next checkout
// may wait — but an idle helper is by construction running nothing and
// answers in microseconds, and one that cannot answer within
// `ready_probe_ms` is wedged, which is exactly what this is here to
// catch. The cost is therefore bounded by the number of *wedged*
// helpers and paid once each: an unanswered probe retires the helper
// (`next_helper` shuts it down and moves on, `handle_checkin` refuses
// to take it back), so it is never probed again. Shortening the timeout
// to make a larger pool cheaper would trade that for retiring healthy
// helpers under load, which is the worse failure.
//
// That accounting is only true because the probe cannot fault. It once
// had to be a private `try_call` to get that, because the public
// `status` panicked on a timeout — inside the pool actor that is not a
// retired helper, it is a dead pool, and a dead pool kills the broker
// with it. `status` now answers `StatusUnresponsive` instead, so the
// probe is the ordinary public question plus this function's policy on
// the answer: only a helper that says it is ready gets lent.
fn helper_ready(helper: Helper) -> Bool {
  case process.is_alive(helper.pid) {
    False -> False
    True ->
      case status(helper, waiting: ready_probe_ms) {
        StatusReady(_) -> True
        StatusStarting | StatusDead(_) | StatusUnresponsive -> False
      }
  }
}

// How long an idle helper has to answer a readiness probe before the
// pool treats it as wedged. See `helper_ready`.
const ready_probe_ms = 1000
