//// Round trips for `cap/context`: the argument-free call, the total
//// decoding of a report under both boundary shapes, and the mapping of
//// every refusal code.
////
//// The channel is faked rather than driven, as in `cap/memory_test`, so
//// what is under test is only this module's marshalling. The wire keys
//// are spelled here because this is one end of a wire whose other end is
//// `codemode/recall`; the two packages share no dependency, so each side
//// pins its own half and a key renamed on one becomes a decode failure
//// the other reports.

import cap/context
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/string
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

fn int(value: Int) -> msgpack.MsgPackValue {
  msgpack.IntValue(value)
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

// The five fields every report carries, whatever its boundary.
fn common() -> List(#(String, msgpack.MsgPackValue)) {
  [
    #("strand", text("main")),
    #("window", int(2)),
    #("context_window", int(200_000)),
    #("used_tokens", int(140_000)),
    #("notes", int(3)),
  ]
}

// --- context.report -----------------------------------------------------

/// A checkpoint boundary decodes with both of its numbers, and the call
/// puts an empty map on the wire: the only argument it could take is the
/// identity of somebody else.
pub fn report_round_trip_test() {
  let take =
    answering(
      map([
        #("boundary", text("checkpoint")),
        #("checkpoint_tokens", int(160_000)),
        #("keep_recent_tokens", int(40_000)),
        ..common()
      ]),
    )

  assert context.report()
    == Ok(context.Report(
      strand: "main",
      window: 2,
      context_window: 200_000,
      used_tokens: 140_000,
      boundary: context.CheckpointAt(
        tokens: 160_000,
        keep_recent_tokens: 40_000,
      ),
      notes: 3,
    ))

  assert take() == Ok(#("context.report", map([])))
}

/// A host with compaction off sends the tag and nothing beside it, and
/// the two numbers are not looked for: a report that had to carry zeroes
/// would make a real zero keep-recent budget indistinguishable from no
/// boundary at all.
pub fn report_decodes_an_absent_boundary_test() {
  let _take = answering(map([#("boundary", text("none")), ..common()]))

  let assert Ok(report) = context.report() as "a `none` boundary must decode"
  assert report.boundary == context.NoCheckpoint
  assert report.notes == 3
}

/// The fields a program computes on survive the trip unchanged, which is
/// the whole reason the call exists: a program subtracts for itself.
pub fn report_carries_the_arithmetic_a_program_does_test() {
  let _take =
    answering(
      map([
        #("boundary", text("checkpoint")),
        #("checkpoint_tokens", int(160_000)),
        #("keep_recent_tokens", int(40_000)),
        ..common()
      ]),
    )

  let assert Ok(report) = context.report() as "the report must decode"
  let room = case report.boundary {
    context.CheckpointAt(tokens:, ..) -> tokens - report.used_tokens

    context.NoCheckpoint -> report.context_window - report.used_tokens
  }
  assert room == 20_000
}

// --- total decoding -----------------------------------------------------

/// A reply missing a field, carrying a field of the wrong type, or
/// naming a boundary this program does not know is a typed error rather
/// than a crash. The unknown tag is the one worth stating: reading it as
/// `NoCheckpoint` would have a program plan for a cut that is coming.
pub fn a_malformed_reply_is_a_typed_error_test() {
  let bad = [
    map([]),
    map([#("boundary", text("checkpoint")), ..common()]),
    map([#("boundary", text("someday")), ..common()]),
    map([#("boundary", int(1)), ..common()]),
    map([#("boundary", text("none")), #("window", text("two"))]),
  ]
  list.each(bad, fn(reply) {
    let _take = answering(reply)
    let assert Error(context.ContextUnavailable(reason:)) = context.report()
      as "a malformed reply must be an unavailable report"
    assert string.starts_with(reason, "bad context.report result: ")
  })
}

// --- error mapping ------------------------------------------------------

/// The harness's one refusal code maps to the variant that says `carry
/// on`, and any other code survives verbatim — including the
/// `unsupported_cap` a host that wired no context seam answers with.
pub fn error_mapping_test() {
  assert refused("context_unavailable", "the strand's branch could not be read")
    == context.ContextUnavailable(
      reason: "the strand's branch could not be read",
    )
  assert refused("unsupported_cap", "not routed")
    == context.ContextRefused(code: "unsupported_cap", message: "not routed")
  assert refused("invalid_argument", "no")
    == context.ContextRefused(code: "invalid_argument", message: "no")
}

fn refused(code: String, message: String) -> context.ContextError {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Denied(code, message))
  })
  let assert Error(error) = context.report()
    as "a denied call must answer an error"
  error
}

/// A dead channel and a report that could not be built are one variant,
/// since a program can do nothing different about either.
pub fn channel_down_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("broker exited"))
  })

  assert context.report() == Error(context.ContextUnavailable("broker exited"))
}
