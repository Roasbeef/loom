//// `cap/report` — the structured result a program's `main` returns, plus
//// artifact emission.
////
//// A code-mode program is a function returning an `Outcome`. The
//// satellite boot module marshals that value back to the broker with
//// `to_msgpack` after `main` returns; the strand sees a structured
//// result, never scraped stdout. Large or binary products that should
//// outlive the satellite are written as artifacts with `emit`
//// (`report.emit` over the wire), which returns a durable reference the
//// `Outcome` can carry.
////
//// # Structured values, and why the builders live here
////
//// An `Outcome` carries a `Value`, and a `Value` is the wire's own value
//// type. A submitted program cannot name that type's module: the vetting
//// allowlist does not carry `core/msgpack`, and the hermetic build's
//// `--warnings-as-errors` turns an import of a transitive dependency into
//// a compile error, so `import core/msgpack` is refused twice over. Until
//// this module grew builders, that left `report.text` as the only way a
//// program could say anything at all — every structured result had to be
//// flattened into prose, which is the exact loss the result contract
//// (`tools/agent`'s `result_schema`) exists to stop.
////
//// So the constructors and the readers are here, in the one module every
//// seam carries. `string`/`int`/`float`/`bool`/`list`/`object`/`null`
//// build a `Value` and
//// `field`/`as_string`/`as_int`/`as_float`/`as_bool`/`as_list` read one
//// back, all total, so a program composes and inspects structured data
//// without ever naming the module the type comes from.
////
//// Every reader answers about the tag the value actually carries and
//// coerces nothing. `as_int` refuses a float because rounding silently is
//// how a count becomes wrong, and `as_float` refuses an int for the same
//// reason read the other way: the two tags are distinguishable on the
//// wire, `float(1.5) != int(1)` is the vocabulary's own claim, and a
//// reader that widened one into the other would leave a program no way to
//// ask which it was handed.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/result

/// The result of a program. `Completed` carries a structured value;
/// `Errored` carries a human-readable message and structured details, so
/// a failed program still returns data the model can act on rather than
/// crashing the satellite.
pub type Outcome {
  /// The program finished with this value.
  Completed(value: MsgPackValue)
  /// The program failed in a controlled way.
  Errored(message: String, details: MsgPackValue)
}

/// A structured value: what an `Outcome` carries, what a blackboard note
/// holds, and what a child's terminal result comes back as.
///
/// A re-export rather than a type of its own, so a value read off one
/// capability can be handed straight to another without a conversion that
/// could lose a case. The alias is what makes the type *nameable* by a
/// program: `report.Value` resolves without an import the allowlist would
/// refuse (see the module doc).
pub type Value =
  MsgPackValue

/// A durable reference to an emitted artifact, returned by `emit`.
pub type ArtifactRef {
  ArtifactRef(id: String)
}

/// Why an artifact could not be emitted.
pub type ReportError {
  /// The broker refused the emission in-band.
  EmitDenied(code: String, message: String)
  /// The capability channel could not carry the call.
  EmitUnavailable(reason: String)
}

/// A `Completed` outcome carrying a plain-text summary.
pub fn text(summary: String) -> Outcome {
  Completed(value: msgpack.StringValue(summary))
}

/// A `Completed` outcome carrying a structured value.
pub fn value(payload: MsgPackValue) -> Outcome {
  Completed(value: payload)
}

/// An `Errored` outcome from a message alone, with nil details.
pub fn failure(message: String) -> Outcome {
  Errored(message:, details: msgpack.NilValue)
}

/// Encodes an outcome for the boot module to marshal back to the broker.
/// `Completed` is `{ok: true, value}`; `Errored` is
/// `{ok: false, message, details}`.
pub fn to_msgpack(outcome: Outcome) -> MsgPackValue {
  case outcome {
    Completed(value:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
        #(msgpack.StringValue("value"), value),
      ])
    Errored(message:, details:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("ok"), msgpack.BoolValue(False)),
        #(msgpack.StringValue("message"), msgpack.StringValue(message)),
        #(msgpack.StringValue("details"), details),
      ])
  }
}

// --- building a structured value -----------------------------------------
//
// Seven constructors and five readers, each a one-liner over the wire's
// value type. They exist so a program can compose and inspect structured
// data without naming `core/msgpack`, which the vetting allowlist and the
// hermetic build both refuse it (see the module doc).

/// A text value.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_string(report.string("ok")) == Ok("ok")
/// ```
///
pub fn string(text: String) -> Value {
  msgpack.StringValue(text)
}

