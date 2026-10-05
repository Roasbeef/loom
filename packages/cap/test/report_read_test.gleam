//// Saved result reads bind every slice to the original canonical reference.
//// The fake channel supplies authenticated-host answers, not a storage proof.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report
import core/msgpack as mp
import core/report_value as rv
import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

pub fn chunks_preserve_value_and_typed_observations_test() {
  let value =
    mp.MapValue([
      #(
        mp.IntValue(1),
        mp.BinaryValue(bit_array.from_string(string.repeat("a", 90_000))),
      ),
      #(mp.BinaryValue(<<0, 255>>), mp.StringValue("full\u{0000}text")),
    ])
  let #(reference, bytes) = fixture(rv.Completed(value))
  install_slices(reference, bytes)
  let assert Ok(saved) = report.load_result(reference)
    as "Both slices form one valid report."
  assert saved.outcome == report.Completed(value)
  assert saved.manifest_hash == "sha256-" <> digest
  assert saved.build
    == report.Reported(["filesystem"], ["network"], report.Complete)
  assert saved.node == report.Unreported("missing")
  assert saved.calls
    == report.SavedCalls(100, 8, 4, 1, 1, 1, [
      report.SavedCall("fs.read", Some("path"), report.CallOk, None, 0, 1),
      report.SavedCall(
        "fs.write",
        None,
        report.CallFailed,
        Some("refused"),
        1,
        2,
      ),
      report.SavedCall("proc.run", None, report.CallCancelled, None, 3, 2),
      report.SavedCall(
        "lsp.query",
        Some(""),
        report.CallUnsettled,
        Some(""),
        5,
        3,
      ),
    ])
}

pub fn controlled_error_is_full_program_data_test() {
  let details = mp.MapValue([#(mp.BinaryValue(<<0>>), mp.FloatValue(1.0))])
  let #(reference, bytes) = fixture(rv.Errored("full error", details))
  install_slices(reference, bytes)
  let assert Ok(saved) = report.load_result(reference)
    as "A controlled error is a valid retained report."
  assert saved.outcome == report.Errored("full error", details)
}

pub fn malformed_reference_never_dispatches_test() {
  dispatch.install(
    channel.Channel(call: fn(_, _, _) {
      panic as "Invalid references cannot reach the capability channel."
    }),
  )
  let assert Error(report.InvalidReference(_)) =
    report.load_result("/etc/passwd")
    as "A reference is not a filesystem path."
}

pub fn denied_and_unavailable_reads_preserve_cause_test() {
  let #(reference, _) = fixture(rv.Completed(mp.NilValue))
  dispatch.install(
    channel.Channel(call: fn(_, _, _) {
      Error(channel.Denied("foreign_session", "wrong owner"))
    }),
  )
  assert report.load_result(reference)
    == Error(report.ReadDenied("foreign_session", "wrong owner"))
  dispatch.install(
    channel.Channel(call: fn(_, _, _) { Error(channel.Unreachable("gone")) }),
  )
  assert report.load_result(reference) == Error(report.ReadUnavailable("gone"))
}

pub fn changed_reference_offset_and_length_are_refused_test() {
  let #(reference, bytes) = fixture(rv.Completed(mp.NilValue))
  assert_invalid_reply(reference, chunk(reference <> "0", 0, bytes))
  assert_invalid_reply(reference, chunk(reference, 65_536, bytes))
  assert_invalid_reply(reference, chunk(reference, 0, <<>>))
  assert_invalid_reply(reference, chunk(reference, 0, <<bytes:bits, 0>>))
}

pub fn closed_chunk_shape_and_canonical_bundle_are_checked_test() {
  let #(reference, bytes) = fixture(rv.Completed(mp.NilValue))
  assert_invalid_reply(
    reference,
    report.object([
      #("reference", report.string(reference)),
      #("offset", report.int(0)),
      #("bytes", wire.binary(bytes)),
      #("extra", report.null()),
    ]),
  )
  assert_invalid_reply(
    reference,
    report.object([
      #("reference", report.string(reference)),
      #("offset", report.int(0)),
      #("offset", report.int(0)),
    ]),
  )
  let size = bit_array.byte_size(bytes)
  assert_invalid_reply(
    reference,
    chunk(reference, 0, bit_array.from_string(string.repeat("x", size))),
  )
}

pub fn a_short_middle_chunk_cannot_extend_the_read_test() {
  let #(reference, bytes) =
    fixture(rv.Completed(mp.StringValue(string.repeat("x", 90_000))))
  dispatch.install(
    channel.Channel(call: fn(_, args, _) {
      assert wire.int_field(args, "offset") == Ok(0)
      let assert Ok(short) = bit_array.slice(bytes, 0, 65_535)
        as "The first slice exists."
      Ok(chunk(reference, 0, short))
    }),
  )
  assert report.load_result(reference) |> result.is_error
}

fn assert_invalid_reply(reference: String, reply: mp.MsgPackValue) -> Nil {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(reply) }))
  let assert Error(report.InvalidReport(_)) = report.load_result(reference)
    as "The helper must refuse a changed or malformed owner reply."
  Nil
}

fn install_slices(reference: String, bytes: BitArray) {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _) {
      assert cap == "report.result_chunk"
      assert wire.string_field(args, "reference") == Ok(reference)
      let assert Ok(offset) = wire.int_field(args, "offset")
        as "Every request names an offset."
      assert offset >= 0 && offset % 65_536 == 0
      let count = int.min(65_536, bit_array.byte_size(bytes) - offset)
      let assert Ok(part) = bit_array.slice(bytes, offset, count)
        as "The slice is within the original report."
      Ok(chunk(reference, offset, part))
    }),
  )
}

fn chunk(reference: String, offset: Int, bytes: BitArray) -> mp.MsgPackValue {
  // Field order does not grant identity; the helper checks names and values.
  report.object([
    #("bytes", wire.binary(bytes)),
    #("offset", report.int(offset)),
    #("reference", report.string(reference)),
  ])
}

fn fixture(outcome: rv.Outcome) -> #(String, BitArray) {
  let assert Ok(metadata) =
    rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(
        rv.Reported(["filesystem"], ["network"], rv.Complete),
        rv.Unreported("missing"),
      ),
      rv.CallLog(100, 8, 4, 1, 1, 1, [
        rv.CallRecord("fs.read", Some("path"), rv.CallOk, None, 0, 1),
        rv.CallRecord("fs.write", None, rv.CallFailed, Some("refused"), 1, 2),
        rv.CallRecord("proc.run", None, rv.CallCancelled, None, 3, 2),
        rv.CallRecord("lsp.query", Some(""), rv.CallUnsettled, Some(""), 5, 3),
      ]),
    )
    as "Fixture metadata satisfies the fixed report contract."
  let assert Ok(saved) = rv.from_outcome(outcome, metadata)
    as "Fixture outcome fits the report profile."
  let bytes = rv.bytes(saved)
  let reference =
    "result://019b0000-0000-7000-8000-000000000001/019b0000-0000-7000-8000-000000000002/"
    <> digest
    <> "/"
    <> int.to_string(bit_array.byte_size(bytes))
  #(reference, bytes)
}
