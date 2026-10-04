//// A fake `loom-exec` helper for the simulation's effect plane.
////
//// A simulated session's tools run through `broker/executor`, and the
//// executor needs helpers to borrow. This is the smallest one that speaks the
//// real protocol: it answers the broker's hello, echoes heartbeats, takes an
//// `exec_start`, and then does nothing until it is cancelled, which it answers
//// with the exit a cancelled execution reports. It never ends an execution by
//// itself, so an execution lasts exactly as long as the simulated tool that
//// started it chooses, which is what lets a scheduled fault land while one is
//// in flight.
////
//// It speaks over a `ChannelTransport`, with the real `broker/framing`
//// deframer, so the helper actor under it runs its production code path minus
//// the OS process. `broker`'s own test suite has a richer fake
//// (`support/fake_helper`) with many scripts; that module is test code in a
//// package this one cannot import from, and this one needs a single behavior.
////
//// ## Flow
////
//// `start_helper` → `listen` → `react`
////
//// 1. `start_helper` makes the fake and its broker-side actor, attaches the
////    two, and waits for the handshake.
//// 2. `listen` reads the bytes the actor wrote and gives each whole frame to
////    `react`, which answers it.

import broker/exec
import broker/framing
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}

// What the broker side can say to the fake.
type Message {

  // Wires the fake to the helper actor's inbound subject.
  Attach(wire: Subject(exec.WireEvent))

  // Bytes the actor wrote.
  Outbound(bytes: BitArray)

  // The actor closed its end.
  PeerClosed
}

type State {
  State(
    inbox: Subject(Message),
    wire: Subject(exec.WireEvent),
    deframer: framing.Deframer,
    // The frame id of the execution that is running, if one is.
    running: Option(Int),
  )
}

/// Starts a fake helper and the broker-side actor over it, and returns the
/// actor once its handshake has completed.
///
/// ## Examples
///
/// ```gleam
/// let helper = fake_jail.start_helper()
/// ```
///
pub fn start_helper() -> exec.Helper {
  let handoff = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    wait_for_attach(inbox)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000)
    as "the fake helper started"
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
      kill_witness_ms: 5000,
      heartbeat_interval_ms: 0,
    )
  let assert Ok(helper) = exec.start(config) as "the helper actor starts"
  process.send(inbox, Attach(wire: exec.wire(helper)))
  let assert Ok(_features) = exec.await_ready(helper, waiting: 3000)
    as "the fake helper completes its handshake"
  helper
}

// The fake says hello as soon as it is attached, and until then it ignores
// what the actor writes, because the actor writes nothing before it has been
// told the fake is there.
fn wait_for_attach(inbox: Subject(Message)) -> Nil {
  case process.receive_forever(inbox) {
    Attach(wire:) -> {
      let state =
        State(inbox:, wire:, deframer: framing.deframer(), running: None)
      reply(
        state,
        framing.Frame(
          id: 1,
          body: framing.Hello(
            proto: framing.exec_protocol_version,
            peer: "exec-helper",
            features: ["rlimits", "pgroup", "bwrap", "landlock", "seccomp"],
          ),
        ),
      )
      listen(state)
    }
    Outbound(bytes: _) -> wait_for_attach(inbox)
    PeerClosed -> Nil
  }
}

fn listen(state: State) -> Nil {
  case process.receive_forever(state.inbox) {
    PeerClosed -> Nil
    Attach(wire: _) -> listen(state)
    Outbound(bytes:) -> {
      let framing.Pushed(deframer:, inbound:, fault: _) =
        framing.push(state.deframer, bytes)
      let state = State(..state, deframer:)
      let state =
        list.fold(inbound, state, fn(state, item) {
          case item {
            framing.Known(frame:) -> react(state, frame)
            framing.UnknownInbound(..) -> state
          }
        })
      listen(state)
    }
  }
}

// What the fake does with one frame. A shutdown is answered the way the real
// helper answers it, by exiting with status 0, which is the retirement proof
// the pool waits for.
fn react(state: State, frame: framing.Frame) -> State {
  case frame.body {
    framing.Shutdown -> {
      process.send(state.wire, exec.WireClosed(status: 0))
      process.send(state.inbox, PeerClosed)
      state
    }
    framing.Heartbeat ->
      reply(state, framing.Frame(id: frame.id, body: framing.Heartbeat))
    framing.ExecStart(..) -> State(..state, running: Some(frame.id))
    framing.Cancel -> cancelled(state)
    _ignored -> state
  }
}

// A cancel ends the running execution the way a cancelled one ends: signal 15
// and the `cancelled` flag, under a full enforcement report so that no demand
// the broker makes can refuse it. A cancel with nothing running is ignored.
fn cancelled(state: State) -> State {
  case state.running {
    None -> state
    Some(id) -> {
      reply(
        state,
        framing.Frame(
          id:,
          body: framing.ExecExit(
            code: 0,
            signal: 15,
            stdout_bytes: 0,
            stderr_bytes: 0,
            stdout_truncated: False,
            stderr_truncated: False,
            enforcement: [
              "bwrap",
              "mounts:ro=0,rw=1,mask=0,scratch=tmpfs,plan=0000000000000000",
              "landlock:abi=5",
              "no-new-privs",
              "seccomp-net",
              "rlimits",
              "pgroup",
            ],
            degraded: False,
            wall_ms: 1,
            timed_out: False,
            cancelled: True,
          ),
        ),
      )
      State(..state, running: None)
    }
  }
}

fn reply(state: State, frame: framing.Frame) -> State {
  let assert Ok(bytes) = framing.encode(frame) as "the fake's frame encodes"
  process.send(state.wire, exec.WireBytes(data: bytes))
  state
}
