//// The ExecPool: supervised lifecycle of `loom-exec` sandbox helpers.
////
//// Each helper is one OS process speaking the Part 1.4 framing protocol
//// on stdio, running **one execution at a time** (the helper answers a
//// second `exec_start` with a `busy` error); concurrency lives here, in
//// the pool, by running more helpers. A broker-side `Helper` actor owns
//// each helper's channel: it performs the hello handshake, deframes
//// inbound bytes with the pure `broker/framing` deframer, streams
//// output events to the caller, heartbeats the helper while idle, and
//// mirrors the cancel escalation (the helper TERMs the payload and then
//// KILLs its pgroup within 2s of `cancel`; if no `exec_exit` arrives
//// within the grace period the actor kills the whole helper — belt and
//// braces). The two rungs are addressed differently under a jail, and
//// what the exit reports differs with them: see `cancel` below.
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
//// `ChannelTransport` lets tests drive the same actor with an
//// in-process fake speaking the same bytes. Helper failure of any kind
//// settles in-band as an `ExecFailure` event — never a crash of the
//// caller.

import broker/framing.{type Fault, type Frame, type OutputStream}
import broker/internal/ffi_crypto
import broker/internal/ffi_os
import broker/internal/ffi_port
import broker/policy.{type SandboxPolicy}
import core/msgpack
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Pid, type Subject, type Timer}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

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

/// The helper actor's message type. Opaque; constructed only through
/// this module's API.
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
  CancelDeadline(exec_id: Int)
  HandshakeDeadline
  HeartbeatTick
  Heartbeat(reply: Subject(Result(Nil, ExecFailure)))
  Shutdown
  FromWire(event: WireEvent)
}

type Phase {
  AwaitingHello
  Ready(features: List(String))
  Dead(failure: ExecFailure)
}

type RunningExec {
  RunningExec(
    id: Int,
    events: Subject(ExecEvent),
    demand: EnforcementDemand,
    cancel_timer: Option(Timer),
  )
}

type State {
  State(
    config: HelperConfig,
    wire_out: Wire,
    commands: Subject(Msg),
    deframer: framing.Deframer,
    phase: Phase,
    next_id: Int,
    exec: Option(RunningExec),
    ready_waiters: List(Subject(Result(List(String), ExecFailure))),
    pending_heartbeats: List(#(Int, Subject(Result(Nil, ExecFailure)))),
    tick_outstanding: Bool,
    cleaned: Bool,
  )
}

// --- helper lifecycle ---------------------------------------------------

/// Starts a helper actor over a transport. The handshake runs
/// asynchronously; use `await_ready` (or `spawn_helper`, which does) to
/// learn the features or the failure.
pub fn start(config: HelperConfig) -> Result(Helper, actor.StartError) {
  actor.new_with_initialiser(5000, fn(commands) {
    let wire = process.new_subject()
    let base =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, FromWire)
    // The port must be opened by this process: port messages are
    // delivered to the opener, and the opener is where the selector
    // lives.
    use #(wire_out, selector) <- result.try(case config.transport {
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
    })
    // The handshake must complete within its deadline or the helper is
    // declared dead — this bounds every `await_ready` call.
    let _ =
      process.send_after(
        commands,
        config.handshake_timeout_ms,
        HandshakeDeadline,
      )
    let state =
      State(
        config:,
        wire_out:,
        commands:,
        deframer: framing.deframer(),
        phase: AwaitingHello,
        next_id: 1,
        exec: None,
        ready_waiters: [],
        pending_heartbeats: [],
        tick_outstanding: False,
        cleaned: False,
      )
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(#(commands, wire))
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) {
    let #(commands, wire) = started.data
    Helper(commands:, wire:, pid: started.pid)
  })
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
/// features. Bounded by the config's handshake timeout.
pub fn await_ready(
  helper: Helper,
  waiting timeout: Int,
) -> Result(List(String), ExecFailure) {
  process.call(helper.commands, waiting: timeout, sending: AwaitReady)
}

/// The helper's current lifecycle position.
pub fn status(helper: Helper, waiting timeout: Int) -> HelperStatus {
  process.call(helper.commands, waiting: timeout, sending: QueryStatus)
}

