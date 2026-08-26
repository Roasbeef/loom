//// Inbound deframing for the satellite boot runtime (J3): the read half
//// of the capability channel, reproduced over `core/msgpack` alone.
////
//// ## Why not `broker/framing`
////
//// The broker's framing module is the *host* side of this wire. The
//// satellite is the untrusted far side and must not link the `broker`
//// package (a hostile `.beam` that slipped vetting would gain nothing,
//// but the dependency edge itself is the thing we refuse — the cap
//// package is the language a program is written against, publishable on
//// its own). So the small deframer a satellite needs is written here
//// against `core/msgpack` and the total field extractors in
//// `cap/internal/wire`. Outbound framing already lives in `wire`; this is
//// its mirror.
////
//// ## Totality
////
//// A `push` never crashes. A length prefix over `max_frame_bytes`, a
//// payload that will not parse, an unsupported version, or a wrong-shape
//// `cap_result` are all `Fault` values: the boot reader answers in-flight
//// calls in-band and closes the channel (spec §3.3 invariant 6). A
//// well-formed frame of any *other* kind is `IgnoredKind` — the reader
//// drops it and keeps the channel open, matching the broker's
//// forward-compatible treatment of unknown kinds. The only kind a
//// satellite acts on is `cap_result`.
////
//// The deframer is pure and incremental: frame boundaries never depend on
//// how the transport chunked its reads, so feeding a byte stream one byte
//// at a time yields exactly the frames of feeding it whole.

import cap/internal/channel.{type CapOutcome, CapErr, CapOk}
import cap/internal/wire
import core/corruption.{type CorruptionReport}
import core/msgpack
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The protocol version stamped into every frame envelope (Part 1.4);
/// mirrors `wire.protocol_version` on the outbound side.
pub const protocol_version = 1

/// The inbound frame cap, mirroring the broker's 16 MiB `max_frame_bytes`:
/// a corrupt or hostile length prefix must not make the satellite
/// allocate gigabytes before it can reject the frame.
pub const max_frame_bytes = 16_777_216

/// One well-formed inbound frame the reader can act on or drop.
pub type Inbound {
  /// A `cap_result` correlated to its `cap_call` `id`, already mapped onto
  /// the channel's `CapOutcome` so the reader can `channel.deliver` it
  /// directly.
  CapResult(id: Int, outcome: CapOutcome)
  /// A structurally valid frame of a kind a satellite does not act on
  /// (anything but `cap_result`). Dropped; the channel stays open.
  IgnoredKind(id: Int, kind: String)
}

/// A channel-fatal condition met while deframing. The boot reader turns
/// any of these into `channel.fail`, which settles in-flight calls in-band
/// and latches the channel dead.
pub type Fault {
  /// A length prefix exceeded `max_frame_bytes`.
  Oversized(declared_bytes: Int)
  /// A frame payload did not parse, or a known kind's body was the wrong
  /// shape.
  Malformed(report: CorruptionReport)
  /// The envelope carried a protocol version other than `protocol_version`.
  BadVersion(version: Int)
}

/// The read cursor over the transport byte stream: bytes buffered after
/// the last complete frame. Opaque; construct with `deframer`.
pub opaque type Deframer {
  Deframer(buffer: BitArray)
}

/// The outcome of one `push`: the deframer to continue with, the frames
/// completed by this chunk in arrival order, and the fault that ended the
/// stream if one did. Frames completed before the fault are still
/// delivered.
pub type Pushed {
  Pushed(deframer: Deframer, inbound: List(Inbound), fault: Option(Fault))
}

/// A fresh deframer with an empty carry.
pub fn deframer() -> Deframer {
  Deframer(buffer: <<>>)
}

/// Feeds one transport chunk to the deframer. Pure; chunking never affects
/// the frames produced.
///
/// ## Examples
///
/// ```gleam
/// assert inbound.push(inbound.deframer(), <<>>).inbound == []
/// ```
///
pub fn push(deframer: Deframer, bytes: BitArray) -> Pushed {
  push_loop(bit_array.append(deframer.buffer, bytes), [])
}

fn push_loop(buffer: BitArray, seen: List(Inbound)) -> Pushed {
  case buffer {
    <<size:size(32), rest:bits>> -> push_sized(buffer, size, rest, seen)
    // Fewer than four bytes buffered: carry.
    _ -> carry(buffer, seen, None)
  }
}

// A length prefix was read; either it is already too large to accept,
// or there is a frame's worth of bytes to look for.
fn push_sized(
  buffer: BitArray,
  size: Int,
  rest: BitArray,
  seen: List(Inbound),
) -> Pushed {
  case size > max_frame_bytes {
    True -> carry(buffer, seen, Some(Oversized(declared_bytes: size)))
    False -> push_frame(buffer, rest, size, seen)
  }
}

