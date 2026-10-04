//// Canonical semantic content for future chunked workspace custody transport.
////
//// Invocation v1 is exactly [1, 0, scope, operation, step, origin, request_id,
//// request]. Scope is [session UUIDv7, executor, workspace, workspace epoch,
//// session epoch]. Completion v1 is exactly [1, 1, result], where success is
//// [0, response, diagnostics-option] and service failure is [1, service-error].
//// Every domain variant is [tag, fields...] with zero-based declaration-order
//// tags, except the named read/Git projections spelled out in their modules.
//// Result is [0, success] or [1, error]; Option is [0] or [1, value]. Record
//// arrays start with tag zero, except Scope and ToolOrigin. ToolOrigin is
//// exactly [source index, 32-byte arguments digest]. No optional surplus fields
//// or unknown tags are admitted. Encoding uses core/msgpack's shortest scalar/container form;
//// decoding also checks canonical bytes, so immutable evidence has one spelling.
////
//// The byte ceilings are 9 MiB for an invocation and 32 MiB for a completion,
//// covering eight-MiB request material and edit preimage/postimage plus bounded
//// diagnostics. The 32-MiB reservation covers an eight-MiB preimage plus a
//// nearly sixteen-MiB postimage and the canonical envelope/observer block;
//// 24 MiB would leave no space for those last fields after a maximal edit.
//// These are semantic-content limits, NOT TLS frame sizes. The
//// existing 256-KiB wire needs a separately bounded chunking/custody protocol.
//// Before core/msgpack.decode, preflight scans lengths and enforces depth 32,
//// 65536 aggregate nodes and 8192 elements per container without allocating
//// decoded inventories. Typed decoders then enforce existing domain ceilings.
//// Encode validates the same representability and allocation rules; host values
//// containing runtime exit terms cannot cross this data-only boundary.
////
//// request owns invocation variants; read, search, edit and git own their
//// domain projections; response connects operation results to those domains.
//// decode_completion requires the retained Request and checks response_matches
//// before releasing any success. Identity comparison and durable reservation
//// belong to the caller. This codec grants no authority and executes no effects.

import core/ids
import core/msgpack
import core/workspace as cw
import gleam/bit_array
import gleam/result
import tools/workspace
import tools/workspace_codec/preflight
import tools/workspace_codec/request
import tools/workspace_codec/response
import tools/workspace_codec/value as v
import tools/workspace_local

/// Exact invocation semantic-content ceiling, nine MiB.
pub const max_invocation_bytes = 9_437_184

/// Exact completion semantic-content ceiling, thirty-two MiB.
pub const max_completion_bytes = 33_554_432

/// Version of this closed positional semantic schema.
pub const schema_version = 1

/// Fixed bounded diagnostics which never retain rejected peer data.
pub type CodecError {
  /// Malformed, noncanonical or domain-invalid content, including runtime terms.
  InvalidPayload

  /// The complete semantic content exceeds its byte reservation.
  PayloadTooLarge

  /// Alignment, nesting, container count or aggregate allocation was refused.
  PreflightRefused

  /// The response kind or read/Git projection differs from the retained request.
  ResponseMismatch
}

/// Encodes all immutable invocation fields in the documented canonical order.
///
/// ## Examples
///
/// `decode_invocation(encode_invocation(call))` preserves the whole call.
pub fn encode_invocation(
  invocation: workspace.Invocation,
) -> Result(BitArray, CodecError) {
  let value = invocation_value(invocation)
  use _ <- result.try(invocation_field(value) |> invalid)
  encode(value, max_invocation_bytes)
}

/// Totally decodes one canonical bounded invocation through existing constructors.
///
/// ## Examples
///
/// Unknown versions, extra fields and invalid UUIDs return fixed CodecError data.
pub fn decode_invocation(
  bytes: BitArray,
) -> Result(workspace.Invocation, CodecError) {
  use value <- result.try(decode(bytes, max_invocation_bytes))
  use invocation <- result.try(invocation_field(value) |> invalid)

  // UUID parsers accept uppercase input, but durable identity has one spelling.
  use Nil <- result.try(
    v.check(fn() { invocation_value(invocation) == value }) |> invalid,
  )
  Ok(invocation)
}

/// Encodes exact completion evidence, including diagnostics, for a retained request.
///
/// ## Examples
///
/// A read success cannot be encoded for a retained Write request.
pub fn encode_completion(
  expected: workspace.Request,
  completed: Result(workspace_local.Completed, workspace.ServiceError),
) -> Result(BitArray, CodecError) {
  use Nil <- result.try(matches(expected, completed))
  let value =
    msgpack.ArrayValue([
      msgpack.IntValue(schema_version),
      msgpack.IntValue(1),
      completion_value(completed),
    ])
  use _ <- result.try(completion_field(value) |> invalid)
  encode(value, max_completion_bytes)
}

/// Decodes completion evidence and refuses a mismatched response projection.
///
/// ## Examples
///
/// The caller supplies the original persisted Request, never a peer's guess.
pub fn decode_completion(
  expected: workspace.Request,
  bytes: BitArray,
) -> Result(
  Result(workspace_local.Completed, workspace.ServiceError),
  CodecError,
) {
  use value <- result.try(decode(bytes, max_completion_bytes))
  use completed <- result.try(completion_field(value) |> invalid)
  use Nil <- result.try(matches(expected, completed))
  Ok(completed)
}

