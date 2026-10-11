//// How a tool outcome is stored in the executor's ledger.
////
//// The ledger keeps an outcome as an opaque blob with a SHA-256 digest, so a
//// damaged blob is caught when it is read. This module is the layer above
//// that: it turns a `ToolOutcome` into bytes and back. The bytes are JSON in
//// the shape `core/codec` already uses for durable messages, wrapped in a
//// small envelope, and the way back is total. A blob that parses but does not
//// describe an outcome is a `CorruptionReport`, never a crash and never a
//// different outcome, because a stored result is what the orchestrator will
//// stage in its conversation.
////
//// Nothing here is a closure or a pid, so the same bytes read back the same on
//// any machine and in any later VM.

import core/codec
import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/list
import gleam/result
import runtime/effects.{type ToolOutcome, ToolCompleted, ToolFailed}

/// Encodes an outcome as the bytes the ledger stores.
///
/// ## Examples
///
/// ```gleam
/// let bytes = codec.encode_outcome(effects.ToolFailed(reason: "no"))
/// assert codec.decode_outcome(bytes) == Ok(effects.ToolFailed(reason: "no"))
/// ```
pub fn encode_outcome(outcome: ToolOutcome) -> BitArray {
  let envelope = case outcome {
    ToolCompleted(result:, terminate:) ->
      json.Object([
        #("kind", json.String("completed")),
        #("result", codec.encode_message(result)),
        #("terminate", json.Bool(terminate)),
      ])
    ToolFailed(reason:) ->
      json.Object([
        #("kind", json.String("failed")),
        #("reason", json.String(reason)),
      ])
  }
  bit_array.from_string(json.to_string(envelope))
}

/// Decodes stored bytes into the outcome they describe.
///
/// Anything that is not an envelope this module wrote is refused with a report
/// naming what was expected, including bytes that are not UTF-8, JSON that is
/// not an object, an unknown `kind`, and a result message `core/codec` rejects.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = codec.decode_outcome(<<"not json":utf8>>)
/// ```
pub fn decode_outcome(
  bytes: BitArray,
) -> Result(ToolOutcome, CorruptionReport) {
  let where = "client/remote/codec.outcome"
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_not_text) {
      corruption.report(
        at: where,
        on: "bytes",
        expected: "UTF-8 text",
        context: "a stored outcome that is not text",
      )
    }),
  )
  use value <- result.try(json.parse(text))
  use fields <- result.try(object_fields(value, where))
  use kind <- result.try(string_field(fields, "kind", where))
  case kind {
    "completed" -> {
      use message <- result.try(field(fields, "result", where))
      use terminate <- result.try(bool_field(fields, "terminate", where))
      use result <- result.try(codec.decode_message(message))
      Ok(ToolCompleted(result:, terminate:))
    }
    "failed" -> {
      use reason <- result.try(string_field(fields, "reason", where))
      Ok(ToolFailed(reason:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "completed or failed",
        context: other,
      ))
  }
}

fn object_fields(
  value: JsonValue,
  where: String,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(wrong_shape(where, "envelope", "an object", value))
  }
}

fn field(
  fields: List(#(String, JsonValue)),
  name: String,
  where: String,
) -> Result(JsonValue, CorruptionReport) {
  case list.key_find(fields, name) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: name,
        expected: "a field named " <> name,
        context: "absent",
      ))
  }
}

fn string_field(
  fields: List(#(String, JsonValue)),
  name: String,
  where: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(field(fields, name, where))
  case value {
    json.String(text) -> Ok(text)
    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(wrong_shape(where, name, "a string", value))
  }
}

fn bool_field(
  fields: List(#(String, JsonValue)),
  name: String,
  where: String,
) -> Result(Bool, CorruptionReport) {
  use value <- result.try(field(fields, name, where))
  case value {
    json.Bool(flag) -> Ok(flag)
    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Null -> Error(wrong_shape(where, name, "a boolean", value))
  }
}

fn wrong_shape(
  where: String,
  name: String,
  expected: String,
  found: JsonValue,
) -> CorruptionReport {
  corruption.report(
    at: where,
    on: name,
    expected:,
    context: json.to_string(found),
  )
}
