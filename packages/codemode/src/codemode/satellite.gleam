//// The satellite host — the trusted, in-harness owner of a code-mode
//// execution and the broker end of its capability channel (design §6.3
//// "Layer two: the satellite node", `docs/architecture/code-mode.md`).
////
//// A compiled `Artifact` runs in a disposable, jailed `erl` node: a full
//// BEAM for real concurrency, but with no network except the one cap
//// channel, no Erlang distribution, and a cgroup + wall deadline over the
//// whole node. This module is the *host* that launches that node, answers
//// its capability calls, enforces the deadline, and destroys it as a unit.
//// It runs in the harness VM; it never runs model-influenced code (Rule
//// Zero, `docs/architecture/effects.md`).
////
//// # The satellite launch contract (the Go/sandbox agent's spec, J3c)
////
//// The host hands a `LaunchSpec` to an injected `Launcher`. Production's
//// launcher creates and listens on the cap socket, then dispatches a
//// jailed `erl` through the broker exec path (`broker.clear_call`, the
//// exec-control channel) with the shape below; a deterministic test
//// injects an in-process peer instead. The contract:
////
//// - **cap socket first.** Before launching the node the launcher creates
////   and listens on an AF_UNIX stream socket at `cap_socket_path`
////   (`gen_tcp` with `{local, Path}`, or an FFI equivalent), then accepts
////   the satellite's connection. Frames are length-prefixed msgpack
////   (`u32_be length ++ msgpack`); Gleam owns frame boundaries (packet
////   raw). The launcher wires the socket's inbound bytes to
////   `LaunchSpec.wire` and returns a `CapConnection` whose `send` writes
////   outbound frames and whose `destroy` closes the socket and reaps the
////   node.
//// - **argv** launches the compiled artifact's boot entry with Erlang
////   distribution OFF and no epmd, e.g.:
////   ```
////   erl -noshell -boot no_dot_erlang -pa <artifact.beam_dir> \
////       -proto_dist none -start_epmd false \
////       -run <artifact.entry_module> main
////   ```
////   No `-name`/`-sname` is ever passed, so the node cannot cluster; the
////   framed cap socket is its only link to anything (two-channel doctrine).
//// - **env** is allowlist-constructed (never inherited) and carries the
////   two cap-channel handles the boot runtime reads:
////   - `LOOM_CAP_TOKEN_FILE` — path to the private, mode-0600 token file
////     (inside a mode-0700 dir) the host wrote, read-only bind-mounted into
////     the jail. The runtime reads the 32-byte token and echoes it on
////     every `cap_call`.
////   - `LOOM_CAP_SOCK` — path to the AF_UNIX cap socket. The runtime
////     connects it with `gen_tcp:connect({local, Path}, 0, [binary,
////     {active,false}, {packet,raw}])`.
////   plus whatever the program's policy permits (`PATH`, …).
//// - **policy** is network OFF except the one cap socket, the session base
////   composed for this execution, and a cgroup capping memory/CPU/pids
////   with the wall deadline of `budget.deadline_ms`. The host additionally
////   enforces the wall deadline itself: on expiry it `broker.abort`s the
////   operation and closes the socket, killing the node and every executor
////   it fanned out. Closing the socket mid-`cap_call` surfaces to the
////   program as an `Unreachable` capability error before the node dies
////   (J3a EOF semantics), a clean way to unblock it.
////
//// # The cap-channel token (defence in depth)
////
//// The host mints a 32-byte cap-channel token (via `broker/token`, reusing
//// its constant-time check and injected entropy — no new FFI), writes it
//// to the private token file, and checks it on *every* inbound `cap_call`
//// before routing. This is the defence that denies a hostile `.beam` which
//// slipped vetting: even inside the jail it reaches only this one
//// token-checked door. This token is entirely separate from the broker's
//// own per-clearance exec tokens, which `clear_call` mints and revokes
//// internally and the satellite never sees.
////
//// # Pooled budget
////
//// Every `cap_call` becomes a `broker.clear_call` under one shared
//// `{op_id, step_id}`, so the broker pools budget across the whole
//// execution: fan-out buys parallelism, not extra resources (design §6.5;
//// the broker `CLAUDE.md` invariant "Budget is pooled per execution").
////
//// # The terminal outcome frame
////
//// The satellite writes exactly one terminal frame carrying the program's
//// marshalled `report.Outcome` over the same cap socket (J3a contract):
////
//// ```
//// frame = u32_be length ++ msgpack({v:1, id:0, kind:"outcome", body})
//// body  = {ok:true, value} | {ok:false, message, details}
//// ```
////
//// `broker/framing` does not know the `outcome` kind — it would classify
//// the frame as `UnknownKind` and discard the body — so the host runs its
//// *own* small deframer over the cap socket: it splits length-prefixed
//// payloads itself, hands `cap_call`/`cancel`/`heartbeat` payloads to
//// `broker/framing` for typed decoding, and decodes the one `outcome`
//// frame's body itself into an `Outcome`. That frame is the signal the
//// program finished; the host records the outcome and destroys the node.

