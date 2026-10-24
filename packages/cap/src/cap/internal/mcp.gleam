//// The one seam MCP traffic crosses: marshal a tool call into a
//// `cap_call` under the per-server capability name `mcp.<server>`, and
//// decode the pinned result shape back into `cap/mcp`'s vocabulary.
////
//// ## Why this module is internal, and what that buys
////
//// The confinement is two layers, and each does one job. The vetting
//// allowlist admits only the generated `cap/mcp/<server>` façades, so a
//// program reaches exactly the servers somebody decided to hand it —
//// per-server trust, visible in the import list. This module being
//// `cap/internal/*` is the second layer: the Gleam compiler forbids
//// another package from importing an internal module, so a program
//// cannot name `invoke` and dispatch to an arbitrary server string —
//// which would be the generic MCP dispatcher by the back door, per-tool
//// names and all, and would collapse the per-server trust granularity
//// to "any server the router knows".
////
//// Generated façades call `invoke` or `invoke_typed` with fixed server and
//// tool names. Their typed records compose only report builders and the total
//// combinators in `mcp_codec`; schema text appears only as escaped literals.
//// Wire marshaling and dispatch remain here, so schema-derived projections
//// cannot select another capability or alter the envelope.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/mcp_codec
import cap/internal/wire
import cap/mcp.{type ToolResult, Other, Text, ToolResult}
import cap/report
import core/msgpack.{type MsgPackValue}
import gleam/option.{None, Some}
import gleam/result

/// Calls one tool on one MCP server.
///
/// Capability: `mcp.<server>` — per-server, because the server is the
/// trust granularity: per-server names give the host router per-server
/// rows, and per-server ceilings later. `tool` is the server's original
/// tool name, verbatim — wire identity is never mangled, whatever the
/// generated façade renamed for Gleam. `arguments` is the tool's
/// JSON-shaped argument map, built with `cap/report`'s value builders.
pub fn invoke(
  server: String,
  tool: String,
  arguments: report.Value,
) -> Result(ToolResult, mcp.McpError) {
  let args =
    wire.args([#("tool", wire.string(tool)), #("arguments", arguments)])
  use value <- result.try(
    dispatch.call("mcp." <> server, args) |> result.map_error(map_error),
  )
  use #(tool_result, is_error) <- result.try(
    decode_result(value)
    |> result.map_error(fn(reason) {
      mcp.ResultMalformed(reason: "bad mcp result: " <> reason)
    }),
  )

  // Report tool execution failure or return the successful tool result.
  case is_error {
    False -> Ok(tool_result)

    // The server ran the tool and the tool said no: an in-band failure
    // the program reads, with the joined text as its message.
    True ->
      Error(mcp.ToolFailed(
        message: mcp.text(tool_result),
        content: tool_result.content,
      ))
  }
}

/// Calls a tool and decodes its required structured output against its schema.
/// Transport and tool failures keep their existing errors. Schema failures
/// retain the original tool result, including text the caller may inspect.
///
/// ## Examples
///
/// ```gleam
/// mcp.invoke_typed("inventory", "count", report.object([]), mcp_codec.int())
/// // -> Ok(3), or a transport, tool, or structured-schema error.
/// ```
pub fn invoke_typed(
  server: String,
  tool: String,
  arguments: report.Value,
  decoder: mcp_codec.Decoder(a),
) -> Result(a, mcp.McpError) {
  use tool_result <- result.try(invoke(server, tool, arguments))

  // Decode structured content from tool result if present.
  let decoded = case tool_result.structured {
    None -> Error(mcp.DecodeError([], "missing structured content"))
    Some(value) -> mcp_codec.decode(value, decoder)
  }

  decoded
  |> result.map_error(fn(error) { mcp.ResultSchemaMismatch(error, tool_result) })
}

/// Maps low-level channel errors into domain MCP errors.
fn map_error(error: CallError) -> mcp.McpError {
  case error {
    Unreachable(reason:) -> mcp.ServerUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "mcp_unavailable" -> mcp.ServerUnavailable(reason: message)
        _ -> mcp.McpDenied(code:, message:)
      }
  }
}

/// Decodes the payload result structure into content blocks and error status.
fn decode_result(value: MsgPackValue) -> Result(#(ToolResult, Bool), String) {
  use content <- result.try(wire.array_of(value, "content", of: decode_block))
  use is_error <- result.try(error_flag(value))

  // Presence belongs to the MCP result envelope. A present null must reach
  // the schema decoder rather than becoming indistinguishable from absence.
  let structured = case wire.field(value, "structured") {
    Ok(found) -> Some(found)
    Error(_) -> None
  }

  Ok(#(ToolResult(content:, structured:), is_error))
}

/// Decodes a single content block into a text or other content variant.
fn decode_block(value: MsgPackValue) -> Result(mcp.Content, String) {
  use kind <- result.try(wire.string_field(value, "type"))

  // Decode the content block based on whether its type is text.
  case kind {
    "text" -> wire.string_field(value, "text") |> result.map(Text)

    // Every other kind is carried by name only in v1; the block's other
    // fields are dropped rather than failing a result the program can
    // still mostly read.
    other -> Ok(Other(kind: other))
  }
}

/// Reads the error boolean flag from the result payload.
fn error_flag(value: MsgPackValue) -> Result(Bool, String) {
  case wire.field(value, "is_error") {
    // Absent reads as success; the doc on `decode_result` says why.
    Error(_missing) -> Ok(False)
    Ok(msgpack.BoolValue(flag)) -> Ok(flag)
    Ok(msgpack.NilValue)
    | Ok(msgpack.IntValue(..))
    | Ok(msgpack.FloatValue(..))
    | Ok(msgpack.StringValue(..))
    | Ok(msgpack.BinaryValue(..))
    | Ok(msgpack.ArrayValue(..))
    | Ok(msgpack.MapValue(..)) -> Error("field is_error is not a boolean")
  }
}
