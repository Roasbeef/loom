//// An in-process fake `loom-exec` helper for the satellite host's
//// deterministic tests. It speaks the real Part 1.4 protocol bytes over a
//// `ChannelTransport`, so the broker and its helper actor run their
//// production code path, minus any OS process or jail.
////
//// Three behaviours cover what the host tests need:
////
//// - `EchoNow` settles `exec_start` immediately, echoing the argv to
////   stdout under a clean exit — the happy shape.
//// - `Gated(control)` announces each `exec_start` on `control` and then
////   *holds* the execution open until the driver sends `Release(id)` to
////   the announced subject. This lets a test keep several clearances
////   outstanding at once (to probe the pooled budget) and release them in
////   a chosen order (to force out-of-order completion).
//// - `HoldForCancel` never settles on its own; a `cancel` settles it with
////   a distinctive exit code 137 and signal 15, so a test can prove a
////   specific clearance — and only that one — was cancelled.

import broker/exec
import broker/framing
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// How a fake helper reacts to an execution.
pub type Behavior {
  /// Echo the argv and exit cleanly, at once.
  EchoNow
  /// Announce each exec on `control` and hold until released.
  Gated(control: Subject(Started))
  /// Never settle unless cancelled; a cancel exits 137 / signal 15.
  HoldForCancel
  /// Echo and exit at once, but report a jail the kernel could only
  /// partly provide: one layer applied, one `skip:`ped, and the helper's
  /// own `degraded` bool (which tracks only bwrap) left false.
  PartialJail
}

/// A `Gated` helper's announcement of a started execution, carrying the
/// subject the driver sends `Release` to.
pub type Started {
  Started(id: Int, argv: List(String), release: Subject(FakeMsg))
}

/// Messages driving the fake helper process.
pub type FakeMsg {
  Attach(wire: Subject(exec.WireEvent))
  Outbound(bytes: BitArray)
  PeerClosed
  Release(id: Int)
}

/// Starts a fake helper plus its broker-side actor and completes the
/// handshake, returning the ready `exec.Helper`.
pub fn start_helper(behavior: Behavior) -> exec.Helper {
  let handoff = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    wait_attach(behavior, inbox)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000)
  let transport =
    exec.ChannelTransport(
      send: fn(bytes) { process.send(inbox, Outbound(bytes:)) },
      close: fn() { process.send(inbox, PeerClosed) },
    )
  let config =
    exec.HelperConfig(
      transport:,
      handshake_timeout_ms: 2000,
      cancel_grace_ms: 400,
      heartbeat_interval_ms: 0,
    )
  let assert Ok(helper) = exec.start(config)
  process.send(inbox, Attach(wire: exec.wire(helper)))
  let assert Ok(_features) = exec.await_ready(helper, waiting: 3000)
  helper
}

type FakeState {
  FakeState(
    behavior: Behavior,
    inbox: Subject(FakeMsg),
    wire: Subject(exec.WireEvent),
    deframer: framing.Deframer,
    // The running execution's frame id and its argv (held for a gated
    // release or a cancel).
    running: Option(#(Int, List(String))),
  )
}

fn wait_attach(behavior: Behavior, inbox: Subject(FakeMsg)) -> Nil {
  case process.receive_forever(inbox) {
    Attach(wire:) -> {
      let state =
        FakeState(
          behavior:,
          inbox:,
          wire:,
          deframer: framing.deframer(),
          running: None,
        )
      let state =
        reply(
          state,
          framing.Frame(
            id: 1,
            body: framing.Hello(
              proto: framing.protocol_version,
              peer: "codemode-fake",
              features: ["rlimits", "pgroup", "bwrap", "landlock", "seccomp"],
            ),
          ),
        )
      loop(state)
    }
    _ -> wait_attach(behavior, inbox)
  }
}

fn loop(state: FakeState) -> Nil {
  case process.receive_forever(state.inbox) {
    PeerClosed -> Nil
    Attach(wire: _) -> loop(state)
    Release(id:) -> loop(release(state, id))
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
    framing.ExecStart(argv:, ..) -> exec_start(state, frame.id, argv)
    framing.Cancel -> cancelled(state)
    framing.Heartbeat ->
      reply(state, framing.Frame(id: frame.id, body: framing.Heartbeat))
    _ -> state
  }
}

fn exec_start(state: FakeState, id: Int, argv: List(String)) -> FakeState {
  case state.behavior {
    EchoNow -> echo_exit(state, id, argv)
    PartialJail -> partial_exit(state, id, argv)
    HoldForCancel -> FakeState(..state, running: Some(#(id, argv)))
    Gated(control:) -> {
      process.send(control, Started(id:, argv:, release: state.inbox))
      FakeState(..state, running: Some(#(id, argv)))
    }
  }
}

fn release(state: FakeState, id: Int) -> FakeState {
  case state.running {
    Some(#(running_id, argv)) if running_id == id -> echo_exit(state, id, argv)
    _ -> state
  }
}

fn cancelled(state: FakeState) -> FakeState {
  case state.running {
    Some(#(id, _argv)) -> {
      let state =
        reply(
          state,
          framing.Frame(
            id:,
            body: exit_body(code: 137, signal: 15, stdout_bytes: 0),
          ),
        )
      FakeState(..state, running: None)
    }
    None -> state
  }
}

fn echo_exit(state: FakeState, id: Int, argv: List(String)) -> FakeState {
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
  let state =
    reply(
      state,
      framing.Frame(
        id:,
        body: exit_body(code: 0, signal: 0, stdout_bytes: size),
      ),
    )
  FakeState(..state, running: None)
}

// The same clean exit as `echo_exit`, reporting a partly-provided jail.
fn partial_exit(state: FakeState, id: Int, argv: List(String)) -> FakeState {
  let data = bit_array.from_string(string.join(argv, " ") <> "\n")
  let size = bit_array.byte_size(data)
  let state =
    reply(
      state,
      framing.Frame(
        id:,
        body: framing.ExecExit(
          code: 0,
          signal: 0,
          stdout_bytes: size,
          stderr_bytes: 0,
          stdout_truncated: False,
          stderr_truncated: False,
          enforcement: ["bwrap", "skip:landlock: unavailable on this kernel"],
          degraded: False,
          wall_ms: 1,
          timed_out: False,
        ),
      ),
    )
  FakeState(..state, running: None)
}

fn exit_body(
  code code: Int,
  signal signal: Int,
  stdout_bytes stdout_bytes: Int,
) -> framing.Body {
  framing.ExecExit(
    code:,
    signal:,
    stdout_bytes:,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: ["bwrap", "landlock:abi=5", "seccomp-net", "rlimits", "pgroup"],
    degraded: False,
    wall_ms: 1,
    timed_out: False,
  )
}

fn reply(state: FakeState, frame: framing.Frame) -> FakeState {
  let assert Ok(bytes) = framing.encode(frame)
  process.send(state.wire, exec.WireBytes(data: bytes))
  state
}