import broker/broker.{type Broker, type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand}
import broker/framing.{type CapOutcome}
import broker/policy.{type SandboxPolicy}
import broker/token
import codemode/compile.{type Artifact}
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import tools/tool.{type Collected}

/// The frame kind the satellite uses for the terminal outcome (J3a).
pub const outcome_kind = "outcome"

// How long the host actor's initialiser may take.
const host_init_timeout_ms = 1000

// Slack over the wall deadline before `run` gives up on a wholly dead host.
const result_margin_ms = 5000

// How long a per-cap-call clearance (the synchronous `clear_call`) may take.
const clear_timeout_ms = 5000

/// The structured result a code-mode program returns, decoded from the
/// terminal `outcome` frame's body (mirrors `cap/report`'s wire shape,
/// decoded here without depending on the `cap` package).
pub type Outcome {
  /// The program finished with this structured value.
  Completed(value: MsgPackValue)
  /// The program failed in a controlled way, with a message and details.
  Errored(message: String, details: MsgPackValue)
}

/// The pooled execution identity: one token, one budget ledger, one
/// `{op_id, step_id}` shared by every `cap_call`.
pub type ExecId {
  ExecId(op_id: OpId, step_id: String)
}

/// Why an execution did not return an `Outcome`. Every variant is a value;
/// none is a crash.
pub type RunError {
  /// The cap-channel token could not be minted (entropy fault).
  TokenMintFailed(reason: String)
  /// The private token file could not be written.
  TokenFileFailed(reason: String)
  /// The host actor failed to start.
  HostUnavailable(reason: String)
  /// The satellite node could not be launched.
  LaunchRejected(reason: String)
  /// The wall deadline passed before the program finished; the node was
  /// killed as a unit.
  DeadlineExceeded
  /// The satellite's cap channel closed before the program reported an
  /// outcome (the node died or was reaped).
  SatelliteGone(reason: String)
  /// The cap channel broke the framing protocol; it was closed.
  ChannelFaulted(reason: String)
  /// The satellite's terminal `outcome` frame was malformed.
  OutcomeMalformed(reason: String)
}

// --- the cap router seam -------------------------------------------------

/// One inbound capability call, with the pooled execution context needed
/// to build its clearance.
pub type CapRequest {
  CapRequest(
    /// The capability name (e.g. `proc.run`).
    cap: String,
    /// The marshalled call arguments.
    args: MsgPackValue,
    /// The pooled operation id.
    op_id: OpId,
    /// The pooled step id.
    step_id: String,
    /// The session base policy for this execution.
    base_policy: SandboxPolicy,
    /// The pooled per-execution budget.
    budget: Budget,
    /// Enforcement strictness for jailed effects.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The working directory inside the jail.
    cwd: String,
  )
}

/// How to service one routed capability call: the clearance to dispatch,
/// and how to render its settlement back to the satellite.
pub type CapPlan {
  CapPlan(spec: CallSpec, render: fn(Collected) -> CapOutcome)
}

/// A router's in-band refusal of a capability call.
pub type CapDenial {
  CapDenial(code: String, message: String)
}

/// Maps a `CapRequest` to a `CapPlan`, or refuses it in-band. Injected so
/// the host stays generic and tests can substitute a stub. See
/// `default_router` for the built-in table.
pub type CapRouter =
  fn(CapRequest) -> Result(CapPlan, CapDenial)

// --- the launch seam -----------------------------------------------------

/// Everything the launcher needs to start the satellite node. This record
/// *is* the launch contract; see the module doc for the socket/argv/env/
/// policy shape the production launcher must realize.
pub type LaunchSpec {
  LaunchSpec(
    /// The compiled artifact to boot.
    artifact: Artifact,
    /// Path to the private cap-channel token file (`LOOM_CAP_TOKEN_FILE`).
    token_path: String,
    /// Path to the cap-channel AF_UNIX socket (`LOOM_CAP_SOCK`).
    cap_socket_path: String,
    /// The pooled operation id.
    op_id: OpId,
    /// The pooled step id.
    step_id: String,
    /// The session base policy (network off except the cap socket).
    base_policy: SandboxPolicy,
    /// The pooled per-execution budget and wall deadline.
    budget: Budget,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The working directory inside the jail.
    cwd: String,
    /// Where the launcher must deliver inbound cap-channel bytes.
    wire: Subject(WireIn),
  )
}

