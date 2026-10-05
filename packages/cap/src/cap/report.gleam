//// `cap/report` — the structured result a program's `main` returns, plus
//// artifact emission and complete saved-result reads.
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
import core/corruption
import core/json
import core/json_wire
import core/msgpack.{type MsgPackValue}
import core/report_value
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option}
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

/// A complete saved program result with independently produced host observations.
pub type SavedReport {
  /// The full value and original execution metadata, without transport credentials.
  SavedReport(
    /// The program's complete success or controlled error value.
    outcome: Outcome,
    /// The canonical digest of the compiled artifact that executed.
    manifest_hash: String,
    /// The build helper's actual enforcement observation.
    build: SavedStage,
    /// The satellite helper's actual enforcement observation.
    node: SavedStage,
    /// The original complete bounded host call log.
    calls: SavedCalls,
  )
}

/// An enforcement observation preserves absence and the helper's actual quality.
pub type SavedStage {
  /// Applied and skipped layers in their original order.
  Reported(
    /// Layers the helper reported applying.
    applied: List(String),
    /// Layers the helper reported skipping.
    skipped: List(String),
    /// The helper's original quality flag, without inference from layer names.
    quality: SavedQuality,
  )

  /// An absent report is not a claim that the stage was confined.
  Unreported(
    /// The original explanation for the absence.
    reason: String,
  )
}

/// The quality reported by the original helper.
pub type SavedQuality {
  /// The helper reported complete enforcement.
  Complete

  /// The helper reported degraded enforcement.
  Degraded
}

/// A capability call's original host-observed disposition.
pub type SavedCallStatus {
  /// The call succeeded.
  CallOk

  /// The call failed or was refused.
  CallFailed

  /// The satellite cancelled the call.
  CallCancelled

  /// The call remained active when the program settled.
  CallUnsettled
}

/// A bounded redacted call observation, in original admission order.
pub type SavedCall {
  /// Records one call without retaining its authority or credentials.
  SavedCall(
    /// The admitted capability name.
    cap: String,
    /// An optional redacted argument summary.
    args: Option(String),
    /// The host-observed disposition.
    status: SavedCallStatus,
    /// An optional error code.
    error: Option(String),
    /// Milliseconds from original execution start.
    start_ms: Int,
    /// Original call duration in milliseconds.
    duration_ms: Int,
  )
}

/// Complete execution counters and the original bounded itemised call list.
pub type SavedCalls {
  /// Itemisation may cover fewer calls than the complete counters.
  SavedCalls(
    /// Original execution start in Unix milliseconds.
    started_unix_ms: Int,
    /// Original total elapsed milliseconds.
    elapsed_ms: Int,
    /// All admitted calls, including those beyond the itemisation limit.
    total: Int,
    /// Failed or refused calls.
    failed: Int,
    /// Cancelled calls.
    cancelled: Int,
    /// Calls still active at settlement.
    unsettled: Int,
    /// At most 128 original call observations.
    items: List(SavedCall),
  )
}

