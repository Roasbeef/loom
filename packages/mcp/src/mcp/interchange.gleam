//// `mcp/interchange` — the value translation between the capability
//// wire and the MCP wire: msgpack out to JSON, JSON back to msgpack.
////
//// A code-mode program builds a tool's arguments with `cap/report`'s
//// value builders, so they arrive at the harness as msgpack; an MCP
//// server speaks JSON-RPC, so they leave as JSON, and its answer makes
//// the return trip. Both directions are total: every input settles as a
//// converted value or as an `InterchangeFault` naming the path and the
//// thing that would not cross, never a crash and never a silent
//// substitution.
////
//// ## What the two vocabularies disagree about
////
//// Four decisions, each of which was a choice rather than a fact:
////
//// 1. **msgpack `Int` always fits JSON.** `core/json.Int` is arbitrary
////    precision, so no integer a program can build is unrepresentable
////    on the way out. The asymmetry is real and runs the other way.
////
//// 2. **A JSON integer outside msgpack's range fails the whole
////    result.** msgpack encodes integers in `[-2^63, 2^64 - 1]`
////    (`core/msgpack`'s own encoder refuses the rest), so a server
////    answering with a larger one has said something this wire cannot
////    carry. It is refused in band as a fault — never wrapped, never
////    clamped, never quietly turned into a float. A program reading a
////    wrapped integer would act on a number the server did not send.
////
//// 3. **msgpack `Binary` is refused in an argument.** JSON has no byte
////    string, and the two encodings a caller might expect — base64 text
////    or an array of integers — are guesses about what the server
////    wants. `cap/report`'s builders cannot construct one, so this is
////    unreachable from a vetted program and is refused rather than
////    encoded on a hunch.
////
//// 4. **`NilValue` and `Null` are each other**, and a msgpack map key
////    that is not a string is refused: a JSON object's keys are
////    strings, and inventing a rendering for a non-string key would
////    change what the server is asked.
////
//// Floats cross unchanged in both directions. A JSON float sitting
//// where a server's schema promised an integer is the server's
//// business, not this module's: it is carried as the float it is, and
//// the program's decoder is what decides whether it will do.
////
//// ## Depth needs no bound here
////
//// Both container types are bounded at `max_depth` (256) by the parser
//// that produced them — `core/json.parse` for a server's answer,
//// `core/msgpack.decode` for a program's arguments — and the two
//// constants are the same. So a value that arrives here is already
//// shallow enough for the encoder on the far side, and this module adds
//// no ceiling of its own to keep in step with theirs.

import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/list
import gleam/result

/// The largest integer msgpack encodes (`uint64`).
pub const max_msgpack_int = 18_446_744_073_709_551_615

/// The smallest integer msgpack encodes (`int64`).
pub const min_msgpack_int = -9_223_372_036_854_775_808

/// Why a value would not cross. `at` is a dotted/indexed path from the
/// root of the value being converted, so a refusal names where to look;
/// `what` says what was found there.
pub type InterchangeFault {
  /// A msgpack value with no JSON counterpart.
  NotJson(at: String, what: String)

  /// A JSON value with no msgpack counterpart.
  NotMsgpack(at: String, what: String)
}

/// The fault, worded for a program reading it in band.
///
/// ## Examples
///
/// ```gleam
/// assert interchange.describe(interchange.NotJson("$.a", "binary"))
///   == "$.a is binary, which does not cross to JSON"
/// ```
///
pub fn describe(fault: InterchangeFault) -> String {
  case fault {
    NotJson(at:, what:) ->
      at <> " is " <> what <> ", which does not cross to JSON"
    NotMsgpack(at:, what:) ->
      at <> " is " <> what <> ", which does not cross to msgpack"
  }
}

/// The root path a conversion reports against.
pub const root_path = "$"

/// Converts a capability-wire value into the JSON an MCP server is sent.
///
/// Total. The only two refusals are a binary and a map key that is not a
/// string; see the module doc for why neither is guessed at.
///
/// ## Examples
///
/// ```gleam
/// assert interchange.to_json(msgpack.IntValue(7)) == Ok(json.Int(7))
/// ```
///
pub fn to_json(value: MsgPackValue) -> Result(JsonValue, InterchangeFault) {
  json_at(value, root_path)
}

fn json_at(
  value: MsgPackValue,
  at: String,
) -> Result(JsonValue, InterchangeFault) {
  case value {
    msgpack.NilValue -> Ok(json.Null)
    msgpack.BoolValue(value:) -> Ok(json.Bool(value))
    msgpack.IntValue(value:) -> Ok(json.Int(value))
    msgpack.FloatValue(value:) -> Ok(json.Float(value))
    msgpack.StringValue(value:) -> Ok(json.String(value))
    msgpack.BinaryValue(bytes: _) -> Error(NotJson(at:, what: "a byte string"))
    msgpack.ArrayValue(items:) -> json_items(items, at)
    msgpack.MapValue(entries:) -> json_entries(entries, at)
  }
}

