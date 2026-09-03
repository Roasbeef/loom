//// Deterministic, in-process tests for the satellite boot runtime. No
//// live socket: the transport is injected as function values, with a
//// recorder for `send`/`outcome_sink` and a small blocking "wire" actor
//// standing in for the inbound socket so the reader can `recv` from its
//// own process (a plain subject can only be received by its owner).

import cap/fs
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/inbound
import cap/internal/wire
import cap/report
import cap/runtime
import core/msgpack
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor

// --- the blocking inbound "wire" ----------------------------------------

// A test double for the inbound socket: `WirePull` blocks (the reply is
// parked) until a `WirePush` provides bytes, so the reader's `recv` behaves
// like a real blocking read and the test controls exactly when a frame
// arrives — the ordering the channel's id allocation depends on.
type WireMsg {
  WirePush(bytes: BitArray)
  WirePull(reply: Subject(Result(BitArray, Nil)))
}

type WireState {
  WireState(
    queue: List(BitArray),
    waiting: List(Subject(Result(BitArray, Nil))),
  )
}

fn start_wire() -> Subject(WireMsg) {
  let assert Ok(started) =
    actor.new(WireState(queue: [], waiting: []))
    |> actor.on_message(wire_handle)
    |> actor.start
  started.data
}

fn wire_handle(
  state: WireState,
  msg: WireMsg,
) -> actor.Next(WireState, WireMsg) {
  case msg {
    WirePush(bytes:) ->
      case state.waiting {
        [first, ..rest] -> {
          process.send(first, Ok(bytes))
          actor.continue(WireState(..state, waiting: rest))
        }
        [] ->
          actor.continue(
            WireState(..state, queue: list.append(state.queue, [bytes])),
          )
      }
    WirePull(reply:) ->
      case state.queue {
        [first, ..rest] -> {
          process.send(reply, Ok(first))
          actor.continue(WireState(..state, queue: rest))
        }
        [] ->
          actor.continue(
            WireState(..state, waiting: list.append(state.waiting, [reply])),
          )
      }
  }
}

// A booted satellite over the in-process transport, plus the recorders the
// test drives it through.
type Booted {
  Booted(
    sent: Subject(BitArray),
    wire: Subject(WireMsg),
    outcomes: Subject(BitArray),
  )
}

fn boot(program: fn() -> report.Outcome) -> Booted {
  // Each case stands for one satellite node, which starts with an empty
  // channel slot. The tests share one VM, so clear the slot the way a fresh
  // node would — `boot` refuses to install over a live one (C-F1).
  dispatch.reset()
  let sent = process.new_subject()
  let outcomes = process.new_subject()
  let wire = start_wire()
  let transport =
    runtime.Transport(
      send: fn(bytes) {
        process.send(sent, bytes)
        Nil
      },
      recv: fn() { process.call(wire, waiting: 60_000, sending: WirePull) },
      outcome_sink: fn(bytes) {
        process.send(outcomes, bytes)
        Nil
      },
    )
  let _ =
    process.spawn_unlinked(fn() {
      let _ = runtime.boot(<<7, 7, 7>>, transport, program)
      Nil
    })
  Booted(sent:, wire:, outcomes:)
}

// --- full round trip ----------------------------------------------------