/// A saved-result read preserves validation, policy and channel failures.
pub type ReadError {
  /// The supplied text is not a canonical bounded result reference.
  InvalidReference(reason: String)

  /// The authenticated owner refused the read with this code and explanation.
  ReadDenied(code: String, message: String)

  /// The capability channel could not carry the read.
  ReadUnavailable(reason: String)

  /// A reply changed the original reference, offset, length or report encoding.
  InvalidReport(reason: String)
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
/// A field a schema declared as `number` may nonetheless arrive
/// int-tagged — `number` admits `42`, and the value crosses the wire
/// carrying the tag it was written with — so try `as_int` when
/// `as_float` refuses one.
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

/// Parses JSON into the same structured value used by notes and child results.
/// Rejects duplicate object keys, excessive nesting, and trailing input.
///
/// ## Examples
///
/// ```gleam
/// report.decode_json("{\"count\":3}")
///   == Ok(report.object([#("count", report.int(3))]))
/// ```
pub fn decode_json(text: String) -> Result(Value, String) {
  json.parse(text)
  |> result.map(json_wire.of_json)
  |> result.map_error(fn(error) { error.subject <> ": " <> error.expected })
}

/// Encodes a structured value as compact JSON without coercing its contents.
/// Binary values, non-text keys, duplicate keys, and excessive nesting fail.
///
/// ## Examples
///
/// ```gleam
/// report.encode_json(report.object([#("count", report.int(3))]))
///   == Ok("{\"count\":3}")
/// ```
pub fn encode_json(value: Value) -> Result(String, String) {
  json_wire.to_json(value) |> result.map(json.to_string)
}

/// Loads a complete saved result through the authenticated session owner.
///
/// The reference names data; it grants no read authority. The host checks the
/// current session and retained digest before returning aligned chunks. This
/// helper collects at most 261 chunks, concatenates once, and validates the full
/// report. The host meters those calls across all references in this invocation;
/// reading does not renew its deadline, call credits or pooled byte budget.
/// Known metadata is typed, while the program's value and details remain Value.
/// Capability: `report.result_chunk`. Only configured owner hosts serve it.
///
/// ## Examples
///
/// ```gleam
/// // Use the result:// reference from an earlier code-mode final message.
/// case report.load_result(saved_reference) {
///   Ok(saved) -> saved.outcome
///   Error(_) -> report.failure("The saved result could not be read.")
/// }
/// ```
pub fn load_result(reference: String) -> Result(SavedReport, ReadError) {
  use checked <- result.try(
    report_value.parse_ref(reference)
    |> result.map_error(fn(error) {
      InvalidReference(corruption.describe(error))
    }),
  )
  use chunks <- result.try(
    read_chunks(reference, 0, report_value.ref_byte_length(checked), []),
  )

  // One concatenation retains the original linear byte budget. Appending each
  // chunk to an accumulated binary would repeatedly copy the complete prefix.
  chunks
  |> list.reverse
  |> bit_array.concat
  |> report_value.decode
  |> result.map(saved_report)
  |> result.map_error(fn(error) { InvalidReport(corruption.describe(error)) })
}

fn read_chunks(
  reference: String,
  offset: Int,
  remaining: Int,
  chunks: List(BitArray),
) -> Result(List(BitArray), ReadError) {
  use <- bool.lazy_guard(when: remaining == 0, return: fn() { Ok(chunks) })
  let expected = int.min(65_536, remaining)
  use reply <- result.try(
    dispatch.call(
      "report.result_chunk",
      wire.args([
        #("reference", wire.string(reference)),
        #("offset", wire.int(offset)),
      ]),
    )
    |> result.map_error(read_error),
  )
  use bytes <- result.try(read_chunk(reply, reference, offset, expected))

  // The checked reference bounds total bytes, so every successful call advances
  // one fixed slice toward completion. No response can prolong this recursion.
  read_chunks(reference, offset + expected, remaining - expected, [
    bytes,
    ..chunks
  ])
}

fn read_chunk(
  reply: MsgPackValue,
  reference: String,
  offset: Int,
  expected: Int,
) -> Result(BitArray, ReadError) {
  use Nil <- result.try(case reply {
    msgpack.MapValue([_, _, _]) -> Ok(Nil)
    _ -> Error(InvalidReport("expected the closed result chunk record"))
  })
  use echoed <- result.try(
    wire.string_field(reply, "reference") |> result.map_error(InvalidReport),
  )
  use at <- result.try(
    wire.int_field(reply, "offset") |> result.map_error(InvalidReport),
  )
  use bytes <- result.try(
    wire.binary_field(reply, "bytes") |> result.map_error(InvalidReport),
  )

  // Three required distinct fields exhaust the closed record. Matching the
  // original address and exact expected slice refuses replay and truncation.
  use <- bool.guard(
    when: echoed != reference
      || at != offset
      || bit_array.byte_size(bytes) != expected
      || bit_array.bit_size(bytes) != expected * 8,
    return: Error(InvalidReport(
      "result chunk changed reference, offset or length",
    )),
  )
  Ok(bytes)
}

fn read_error(error: CallError) -> ReadError {
  case error {
    Denied(code:, message:) -> ReadDenied(code:, message:)
    Unreachable(reason:) -> ReadUnavailable(reason:)
  }
}

fn saved_report(saved: report_value.CompleteReport) -> SavedReport {
  let metadata = report_value.report_metadata(saved)
  let enforcement = report_value.enforcement(metadata)
  let calls = report_value.calls(metadata)
  SavedReport(
    outcome: case report_value.outcome(saved) {
      report_value.Completed(value) -> Completed(value)
      report_value.Errored(message, details) -> Errored(message, details)
    },
    manifest_hash: report_value.manifest_hash(metadata),
    build: saved_stage(enforcement.build),
    node: saved_stage(enforcement.node),
    calls: SavedCalls(
      started_unix_ms: calls.started_unix_ms,
      elapsed_ms: calls.elapsed_ms,
      total: calls.total,
      failed: calls.failed,
      cancelled: calls.cancelled,
      unsettled: calls.unsettled,
      items: list.map(calls.items, saved_call),
    ),
  )
}

fn saved_stage(stage: report_value.StageReport) -> SavedStage {
  case stage {
    report_value.Unreported(reason) -> Unreported(reason)
    report_value.Reported(applied, skipped, quality) ->
      Reported(applied, skipped, case quality {
        report_value.Complete -> Complete
        report_value.Degraded -> Degraded
      })
  }
}

fn saved_call(call: report_value.CallRecord) -> SavedCall {
  SavedCall(
    cap: call.cap,
    args: call.args,
    status: case call.status {
      report_value.CallOk -> CallOk
      report_value.CallFailed -> CallFailed
      report_value.CallCancelled -> CallCancelled
      report_value.CallUnsettled -> CallUnsettled
    },
    error: call.error,
    start_ms: call.start_ms,
    duration_ms: call.duration_ms,
  )
}

/// A one-line rendering of a `ReportError`.
///
/// ## Examples
///
/// ```gleam
/// assert report.error_text(report.EmitUnavailable("no channel")) == "emit unavailable: no channel"
/// ```
///
pub fn error_text(error: ReportError) -> String {
  case error {
    EmitDenied(code:, message:) -> code <> ": " <> message
    EmitUnavailable(reason:) -> "emit unavailable: " <> reason
  }
}