/// The host's handle on a launched satellite: how to write outbound frames
/// and how to destroy the node (which closes the socket).
pub type CapConnection {
  CapConnection(send: fn(BitArray) -> Nil, destroy: fn() -> Nil)
}

/// Launches a satellite node for a `LaunchSpec`, or fails in-band with a
/// reason. Production listens on the cap socket then dispatches a jailed
/// `erl` through the broker exec path; tests inject an in-process peer.
pub type Launcher =
  fn(LaunchSpec) -> Result(CapConnection, String)

/// Inbound cap-channel events delivered to the host by the launcher.
pub type WireIn {
  /// Raw protocol bytes from the satellite.
  WireBytes(data: BitArray)
  /// The cap channel closed, with a reason.
  WireClosed(reason: String)
}

/// The host's configuration: the session base, budget, and the injected
/// effect seams (entropy, clock, token-file I/O, and the cap router).
pub type SatelliteConfig {
  SatelliteConfig(
    base_policy: SandboxPolicy,
    budget: Budget,
    demand: EnforcementDemand,
    env: List(#(String, String)),
    cwd: String,
    cap_socket_path: String,
    entropy: fn(Int) -> BitArray,
    clock: Clock,
    /// Writes the 32-byte cap token to a private file, returning its path.
    write_token_file: fn(BitArray) -> Result(String, String),
    /// Unlinks the token file on teardown (idempotent).
    unlink_token_file: fn(String) -> Nil,
    /// Maps capability calls to clearances.
    router: CapRouter,
    /// How long to wait for one cap call's settlement.
    call_timeout_ms: Int,
  )
}

// --- run ------------------------------------------------------------------

/// Runs a compiled artifact in a jailed satellite, servicing its
/// capability calls through `broker` under the pooled `exec_id`, and
/// returns the program's structured `Outcome`.
///
/// Mints and delivers the cap-channel token, launches the node, owns the
/// broker end of the cap channel, enforces the wall deadline, and destroys
/// the node and unlinks the token file on every exit path.
pub fn run(
  artifact: Artifact,
  exec_id: ExecId,
  broker: Broker,
  config: SatelliteConfig,
  launch: Launcher,
) -> Result(Outcome, RunError) {
  let ExecId(op_id:, step_id:) = exec_id
  let vault = token.new(config.entropy)
  let binding =
    token.Binding(
      op_id:,
      step_id:,
      policy: config.base_policy,
      deadline_ms: config.budget.deadline_ms,
    )
  case token.mint(vault, binding) {
    Error(mint_error) -> Error(TokenMintFailed(mint_error_text(mint_error)))
    Ok(#(vault, minted)) ->
      case config.write_token_file(token.to_bytes(minted)) {
        Error(reason) -> Error(TokenFileFailed(reason))
        Ok(token_path) ->
          run_launched(
            artifact,
            op_id,
            step_id,
            broker,
            config,
            launch,
            vault,
            token_path,
          )
      }
  }
}

fn run_launched(
  artifact: Artifact,
  op_id: OpId,
  step_id: String,
  broker: Broker,
  config: SatelliteConfig,
  launch: Launcher,
  vault: token.Vault,
  token_path: String,
) -> Result(Outcome, RunError) {
  let #(now, _clock) = clock.read(config.clock)
  let result_subject = process.new_subject()
  case
    start_host(
      op_id,
      step_id,
      broker,
      config,
      vault,
      token_path,
      result_subject,
    )
  {
    Error(start_error) -> {
      config.unlink_token_file(token_path)
      Error(HostUnavailable(start_error_text(start_error)))
    }
    Ok(host) -> {
      let spec =
        LaunchSpec(
          artifact:,
          token_path:,
          cap_socket_path: config.cap_socket_path,
          op_id:,
          step_id:,
          base_policy: config.base_policy,
          budget: config.budget,
          env: config.env,
          cwd: config.cwd,
          wire: host.wire,
        )
      case launch(spec) {
        Error(reason) -> {
          process.send(host.commands, Stop)
          Error(LaunchRejected(reason))
        }
        Ok(connection) -> {
          process.send(
            host.commands,
            Connected(send: connection.send, destroy: connection.destroy),
          )
          let wait =
            int.max(config.budget.deadline_ms - now, 0) + result_margin_ms
          case process.receive(result_subject, wait) {
            Ok(outcome) -> outcome
            Error(Nil) -> {
              process.send(host.commands, Stop)
              Error(HostUnavailable("no terminal result within the deadline"))
            }
          }
        }
      }
    }
  }
}

// --- the host actor -------------------------------------------------------

// The started host's two subjects: `commands` for internal messages,
// `wire` for the launcher's inbound bytes.
type Host {
  Host(commands: Subject(Msg), wire: Subject(WireIn))
}

/// The host actor's message set. Opaque: only this module constructs it,
/// so nothing outside can inject a forged capability settlement.
pub opaque type Msg {
  FromWire(event: WireIn)
  Connected(send: fn(BitArray) -> Nil, destroy: fn() -> Nil)
  CapStarted(id: Int, handle: broker.CallHandle)
  CapDone(id: Int, outcome: CapOutcome)
  Deadline
  Stop
}

// One in-flight routed capability call.
type InFlight {
  InFlight(handle: Option(broker.CallHandle), cancelled: Bool)
}

type State {
  State(
    broker: Broker,
    op_id: OpId,
    step_id: String,
    base_policy: SandboxPolicy,
    budget: Budget,
    demand: EnforcementDemand,
    env: List(#(String, String)),
    cwd: String,
    router: CapRouter,
    clock: Clock,
    call_timeout_ms: Int,
    vault: token.Vault,
    token_path: String,
    unlink_token_file: fn(String) -> Nil,
    commands: Subject(Msg),
    // Raw carry for the host's own length-prefix deframer over the cap
    // socket. The host owns frame boundaries so it can extract the
    // `outcome` frame's body, which `broker/framing` discards.
    buffer: BitArray,
    // The outbound writer, once the launcher has connected. Frames emitted
    // before then buffer in `pending_out` and flush on `Connected`.
    send: Option(fn(BitArray) -> Nil),
    destroy: Option(fn() -> Nil),
    pending_out: List(BitArray),
    inflight: Dict(Int, InFlight),
    result: Subject(Result(Outcome, RunError)),
  )
}

fn start_host(
  op_id: OpId,
  step_id: String,
  broker: Broker,
  config: SatelliteConfig,
  vault: token.Vault,
  token_path: String,
  result_subject: Subject(Result(Outcome, RunError)),
) -> Result(Host, actor.StartError) {
  let #(now, clock) = clock.read(config.clock)
  actor.new_with_initialiser(host_init_timeout_ms, fn(commands) {
    let wire = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(wire, FromWire)
    // The wall deadline: after it, the node dies as a unit (`broker.abort`).
    let delay = int.max(config.budget.deadline_ms - now, 0)
    let _ = process.send_after(commands, delay, Deadline)
    let state =
      State(
        broker:,
        op_id:,
        step_id:,
        base_policy: config.base_policy,
        budget: config.budget,
        demand: config.demand,
        env: config.env,
        cwd: config.cwd,
        router: config.router,
        clock:,
        call_timeout_ms: config.call_timeout_ms,
        vault:,
        token_path:,
        unlink_token_file: config.unlink_token_file,
        commands:,
        buffer: <<>>,
        send: None,
        destroy: None,
        pending_out: [],
        inflight: dict.new(),
        result: result_subject,
      )
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(Host(commands:, wire:))
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Connected(send:, destroy:) -> {
      // Flush anything buffered before the launcher connected.
      list.each(list.reverse(state.pending_out), send)
      actor.continue(
        State(
          ..state,
          send: Some(send),
          destroy: Some(destroy),
          pending_out: [],
        ),
      )
    }
    FromWire(WireBytes(data:)) -> handle_bytes(state, data)
    FromWire(WireClosed(reason:)) ->
      terminate(state, Error(SatelliteGone(reason)))
    CapStarted(id:, handle:) ->
      case dict.get(state.inflight, id) {
        // Already settled and removed: nothing to track.
        Error(Nil) -> actor.continue(state)
        Ok(entry) -> {
          // A cancel that raced ahead of the clearance fires now.
          case entry.cancelled {
            True -> broker.cancel(state.broker, handle)
            False -> Nil
          }
          actor.continue(
            State(
              ..state,
              inflight: dict.insert(
                state.inflight,
                id,
                InFlight(..entry, handle: Some(handle)),
              ),
            ),
          )
        }
      }
    CapDone(id:, outcome:) ->
      case dict.get(state.inflight, id) {
        Error(Nil) -> actor.continue(state)
        Ok(_) -> {
          let state = emit(state, id, outcome)
          actor.continue(
            State(..state, inflight: dict.delete(state.inflight, id)),
          )
        }
      }
    Deadline -> terminate(state, Error(DeadlineExceeded))
    Stop -> {
      cleanup(state)
      actor.stop()
    }
  }
}

// The step a single inbound frame produces.
type FrameStep {
  FrameContinue(state: State)
  FrameDone(state: State, result: Result(Outcome, RunError))
}

fn handle_bytes(state: State, data: BitArray) -> actor.Next(State, Msg) {
  let buffer = bit_array.append(state.buffer, data)
  let Deframed(payloads:, buffer:, fault:) = deframe(buffer)
  let state = State(..state, buffer:)
  case handle_payloads(state, payloads) {
    Error(#(state, result)) -> terminate(state, result)
    Ok(state) ->
      case fault {
        None -> actor.continue(state)
        Some(reason) -> terminate(state, Error(ChannelFaulted(reason)))
      }
  }
}

// Folds the payloads of one chunk, short-circuiting on the terminal frame.
fn handle_payloads(
  state: State,
  payloads: List(BitArray),
) -> Result(State, #(State, Result(Outcome, RunError))) {
  case payloads {
    [] -> Ok(state)
    [payload, ..rest] ->
      case handle_payload(state, payload) {
        FrameContinue(state:) -> handle_payloads(state, rest)
        FrameDone(state:, result:) -> Error(#(state, result))
      }
  }
}

fn handle_payload(state: State, payload: BitArray) -> FrameStep {
  case decode_envelope(payload) {
    // A payload that does not parse as an envelope closes the channel.
    Error(reason) -> FrameDone(state, Error(ChannelFaulted(reason)))
    Ok(#(kind, body)) ->
      case kind == outcome_kind {
        // The terminal outcome frame: decode its body ourselves, since
        // `broker/framing` does not know the kind.
        True -> finish_from_body(state, body)
        // Every other kind is a `broker/framing` frame; let it decode.
        False ->
          case framing.decode_payload(payload) {
            Ok(frame) -> handle_frame(state, frame)
            // Any other unknown kind is ignored (forward compatibility);
            // a genuinely malformed frame closes the channel.
            Error(framing.UnknownKind(..)) -> FrameContinue(state)
            Error(_) ->
              FrameDone(state, Error(ChannelFaulted("malformed cap frame")))
          }
      }
  }
}

fn handle_frame(state: State, frame: framing.Frame) -> FrameStep {
  case frame.body {
    framing.CapCall(token:, cap:, args:, deadline_ms: _) ->
      handle_cap_call(state, frame.id, token, cap, args)
    framing.Cancel -> FrameContinue(handle_cancel(state, frame.id))
    framing.Heartbeat ->
      FrameContinue(send_frame(
        state,
        framing.Frame(id: frame.id, body: framing.Heartbeat),
      ))
    // No other kind flows satellite-to-host on the cap channel. A hostile
    // peer's stray well-formed frame is ignored (the deadline bounds it);
    // only a malformed frame closes the channel.
    _ -> FrameContinue(state)
  }
}

fn handle_cap_call(
  state: State,
  id: Int,
  presented: BitArray,
  cap: String,
  args: MsgPackValue,
) -> FrameStep {
  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)
  // (a) Constant-time token check — the defence that denies a hostile
  // `.beam` which slipped vetting. `check_for` scans without early exit.
  case
    token.check_for(state.vault, presented, state.op_id, state.step_id, now)
  {
    Error(refusal) ->
      FrameContinue(emit(
        state,
        id,
        framing.CapErr(code: "unauthorized", message: refusal_text(refusal)),
      ))
    Ok(_binding) -> FrameContinue(route_cap_call(state, id, cap, args))
  }
}

// The terminal outcome frame's body: decode it into an `Outcome`.
fn finish_from_body(state: State, body: MsgPackValue) -> FrameStep {
  case decode_outcome(body) {
    Ok(outcome) -> FrameDone(state, Ok(outcome))
    Error(reason) -> FrameDone(state, Error(OutcomeMalformed(reason)))
  }
}

// (b) + (c): map the cap to a clearance and dispatch it under the pooled
// `{op_id, step_id}`, tracking it so a `Cancel` can reach it.
fn route_cap_call(
  state: State,
  id: Int,
  cap: String,
  args: MsgPackValue,
) -> State {
  let request =
    CapRequest(
      cap:,
      args:,
      op_id: state.op_id,
      step_id: state.step_id,
      base_policy: state.base_policy,
      budget: state.budget,
      demand: state.demand,
      env: state.env,
      cwd: state.cwd,
    )
  case state.router(request) {
    Error(denial) ->
      emit(
        state,
        id,
        framing.CapErr(code: denial.code, message: denial.message),
      )
    Ok(plan) -> {
      let inflight =
        dict.insert(
          state.inflight,
          id,
          InFlight(handle: None, cancelled: False),
        )
      spawn_collector(
        state.commands,
        state.broker,
        plan,
        id,
        state.call_timeout_ms,
      )
      State(..state, inflight:)
    }
  }
}

// Services one clearance off the actor's timeline: it clears through the
// broker, reports the handle back for cancellation, then collects the one
// settlement and renders it to a `cap_result`.
fn spawn_collector(
  host: Subject(Msg),
  broker: Broker,
  plan: CapPlan,
  id: Int,
  call_timeout_ms: Int,
) -> Nil {
  let _pid =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      case
        broker.clear_call(broker, plan.spec, events:, waiting: clear_timeout_ms)
      {
        Error(refusal) ->
          process.send(host, CapDone(id:, outcome: refusal_outcome(refusal)))
        Ok(handle) -> {
          process.send(host, CapStarted(id:, handle:))
          case tool.collect_events(events, waiting: call_timeout_ms) {
            Ok(collected) ->
              process.send(host, CapDone(id:, outcome: plan.render(collected)))
            Error(Nil) ->
              process.send(
                host,
                CapDone(
                  id:,
                  outcome: framing.CapErr(
                    code: "unsettled",
                    message: "no settlement within the call deadline",
                  ),
                ),
              )
          }
        }
      }
    })
  Nil
}

fn handle_cancel(state: State, id: Int) -> State {
  case dict.get(state.inflight, id) {
    Error(Nil) -> state
    Ok(entry) -> {
      // Cancel the clearance now if it has one; otherwise mark it so the
      // pending `CapStarted` cancels on arrival.
      case entry.handle {
        Some(handle) -> broker.cancel(state.broker, handle)
        None -> Nil
      }
      State(
        ..state,
        inflight: dict.insert(
          state.inflight,
          id,
          InFlight(..entry, cancelled: True),
        ),
      )
    }
  }
}

// Reports the terminal result once, destroys the satellite, and stops.
fn terminate(
  state: State,
  outcome_result: Result(Outcome, RunError),
) -> actor.Next(State, Msg) {
  process.send(state.result, outcome_result)
  cleanup(state)
  actor.stop()
}

// Destroys the satellite as a unit and unlinks the token file. `abort`
// revokes every token of the operation and cancels every executor it
// fanned out; `destroy` closes the socket and reaps the node.
fn cleanup(state: State) -> Nil {
  broker.abort(state.broker, state.op_id)
  case state.destroy {
    Some(destroy) -> destroy()
    None -> Nil
  }
  state.unlink_token_file(state.token_path)
}

// Encodes and writes one frame, buffering until the launcher connects.
fn send_frame(state: State, frame: framing.Frame) -> State {
  case framing.encode(frame) {
    // An unencodable cap_result would be a host bug (ids are positive,
    // bodies typed); drop it rather than crash — the deadline still bounds
    // the execution.
    Error(_) -> state
    Ok(bytes) ->
      case state.send {
        Some(send) -> {
          send(bytes)
          state
        }
        None -> State(..state, pending_out: [bytes, ..state.pending_out])
      }
  }
}

fn emit(state: State, id: Int, outcome: CapOutcome) -> State {
  send_frame(
    state,
    framing.Frame(id:, body: framing.CapResult(outcome:, usage: None)),
  )
}

// --- the host's own length-prefix deframer -------------------------------

// The host owns frame boundaries on the cap socket so it can reach the
// `outcome` frame's body (which `broker/framing` discards as unknown). This
// splits raw length-prefixed payloads; each is then classified by kind.
type Deframed {
  Deframed(payloads: List(BitArray), buffer: BitArray, fault: Option(String))
}

fn deframe(buffer: BitArray) -> Deframed {
  deframe_loop(buffer, [])
}

fn deframe_loop(buffer: BitArray, seen: List(BitArray)) -> Deframed {
  case buffer {
    <<size:size(32), rest:bits>> ->
      case size > framing.max_frame_bytes {
        True ->
          Deframed(
            payloads: list.reverse(seen),
            buffer:,
            fault: Some(
              "a cap frame declared " <> int.to_string(size) <> " bytes",
            ),
          )
        False ->
          case take_payload(rest, size) {
            // Not enough bytes yet: carry and wait for more.
            Error(Nil) ->
              Deframed(payloads: list.reverse(seen), buffer:, fault: None)
            Ok(#(payload, remainder)) ->
              deframe_loop(remainder, [payload, ..seen])
          }
      }
    // Fewer than four bytes buffered: carry.
    _ -> Deframed(payloads: list.reverse(seen), buffer:, fault: None)
  }
}

fn take_payload(
  bytes: BitArray,
  size: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  let available = bit_array.byte_size(bytes)
  case available >= size {
    False -> Error(Nil)
    True -> {
      use payload <- result.try(bit_array.slice(from: bytes, at: 0, take: size))
      use remainder <- result.try(bit_array.slice(
        from: bytes,
        at: size,
        take: available - size,
      ))
      Ok(#(payload, remainder))
    }
  }
}

// Decodes a frame envelope's kind and body, totally. A malformed envelope
// is a `String` fault the caller turns into a channel close.
fn decode_envelope(
  payload: BitArray,
) -> Result(#(String, MsgPackValue), String) {
  case msgpack.decode(payload) {
    Error(_) -> Error("a cap frame payload did not parse")
    Ok(value) -> {
      use kind <- result.try(map_string(value, "kind"))
      use body <- result.try(map_field(value, "body"))
      Ok(#(kind, body))
    }
  }
}

// --- the default cap router ----------------------------------------------

/// The default capability router.
///
/// It services the process-spawning capabilities that map cleanly onto a
/// jailed `broker.clear_call` — today `proc.run`, whose argv is the
/// command to run. The full cap→tool table the satellite ultimately serves
/// is:
///
/// | cap | maps to | via |
/// |---|---|---|
/// | `proc.run` | the jailed executor (bash-style argv) | `clear_call` |
/// | `git.*` / `lsp.*` | their CLIs as argv | `clear_call` |
/// | `fs.read`/`write`/`list`/`edit` | the harness-side `tools/fs` tools | direct (not a jailed exec) |
/// | `net.*` | the egress-proxied executor | `clear_call` (proxy pending) |
/// | `report.emit` / `kv.*` | harness-side stores | direct |
///
/// The rows beyond `proc.run` need the harness-side tool bridge that lands
/// with the fuller runtime; until then they are refused in-band, and
/// callers inject a fuller router. The result-shape of each `cap_result`
/// is the cap module's contract in `packages/cap`.
pub fn default_router(request: CapRequest) -> Result(CapPlan, CapDenial) {
  case request.cap {
    "proc.run" -> proc_plan(request)
    other ->
      Error(CapDenial(
        code: "unsupported_cap",
        message: "capability "
          <> other
          <> " is not routed by the default router",
      ))
  }
}

fn proc_plan(request: CapRequest) -> Result(CapPlan, CapDenial) {
  case decode_argv(request.args) {
    Error(reason) -> Error(CapDenial(code: "invalid_argument", message: reason))
    Ok([]) ->
      Error(CapDenial(
        code: "invalid_argument",
        message: "proc.run needs a non-empty argv",
      ))
    Ok(argv) -> {
      let spec =
        broker.CallSpec(
          op_id: request.op_id,
          step_id: request.step_id,
          base_policy: request.base_policy,
          requirements: request.base_policy,
          grants: [],
          response: broker.ProceedNarrowed,
          demand: request.demand,
          argv:,
          env: request.env,
          cwd: request.cwd,
          budget: request.budget,
        )
      Ok(CapPlan(spec:, render: proc_render))
    }
  }
}

/// Renders a jailed process settlement to the `proc.run` result shape
/// (`exit_code`, `stdout`, `stderr`, truncation and timeout flags).
pub fn proc_render(collected: Collected) -> CapOutcome {
  case collected.outcome {
    broker.CallExited(result:) ->
      framing.CapOk(
        value: msgpack.MapValue([
          #(msgpack.StringValue("exit_code"), msgpack.IntValue(result.code)),
          #(
            msgpack.StringValue("stdout"),
            msgpack.BinaryValue(collected.stdout),
          ),
          #(
            msgpack.StringValue("stderr"),
            msgpack.BinaryValue(collected.stderr),
          ),
          #(
            msgpack.StringValue("stdout_truncated"),
            msgpack.BoolValue(collected.stdout_truncated),
          ),
          #(
            msgpack.StringValue("stderr_truncated"),
            msgpack.BoolValue(collected.stderr_truncated),
          ),
          #(
            msgpack.StringValue("timed_out"),
            msgpack.BoolValue(result.timed_out),
          ),
        ]),
      )
    broker.CallFailed(failure:) ->
      framing.CapErr(
        code: "exec_failed",
        message: tool.exec_failure_text(failure),
      )
  }
}

// --- token-file I/O helpers ----------------------------------------------

/// A token-file writer that writes the 32 bytes to `<directory>/cap-token`,
/// the directory created mode 0700 and the file set mode 0600. The dir is
/// created and locked down before the file is written, so the token is
/// never world-readable even momentarily. Mirrors the broker's fd-3
/// private-file discipline (`docs/architecture/effects.md`).
pub fn private_token_writer(
  directory: String,
) -> fn(BitArray) -> Result(String, String) {
  fn(bytes) {
    let path = directory <> "/cap-token"
    use _ <- result.try(private_directory(directory))
    use _ <- result.try(
      simplifile.write_bits(to: path, bits: bytes)
      |> file_result("write token file"),
    )
    use _ <- result.try(
      simplifile.set_permissions_octal(for_file_at: path, to: 0o600)
      |> file_result("lock down token file"),
    )
    Ok(path)
  }
}

fn private_directory(directory: String) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> file_result("create token directory"),
  )
  simplifile.set_permissions_octal(for_file_at: directory, to: 0o700)
  |> file_result("lock down token directory")
}