/// Dispatches an execution. On `Ok`, events stream to `events` and end
/// with exactly one `Exited` or `Failed`; an `Error` is a dispatch-time
/// refusal and nothing was sent to the helper.
pub fn run(
  helper: Helper,
  request: ExecRequest,
  events events: Subject(ExecEvent),
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  process.call(helper.commands, waiting: timeout, sending: fn(reply) {
    Run(request:, events:, reply:)
  })
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
/// echo.
pub fn heartbeat(
  helper: Helper,
  waiting timeout: Int,
) -> Result(Nil, ExecFailure) {
  process.call(helper.commands, waiting: timeout, sending: Heartbeat)
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

// --- actor internals ----------------------------------------------------

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    FromWire(WireBytes(data:)) -> handle_bytes(state, data)
    FromWire(WireClosed(status:)) -> die(state, ChannelClosed(status:))
    AwaitReady(reply:) ->
      case state.phase {
        Ready(features:) -> {
          process.send(reply, Ok(features))
          actor.continue(state)
        }
        Dead(failure:) -> {
          process.send(reply, Error(failure))
          actor.continue(state)
        }
        AwaitingHello ->
          actor.continue(
            State(..state, ready_waiters: [reply, ..state.ready_waiters]),
          )
      }
    QueryStatus(reply:) -> {
      let helper_status = case state.phase {
        AwaitingHello -> StatusStarting
        Ready(features:) -> StatusReady(features:)
        Dead(failure:) -> StatusDead(failure:)
      }
      process.send(reply, helper_status)
      actor.continue(state)
    }
    Run(request:, events:, reply:) -> handle_run(state, request, events, reply)
    Stdin(data:, eof:) ->
      case state.exec {
        None -> actor.continue(state)
        Some(exec) ->
          send_or_die(
            state,
            framing.Frame(id: exec.id, body: framing.ExecStdin(data:, eof:)),
          )
      }
    CancelExec ->
      case state.exec {
        None -> actor.continue(state)
        Some(exec) ->
          case exec.cancel_timer {
            // Already cancelling: idempotent, keep the first deadline.
            Some(_) -> actor.continue(state)
            None -> {
              let timer =
                process.send_after(
                  state.commands,
                  state.config.cancel_grace_ms,
                  CancelDeadline(exec_id: exec.id),
                )
              let exec = RunningExec(..exec, cancel_timer: Some(timer))
              let state = State(..state, exec: Some(exec))
              send_or_die(
                state,
                framing.Frame(id: exec.id, body: framing.Cancel),
              )
            }
          }
      }
    CancelDeadline(exec_id:) ->
      case state.exec {
        // The exec_exit arrived in time; nothing to escalate.
        None -> actor.continue(state)
        Some(exec) ->
          case exec.id == exec_id {
            // The exec that scheduled this deadline already settled and
            // a new one started (one helper runs one execution at a
            // time, so ids never overlap) — a stale timer must not
            // escalate against a request it knows nothing about.
            False -> actor.continue(state)
            True -> {
              // Belt and braces: the helper missed its own 2s ladder.
              kill_transport(state.wire_out)
              die(state, CancelEscalated)
            }
          }
      }
    HandshakeDeadline ->
      case state.phase {
        AwaitingHello -> die(state, HandshakeTimeout)
        Ready(_) | Dead(_) -> actor.continue(state)
      }
    HeartbeatTick ->
      case state.phase {
        Ready(_) ->
          case state.tick_outstanding {
            True -> die(state, HeartbeatMissed)
            False -> {
              let #(state, id) = fresh_id(state)
              let state = State(..state, tick_outstanding: True)
              schedule_tick(state)
              send_or_die(state, framing.Frame(id:, body: framing.Heartbeat))
            }
          }
        AwaitingHello | Dead(_) -> actor.continue(state)
      }
    Heartbeat(reply:) ->
      case state.phase {
        Ready(_) -> {
          let #(state, id) = fresh_id(state)
          let state =
            State(..state, pending_heartbeats: [
              #(id, reply),
              ..state.pending_heartbeats
            ])
          send_or_die(state, framing.Frame(id:, body: framing.Heartbeat))
        }
        AwaitingHello -> {
          process.send(reply, Error(NotReady))
          actor.continue(state)
        }
        Dead(failure:) -> {
          process.send(reply, Error(failure))
          actor.continue(state)
        }
      }
    Shutdown -> {
      let state = notify_death(state, ChannelClosed(status: 0))
      close_transport(state.wire_out)
      run_cleanup(state)
      actor.stop()
    }
  }
}