// The length prefix is acceptable; take exactly `size` bytes if they
// have arrived yet, then decode them as one frame.
fn push_frame(
  buffer: BitArray,
  rest: BitArray,
  size: Int,
  seen: List(Inbound),
) -> Pushed {
  case take_frame(rest, size) {
    // Not enough bytes yet: carry the whole buffer (prefix included)
    // and wait.
    Error(Nil) -> carry(buffer, seen, None)
    Ok(#(payload, remainder)) ->
      case decode_frame(payload) {
        Ok(frame) -> push_loop(remainder, [frame, ..seen])
        // A fault ends the scan: the reader closes the channel, so
        // there is no need to poison the deframer for later pushes.
        Error(fault) -> carry(remainder, seen, Some(fault))
      }
  }
}

// One `push` result: `buffer` becomes the carried deframer state,
// `seen` (accumulated in reverse) becomes the frames in arrival order.
fn carry(
  buffer: BitArray,
  seen: List(Inbound),
  fault: Option(Fault),
) -> Pushed {
  Pushed(deframer: Deframer(buffer:), inbound: list.reverse(seen), fault:)
}

fn take_frame(
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

// --- frame decoding -----------------------------------------------------

fn decode_frame(payload: BitArray) -> Result(Inbound, Fault) {
  case msgpack.decode(payload) {
    Error(report) -> Error(Malformed(report:))
    Ok(envelope) -> decode_envelope(envelope)
  }
}

fn decode_envelope(envelope: msgpack.MsgPackValue) -> Result(Inbound, Fault) {
  case wire.int_field(envelope, "v") {
    Error(reason) -> Error(malformed("frame.v", reason))
    Ok(version) if version != protocol_version -> Error(BadVersion(version:))
    Ok(_) ->
      case
        wire.int_field(envelope, "id"),
        wire.string_field(envelope, "kind"),
        wire.field(envelope, "body")
      {
        Ok(id), Ok(kind), Ok(body) -> decode_kind(id, kind, body)
        _, _, _ -> Error(malformed("frame", "id, kind and body"))
      }
  }
}

fn decode_kind(
  id: Int,
  kind: String,
  body: msgpack.MsgPackValue,
) -> Result(Inbound, Fault) {
  case kind {
    "cap_result" -> decode_cap_result(id, body)
    _ -> Ok(IgnoredKind(id:, kind:))
  }
}

// The `cap_result` body shape is frozen (Part 1.4): `{ok: true, value}`
// or `{ok: false, error: {code, msg}}`, plus an optional `usage` the
// satellite ignores. Any deviation is a fault, mapped in-band.
fn decode_cap_result(
  id: Int,
  body: msgpack.MsgPackValue,
) -> Result(Inbound, Fault) {
  case wire.bool_field(body, "ok") {
    Error(reason) -> Error(malformed("cap_result.ok", reason))
    Ok(True) -> decode_result_value(id, body)
    Ok(False) -> decode_result_error(id, body)
  }
}

fn decode_result_value(
  id: Int,
  body: msgpack.MsgPackValue,
) -> Result(Inbound, Fault) {
  case wire.field(body, "value") {
    Ok(value) -> Ok(CapResult(id:, outcome: CapOk(value:)))
    Error(reason) -> Error(malformed("cap_result.value", reason))
  }
}

fn decode_result_error(
  id: Int,
  body: msgpack.MsgPackValue,
) -> Result(Inbound, Fault) {
  case wire.field(body, "error") {
    Error(reason) -> Error(malformed("cap_result.error", reason))
    Ok(error_value) ->
      case
        wire.string_field(error_value, "code"),
        wire.string_field(error_value, "msg")
      {
        Ok(code), Ok(message) ->
          Ok(CapResult(id:, outcome: CapErr(code:, message:)))
        _, _ -> Error(malformed("cap_result.error", "code and msg"))
      }
  }
}

fn malformed(subject: String, expected: String) -> Fault {
  Malformed(report: corruption.report(
    at: "cap/internal/inbound.decode_frame",
    on: subject,
    expected:,
    context: "",
  ))
}

/// Renders a fault as a one-line reason, for the `channel.fail` message.
pub fn describe_fault(fault: Fault) -> String {
  case fault {
    Oversized(declared_bytes:) ->
      "oversized inbound frame: " <> int.to_string(declared_bytes) <> " bytes"
    Malformed(report:) -> corruption.describe(report)
    BadVersion(version:) ->
      "unsupported protocol version " <> int.to_string(version)
  }
}