/// Unlinks a token file, ignoring an already-absent file (idempotent).
pub fn unlink_token_file(path: String) -> Nil {
  let _ = simplifile.delete(path)
  Nil
}

fn file_result(
  outcome: Result(a, simplifile.FileError),
  what: String,
) -> Result(a, String) {
  result.map_error(outcome, fn(error) {
    "could not " <> what <> ": " <> simplifile.describe_error(error)
  })
}

// --- total msgpack field decoding ----------------------------------------

// Decodes the marshalled outcome (mirrors `cap/report`'s `to_msgpack`):
// `{ok: true, value}` or `{ok: false, message, details}`. Total: a
// malformed shape is a `String` fault, never a crash.
fn decode_outcome(value: MsgPackValue) -> Result(Outcome, String) {
  use ok <- result.try(map_bool(value, "ok"))
  case ok {
    True -> {
      use payload <- result.try(map_field(value, "value"))
      Ok(Completed(value: payload))
    }
    False -> {
      use message <- result.try(map_string(value, "message"))
      let details = case map_field(value, "details") {
        Ok(details) -> details
        Error(_) -> msgpack.NilValue
      }
      Ok(Errored(message:, details:))
    }
  }
}

fn map_field(value: MsgPackValue, key: String) -> Result(MsgPackValue, String) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.replace_error("missing field `" <> key <> "`")
    _ -> Error("expected a map, got a scalar")
  }
}

