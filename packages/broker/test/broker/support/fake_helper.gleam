//// An in-process fake `loom-exec` helper for deterministic pool tests.
////
//// It speaks the real Part 1.4 protocol bytes over a
//// `ChannelTransport` — outbound broker frames are deframed with the
//// same `broker/framing` deframer, replies are real encoded frames —
//// so the helper actor under test exercises exactly its production
//// code path, minus the OS process.

import broker/exec
import broker/framing
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// What flavour of helper to fake.
pub type Script {
  /// Answers exec_start with the argv echoed to stdout and a clean
  /// exit under full enforcement.
  EchoArgv
  /// Buffers exec_stdin chunks and echoes them to stdout at eof.
  StdinEcho
  /// Runs forever; a cancel settles it with signal 15.
  SleepUntilCancel
  /// Runs forever and ignores cancel — forcing the broker-side
  /// escalation to kill it.
  IgnoreCancel
  /// Refuses every exec_start with a busy error.
  AlwaysBusy
  /// Hello advertises degraded enforcement (no bwrap).
  Degraded
  /// Hello looks healthy but exec_exit reports degraded — the
  /// ground-truth check must catch it.
  LyingDegraded
  /// Emits a truncated output chunk and a truncated exit report.
  Truncating
  /// Sends garbage bytes instead of a frame after exec_start.
  MalformedOnExec
  /// Never echoes heartbeats (the idle liveness probe must declare
  /// the helper dead).
  DeafHeartbeat
  /// Never says hello (handshake timeout).
  NoHello
  /// Says hello with an unsupported protocol version.
  WrongProto
}

/// Messages driving the fake helper process.
pub type FakeMsg {
  /// Wires the fake to the helper actor's inbound subject.
  Attach(wire: Subject(exec.WireEvent))
  /// Bytes the broker-side transport wrote.
  Outbound(bytes: BitArray)
  /// The broker-side transport was closed.
  PeerClosed
}

/// Starts the fake process, returning the transport to hand to
/// `exec.start` and the fake's control subject (for `Attach`).
pub fn start(script: Script) -> #(exec.Transport, Subject(FakeMsg)) {
  let handoff = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    wait_attach(script, inbox)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000)
  let transport =
    exec.ChannelTransport(
      send: fn(bytes) { process.send(inbox, Outbound(bytes:)) },
      close: fn() { process.send(inbox, PeerClosed) },
    )
  #(transport, inbox)
}

/// Starts a fake helper plus its broker-side actor and completes the
/// handshake (except for scripts that intentionally break it).
pub fn start_helper(script: Script) -> exec.Helper {
  start_helper_configured(
    script,
    cancel_grace_ms: 400,
    heartbeat_interval_ms: 0,
  )
}

/// As `start_helper` with control over the actor's timing knobs.
pub fn start_helper_configured(
  script: Script,
  cancel_grace_ms cancel_grace_ms: Int,
  heartbeat_interval_ms heartbeat_interval_ms: Int,
) -> exec.Helper {
  let #(transport, inbox) = start(script)
  let config =
    exec.HelperConfig(
      transport:,
      handshake_timeout_ms: 2000,
      cancel_grace_ms:,
      heartbeat_interval_ms:,
    )
  let assert Ok(helper) = exec.start(config)
  process.send(inbox, Attach(wire: exec.wire(helper)))
  let assert Ok(_features) = exec.await_ready(helper, waiting: 3000)
  helper
}

