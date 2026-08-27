//// An in-process fake `loom-exec` helper for deterministic pool tests.
////
//// It speaks the real Part 1.4 protocol bytes over a
//// `ChannelTransport` — outbound broker frames are deframed with the
//// same `broker/framing` deframer, replies are real encoded frames —
//// so the helper actor under test exercises exactly its production
//// code path, minus the OS process.

import broker/exec
import broker/framing
import broker/policy.{type SandboxPolicy}
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
  /// Hello looks healthy and exec_exit keeps `degraded: False`, but the
  /// enforcement list carries a `skip:` entry — the broker must trust
  /// the list, not the bool.
  SkippedLayer
  /// Echoes the exec_start policy's network mode to stdout
  /// ("off"/"proxy"/"full", or "base" with no per-exec policy) and
  /// exits cleanly — lets tests assert what jail an execution would
  /// actually get.
  EchoNetwork
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
  /// Hello looks healthy and the exec_exit carries no `skip:` at all —
  /// but the only entry is `bwrap`, because stage 2 died before it
  /// could report. The layers the policy called for said nothing, and
  /// silence must not read as applied (#54).
  SilentStage2
  /// A report that is complete except for the seccomp network filter a
  /// network-off policy calls for.
  NoSeccompEntry
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

/// A wedge that can be closed over a helper's channel. While it is open
/// every channel write goes straight through; once `close_wedge` lands,
/// each write blocks for the configured span. That is what a wedged
/// helper actually looks like from the pool's side: the actor is alive
/// and its pid says so, its mailbox keeps growing, and it answers
/// nothing — which is the one case a readiness probe exists to catch and
/// the one case a panicking probe turns into a dead pool.
pub opaque type Wedge {
  Wedge(control: Subject(WedgeMsg))
}

type WedgeMsg {
  CloseWedge
  WedgeClosed(reply: Subject(Bool))
}

/// Starts a fake helper whose channel writes can be made to block, plus
/// the wedge that makes them. Heartbeats tick every 10 ms, so a closed
/// wedge leaves the actor inside a write essentially all the time rather
/// than only while a caller happens to be talking to it.
pub fn start_wedgeable_helper(
  blocking_for wedge_ms: Int,
) -> #(exec.Helper, Wedge) {
  let wedge = start_wedge()
  let #(transport, inbox) = start(EchoArgv)
  let assert exec.ChannelTransport(send:, close:) = transport
  let config =
    exec.HelperConfig(
      transport: exec.ChannelTransport(
        send: fn(bytes) {
          case
            process.call(wedge.control, waiting: 1000, sending: WedgeClosed)
          {
            True -> process.sleep(wedge_ms)
            False -> Nil
          }
          send(bytes)
        },
        close:,
      ),
      handshake_timeout_ms: 2000,
      cancel_grace_ms: 400,
      heartbeat_interval_ms: 10,
    )
  let assert Ok(helper) = exec.start(config)
  process.send(inbox, Attach(wire: exec.wire(helper)))
  let assert Ok(_features) = exec.await_ready(helper, waiting: 3000)
  #(helper, wedge)
}

/// Closes the wedge: from here on the helper's channel writes block.
pub fn close_wedge(wedge: Wedge) -> Nil {
  process.send(wedge.control, CloseWedge)
}

fn start_wedge() -> Wedge {
  let handoff = process.new_subject()
  process.spawn_unlinked(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    wedge_loop(inbox, False)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000)
  Wedge(control: inbox)
}

fn wedge_loop(inbox: Subject(WedgeMsg), closed: Bool) -> Nil {
  case process.receive_forever(inbox) {
    CloseWedge -> wedge_loop(inbox, True)
    WedgeClosed(reply:) -> {
      process.send(reply, closed)
      wedge_loop(inbox, closed)
    }
  }
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
    framing.ExecStart(argv:, token:, policy: exec_policy, ..) ->
      exec_start(state, frame.id, argv, token, exec_policy)
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
  exec_policy: Option(SandboxPolicy),
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
        EchoNetwork -> {
          let mode = case exec_policy {
            None -> "base"
            Some(exec_policy) ->
              case exec_policy.network {
                policy.NetworkOff -> "off"
                policy.NetworkProxy(..) -> "proxy"
                policy.NetworkFull -> "full"
              }
          }
          let data = bit_array.from_string(mode <> "\n")
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
        EchoArgv
        | Degraded
        | LyingDegraded
        | SkippedLayer
        | SilentStage2
        | NoSeccompEntry
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
  let enforcement = case script {
    Degraded | LyingDegraded -> ["rlimits", "pgroup", "skip:bwrap: not found"]
    // Stage 2 never spoke: one entry, no skips, nothing applied.
    SilentStage2 -> ["bwrap"]
    NoSeccompEntry -> [
      "bwrap", "mounts:ro=0,rw=1,mask=0,scratch=tmpfs,plan=0000000000000000",
      "landlock:abi=5", "no-new-privs",
    ]
    // The lying case for the list: healthy bool, skipped layer.
    SkippedLayer -> [
      "bwrap", "mounts:ro=0,rw=1,mask=0,scratch=tmpfs,plan=0000000000000000",
      "no-new-privs", "seccomp-net", "rlimits", "pgroup",
      "skip:landlock: unavailable in this test",
    ]
    _ -> [
      "bwrap", "mounts:ro=0,rw=1,mask=0,scratch=tmpfs,plan=0000000000000000",
      "landlock:abi=5", "no-new-privs", "seccomp-net", "rlimits", "pgroup",
    ]
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
    cancelled: signal != 0,
  )
}

fn reply(state: FakeState, frame: framing.Frame) -> FakeState {
  let assert Ok(bytes) = framing.encode(frame)
  process.send(state.wire, exec.WireBytes(data: bytes))
  state
}