fn handle_run(
  state: State,
  request: ExecRequest,
  events: Subject(ExecEvent),
  reply: Subject(Result(Nil, ExecFailure)),
) -> actor.Next(State, Msg) {
  case state.phase, state.exec {
    Dead(failure:), _ -> {
      process.send(reply, Error(failure))
      actor.continue(state)
    }
    AwaitingHello, _ -> {
      process.send(reply, Error(NotReady))
      actor.continue(state)
    }
    Ready(_), Some(_) -> {
      process.send(reply, Error(HelperBusy))
      actor.continue(state)
    }
    Ready(features:), None ->
      case request.demand, degraded_features(features) {
        FullEnforcement, True -> {
          process.send(reply, Error(DegradedHelper(features:)))
          actor.continue(state)
        }
        _, _ -> {
          let #(state, id) = fresh_id(state)
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
              cancel_timer: None,
            )
          let state = State(..state, exec: Some(exec))
          process.send(reply, Ok(Nil))
          send_or_die(state, frame)
        }
      }
  }
}

// A helper advertising "degraded" (bwrap unavailable) cannot provide
// full enforcement. Per-exec ground truth is additionally checked on
// exec_exit.
fn degraded_features(features: List(String)) -> Bool {
  list.contains(features, "degraded")
}

// Whether an exec_exit's enforcement report shows degradation: the
// helper set the degraded bool (bwrap absent), or any `skip:` entry
// says a layer the policy called for was not applied. The list, not
// the bool, is the ground truth a FullEnforcement demand trusts.
fn degraded_report(enforcement: List(String), degraded: Bool) -> Bool {
  degraded
  || list.any(enforcement, fn(entry) { string.starts_with(entry, "skip:") })
}

fn handle_bytes(state: State, data: BitArray) -> actor.Next(State, Msg) {
  let framing.Pushed(deframer:, inbound:, fault:) =
    framing.push(state.deframer, data)
  let state = State(..state, deframer:)
  let state =
    list.fold(inbound, state, fn(state, item) {
      case state.phase {
        Dead(_) -> state
        AwaitingHello | Ready(_) ->
          case item {
            framing.Known(frame:) -> handle_frame(state, frame)
            framing.UnknownInbound(id:, kind:) ->
              // Well-formed but unknown: answer in-band, keep the
              // channel (forward compatibility, mirrors the helper).
              send_frame(
                state,
                framing.Frame(
                  id:,
                  body: framing.ErrorBody(code: "unknown_kind", message: kind),
                ),
              )
          }
      }
    })
  case fault, state.phase {
    _, Dead(_) -> actor.continue(state)
    None, _ -> actor.continue(state)
    Some(fault), _ -> die(state, ChannelFault(fault:))
  }
}

