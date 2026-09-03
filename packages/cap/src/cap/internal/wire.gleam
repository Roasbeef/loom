//// Shared wire helpers for the cap prelude: outbound frame encoding for
//// the frames a satellite emits (`cap_call`, `cancel`), and total field
//// extraction over the msgpack values the broker sends back in a
//// `cap_result`.
////
//// The cap package speaks the frozen effect-plane framing protocol
//// (spec Part 1.4) but deliberately does *not* depend on the `broker`
//// package — it is the other end of the wire, not a peer of the broker.
//// So the small envelope encoding a satellite needs is reproduced here
//// over `core/msgpack` rather than borrowed. Inbound `cap_result`
//// frames are deframed by the J3 satellite read loop (which does depend
//// on `broker`) and handed to `cap/internal/channel` already decoded, so
//// only the extraction half of decoding lives here.
////
//// Extraction is total: a `cap_result` value that is the wrong shape is
//// a `String` fault a caller maps to its own in-band error, never a
//// crash. That keeps the in-band failure doctrine (design §9) intact
//// even when a capability answers with a malformed payload.

import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The protocol version stamped into every frame envelope (Part 1.4).
pub const protocol_version = 1

/// The payload cap on an outbound frame, mirroring the broker's 16 MiB
/// `max_frame_bytes`: an over-large `cap_call` (a huge `fs.write`, say)
/// fails to encode in-band rather than being sent and rejected.
pub const max_frame_bytes = 16_777_216

/// The default deadline stamped on a `cap_call` when a capability does
/// not set its own. The broker's pooled wall deadline is the real
/// bound; this is the per-call ceiling.
pub const default_deadline_ms = 30_000

// --- outbound frame encoding --------------------------------------------

/// Encodes a `cap_call` frame to its wire bytes, length prefix included:
/// `{v, id, kind: "cap_call", body: {token, cap, args, deadline_ms}}`.
/// The token is the execution's, injected by the channel — never by the
/// program.
pub fn encode_cap_call(
  id: Int,
  token: BitArray,
  cap: String,
  args: MsgPackValue,
  deadline_ms: Int,
) -> Result(BitArray, msgpack.EncodeError) {
  let body =
    msgpack.MapValue([
      #(msgpack.StringValue("token"), msgpack.BinaryValue(token)),
      #(msgpack.StringValue("cap"), msgpack.StringValue(cap)),
      #(msgpack.StringValue("args"), args),
      #(msgpack.StringValue("deadline_ms"), msgpack.IntValue(deadline_ms)),
    ])
  encode_frame(id, "cap_call", body)
}

/// Encodes a `cancel` frame correlated to the `cap_call` `id` it cancels.
/// The channel sends one for every in-flight call whose caller dies (a
/// race loser reaped by structured concurrency), so the broker revokes
/// the effect and kills its executor pgroup.
pub fn encode_cancel(id: Int) -> Result(BitArray, msgpack.EncodeError) {
  encode_frame(id, "cancel", msgpack.MapValue([]))
}

/// The answer half of a `hook_result` body (spec Part 1.4,
/// `protocol-change/012`): the satellite's reply to one invocation the
/// harness asked for.
///
/// Its own type rather than `channel.CapOutcome` because `channel`
/// imports this module and not the other way round, and because the two
/// mean opposite things: a `CapOutcome` is something the harness said to
/// the satellite, and this is the one thing the satellite says back.
pub type Answer {
  /// The invocation produced this value.
  Answered(value: MsgPackValue)

  /// The invocation did not produce a value, under this in-band code.
  Refused(code: String, message: String)
}

/// Encodes a `hook_result` frame correlated to the `hook_call` `id` it
/// answers: `{ok: true, value}` or `{ok: false, error: {code, msg}}`.
///
/// No `usage` key, unlike `cap_result`: an invocation reserves no budget
/// of its own, because everything it spent it spent through the
/// `cap_call`s it made under the invocation's token.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(_bytes) =
///   wire.encode_hook_result(3, wire.Answered(wire.string("done")))
/// ```
///
pub fn encode_hook_result(
  id: Int,
  answer: Answer,
) -> Result(BitArray, msgpack.EncodeError) {
  let body = case answer {
    Answered(value:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
        #(msgpack.StringValue("value"), value),
      ])
    Refused(code:, message:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("ok"), msgpack.BoolValue(False)),
        #(
          msgpack.StringValue("error"),
          msgpack.MapValue([
            #(msgpack.StringValue("code"), msgpack.StringValue(code)),
            #(msgpack.StringValue("msg"), msgpack.StringValue(message)),
          ]),
        ),
      ])
  }
  encode_frame(id, "hook_result", body)
}