fn invocation_value(invocation: workspace.Invocation) -> msgpack.MsgPackValue {
  let #(scope, op, step, origin, id) = workspace.invocation_identity(invocation)
  msgpack.ArrayValue([
    msgpack.IntValue(schema_version),
    msgpack.IntValue(0),
    scope_value(scope),
    msgpack.StringValue(ids.op_id_to_string(op)),
    msgpack.StringValue(cw.step_string(step)),
    request.origin_value(origin),
    msgpack.StringValue(ids.entry_id_to_string(id)),
    request.request_value(workspace.request(invocation)),
  ])
}

fn scope_value(scope: cw.Scope) -> msgpack.MsgPackValue {
  let #(session, binding) = cw.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) = cw.binding_fields(binding)
  let #(executor, workspace_id) = cw.selector_fields(selector)
  msgpack.ArrayValue([
    msgpack.StringValue(ids.session_id_to_string(session)),
    msgpack.StringValue(executor),
    msgpack.StringValue(workspace_id),
    msgpack.IntValue(workspace_epoch),
    msgpack.IntValue(session_epoch),
  ])
}

fn invocation_field(
  value: msgpack.MsgPackValue,
) -> Result(workspace.Invocation, Nil) {
  case value {
    msgpack.ArrayValue([
      msgpack.IntValue(1),
      msgpack.IntValue(0),
      scope,
      op,
      step,
      origin,
      id,
      payload,
    ]) -> {
      use scope <- result.try(scope_field(scope))
      use op <- result.try(v.text(op))
      use op <- result.try(ids.parse_op_id(op) |> result.replace_error(Nil))
      use step <- result.try(v.text(step))
      use step <- result.try(cw.step(step) |> result.replace_error(Nil))

      // Smart constructors retain original physical coordinates and provenance.
      use origin <- result.try(request.parse_origin(origin))
      use id <- result.try(v.text(id))
      use id <- result.try(ids.parse_entry_id(id) |> result.replace_error(Nil))
      use payload <- result.try(request.parse_request(payload))
      Ok(workspace.invocation(scope, op, step, origin, id, payload))
    }
    _ -> Error(Nil)
  }
}

fn scope_field(value: msgpack.MsgPackValue) -> Result(cw.Scope, Nil) {
  case value {
    msgpack.ArrayValue([
      session,
      executor,
      workspace_id,
      workspace_epoch,
      session_epoch,
    ]) -> {
      use session <- result.try(v.text(session))
      use executor <- result.try(v.text(executor))
      use workspace_id <- result.try(v.text(workspace_id))
      use workspace_epoch <- result.try(v.integer(workspace_epoch))
      use session_epoch <- result.try(v.integer(session_epoch))
      cw.scope_from_fields(
        session,
        workspace_id,
        executor,
        session_epoch,
        workspace_epoch,
      )
      |> result.replace_error(Nil)
    }
    _ -> Error(Nil)
  }
}

fn completion_value(
  completed: Result(workspace_local.Completed, workspace.ServiceError),
) -> msgpack.MsgPackValue {
  case completed {
    Ok(workspace_local.Completed(reply, diagnostics)) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        response.response_value(reply),
        v.option_value(diagnostics, msgpack.StringValue),
      ])
    Error(error) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        response.service_error_value(error),
      ])
  }
}

fn completion_field(
  value: msgpack.MsgPackValue,
) -> Result(Result(workspace_local.Completed, workspace.ServiceError), Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(1), msgpack.IntValue(1), content]) ->
      completed_field(content)
    _ -> Error(Nil)
  }
}

fn completed_field(
  value: msgpack.MsgPackValue,
) -> Result(Result(workspace_local.Completed, workspace.ServiceError), Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), reply, diagnostics]) -> {
      use reply <- result.try(response.parse_response(reply))
      use diagnostics <- result.try(v.option_field(diagnostics, v.diagnostic))
      Ok(Ok(workspace_local.Completed(reply, diagnostics)))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), error]) ->
      result.map(response.parse_service_error(error), Error)
    _ -> Error(Nil)
  }
}

fn matches(
  expected: workspace.Request,
  completed: Result(workspace_local.Completed, workspace.ServiceError),
) -> Result(Nil, CodecError) {
  case completed {
    Error(_) -> Ok(Nil)
    Ok(completed) ->
      case workspace.response_matches(expected, completed.response) {
        True -> Ok(Nil)
        False -> Error(ResponseMismatch)
      }
  }
}

fn encode(
  value: msgpack.MsgPackValue,
  cap: Int,
) -> Result(BitArray, CodecError) {
  use bytes <- result.try(msgpack.encode(value) |> invalid)
  use Nil <- result.try(size(bytes, cap))
  use Nil <- result.try(
    preflight.scan(bytes) |> result.replace_error(PreflightRefused),
  )
  Ok(bytes)
}

fn decode(
  bytes: BitArray,
  cap: Int,
) -> Result(msgpack.MsgPackValue, CodecError) {
  use Nil <- result.try(size(bytes, cap))
  use Nil <- result.try(
    preflight.scan(bytes) |> result.replace_error(PreflightRefused),
  )
  use value <- result.try(msgpack.decode(bytes) |> invalid)

  // One spelling matters when these bytes become immutable custody evidence.
  use canonical <- result.try(msgpack.encode(value) |> invalid)
  use Nil <- result.try(v.check(fn() { canonical == bytes }) |> invalid)
  Ok(value)
}

fn size(bytes: BitArray, cap: Int) -> Result(Nil, CodecError) {
  case bit_array.byte_size(bytes) <= cap {
    True -> Ok(Nil)
    False -> Error(PayloadTooLarge)
  }
}

fn invalid(value: Result(a, e)) -> Result(a, CodecError) {
  result.replace_error(value, InvalidPayload)
}