// Handles one well-formed frame. Returns the next state; channel-fatal
// conditions mark the state dead via `mark_dead`.
fn handle_frame(state: State, frame: Frame) -> State {
  case frame.body {
    framing.Hello(proto:, peer: _, features:) ->
      case state.phase {
        AwaitingHello ->
          case proto == framing.protocol_version {
            False -> mark_dead(state, ProtocolViolation(kind: "hello"))
            True -> {
              // Contract: the broker's hello precedes any other frame
              // it sends. The helper has proven it read the fd-3
              // policy, so the temp file can be unlinked now.
              let #(state, id) = fresh_id(state)
              let state =
                send_frame(
                  state,
                  framing.Frame(
                    id:,
                    body: framing.Hello(
                      proto: framing.protocol_version,
                      peer: "broker",
                      features: [],
                    ),
                  ),
                )
              let state = run_cleanup(state)
              let state = State(..state, phase: Ready(features:))
              list.each(list.reverse(state.ready_waiters), fn(waiter) {
                process.send(waiter, Ok(features))
              })
              schedule_tick(state)
              State(..state, ready_waiters: [])
            }
          }
        Ready(_) | Dead(_) -> mark_dead(state, ProtocolViolation(kind: "hello"))
      }
    framing.ExecOut(stream:, data:, bytes:, truncated:) ->
      case running_with_id(state, frame.id) {
        Some(exec) -> {
          process.send(
            exec.events,
            Output(stream:, data:, total_bytes: bytes, truncated:),
          )
          state
        }
        // Stale output from a settled or unknown execution: dropped.
        None -> state
      }
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
    ) ->
      case running_with_id(state, frame.id) {
        Some(exec) -> {
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
            )
          cancel_pending_timer(exec)
          // The enforcement report is ground truth: a degraded run
          // against a FullEnforcement demand settles as a failure even
          // though the helper looked healthy at hello. `skip:` entries
          // count as degradation whatever the bool says — the bool only
          // tracks the bwrap layer, while a skip marks any layer the
          // policy called for that was not applied.
          let event = case exec.demand, degraded_report(enforcement, degraded) {
            FullEnforcement, True -> Failed(failure: DegradedExecution(result:))
            FullEnforcement, False | BestEffort, _ -> Exited(result:)
          }
          process.send(exec.events, event)
          State(..state, exec: None)
        }
        None -> state
      }
    framing.Heartbeat ->
      case list.key_pop(state.pending_heartbeats, frame.id) {
        Ok(#(reply, pending_heartbeats)) -> {
          process.send(reply, Ok(Nil))
          State(..state, pending_heartbeats:)
        }
        // Not a caller probe: it answers the idle tick.
        Error(Nil) -> State(..state, tick_outstanding: False)
      }
    framing.ErrorBody(code:, message:) ->
      case running_with_id(state, frame.id) {
        Some(exec) -> {
          cancel_pending_timer(exec)
          process.send(
            exec.events,
            Failed(failure: RefusedByHelper(code:, message:)),
          )
          State(..state, exec: None)
        }
        // An error we cannot correlate (id 0 usually precedes a close;
        // the close itself settles things). Dropped.
        None -> state
      }
    // These kinds never flow helper-to-broker; a peer sending them is
    // broken or hostile, and the channel dies (spec §3.3 invariant 6).
    framing.ExecStart(..) ->
      mark_dead(state, ProtocolViolation(kind: "exec_start"))
    framing.ExecStdin(..) ->
      mark_dead(state, ProtocolViolation(kind: "exec_stdin"))
    framing.CapCall(..) -> mark_dead(state, ProtocolViolation(kind: "cap_call"))
    framing.CapResult(..) ->
      mark_dead(state, ProtocolViolation(kind: "cap_result"))
    framing.Cancel -> mark_dead(state, ProtocolViolation(kind: "cancel"))
  }
}

// The running execution, when `id` correlates to it.
fn running_with_id(state: State, id: Int) -> Option(RunningExec) {
  case state.exec {
    Some(exec) ->
      case exec.id == id {
        True -> Some(exec)
        False -> None
      }
    None -> None
  }
}

fn cancel_pending_timer(exec: RunningExec) -> Nil {
  case exec.cancel_timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}

fn schedule_tick(state: State) -> Nil {
  case state.config.heartbeat_interval_ms > 0 {
    True -> {
      let _ =
        process.send_after(
          state.commands,
          state.config.heartbeat_interval_ms,
          HeartbeatTick,
        )
      Nil
    }
    False -> Nil
  }
}

fn fresh_id(state: State) -> #(State, Int) {
  let id = state.next_id
  #(State(..state, next_id: id + 1), id)
}

// --- sending and death --------------------------------------------------

// Encodes and writes one frame; on any write failure the channel is
// declared dead in the returned state.
fn send_frame(state: State, frame: Frame) -> State {
  case framing.encode(frame) {
    // Unencodable frames are broker bugs (ids are minted positive,
    // bodies are typed); settle as SendFailed rather than crash.
    Error(_) -> mark_dead(state, SendFailed)
    Ok(bytes) ->
      case transport_send(state.wire_out, bytes) {
        Ok(Nil) -> state
        Error(Nil) -> mark_dead(state, SendFailed)
      }
  }
}