type FakeState {
  FakeState(
    script: Script,
    inbox: Subject(FakeMsg),
    wire: Subject(exec.WireEvent),
    deframer: framing.Deframer,
    // The running execution's frame id and buffered stdin.
    running: Option(#(Int, BitArray)),
  )
}

fn wait_attach(script: Script, inbox: Subject(FakeMsg)) -> Nil {
  case process.receive_forever(inbox) {
    Attach(wire:) -> {
      let state =
        FakeState(
          script:,
          inbox:,
          wire:,
          deframer: framing.deframer(),
          running: None,
        )
      let state = case script {
        NoHello -> state
        WrongProto ->
          reply(
            state,
            framing.Frame(
              id: 1,
              body: framing.Hello(
                proto: 99,
                peer: "exec-helper",
                features: features(script),
              ),
            ),
          )
        _ ->
          reply(
            state,
            framing.Frame(
              id: 1,
              body: framing.Hello(
                proto: framing.protocol_version,
                peer: "exec-helper",
                features: features(script),
              ),
            ),
          )
      }
      loop(state)
    }
    Outbound(bytes: _) -> wait_attach(script, inbox)
    PeerClosed -> Nil
  }
}

fn features(script: Script) -> List(String) {
  case script {
    Degraded -> ["rlimits", "pgroup", "degraded"]
    _ -> ["rlimits", "pgroup", "bwrap", "landlock", "seccomp"]
  }
}

fn loop(state: FakeState) -> Nil {
  case process.receive_forever(state.inbox) {
    PeerClosed -> Nil
    Attach(wire: _) -> loop(state)
    Outbound(bytes:) -> {
      let framing.Pushed(deframer:, inbound:, fault: _) =
        framing.push(state.deframer, bytes)
      let state = FakeState(..state, deframer:)
      let state =
        list.fold(inbound, state, fn(state, item) {
          case item {
            framing.Known(frame:) -> react(state, frame)
            framing.UnknownInbound(..) -> state
          }
        })
      loop(state)
    }
  }
}

fn react(state: FakeState, frame: framing.Frame) -> FakeState {
  case frame.body {
    framing.Hello(..) -> state
    framing.Heartbeat ->
      case state.script {
        DeafHeartbeat -> state
        _ -> reply(state, framing.Frame(id: frame.id, body: framing.Heartbeat))
      }
    framing.ExecStart(argv:, token:, ..) ->
      exec_start(state, frame.id, argv, token)
    framing.ExecStdin(data:, eof:) -> stdin(state, data, eof)
    framing.Cancel -> cancelled(state)
    _ -> state
  }
}

fn exec_start(
  state: FakeState,
  id: Int,
  argv: List(String),
  token: BitArray,
) -> FakeState {
  case bit_array.byte_size(token) == 32 {
    // The real helper presence-checks the token; the fake checks the
    // size so broker tests prove a real token reached the wire.
    False ->
      reply(
        state,
        framing.Frame(
          id:,
          body: framing.ErrorBody(
            code: "malformed_frame",
            message: "exec_start: missing token",
          ),
        ),
      )
    True ->
      case state.script {
        AlwaysBusy ->
          reply(
            state,
            framing.Frame(
              id:,
              body: framing.ErrorBody(
                code: "busy",
                message: "an execution is already running",
              ),
            ),
          )
        MalformedOnExec -> {
          process.send(
            state.wire,
            exec.WireBytes(data: <<0, 0, 0, 3, 0xde, 0xad, 0xbe>>),
          )
          state
        }
        SleepUntilCancel | IgnoreCancel | StdinEcho ->
          FakeState(..state, running: Some(#(id, <<>>)))
        Truncating -> {
          let state =
            reply(
              state,
              framing.Frame(
                id:,
                body: framing.ExecOut(
                  stream: framing.Stdout,
                  data: <<"trunc">>,
                  bytes: 5,
                  truncated: True,
                ),
              ),
            )
          reply(
            state,
            framing.Frame(
              id:,
              body: exit_body(
                state.script,
                stdout_bytes: 5,
                stdout_truncated: True,
                signal: 0,
              ),
            ),
          )
        }
        EchoArgv
        | Degraded
        | LyingDegraded
        | DeafHeartbeat
        | NoHello
        | WrongProto -> {
          let data = bit_array.from_string(string.join(argv, " ") <> "\n")
          let size = bit_array.byte_size(data)
          let state =
            reply(
              state,
              framing.Frame(
                id:,
                body: framing.ExecOut(
                  stream: framing.Stdout,
                  data:,
                  bytes: size,
                  truncated: False,
                ),
              ),
            )
          reply(
            state,
            framing.Frame(
              id:,
              body: exit_body(
                state.script,
                stdout_bytes: size,
                stdout_truncated: False,
                signal: 0,
              ),
            ),
          )
        }
      }
  }
}

fn stdin(state: FakeState, data: BitArray, eof: Bool) -> FakeState {
  case state.running, state.script {
    Some(#(id, buffered)), StdinEcho -> {
      let buffered = bit_array.append(buffered, data)
      case eof {
        False -> FakeState(..state, running: Some(#(id, buffered)))
        True -> {
          let size = bit_array.byte_size(buffered)
          let state =
            reply(
              state,
              framing.Frame(
                id:,
                body: framing.ExecOut(
                  stream: framing.Stdout,
                  data: buffered,
                  bytes: size,
                  truncated: False,
                ),
              ),
            )
          let state =
            reply(
              state,
              framing.Frame(
                id:,
                body: exit_body(
                  state.script,
                  stdout_bytes: size,
                  stdout_truncated: False,
                  signal: 0,
                ),
              ),
            )
          FakeState(..state, running: None)
        }
      }
    }
    _, _ -> state
  }
}

fn cancelled(state: FakeState) -> FakeState {
  case state.running, state.script {
    _, IgnoreCancel -> state
    Some(#(id, _)), _ -> {
      let state =
        reply(
          state,
          framing.Frame(
            id:,
            body: exit_body(
              state.script,
              stdout_bytes: 0,
              stdout_truncated: False,
              signal: 15,
            ),
          ),
        )
      FakeState(..state, running: None)
    }
    None, _ -> state
  }
}

fn exit_body(
  script: Script,
  stdout_bytes stdout_bytes: Int,
  stdout_truncated stdout_truncated: Bool,
  signal signal: Int,
) -> framing.Body {
  let degraded = case script {
    Degraded | LyingDegraded -> True
    _ -> False
  }
  let enforcement = case degraded {
    True -> ["rlimits", "pgroup", "skip:bwrap: not found"]
    False -> ["bwrap", "landlock:abi=5", "seccomp-net", "rlimits", "pgroup"]
  }
  framing.ExecExit(
    code: 0,
    signal:,
    stdout_bytes:,
    stderr_bytes: 0,
    stdout_truncated:,
    stderr_truncated: False,
    enforcement:,
    degraded:,
    wall_ms: 3,
    timed_out: False,
  )
}

fn reply(state: FakeState, frame: framing.Frame) -> FakeState {
  let assert Ok(bytes) = framing.encode(frame)
  process.send(state.wire, exec.WireBytes(data: bytes))
  state
}
