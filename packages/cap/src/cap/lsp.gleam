//// `cap/lsp` — semantic queries through the project's language server:
//// references, go-to-definition, rename, and diagnostics. These are
//// real semantic operations (the server understands the language), not
//// regex surgery — the same first-class LSP tooling the harness exposes
//// (design §5.4), reached as typed `cap_call`s.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/result

/// A position in a file: zero-based `line` and `character`, matching the
/// LSP convention.
pub type Location {
  Location(path: String, line: Int, character: Int)
}

/// A text edit a rename would apply.
pub type TextEdit {
  TextEdit(path: String, line: Int, character: Int, new_text: String)
}

/// A diagnostic's severity.
pub type Severity {
  SeverityError
  SeverityWarning
  SeverityInformation
  SeverityHint
}

/// One diagnostic reported by the language server.
pub type Diagnostic {
  Diagnostic(location: Location, severity: Severity, message: String)
}

/// Why an LSP query failed.
pub type LspError {
  /// No language server is available for the file's language.
  NoServer(message: String)
  /// The broker refused the query in-band.
  LspDenied(code: String, message: String)
  /// The capability channel could not carry the call.
  LspUnavailable(reason: String)
}

/// All references to the symbol at `location`.
///
/// Capability: `lsp.references`.
pub fn references(location: Location) -> Result(List(Location), LspError) {
  query_locations("lsp.references", location)
}

/// The definition site(s) of the symbol at `location`.
///
/// Capability: `lsp.definition`.
pub fn definition(location: Location) -> Result(List(Location), LspError) {
  query_locations("lsp.definition", location)
}

/// The edits a rename of the symbol at `location` to `new_name` would
/// apply. The caller applies them (e.g. via `cap/fs`) — the query itself
/// changes nothing.
///
/// Capability: `lsp.rename`.
pub fn rename(
  location: Location,
  new_name: String,
) -> Result(List(TextEdit), LspError) {
  let args =
    wire.args([
      #("location", encode_location(location)),
      #("new_name", wire.string(new_name)),
    ])
  use value <- result.try(
    dispatch.call("lsp.rename", args) |> result.map_error(map_error),
  )
  wire.array_of(value, "edits", of: decode_text_edit)
  |> result.map_error(fn(reason) {
    LspUnavailable("bad lsp.rename result: " <> reason)
  })
}

/// Diagnostics for a file.
///
/// Capability: `lsp.diagnostics`.
pub fn diagnostics(path: String) -> Result(List(Diagnostic), LspError) {
  let args = wire.args([#("path", wire.string(path))])
  use value <- result.try(
    dispatch.call("lsp.diagnostics", args) |> result.map_error(map_error),
  )
  wire.array_of(value, "diagnostics", of: decode_diagnostic)
  |> result.map_error(fn(reason) {
    LspUnavailable("bad lsp.diagnostics result: " <> reason)
  })
}

fn query_locations(
  cap: String,
  location: Location,
) -> Result(List(Location), LspError) {
  let args = wire.args([#("location", encode_location(location))])
  use value <- result.try(
    dispatch.call(cap, args) |> result.map_error(map_error),
  )
  wire.array_of(value, "locations", of: decode_location)
  |> result.map_error(fn(reason) {
    LspUnavailable("bad " <> cap <> " result: " <> reason)
  })
}

fn encode_location(location: Location) -> MsgPackValue {
  wire.args([
    #("path", wire.string(location.path)),
    #("line", wire.int(location.line)),
    #("character", wire.int(location.character)),
  ])
}

fn decode_location(value: MsgPackValue) -> Result(Location, String) {
  use path <- result.try(wire.string_field(value, "path"))
  use line <- result.try(wire.int_field(value, "line"))
  use character <- result.try(wire.int_field(value, "character"))
  Ok(Location(path:, line:, character:))
}

fn decode_text_edit(value: MsgPackValue) -> Result(TextEdit, String) {
  use path <- result.try(wire.string_field(value, "path"))
  use line <- result.try(wire.int_field(value, "line"))
  use character <- result.try(wire.int_field(value, "character"))
  use new_text <- result.try(wire.string_field(value, "new_text"))
  Ok(TextEdit(path:, line:, character:, new_text:))
}

fn decode_diagnostic(value: MsgPackValue) -> Result(Diagnostic, String) {
  use location <- result.try(decode_location(value))
  use severity <- result.try(wire.int_field(value, "severity"))
  use message <- result.try(wire.string_field(value, "message"))
  Ok(Diagnostic(location:, severity: severity_from_int(severity), message:))
}

// LSP severities are 1..=4 (error, warning, information, hint); anything
// else is treated as the most severe so a program never under-reports.
fn severity_from_int(code: Int) -> Severity {
  case code {
    1 -> SeverityError
    2 -> SeverityWarning
    3 -> SeverityInformation
    4 -> SeverityHint
    _ -> SeverityError
  }
}

fn map_error(error: CallError) -> LspError {
  case error {
    Unreachable(reason:) -> LspUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "no_server" -> NoServer(message:)
        _ -> LspDenied(code:, message:)
      }
  }
}
