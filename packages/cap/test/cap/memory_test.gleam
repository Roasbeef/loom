//// Round trips for `cap/memory`: the one argument the stub puts on the
//// wire, the discarded reply, and the mapping of every refusal code.
////
//// The channel is faked rather than driven, as in `cap/history_test`, so
//// what is under test is only this module's marshalling.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/memory
import core/msgpack
import gleam/erlang/process
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- helpers ------------------------------------------------------------

fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

fn text(value: String) -> msgpack.MsgPackValue {
  msgpack.StringValue(value)
}

fn answering(
  reply: msgpack.MsgPackValue,
) -> fn() -> Result(#(String, msgpack.MsgPackValue), Nil) {
  let sent = process.new_subject()
  install_fake(with: fn(cap, args, _deadline) {
    process.send(sent, #(cap, args))
    Ok(reply)
  })
  fn() { process.receive(sent, 100) }
}

// --- memory.remember ----------------------------------------------------

/// The note reaches the wire under one key, and a successful write is
/// `Nil` — there is nothing to report about a note that was written.
pub fn remember_round_trip_test() {
  let take = answering(map([]))

  assert memory.remember("prefer tabs in this tree") == Ok(Nil)

  assert take()
    == Ok(#(
      "memory.remember",
      map([#("note", text("prefer tabs in this tree"))]),
    ))
}

/// The text is sent exactly as given, untrimmed: trimming here would be
/// a second place deciding what the stored bytes are, and the emptiness
/// question belongs where the redaction happens.
pub fn remember_does_not_trim_test() {
  let take = answering(map([]))
  let _written = memory.remember("  spaced  ")
  assert take()
    == Ok(#("memory.remember", map([#("note", text("  spaced  "))])))
}

/// Whatever the harness answers with is discarded, so a reply that grows
/// a field later cannot break a program written today.
pub fn remember_ignores_the_reply_shape_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(map([#("stored", msgpack.BoolValue(True))]))
  })

  assert memory.remember("a lesson") == Ok(Nil)
}

// --- error mapping ------------------------------------------------------

/// Every refusal code the harness mints maps to the variant of the same
/// name, and an unknown code survives verbatim — including the
/// `unsupported_cap` a host with no memory store answers with.
pub fn error_mapping_test() {
  assert refused("memory_busy", "a distillation holds the lease")
    == memory.MemoryBusy(message: "a distillation holds the lease")
  assert refused("memory_unavailable", "could not open")
    == memory.MemoryUnavailable(reason: "could not open")
  assert refused("note_too_long", "2400 characters after redaction")
    == memory.NoteTooLong(message: "2400 characters after redaction")
  assert refused("memory_full", "lifetime limit of 256 notes")
    == memory.MemoryFull(message: "lifetime limit of 256 notes")
  assert refused("note_empty", "`note` is empty")
    == memory.NothingToRemember(message: "`note` is empty")
  assert refused("unsupported_cap", "not routed")
    == memory.MemoryRefused(code: "unsupported_cap", message: "not routed")
}

fn refused(code: String, message: String) -> memory.MemoryError {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Denied(code, message))
  })
  let assert Error(error) = memory.remember("a lesson")
    as "a denied call must answer an error"
  error
}

/// A dead channel and a store that would not open are one variant, since
/// a program can do nothing different about either.
pub fn channel_down_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("broker exited"))
  })

  assert memory.remember("a lesson")
    == Error(memory.MemoryUnavailable("broker exited"))
}