fn send_or_die(state: State, frame: Frame) -> actor.Next(State, Msg) {
  actor.continue(send_frame(state, frame))
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

fn run_cleanup(state: State) -> State {
  case state.cleaned {
    True -> state
    False -> {
      case state.wire_out {
        WirePort(port: _, os_pid: _, cleanup:) -> cleanup()
        WireChannel(send: _, close: _) -> Nil
      }
      State(..state, cleaned: True)
    }
  }
}

// Marks the helper dead and settles everything in flight in-band. The
// actor stays alive answering requests with the failure, so callers
// racing the death get errors, not crashed calls; the pool retires it.
fn mark_dead(state: State, failure: ExecFailure) -> State {
  case state.phase {
    Dead(_) -> state
    AwaitingHello | Ready(_) -> {
      let state = notify_death(state, failure)
      close_transport(state.wire_out)
      let state = run_cleanup(state)
      State(..state, phase: Dead(failure:))
    }
  }
}

fn die(state: State, failure: ExecFailure) -> actor.Next(State, Msg) {
  actor.continue(mark_dead(state, failure))
}

fn notify_death(state: State, failure: ExecFailure) -> State {
  case state.exec {
    Some(exec) -> {
      cancel_pending_timer(exec)
      process.send(exec.events, Failed(failure:))
    }
    None -> Nil
  }
  list.each(state.ready_waiters, fn(waiter) {
    process.send(waiter, Error(failure))
  })
  list.each(state.pending_heartbeats, fn(pending) {
    process.send(pending.1, Error(failure))
  })
  State(..state, exec: None, ready_waiters: [], pending_heartbeats: [])
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
  /// Loom has no jail here (macOS Seatbelt is WP-H phase 2, the Windows
  /// sandbox phase 3; neither is built). `loom-exec` refuses to serve
  /// without `--allow-unenforced`, and with it confines nothing at all.
  UnjailedHost(os_name: String)
}

/// The platform this VM — and therefore the helper it spawns — runs on.
pub fn host_platform() -> HostPlatform {
  host_platform_for(ffi_os.os_name())
}

/// The pure decision, taking `os:type/0`'s name so the answers no Linux
/// host can reach are still testable from Linux. Kept deliberately in
/// step with the helper's own `PlatformFor`: Linux is phase 1 and is the
/// only jail that exists.
pub fn host_platform_for(os_name: String) -> HostPlatform {
  case os_name {
    "linux" -> JailedHost
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
}

type PoolState {
  PoolState(
    size: Int,
    spawn: fn() -> Result(Helper, SpawnError),
    idle: List(Helper),
    lent: Int,
  )
}

/// Starts a pool of up to `size` helpers, spawned lazily with `spawn`
/// (a seam: production passes `exec.spawn_helper` applied to a
/// `SpawnConfig`; tests pass a fake-transport spawner). Spawning runs
/// inside the pool actor, so a slow spawn delays concurrent checkouts —
/// acceptable at pool sizes of a handful; revisit with pre-warming if
/// it ever is not.
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
pub fn checkout(
  pool: Pool,
  waiting timeout: Int,
) -> Result(Helper, CheckoutError) {
  process.call(pool.subject, waiting: timeout, sending: Checkout)
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
    Checkin(helper:) -> {
      let lent = case state.lent > 0 {
        True -> state.lent - 1
        False -> 0
      }
      case helper_ready(helper) {
        True ->
          actor.continue(
            PoolState(..state, lent:, idle: [helper, ..state.idle]),
          )
        False -> {
          shutdown(helper)
          actor.continue(PoolState(..state, lent:))
        }
      }
    }
    StopPool -> {
      list.each(state.idle, shutdown)
      actor.stop()
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
        True ->
          case state.spawn() {
            Ok(helper) -> #(
              PoolState(..state, lent: state.lent + 1),
              Ok(helper),
            )
            Error(error) -> #(state, Error(SpawnFailed(error:)))
          }
      }
  }
}

fn helper_ready(helper: Helper) -> Bool {
  case process.is_alive(helper.pid) {
    False -> False
    True ->
      case status(helper, waiting: 1000) {
        StatusReady(_) -> True
        StatusStarting | StatusDead(_) -> False
      }
  }
}