fn map_bool(value: MsgPackValue, key: String) -> Result(Bool, String) {
  use found <- result.try(map_field(value, key))
  case found {
    msgpack.BoolValue(flag) -> Ok(flag)
    _ -> Error("field `" <> key <> "` is not a bool")
  }
}

fn map_string(value: MsgPackValue, key: String) -> Result(String, String) {
  use found <- result.try(map_field(value, key))
  case found {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error("field `" <> key <> "` is not a string")
  }
}

fn decode_argv(value: MsgPackValue) -> Result(List(String), String) {
  use found <- result.try(map_field(value, "argv"))
  case found {
    msgpack.ArrayValue(items:) ->
      list.try_map(items, fn(item) {
        case item {
          msgpack.StringValue(text) -> Ok(text)
          _ -> Error("argv must be an array of strings")
        }
      })
    _ -> Error("argv must be an array of strings")
  }
}

// --- diagnostics ----------------------------------------------------------

fn mint_error_text(error: token.MintError) -> String {
  case error {
    token.EntropyFailure(got_bytes:) ->
      "entropy source returned " <> int.to_string(got_bytes) <> " bytes"
    token.DuplicateToken -> "entropy source repeated a token"
  }
}

fn refusal_text(refusal: token.Refusal) -> String {
  case refusal {
    token.UnknownToken -> "the presented cap token is unknown"
    token.Revoked -> "the presented cap token was revoked"
    token.Expired(deadline_ms:) ->
      "the presented cap token expired at " <> int.to_string(deadline_ms)
    token.WrongBinding ->
      "the presented cap token is bound to another execution"
  }
}