fn json_items(
  items: List(MsgPackValue),
  at: String,
) -> Result(JsonValue, InterchangeFault) {
  items
  |> list.index_map(fn(item, index) { #(item, indexed(at, index)) })
  |> list.try_map(fn(pair) { json_at(pair.0, pair.1) })
  |> result.map(json.Array)
}

fn json_entries(
  entries: List(#(MsgPackValue, MsgPackValue)),
  at: String,
) -> Result(JsonValue, InterchangeFault) {
  entries
  |> list.try_map(fn(entry) {
    use key <- result.try(json_key(entry.0, at))
    use converted <- result.try(json_at(entry.1, member(at, key)))
    Ok(#(key, converted))
  })
  |> result.map(json.Object)
}

// A JSON object's keys are strings, so a msgpack map with any other key
// is refused rather than rendered: a rendering of an integer key would
// name a field the server never declared.
//
// Enumerated rather than closed with a catch-all, so a ninth
// `MsgPackValue` variant is a compile error here instead of silently
// joining the refusal it happens to fit.
fn json_key(key: MsgPackValue, at: String) -> Result(String, InterchangeFault) {
  case key {
    msgpack.StringValue(value:) -> Ok(value)
    msgpack.NilValue -> Error(keyed_by(at, "nil"))
    msgpack.BoolValue(..) -> Error(keyed_by(at, "a boolean"))
    msgpack.IntValue(..) -> Error(keyed_by(at, "an integer"))
    msgpack.FloatValue(..) -> Error(keyed_by(at, "a float"))
    msgpack.BinaryValue(..) -> Error(keyed_by(at, "a byte string"))
    msgpack.ArrayValue(..) -> Error(keyed_by(at, "an array"))
    msgpack.MapValue(..) -> Error(keyed_by(at, "a map"))
  }
}

fn keyed_by(at: String, kind: String) -> InterchangeFault {
  NotJson(at:, what: "a map keyed by " <> kind <> " rather than by a string")
}

/// Converts an MCP server's JSON into the capability-wire value a
/// program reads.
///
/// Total. The one refusal is an integer outside msgpack's range, and it
/// fails the whole conversion rather than the one number: a result that
/// silently lost or wrapped a field is worse than a result the program
/// is told it cannot have.
///
/// ## Examples
///
/// ```gleam
/// assert interchange.to_msgpack(json.Null) == Ok(msgpack.NilValue)
/// ```
///
pub fn to_msgpack(value: JsonValue) -> Result(MsgPackValue, InterchangeFault) {
  msgpack_at(value, root_path)
}

fn msgpack_at(
  value: JsonValue,
  at: String,
) -> Result(MsgPackValue, InterchangeFault) {
  case value {
    json.Null -> Ok(msgpack.NilValue)
    json.Bool(value:) -> Ok(msgpack.BoolValue(value))
    json.Int(value:) -> msgpack_int(value, at)
    json.Float(value:) -> Ok(msgpack.FloatValue(value))
    json.String(value:) -> Ok(msgpack.StringValue(value))
    json.Array(items:) -> msgpack_items(items, at)
    json.Object(fields:) -> msgpack_fields(fields, at)
  }
}

// `core/json.Int` is arbitrary precision and msgpack is not, so this is
// the one place a value can be too large for the wire it is headed for.
fn msgpack_int(
  value: Int,
  at: String,
) -> Result(MsgPackValue, InterchangeFault) {
  case value >= min_msgpack_int && value <= max_msgpack_int {
    True -> Ok(msgpack.IntValue(value))
    False -> Error(NotMsgpack(at:, what: "an integer outside msgpack's range"))
  }
}

fn msgpack_items(
  items: List(JsonValue),
  at: String,
) -> Result(MsgPackValue, InterchangeFault) {
  items
  |> list.index_map(fn(item, index) { #(item, indexed(at, index)) })
  |> list.try_map(fn(pair) { msgpack_at(pair.0, pair.1) })
  |> result.map(msgpack.ArrayValue)
}

fn msgpack_fields(
  fields: List(#(String, JsonValue)),
  at: String,
) -> Result(MsgPackValue, InterchangeFault) {
  fields
  |> list.try_map(fn(field) {
    use converted <- result.try(msgpack_at(field.1, member(at, field.0)))
    Ok(#(msgpack.StringValue(field.0), converted))
  })
  |> result.map(msgpack.MapValue)
}

// --- paths ------------------------------------------------------------------

fn member(at: String, key: String) -> String {
  at <> "." <> key
}

fn indexed(at: String, index: Int) -> String {
  at <> "[" <> int.to_string(index) <> "]"
}