fn encode_frame(
  id: Int,
  kind: String,
  body: MsgPackValue,
) -> Result(BitArray, msgpack.EncodeError) {
  let envelope =
    msgpack.MapValue([
      #(msgpack.StringValue("v"), msgpack.IntValue(protocol_version)),
      #(msgpack.StringValue("id"), msgpack.IntValue(id)),
      #(msgpack.StringValue("kind"), msgpack.StringValue(kind)),
      #(msgpack.StringValue("body"), body),
    ])
  use payload <- result.try(msgpack.encode(envelope))
  let size = bit_array.byte_size(payload)
  case size > max_frame_bytes {
    True -> Error(msgpack.UnencodableLength(length: size))
    False -> Ok(<<size:size(32), payload:bits>>)
  }
}

// --- inbound result extraction ------------------------------------------

/// A convenience constructor for a `cap_call` args map.
pub fn args(entries: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(entries, fn(pair) { #(msgpack.StringValue(pair.0), pair.1) }),
  )
}

/// Wraps a string as a msgpack value.
pub fn string(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

/// Wraps an integer as a msgpack value.
pub fn int(value: Int) -> MsgPackValue {
  msgpack.IntValue(value)
}

/// Wraps a boolean as a msgpack value.
pub fn bool(value: Bool) -> MsgPackValue {
  msgpack.BoolValue(value)
}

/// Wraps raw bytes as a msgpack value.
pub fn binary(value: BitArray) -> MsgPackValue {
  msgpack.BinaryValue(value)
}

/// Wraps a list of strings as a msgpack array value.
pub fn string_array(values: List(String)) -> MsgPackValue {
  msgpack.ArrayValue(list.map(values, msgpack.StringValue))
}

/// Looks a required field up in a msgpack map, failing with a message
/// naming the missing key.
pub fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, String) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.replace_error("missing field " <> key)
    _ -> Error("expected a map, got a scalar")
  }
}

/// Reads an optional field: `None` when the key is absent or explicitly
/// nil, `Some(value)` otherwise.
pub fn optional_field(
  value: MsgPackValue,
  key: String,
) -> Option(MsgPackValue) {
  case field(value, key) {
    Ok(msgpack.NilValue) -> None
    Ok(found) -> Some(found)
    Error(_) -> None
  }
}

/// Reads a required string field.
pub fn string_field(
  value: MsgPackValue,
  key: String,
) -> Result(String, String) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error("field " <> key <> " is not a string")
  }
}

/// Reads a required integer field.
pub fn int_field(value: MsgPackValue, key: String) -> Result(Int, String) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.IntValue(number) -> Ok(number)
    _ -> Error("field " <> key <> " is not an integer")
  }
}

/// Reads a required boolean field.
pub fn bool_field(value: MsgPackValue, key: String) -> Result(Bool, String) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.BoolValue(flag) -> Ok(flag)
    _ -> Error("field " <> key <> " is not a boolean")
  }
}

/// Reads a required binary field. A msgpack `nil` is accepted as empty,
/// matching the broker's tolerance for the Go helper's nil slices.
pub fn binary_field(
  value: MsgPackValue,
  key: String,
) -> Result(BitArray, String) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.BinaryValue(bytes:) -> Ok(bytes)
    msgpack.NilValue -> Ok(<<>>)
    _ -> Error("field " <> key <> " is not a binary")
  }
}

/// Reads a required array field as a list of raw values.
pub fn array_field(
  value: MsgPackValue,
  key: String,
) -> Result(List(MsgPackValue), String) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.ArrayValue(items:) -> Ok(items)
    msgpack.NilValue -> Ok([])
    _ -> Error("field " <> key <> " is not an array")
  }
}

/// Decodes each element of a required array field with `of`, aggregating
/// the first fault.
pub fn array_of(
  value: MsgPackValue,
  key: String,
  of decoder: fn(MsgPackValue) -> Result(a, String),
) -> Result(List(a), String) {
  use items <- result.try(array_field(value, key))
  list.try_map(items, decoder)
}