fn start_error_text(error: actor.StartError) -> String {
  "the satellite host actor failed to start: " <> string.inspect(error)
}

fn refusal_outcome(refusal: broker.Refusal) -> CapOutcome {
  case refusal {
    broker.PolicyRefused(denial:) ->
      framing.CapErr(code: "policy", message: denial.reason)
    broker.InvalidPolicy(error: _) ->
      framing.CapErr(
        code: "invalid_policy",
        message: "the composed policy is invalid",
      )
    broker.BudgetRefused(refusal: budget_refusal) ->
      framing.CapErr(code: "budget", message: budget_text(budget_refusal))
    broker.MintRefused(error: _) ->
      framing.CapErr(code: "mint", message: "the broker could not mint a token")
    broker.NoHelper(error: _) ->
      framing.CapErr(
        code: "no_helper",
        message: "no sandbox helper was available",
      )
    broker.BrokerUnavailable ->
      framing.CapErr(code: "broker", message: "the tool broker is unavailable")
  }
}

fn budget_text(refusal: budget.Refusal) -> String {
  case refusal {
    budget.OutstandingCapReached(cap:) ->
      "the pooled outstanding-effect cap "
      <> int.to_string(cap)
      <> " is reached"
    budget.DeadlinePassed(deadline_ms:) ->
      "the pooled wall deadline " <> int.to_string(deadline_ms) <> " has passed"
  }
}
