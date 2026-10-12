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
////
//// A background execution's row stores an execution value instead of a tool
//// outcome, in an envelope of its own kind (`execution`). `decode_stored`
//// reads either kind and says which it was; `decode_outcome` reads only a tool
//// outcome and reports an execution's bytes as damaged, so a tool call can
//// never be answered with a program's value.

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

/// What a ledger row's stored bytes hold.
pub type Stored {
  /// A tool call's outcome.
  StoredOutcome(outcome: ToolOutcome)

  /// A background execution's value, as `tools/codemode.execution_value`
  /// rendered it.
  StoredExecution(value: JsonValue)
}

/// Encodes a background execution's value as the bytes the ledger stores.
///
/// ## Examples
///
/// ```gleam
/// let bytes = codec.encode_execution(json.Int(1))
/// assert codec.decode_stored(bytes) == Ok(codec.StoredExecution(json.Int(1)))
/// ```
pub fn encode_execution(value: JsonValue) -> BitArray {
  json.Object([#("kind", json.String("execution")), #("value", value)])
  |> json.to_string
  |> bit_array.from_string
}

/// Decodes stored bytes of either kind, refusing anything this module did not
/// write with a report naming what was expected.
///
/// ## Examples
///
/// ```gleam
/// let bytes = codec.encode_outcome(effects.ToolFailed(reason: "no"))
/// assert codec.decode_stored(bytes)
///   == Ok(codec.StoredOutcome(effects.ToolFailed(reason: "no")))
/// ```
pub fn decode_stored(bytes: BitArray) -> Result(Stored, CorruptionReport) {
  let where = "client/remote/codec.stored"
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
      Ok(StoredOutcome(ToolCompleted(result:, terminate:)))
    }
    "failed" -> {
      use reason <- result.try(string_field(fields, "reason", where))
      Ok(StoredOutcome(ToolFailed(reason:)))
    }
    "execution" -> {
      use value <- result.try(field(fields, "value", where))
      Ok(StoredExecution(value))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "kind",
        expected: "completed, failed or execution",
        context: other,
      ))
  }
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
  use stored <- result.try(decode_stored(bytes))
  case stored {
    StoredOutcome(outcome:) -> Ok(outcome)
    StoredExecution(..) ->
      Error(corruption.report(
        at: "client/remote/codec.outcome",
        on: "kind",
        expected: "completed or failed",
        context: "execution",
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
