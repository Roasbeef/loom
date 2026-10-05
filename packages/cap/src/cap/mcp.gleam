//// `cap/mcp` — the shared vocabulary for the generated `cap/mcp/<server>`
//// modules: what an MCP tool call returns, and the ways it can fail.
////
//// This module carries **no authority**. It declares types and reads
//// values already in hand; it performs no capability call and holds no
//// door to one, so importing it grants nothing — the `cap/report`
//// precedent. The invoke that actually crosses the wire lives in
//// `cap/internal/mcp`, which a program cannot import, and is reachable
//// only through a generated `cap/mcp/<server>` façade the vetting
//// allowlist names. Trust is granted per server, by allowlisting that
//// server's module, never by this one.
////
//// A tool's arguments are built with `cap/report`'s value builders
//// (`report.object`, `report.string`, …): `Value` *is* `report.Value`,
//// the one structured-value type every seam already carries, so an MCP
//// argument map is composed with the same vocabulary an `Outcome` is —
//// no second builder set to learn, and nothing here to keep in sync
//// with it.

import cap/report
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// One block of a tool result's content. MCP servers answer with a list
/// of typed blocks; text is the kind a program reads, and every other
/// kind is carried by name only in v1 (`Other`), so a result holding an
/// image or a resource still decodes rather than failing the call.
pub type Content {
  /// A text block: `{type: "text", text}` on the wire.
  Text(text: String)

  /// Any other block kind, carried as its `type` string verbatim.
  Other(kind: String)
}

/// What a successful MCP tool call returns: the content blocks, plus the
/// tool's optional structured output (`structuredContent` in MCP terms)
/// when the server sent one.
pub type ToolResult {
  ToolResult(content: List(Content), structured: Option(report.Value))
}

/// A result's text content: every `Text` block, joined with newlines —
/// the common read for a tool whose answer is prose.
pub fn text(result: ToolResult) -> String {
  list.filter_map(result.content, fn(block) {
    case block {
      Text(text:) -> Ok(text)
      Other(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

/// A schema failure relative to the structured-content root.
pub type DecodeError {
  /// Literal path segments keep punctuation in property names unambiguous.
  DecodeError(
    /// Property names or zero-based array indices, outermost first.
    path: List(String),
    /// The expected shape or violated schema choice.
    reason: String,
  )
}

/// Why an MCP call failed. Descriptive variants for the causes a program
/// branches on; `McpDenied` carries any other broker code verbatim;
/// `ServerUnavailable` is a transport or reachability failure.
pub type McpError {
  /// The server ran the tool and the tool reported failure
  /// (`is_error: true`). `message` is the joined text content; the full
  /// blocks ride along for a caller that wants more than prose.
  ToolFailed(message: String, content: List(Content))

  /// The capability channel could not carry the call, or the harness
  /// router refused it as `mcp_unavailable` — the server is not running
  /// or its client has gone. (A server this host never configured is a
  /// different refusal: `unsupported_cap`, under `McpDenied`.)
  ServerUnavailable(reason: String)

  /// Any other in-band broker or router refusal, code preserved
  /// verbatim (`unsupported_cap`, `mcp_timeout`, a ceiling, …).
  McpDenied(code: String, message: String)

  /// The `cap_result` did not match the pinned result shape.
  ResultMalformed(reason: String)

  /// The tool succeeded but its structured output failed its declared schema.
  /// The complete capability result survives for inspection or text fallback.
  ResultSchemaMismatch(
    /// The exact failing property or list index and the expected shape.
    error: DecodeError,
    /// The original content blocks and optional structured value.
    result: ToolResult,
  )
}

/// A one-line rendering of an `McpError`.
///
/// ## Examples
///
/// ```gleam
/// assert mcp.error_text(mcp.ServerUnavailable("down")) == "server unavailable: down"
/// ```
///
pub fn error_text(error: McpError) -> String {
  case error {
    ToolFailed(message:, content: _) -> "tool failed: " <> message
    ServerUnavailable(reason:) -> "server unavailable: " <> reason
    McpDenied(code:, message:) -> code <> ": " <> message
    ResultMalformed(reason:) -> "malformed result: " <> reason
    ResultSchemaMismatch(error:, result: _) ->
      "result did not match the expected schema at "
      <> string.join(error.path, ".")
      <> ": "
      <> error.reason
  }
}