/// A whole-number value.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_int(report.int(3)) == Ok(3)
/// ```
///
pub fn int(number: Int) -> Value {
  msgpack.IntValue(number)
}

/// A floating-point value.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_float(report.float(1.5)) == Ok(1.5)
/// assert report.float(1.5) != report.int(1)
/// ```
///
pub fn float(number: Float) -> Value {
  msgpack.FloatValue(number)
}

/// A boolean value.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_bool(report.bool(True)) == Ok(True)
/// ```
///
pub fn bool(flag: Bool) -> Value {
  msgpack.BoolValue(flag)
}

/// A list value.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_list(report.list([report.int(1)])) == Ok([report.int(1)])
/// ```
///
pub fn list(items: List(Value)) -> Value {
  msgpack.ArrayValue(items)
}

/// An object value: named fields, in the order given.
///
/// ## Examples
///
/// ```gleam
/// let value = report.object([#("n", report.int(2))])
/// assert report.field(value, "n") == Ok(report.int(2))
/// ```
///
pub fn object(fields: List(#(String, Value))) -> Value {
  msgpack.MapValue(
    list.map(fields, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
  )
}

/// The absent value.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_string(report.null()) == Error(Nil)
/// ```
///
pub fn null() -> Value {
  msgpack.NilValue
}

// --- reading one back ------------------------------------------------------

/// One field of an object value, or `Error(Nil)` when the value is not an
/// object or has no such field.
///
/// ## Examples
///
/// ```gleam
/// assert report.field(report.object([]), "missing") == Error(Nil)
/// ```
///
pub fn field(value: Value, key: String) -> Result(Value, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(Nil)
  }
}

/// A value's text, or `Error(Nil)` when it is not text.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_string(report.int(1)) == Error(Nil)
/// ```
///
pub fn as_string(value: Value) -> Result(String, Nil) {
  case value {
    msgpack.StringValue(text) -> Ok(text)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(Nil)
  }
}

/// A value's whole number, or `Error(Nil)` when it is not one. A float is
/// *not* accepted: rounding silently is how a count becomes wrong.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_int(report.float(1.0)) == Error(Nil)
/// ```
///
pub fn as_int(value: Value) -> Result(Int, Nil) {
  case value {
    msgpack.IntValue(number) -> Ok(number)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(Nil)
  }
}

/// A value's floating-point number, or `Error(Nil)` when it is not one.
/// An int is *not* accepted, the mirror of `as_int`'s refusal of a float:
/// the two tags are distinct on the wire, and a reader that widened one
/// into the other would leave a program no way to ask which arrived.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_float(report.int(1)) == Error(Nil)
/// ```
///
pub fn as_float(value: Value) -> Result(Float, Nil) {
  case value {
    msgpack.FloatValue(number) -> Ok(number)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(Nil)
  }
}

/// A value's boolean, or `Error(Nil)` when it is not one.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_bool(report.string("true")) == Error(Nil)
/// ```
///
pub fn as_bool(value: Value) -> Result(Bool, Nil) {
  case value {
    msgpack.BoolValue(flag) -> Ok(flag)
    msgpack.NilValue
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(Nil)
  }
}

/// A value's items, or `Error(Nil)` when it is not a list.
///
/// ## Examples
///
/// ```gleam
/// assert report.as_list(report.object([])) == Error(Nil)
/// ```
///
pub fn as_list(value: Value) -> Result(List(Value), Nil) {
  case value {
    msgpack.ArrayValue(items:) -> Ok(items)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.MapValue(..) -> Error(Nil)
  }
}

/// Emits an artifact and returns a durable reference to it.
///
/// Capability: `report.emit`. `content_type` is a MIME-ish label the
/// broker stores alongside the bytes.
pub fn emit(
  name name: String,
  content_type content_type: String,
  bytes bytes: BitArray,
) -> Result(ArtifactRef, ReportError) {
  let args =
    wire.args([
      #("name", wire.string(name)),
      #("content_type", wire.string(content_type)),
      #("bytes", wire.binary(bytes)),
    ])
  use value <- result.try(
    dispatch.call("report.emit", args) |> result.map_error(map_error),
  )
  wire.string_field(value, "id")
  |> result.map(ArtifactRef)
  |> result.map_error(fn(reason) {
    EmitUnavailable("bad report.emit result: " <> reason)
  })
}

fn map_error(error: CallError) -> ReportError {
  case error {
    Denied(code:, message:) -> EmitDenied(code:, message:)
    Unreachable(reason:) -> EmitUnavailable(reason:)
  }
}
