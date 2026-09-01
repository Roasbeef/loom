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
//// The generator emits façades that only *call* `invoke` — one typed
//// function per tool, each a name, a signature, and this one call —
//// and never emits marshaling logic of its own. All of it lives here,
//// written once. That is what shrinks the adversarial surface of a
//// hostile `tools/list`: server-influenced text can reach a generated
//// module only as names and signatures, never as code that touches the
//// wire.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import cap/mcp.{type ToolResult, Other, Text, ToolResult}
import cap/report
import core/msgpack.{type MsgPackValue}
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

// The harness's own refusal name for a server that is not running, not
// configured on this host, or whose client has gone reads back as the
// variant that means the same thing; every other in-band refusal travels
// as `McpDenied` with its code verbatim, so a code neither side has
// learned yet is carried rather than folded into a category. The two
// packages share no dependency — they are the ends of one wire, not
// peers — so this side restates the name, exactly as `cap/strand`
// restates the orchestration codes, and `client/mcp` pins its half.
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

// Decodes the pinned result shape:
// `{content: [<block>...], is_error: Bool, structured?: <value>}`.
// Total: any wrong shape is a `String` fault the caller wraps as
// `ResultMalformed`, never a crash. `is_error` is tolerated absent and
// reads as `False` — the harness always writes it, but a missing flag on
// an otherwise well-formed result is the protocol posture everywhere
// else here (see `wire.binary_field`'s nil tolerance): decode what was
// meant rather than refuse what was elided.
fn decode_result(value: MsgPackValue) -> Result(#(ToolResult, Bool), String) {
  use content <- result.try(wire.array_of(value, "content", of: decode_block))
  use is_error <- result.try(error_flag(value))
  let structured = wire.optional_field(value, "structured")
  Ok(#(ToolResult(content:, structured:), is_error))
}

fn decode_block(value: MsgPackValue) -> Result(mcp.Content, String) {
  use kind <- result.try(wire.string_field(value, "type"))
  case kind {
    "text" -> wire.string_field(value, "text") |> result.map(Text)

    // Every other kind is carried by name only in v1; the block's other
    // fields are dropped rather than failing a result the program can
    // still mostly read.
    other -> Ok(Other(kind: other))
  }
}

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
