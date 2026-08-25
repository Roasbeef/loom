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

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
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
