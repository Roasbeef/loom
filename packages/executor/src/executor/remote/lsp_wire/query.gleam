//// Complete interactive LSP rows and errors retain their existing query meanings.
////
//// Symbol queries keep every valid optional combination. Sites use one-based
//// codepoint coordinates and canonical executor path spellings. Outline wire
//// rows are flat preorder; backward parents and a 256-level semantic ceiling
//// precede reconstruction, and canonical re-encoding rejects alternate order.

import core/msgpack as m
import executor/remote/lsp_wire/value as v
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/observation as o
import lsp/query as q

/// Encodes all original optional symbol coordinates.
///
/// ## Examples
///
/// A line is nil when the query leaves it unspecified.
@internal
pub fn symbol_value(query: q.SymbolQuery) -> m.MsgPackValue {
  m.ArrayValue([
    m.StringValue(query.symbol),
    v.option(query.path, m.StringValue),
    v.option(query.line, m.IntValue),
  ])
}

/// Decodes meaningful optional combinations and positive one-based lines.
///
/// ## Examples
///
/// A line without a path is refused.
@internal
pub fn parse_symbol(value: m.MsgPackValue) -> Result(q.SymbolQuery, Nil) {
  case value {
    m.ArrayValue([symbol, path, line]) -> {
      use symbol <- result.try(v.name(symbol, 131_072))
      use path <- result.try(v.optional(path, v.path))
      use line <- result.try(
        v.optional(line, fn(value) {
          v.integer(value, 1, 9_223_372_036_854_775_807)
        }),
      )
      use Nil <- result.try(v.check(fn() { line == None || path != None }))
      Ok(q.SymbolQuery(symbol:, path:, line:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes one complete one-based site.
///
/// ## Examples
///
/// Site text retains its original UTF-8 bytes.
@internal
pub fn site_value(site: q.Site) -> m.MsgPackValue {
  m.ArrayValue([
    m.StringValue(site.path),
    m.IntValue(site.line),
    m.IntValue(site.column),
    m.StringValue(site.text),
  ])
}

/// Decodes admitted path spelling and positive codepoint positions.
///
/// ## Examples
///
/// Zero line or column cannot become a successful site.
@internal
pub fn parse_site(value: m.MsgPackValue) -> Result(q.Site, Nil) {
  case value {
    m.ArrayValue([path, line, column, text]) -> {
      use path <- result.try(v.path(path))
      use line <- result.try(v.integer(line, 1, 9_223_372_036_854_775_807))
      use column <- result.try(v.integer(column, 1, 9_223_372_036_854_775_807))
      use text <- result.try(v.text(text, 4_194_304))
      Ok(q.Site(path:, line:, column:, text:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes the independent finite observation scope.
///
/// ## Examples
///
/// Outlines and explicit reference targets retain separate ordered inventories.
@internal
pub fn observation_request_value(request: o.Request) -> m.MsgPackValue {
  m.ArrayValue([
    m.StringValue(request.server),
    m.StringValue(request.root),
    v.array(request.outlines, m.StringValue),
    v.array(request.targets, symbol_value),
  ])
}

/// Checks complete observation scope counts and path-bearing targets.
/// Repeated paths retain their original positions in the bounded request.
///
/// ## Examples
///
/// A thirty-third target refuses rather than truncating the request.
@internal
pub fn parse_observation_request(
  value: m.MsgPackValue,
) -> Result(o.Request, Nil) {
  case value {
    m.ArrayValue([server, root, outlines, targets]) -> {
      use server <- result.try(v.text(server, 128))
      use Nil <- result.try(
        v.check(fn() { !string.contains(server, "\u{0000}") }),
      )
      use root <- result.try(case root {
        m.StringValue("") -> Ok("")
        value -> v.path(value)
      })
      use outlines <- result.try(v.items(outlines, 16, v.path))
      use targets <- result.try(v.items(targets, 32, parse_symbol))
      use Nil <- result.try(
        v.check(fn() { list.all(targets, fn(target) { target.path != None }) }),
      )
      Ok(o.Request(server:, root:, outlines:, targets:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes Started versus already Warm without choosing a default server.
///
/// ## Examples
///
/// Started retains the configured server label.
@internal
pub fn warmth_value(warmth: q.Warmth) -> m.MsgPackValue {
  case warmth {
    q.Warm -> m.ArrayValue([m.IntValue(0)])
    q.Started(server) -> m.ArrayValue([m.IntValue(1), m.StringValue(server)])
  }
}

/// Decodes the exact closed warmth shape.
///
/// ## Examples
///
/// An unknown warmth tag is refused.
@internal
pub fn parse_warmth(value: m.MsgPackValue) -> Result(q.Warmth, Nil) {
  case value {
    m.ArrayValue([m.IntValue(0)]) -> Ok(q.Warm)
    m.ArrayValue([m.IntValue(1), server]) ->
      v.name(server, 128) |> result.map(q.Started)
    _ -> Error(Nil)
  }
}

/// Encodes a complete typed served value.
///
/// ## Examples
///
/// Warmth remains outside its result payload.
@internal
pub fn served_value(
  served: q.Served(a),
  encode: fn(a) -> m.MsgPackValue,
) -> m.MsgPackValue {
  m.ArrayValue([warmth_value(served.warmth), encode(served.value)])
}

/// Decodes both the warmth and complete result payload.
///
/// ## Examples
///
/// Surplus wrapper fields are refused.
@internal
pub fn parse_served(
  value: m.MsgPackValue,
  decode: fn(m.MsgPackValue) -> Result(a, Nil),
) -> Result(q.Served(a), Nil) {
  case value {
    m.ArrayValue([warmth, value]) -> {
      use warmth <- result.try(parse_warmth(warmth))
      use value <- result.try(decode(value))
      Ok(q.Served(value:, warmth:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes a complete reference positional row.
///
/// ## Examples
///
/// Every original field participates in the retained semantic result.
@internal
pub fn reference_value(row: q.Reference) -> m.MsgPackValue {
  m.ArrayValue([site_value(row.site), v.option(row.container, m.StringValue)])
}

/// Decodes every field before accepting the complete reference row.
///
/// ## Examples
///
/// Surplus or malformed fields refuse the whole result.
@internal
pub fn parse_reference(value: m.MsgPackValue) -> Result(q.Reference, Nil) {
  case value {
    m.ArrayValue([site, container]) -> {
      use site <- result.try(parse_site(site))
      use container <- result.try(
        v.optional(container, fn(value) { v.text(value, 4_194_304) }),
      )
      Ok(q.Reference(site:, container:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes a complete hover positional row.
///
/// ## Examples
///
/// Every original field participates in the retained semantic result.
@internal
pub fn hover_value(row: q.Hover) -> m.MsgPackValue {
  m.ArrayValue([site_value(row.site), m.StringValue(row.contents)])
}

/// Decodes every field before accepting the complete hover row.
///
/// ## Examples
///
/// Surplus or malformed fields refuse the whole result.
@internal
pub fn parse_hover(value: m.MsgPackValue) -> Result(q.Hover, Nil) {
  case value {
    m.ArrayValue([site, contents]) -> {
      use site <- result.try(parse_site(site))
      use contents <- result.try(v.text(contents, 4_194_304))
      Ok(q.Hover(site:, contents:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes a complete call positional row.
///
/// ## Examples
///
/// Every original field participates in the retained semantic result.
@internal
pub fn call_value(row: q.Call) -> m.MsgPackValue {
  m.ArrayValue([
    m.StringValue(row.name),
    site_value(row.site),
    v.array(row.at, site_value),
  ])
}

/// Decodes every field before accepting the complete call row.
///
/// ## Examples
///
/// Surplus or malformed fields refuse the whole result.
@internal
pub fn parse_call(value: m.MsgPackValue) -> Result(q.Call, Nil) {
  case value {
    m.ArrayValue([name, site, at]) -> {
      use name <- result.try(v.text(name, 4_194_304))
      use site <- result.try(parse_site(site))
      use at <- result.try(v.items(at, 10_000, parse_site))
      Ok(q.Call(name:, site:, at:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes a complete diagnostic positional row.
///
/// ## Examples
///
/// Every original field participates in the retained semantic result.
@internal
pub fn diagnostic_value(row: q.Diagnostic) -> m.MsgPackValue {
  m.ArrayValue([
    site_value(row.site),
    severity_value(row.severity),
    m.StringValue(row.message),
  ])
}

/// Decodes every field before accepting the complete diagnostic row.
///
/// ## Examples
///
/// Surplus or malformed fields refuse the whole result.
@internal
pub fn parse_diagnostic(value: m.MsgPackValue) -> Result(q.Diagnostic, Nil) {
  case value {
    m.ArrayValue([site, severity, message]) -> {
      use site <- result.try(parse_site(site))
      use severity <- result.try(parse_severity(severity))
      use message <- result.try(v.text(message, 4_194_304))
      Ok(q.Diagnostic(site:, severity:, message:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes a complete file edit positional row.
///
/// ## Examples
///
/// Every original field participates in the retained semantic result.
@internal
pub fn file_edit_value(row: q.FileEdit) -> m.MsgPackValue {
  m.ArrayValue([
    m.StringValue(row.path),
    m.StringValue(row.base),
    m.StringValue(row.edited),
    m.IntValue(row.edits),
  ])
}

/// Decodes every field before accepting the complete file edit row.
///
/// ## Examples
///
/// Surplus or malformed fields refuse the whole result.
@internal
pub fn parse_file_edit(value: m.MsgPackValue) -> Result(q.FileEdit, Nil) {
  case value {
    m.ArrayValue([path, base, edited, edits]) -> {
      use path <- result.try(v.path(path))
      use base <- result.try(v.text(base, 4_194_304))
      use edited <- result.try(v.text(edited, 4_194_304))
      use edits <- result.try(v.integer(edits, 0, 9_223_372_036_854_775_807))
      Ok(q.FileEdit(path:, base:, edited:, edits:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes the unchanged closed diagnostic severity order.
///
/// ## Examples
///
/// SeverityError remains the first explicit severity.
@internal
pub fn severity_value(severity: q.Severity) -> m.MsgPackValue {
  m.IntValue(case severity {
    q.SeverityError -> 0
    q.SeverityWarning -> 1
    q.SeverityInformation -> 2
    q.SeverityHint -> 3
  })
}

/// Refuses absent and unknown severities rather than downgrading them.
///
/// ## Examples
///
/// A fifth severity has no meaning in this vocabulary.
@internal
pub fn parse_severity(value: m.MsgPackValue) -> Result(q.Severity, Nil) {
  case value {
    m.IntValue(0) -> Ok(q.SeverityError)
    m.IntValue(1) -> Ok(q.SeverityWarning)
    m.IntValue(2) -> Ok(q.SeverityInformation)
    m.IntValue(3) -> Ok(q.SeverityHint)
    _ -> Error(Nil)
  }
}

/// Preserves Settled versus Unsettled even when the diagnostic list is empty.
///
/// ## Examples
///
/// An unsettled empty list is not clean code.
@internal
pub fn diagnostics_value(diagnostics: q.Diagnostics) -> m.MsgPackValue {
  case diagnostics {
    q.Settled(rows) ->
      m.ArrayValue([m.IntValue(0), v.array(rows, diagnostic_value)])
    q.Unsettled(rows) ->
      m.ArrayValue([m.IntValue(1), v.array(rows, diagnostic_value)])
  }
}

/// Decodes complete diagnostic evidence with its original settlement tag.
///
/// ## Examples
///
/// Unknown settlement tags refuse the whole result.
@internal
pub fn parse_diagnostics(value: m.MsgPackValue) -> Result(q.Diagnostics, Nil) {
  case value {
    m.ArrayValue([m.IntValue(0), rows]) ->
      v.items(rows, 10_000, parse_diagnostic) |> result.map(q.Settled)
    m.ArrayValue([m.IntValue(1), rows]) ->
      v.items(rows, 10_000, parse_diagnostic) |> result.map(q.Unsettled)
    _ -> Error(Nil)
  }
}

/// Encodes each actual file landing independently.
///
/// ## Examples
///
/// A rejected or unattempted file never becomes Landed.
@internal
pub fn landing_value(landing: q.Landing) -> m.MsgPackValue {
  case landing {
    q.Landed(path, edits) ->
      m.ArrayValue([m.IntValue(0), m.StringValue(path), m.IntValue(edits)])
    q.Rejected(path, reason) ->
      m.ArrayValue([m.IntValue(1), m.StringValue(path), m.StringValue(reason)])
    q.NotAttempted(path) -> m.ArrayValue([m.IntValue(2), m.StringValue(path)])
  }
}

/// Decodes exact partial landing evidence.
///
/// ## Examples
///
/// A malformed landing refuses rather than losing a partial-write report.
@internal
pub fn parse_landing(value: m.MsgPackValue) -> Result(q.Landing, Nil) {
  case value {
    m.ArrayValue([m.IntValue(0), path, edits]) -> {
      use path <- result.try(v.path(path))
      use edits <- result.try(v.integer(edits, 0, 9_223_372_036_854_775_807))
      Ok(q.Landed(path, edits))
    }
    m.ArrayValue([m.IntValue(1), path, reason]) -> {
      use path <- result.try(v.path(path))
      use reason <- result.try(v.text(reason, 4_194_304))
      Ok(q.Rejected(path, reason))
    }
    m.ArrayValue([m.IntValue(2), path]) ->
      v.path(path) |> result.map(q.NotAttempted)
    _ -> Error(Nil)
  }
}

/// Encodes complete file landings followed by post-write diagnostics.
///
/// ## Examples
///
/// Rename retains partial outcomes in their original path order.
@internal
pub fn rename_report_value(report: q.RenameReport) -> m.MsgPackValue {
  m.ArrayValue([
    v.array(report.files, landing_value),
    diagnostics_value(report.diagnostics),
  ])
}

/// Decodes every landing and its complete diagnostics.
///
/// ## Examples
///
/// An absent diagnostics field is refused.
@internal
pub fn parse_rename_report(
  value: m.MsgPackValue,
) -> Result(q.RenameReport, Nil) {
  case value {
    m.ArrayValue([files, diagnostics]) -> {
      use files <- result.try(v.items(files, 10_000, parse_landing))
      use diagnostics <- result.try(parse_diagnostics(diagnostics))
      Ok(q.RenameReport(files:, diagnostics:))
    }
    _ -> Error(Nil)
  }
}

/// Encodes existing query failures in source variant order.
///
/// ## Examples
///
/// Unsupported preserves both the configured server and request label.
@internal
pub fn error_value(error: q.QueryError) -> m.MsgPackValue {
  case error {
    q.NoServer(reason) -> m.ArrayValue([m.IntValue(0), m.StringValue(reason)])
    q.Unsupported(server, request) ->
      m.ArrayValue([
        m.IntValue(1),
        m.StringValue(server),
        m.StringValue(request),
      ])
    q.NotFound(query, searched) ->
      m.ArrayValue([
        m.IntValue(2),
        symbol_value(query),
        v.option(searched, m.StringValue),
      ])
    q.Ambiguous(candidates) ->
      m.ArrayValue([m.IntValue(3), v.array(candidates, site_value)])
    q.ServerRefused(message) ->
      m.ArrayValue([m.IntValue(4), m.StringValue(message)])
    q.Unavailable(reason) ->
      m.ArrayValue([m.IntValue(5), m.StringValue(reason)])
  }
}

/// Decodes only existing query failure variants.
///
/// ## Examples
///
/// Unknown custody is not decoded as an empty query success.
@internal
pub fn parse_error(value: m.MsgPackValue) -> Result(q.QueryError, Nil) {
  case value {
    m.ArrayValue([m.IntValue(0), reason]) ->
      v.text(reason, 4_194_304) |> result.map(q.NoServer)
    m.ArrayValue([m.IntValue(1), server, request]) -> {
      use server <- result.try(v.name(server, 128))
      use request <- result.try(v.text(request, 4_194_304))
      Ok(q.Unsupported(server, request))
    }
    m.ArrayValue([m.IntValue(2), query, searched]) -> {
      use query <- result.try(parse_symbol(query))
      use searched <- result.try(
        v.optional(searched, fn(value) { v.text(value, 4_194_304) }),
      )
      Ok(q.NotFound(query, searched))
    }
    m.ArrayValue([m.IntValue(3), candidates]) ->
      v.items(candidates, 10_000, parse_site) |> result.map(q.Ambiguous)
    m.ArrayValue([m.IntValue(4), message]) ->
      v.text(message, 4_194_304) |> result.map(q.ServerRefused)
    m.ArrayValue([m.IntValue(5), reason]) ->
      v.text(reason, 4_194_304) |> result.map(q.Unavailable)
    _ -> Error(Nil)
  }
}

/// Flattens a complete outline in preorder under the semantic depth/row bounds.
///
/// ## Examples
///
/// Children retain backward parent indices rather than nested wire arrays.
@internal
pub fn outline_value(
  entries: List(q.SymbolEntry),
) -> Result(m.MsgPackValue, Nil) {
  flatten([#(entries, None, 1)], 0, [])
  |> result.map(fn(rows) { m.ArrayValue(list.reverse(rows)) })
}

fn flatten(
  pending: List(#(List(q.SymbolEntry), Option(Int), Int)),
  index: Int,
  rows: List(m.MsgPackValue),
) -> Result(List(m.MsgPackValue), Nil) {
  case pending {
    [] -> Ok(rows)
    [#([], _, _), ..rest] -> flatten(rest, index, rows)
    [#([entry, ..siblings], parent, depth), ..rest] -> {
      use Nil <- result.try(v.check(fn() { index < 10_000 && depth <= 256 }))
      let row =
        m.ArrayValue([
          v.option(parent, m.IntValue),
          m.StringValue(entry.name),
          m.StringValue(entry.kind),
          v.option(entry.detail, m.StringValue),
          site_value(entry.site),
        ])
      flatten(
        [
          #(entry.children, Some(index), depth + 1),
          #(siblings, parent, depth),
          ..rest
        ],
        index + 1,
        [row, ..rows],
      )
    }
  }
}

/// Checks every backward parent and semantic depth before rebuilding the tree.
///
/// ## Examples
///
/// Forward or cyclic parent rows refuse the complete outline.
@internal
pub fn parse_outline(
  value: m.MsgPackValue,
) -> Result(List(q.SymbolEntry), Nil) {
  use rows <- result.try(v.items(value, 10_000, parse_outline_row))
  use _ <- result.try(
    list.try_fold(rows, #(0, dict.new()), fn(state, row) {
      let #(index, depths) = state
      use depth <- result.try(case row.0 {
        None -> Ok(1)
        Some(parent) -> {
          use Nil <- result.try(v.check(fn() { parent < index }))
          dict.get(depths, parent) |> result.map(fn(depth) { depth + 1 })
        }
      })
      use Nil <- result.try(v.check(fn() { depth <= 256 }))
      Ok(#(index + 1, dict.insert(depths, index, depth)))
    }),
  )
  let indexed = list.index_map(rows, fn(row, index) { #(index, row) })
  let children =
    list.fold(list.reverse(indexed), dict.new(), fn(children, indexed) {
      let #(index, #(parent, entry)) = indexed
      let nested = dict.get(children, Some(index)) |> result.unwrap([])
      let entry = q.SymbolEntry(..entry, children: nested)
      let siblings = dict.get(children, parent) |> result.unwrap([])
      dict.insert(children, parent, [entry, ..siblings])
    })
  let answer = dict.get(children, None) |> result.unwrap([])
  use canonical <- result.try(outline_value(answer))
  use Nil <- result.try(v.check(fn() { canonical == value }))
  Ok(answer)
}

fn parse_outline_row(
  value: m.MsgPackValue,
) -> Result(#(Option(Int), q.SymbolEntry), Nil) {
  case value {
    m.ArrayValue([parent, name, kind, detail, site]) -> {
      use parent <- result.try(
        v.optional(parent, fn(value) { v.integer(value, 0, 9999) }),
      )
      use name <- result.try(v.text(name, 4_194_304))
      use kind <- result.try(v.text(kind, 4_194_304))
      use detail <- result.try(
        v.optional(detail, fn(value) { v.text(value, 4_194_304) }),
      )
      use site <- result.try(parse_site(site))
      Ok(#(parent, q.SymbolEntry(name:, kind:, detail:, site:, children: [])))
    }
    _ -> Error(Nil)
  }
}