pub fn boot_round_trip_test() {
  let booted =
    boot(fn() {
      case fs.read("/x.txt") {
        Ok(body) -> report.text(body)
        Error(_) -> report.failure("read failed")
      }
    })

  // The program's fs.read leaves as a cap_call with id 0; answer it.
  let assert Ok(call_bytes) = process.receive(booted.sent, 2000)
  assert frame_head(call_bytes) == Ok(#(0, "cap_call"))
  process.send(booted.wire, WirePush(cap_ok(0, contents("file body"))))

  // The marshalled outcome carries the returned value.
  let assert Ok(outcome_bytes) = process.receive(booted.outcomes, 2000)
  let body = completed_body(outcome_bytes)
  assert wire.string_field(body, "value") == Ok("file body")
}

// --- an unrecognized id is dropped, idempotently ------------------------

pub fn boot_drops_unknown_id_test() {
  let booted =
    boot(fn() {
      case fs.read("/x") {
        Ok(body) -> report.text(body)
        Error(_) -> report.failure("read failed")
      }
    })

  let assert Ok(_) = process.receive(booted.sent, 2000)
  // A result for a call id nobody is waiting on: dropped, no outcome yet.
  process.send(booted.wire, WirePush(cap_ok(999, contents("wrong"))))
  assert process.receive(booted.outcomes, 150) == Error(Nil)

  // The real result unblocks the program.
  process.send(booted.wire, WirePush(cap_ok(0, contents("right"))))
  let assert Ok(outcome_bytes) = process.receive(booted.outcomes, 2000)
  assert wire.string_field(completed_body(outcome_bytes), "value")
    == Ok("right")
}

// --- a malformed frame is a controlled shutdown, settled in-band --------

pub fn boot_malformed_frame_settles_in_band_test() {
  let booted =
    boot(fn() {
      case fs.read("/x") {
        // A closed channel surfaces as a transport failure the program can
        // still act on, then report — never a crash of the satellite.
        Error(fs.FsUnavailable(_)) -> report.text("settled")
        _ -> report.failure("expected unavailable")
      }
    })

  let assert Ok(_) = process.receive(booted.sent, 2000)
  // A well-formed msgpack value that is not a frame envelope: malformed at
  // the frame level. The reader closes the channel; the in-flight read
  // settles in-band and the program still emits an outcome.
  process.send(booted.wire, WirePush(<<1:size(32), 0x01>>))

  let assert Ok(outcome_bytes) = process.receive(booted.outcomes, 2000)
  assert wire.string_field(completed_body(outcome_bytes), "value")
    == Ok("settled")
}

// --- a program that returns Errored still marshals an outcome -----------

pub fn boot_errored_outcome_is_marshalled_test() {
  let booted = boot(fn() { report.failure("boom") })
  let assert Ok(outcome_bytes) = process.receive(booted.outcomes, 2000)
  let body = errored_body(outcome_bytes)
  assert wire.string_field(body, "message") == Ok("boom")
}

// --- a crashing program becomes an Errored outcome, never a dead node ---

pub fn boot_program_crash_becomes_errored_test() {
  let booted =
    boot(fn() {
      process.kill(process.self())
      process.sleep(5000)
      report.text("unreachable")
    })
  let assert Ok(outcome_bytes) = process.receive(booted.outcomes, 2000)
  let body = errored_body(outcome_bytes)
  assert wire.string_field(body, "message") == Ok("program crashed: killed")
}

// --- a live channel slot refuses a second install (C-F1) ----------------

// The channel and token live in a VM-global slot. If a prior execution's
// channel actor is still alive, a process that survived it would read the
// new execution's channel — and so act under the new token — on its next
// cap call. `boot` must refuse rather than overwrite, so the executor's
// obligation to reap first fails loudly instead of silently.
pub fn boot_refuses_to_install_over_a_live_channel_test() {
  dispatch.reset()
  let assert Ok(prior) = channel.start(<<1>>, fn(_bytes) { Nil })
  let assert Ok(owner) = process.subject_owner(channel.subject(prior))
  let assert Ok(Nil) =
    dispatch.install_exclusive(channel.to_channel(prior), owner)

  let booted = boot_over_live_slot(fn() { report.text("never runs") })
  assert case booted {
    Error(runtime.ChannelSlotOccupied(_)) -> True
    _ -> False
  }
  // The refusal left the prior execution's channel in place, untouched.
  assert process.is_alive(owner)

  channel.stop(prior)
  dispatch.reset()
}

// Boots straight through, without the fresh-node reset `boot` performs, so
// the install lands on whatever the case already put in the slot.
fn boot_over_live_slot(
  program: fn() -> report.Outcome,
) -> Result(Nil, runtime.BootError) {
  let wire = start_wire()
  let transport =
    runtime.Transport(
      send: fn(_bytes) { Nil },
      recv: fn() { process.call(wire, waiting: 60_000, sending: WirePull) },
      outcome_sink: fn(_bytes) { Nil },
    )
  runtime.boot(<<7, 7, 7>>, transport, program)
}

// --- the deframer is invariant to chunk boundaries ----------------------

pub fn deframer_chunk_boundary_invariant_test() {
  let stream =
    bit_array.append(cap_ok(0, contents("a")), cap_ok(1, contents("b")))
  let whole = drain(inbound.deframer(), [stream])
  let piecemeal = drain(inbound.deframer(), split_bytes(stream))
  // Same frames whether fed whole or one byte at a time.
  assert whole == piecemeal
  assert list.map(whole, inbound_id) == [0, 1]
}

pub fn inbound_ignores_unknown_kind_test() {
  let bytes = frame(5, "heartbeat", msgpack.MapValue([]))
  let inbound.Pushed(inbound: frames, fault:, ..) =
    inbound.push(inbound.deframer(), bytes)
  assert frames == [inbound.IgnoredKind(id: 5, kind: "heartbeat")]
  assert fault == None
}

pub fn inbound_malformed_is_a_fault_test() {
  let inbound.Pushed(fault:, ..) =
    inbound.push(inbound.deframer(), <<1:size(32), 0x01>>)
  assert case fault {
    Some(_) -> True
    None -> False
  }
}

// --- helpers ------------------------------------------------------------

// Strip the u32 length prefix and read a frame's id and kind.
fn frame_head(bytes: BitArray) -> Result(#(Int, String), Nil) {
  let env = decode_envelope(bytes)
  case wire.int_field(env, "id"), wire.string_field(env, "kind") {
    Ok(id), Ok(kind) -> Ok(#(id, kind))
    _, _ -> Error(Nil)
  }
}

fn decode_envelope(bytes: BitArray) -> msgpack.MsgPackValue {
  let assert <<_size:size(32), payload:bits>> = bytes
  let assert Ok(envelope) = msgpack.decode(payload)
  envelope
}

// Assert the frame is a Completed outcome and return its body.
fn completed_body(bytes: BitArray) -> msgpack.MsgPackValue {
  let env = decode_envelope(bytes)
  assert wire.string_field(env, "kind") == Ok(runtime.outcome_kind)
  let assert Ok(body) = wire.field(env, "body")
  assert wire.bool_field(body, "ok") == Ok(True)
  body
}

// Assert the frame is an Errored outcome and return its body.
fn errored_body(bytes: BitArray) -> msgpack.MsgPackValue {
  let env = decode_envelope(bytes)
  assert wire.string_field(env, "kind") == Ok(runtime.outcome_kind)
  let assert Ok(body) = wire.field(env, "body")
  assert wire.bool_field(body, "ok") == Ok(False)
  body
}

fn frame(id: Int, kind: String, body: msgpack.MsgPackValue) -> BitArray {
  let envelope =
    msgpack.MapValue([
      #(msgpack.StringValue("v"), msgpack.IntValue(1)),
      #(msgpack.StringValue("id"), msgpack.IntValue(id)),
      #(msgpack.StringValue("kind"), msgpack.StringValue(kind)),
      #(msgpack.StringValue("body"), body),
    ])
  let assert Ok(payload) = msgpack.encode(envelope)
  let size = bit_array.byte_size(payload)
  <<size:size(32), payload:bits>>
}

fn cap_ok(id: Int, value: msgpack.MsgPackValue) -> BitArray {
  frame(
    id,
    "cap_result",
    msgpack.MapValue([
      #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
      #(msgpack.StringValue("value"), value),
    ]),
  )
}

fn contents(text: String) -> msgpack.MsgPackValue {
  wire.args([#("contents", msgpack.StringValue(text))])
}

fn inbound_id(frame: inbound.Inbound) -> Int {
  case frame {
    inbound.CapResult(id:, ..) -> id
    inbound.HookCall(id:, ..) -> id
    inbound.IgnoredKind(id:, ..) -> id
  }
}

// Push each chunk through the deframer in turn, concatenating the frames.
fn drain(
  deframer: inbound.Deframer,
  chunks: List(BitArray),
) -> List(inbound.Inbound) {
  case chunks {
    [] -> []
    [chunk, ..rest] -> {
      let inbound.Pushed(deframer:, inbound: frames, ..) =
        inbound.push(deframer, chunk)
      list.append(frames, drain(deframer, rest))
    }
  }
}

fn split_bytes(bytes: BitArray) -> List(BitArray) {
  split_loop(bytes, 0, bit_array.byte_size(bytes), [])
}

fn split_loop(
  bytes: BitArray,
  index: Int,
  size: Int,
  acc: List(BitArray),
) -> List(BitArray) {
  case index >= size {
    True -> list.reverse(acc)
    False -> {
      let assert Ok(one) = bit_array.slice(from: bytes, at: index, take: 1)
      split_loop(bytes, index + 1, size, [one, ..acc])
    }
  }
}
