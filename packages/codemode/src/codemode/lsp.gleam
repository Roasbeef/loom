//// The language-server router: `lsp.definition`, `lsp.references`,
//// `lsp.hover`, `lsp.outline`, `lsp.calls`, `lsp.diagnostics` and
//// `lsp.rename`, answered in the harness over the session's
//// language-server door (ADR-013 §6).
////
//// # Why code mode reaches the server through the tools' door
////
//// The `lsp_*` tools and these capabilities ask one server the same
//// questions. They go through one `lsp/query.Door` so that there is one
//// symbol-resolution rule, one document-sync rule and one server per
//// session, whichever surface asked. This module holds none of those: it
//// decodes a `cap_call`'s arguments into an `lsp/query.SymbolQuery`, calls
//// a closure, and renders the answer in exactly the msgpack shapes
//// `cap/lsp` decodes. A program is not a second client of the server; it
//// is a second caller of the same door.
////
//// # Every plan is `ServedHere`
////
//// As `client/mcp.routing` serves `mcp.<server>`, and for its reason: the
//// server is already running, jailed, under a lease
//// the session holds (ADR-013 §1), and a query is a message to it over a
//// channel the harness owns. Nothing here spawns a process or crosses a
//// namespace, so a composed `SandboxPolicy` would be a policy with no
//// enforcer present. What bounds a call is the door's own per-request
//// deadline and the host's `call_timeout_ms`.
////
//// # Rename: preview is computed here, apply is composed by the client
////
//// `lsp.rename` carries a `mode`. `preview` calls the door's
//// `prepare_rename`, which writes nothing, and turns each file's base and
//// edited text into the lines that would change; that diff is pure and
//// needs nothing the harness has not already handed back, so it lives
//// here. `apply` calls `Seam.rename`, which the client composes out of
//// `prepare_rename`, the hashline landing that `fs_edit` uses, and
//// `after_write` (ADR-013 §4). This router never writes a file and cannot
//// be made to: the only write path it can reach is a closure somebody
//// else built around the concurrency check.
////
//// # Two wire channels for failure, one for each kind
////
//// A `QueryError` that is only a sentence (`NoServer`, `ServerRefused`,
//// `Unavailable`) is an in-band refusal, a code and a message. The three
//// that carry structure a message cannot (`NotFound`'s symbol,
//// `Ambiguous`'s candidate sites, `Unsupported`'s server and request)
//// travel as an answer tagged `unresolved`: the harness looked, and the
//// looking is the answer. `cap/lsp.LspError`'s docs state the same
//// mapping from the other end; `lsp_test` pins this end by whole-map
//// comparison, because `cap` and `codemode` share no dependency.
////
//// # What is dropped on the way out
////
//// `Served.warmth` is not sent. A server restart costs seconds, and a
//// tool result says so because a model reading a slow answer would
//// otherwise take it for a hang; a program has no reader to reassure,
//// and its deadline is the execution's either way.

import broker/framing.{type CapOutcome}
import codemode/internal/args
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, ServedHere,
}
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/query.{
  type Call, type Diagnostic, type Diagnostics, type Door, type FileEdit,
  type Landing, type QueryError, type Reference, type RenameReport, type Served,
  type Site, type SymbolEntry, type SymbolQuery,
}
import tools/hashline

// --- the capability names ----------------------------------------------------

/// The capability a program asks where a symbol is defined with.
pub const definition_cap = "lsp.definition"

/// The capability a program lists a symbol's references with.
pub const references_cap = "lsp.references"

/// The capability a program reads a symbol's type and docs with.
pub const hover_cap = "lsp.hover"

/// The capability a program reads a file's outline with.
pub const outline_cap = "lsp.outline"

/// The capability a program walks one level of a call hierarchy with.
pub const calls_cap = "lsp.calls"

/// The capability a program reads settled diagnostics with.
pub const diagnostics_cap = "lsp.diagnostics"

/// The capability a program previews or applies a rename with.
pub const rename_cap = "lsp.rename"

/// Every capability this router services. The client appends these to
/// the advertised set only when a language server is configured, as it
/// does `client/mcp.serviced_caps`, so a workspace without one pays
/// nothing and a program cannot be told `lsp.*` exists where it does not.
pub const serviced_caps = [
  definition_cap, references_cap, hover_cap, outline_cap, calls_cap,
  diagnostics_cap, rename_cap,
]

// --- the bound and the codes ---------------------------------------------------

/// The most entries a `definition` or `references` answer carries, the
/// most candidates an `ambiguous` answer lists, and the most changed
/// lines a previewed file reports. `cap/lsp.max_items` states the same
/// number to programs; this module is the enforcer, and every answer it
/// caps carries the uncapped `total` beside it.
pub const max_items = 200

/// The refusal code for `query.NoServer`.
pub const no_server_code = "no_server"

/// The refusal code for `query.ServerRefused`.
pub const refused_code = "server_refused"

/// The refusal code for `query.Unavailable`.
pub const unavailable_code = "server_unavailable"

// --- the seam ------------------------------------------------------------------

/// Whether a rename only reports what it would change, or lands it.
///
/// Its own type here rather than in `lsp/query` because the door has no
/// mode: preview is the door's `prepare_rename` read through a diff, and
/// apply is a composition the client owns. The `lsp_rename` tool mirrors
/// this type.
pub type RenameMode {
  /// Compute the rename and write nothing.
  Preview

  /// Compute the rename and land it through the hashline path.
  Apply
}

/// One line a previewed rename would change.
pub type LineChange {
  LineChange(
    /// The 1-based line number in the file as it is now.
    line: Int,
    /// The line as it reads now, without its terminator.
    before: String,
    /// The line as it would read after the rename.
    after: String,
  )
}

/// One file a previewed rename would change.
pub type PlannedFile {
  PlannedFile(
    /// The workspace path, as the door reported it.
    path: String,
    /// How many of the server's edits fall in this file.
    edits: Int,
    /// The changed lines in line order, at most `max_items` of them.
    changes: List(LineChange),
  )
}

/// The harness-side closures this router calls.
///
/// Injected for the reason every seam in this package is: `codemode` must
/// not learn which server a session runs or where its workspace is.
///
/// Constructor invariants: `door` is the session's one language-server
/// door, the same record the `lsp_*` tools are built over. `rename` is the
/// applied rename, composed by the client as `door.prepare_rename`, then
/// the hashline landing of every file with every digest checked before
/// the first write, then `door.after_write` for each landed file; it
/// returns the per-file report and the diagnostics that followed.
pub type Seam {
  Seam(
    /// The session's language-server door.
    door: Door,
    /// Apply a rename of the queried symbol to the given name.
    rename: fn(SymbolQuery, String) -> Result(Served(RenameReport), QueryError),
  )
}

/// The language-server router, in front of `inner`.
///
/// Composed rather than total, as `codemode/search.routing` is: it answers
/// seven names and hands everything else down untouched.
///
/// ## Examples
///
/// ```gleam
/// // lsp.routing(seam, over: search.routing(search_seam, over: base))
/// ```
///
pub fn routing(seam: Seam, over inner: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    // Gleam patterns cannot name a constant, so the arms are literals
    // while `serviced_caps` holds the constants. `lsp_test` walks
    // `serviced_caps` and asserts each one is served here, which is what
    // keeps the two lists one list.
    case request.cap {
      "lsp.definition" -> definition_plan(seam, request)
      "lsp.references" -> references_plan(seam, request)
      "lsp.hover" -> hover_plan(seam, request)
      "lsp.outline" -> outline_plan(seam, request)
      "lsp.calls" -> calls_plan(seam, request)
      "lsp.diagnostics" -> diagnostics_plan(seam, request)
      "lsp.rename" -> rename_plan(seam, request)
      _other -> inner(request)
    }
  }
}

// --- the arms --------------------------------------------------------------------

// Each arm decodes every argument before returning a plan, so a malformed
// call is refused at admission and costs no ordinal and no server round
// trip. The closure the plan carries is the only place the door is called.

fn definition_plan(
  seam: Seam,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use symbol_query <- result.try(query_arg(request.args))
  let definition = seam.door.definition
  Ok(
    ServedHere(fn() {
      definition(symbol_query)
      |> answer(fn(sites) { found_fields("sites", sites, site_value) })
    }),
  )
}

fn references_plan(
  seam: Seam,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use symbol_query <- result.try(query_arg(request.args))
  let references = seam.door.references
  Ok(
    ServedHere(fn() {
      references(symbol_query)
      |> answer(fn(references) {
        found_fields("references", references, reference_value)
      })
    }),
  )
}

fn hover_plan(seam: Seam, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use symbol_query <- result.try(query_arg(request.args))
  let hover = seam.door.hover
  Ok(
    ServedHere(fn() {
      hover(symbol_query)
      |> answer(fn(hover) {
        [#("contents", msgpack.StringValue(hover.contents))]
      })
    }),
  )
}

fn outline_plan(seam: Seam, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use path <- result.try(args.string(request.args, "path"))
  let outline = seam.door.outline
  Ok(
    ServedHere(fn() {
      outline(path)
      |> answer(fn(symbols) {
        [#("symbols", msgpack.ArrayValue(list.map(symbols, symbol_value)))]
      })
    }),
  )
}

fn calls_plan(seam: Seam, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use symbol_query <- result.try(query_arg(request.args))
  use direction <- result.try(direction_arg(request.args))
  let calls = seam.door.calls
  Ok(
    ServedHere(fn() {
      calls(symbol_query, direction)
      |> answer(fn(calls) {
        [#("calls", msgpack.ArrayValue(list.map(calls, call_value)))]
      })
    }),
  )
}

fn diagnostics_plan(
  seam: Seam,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use path <- result.try(optional_string(request.args, "path"))
  let diagnostics = seam.door.diagnostics
  Ok(
    ServedHere(fn() {
      diagnostics(path)
      |> answer(diagnostics_fields)
    }),
  )
}

fn rename_plan(seam: Seam, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use symbol_query <- result.try(query_arg(request.args))
  use new_name <- result.try(args.string(request.args, "new_name"))
  use mode <- result.try(mode_arg(request.args))
  let prepare = seam.door.prepare_rename
  let apply = seam.rename
  Ok(
    ServedHere(fn() {
      case mode {
        // The door's `prepare_rename` writes nothing, so a preview is that
        // answer read through a diff and is safe to call as often as a
        // program likes.
        Preview ->
          prepare(symbol_query, new_name)
          |> answer(fn(file_edits) { preview_fields(preview(file_edits)) })

        // The only arm that can change a file, and it changes one only
        // through the client's composition.
        Apply ->
          apply(symbol_query, new_name)
          |> answer(applied_fields)
      }
    }),
  )
}

// --- argument decoding ---------------------------------------------------------------

// The three keys every symbol query carries. `cap/lsp` always writes all
// three, `nil` when unset, so a missing key is a wire disagreement and is
// refused rather than defaulted.
//
// Two shapes are refused that the door would otherwise have to guess at:
// a `line` with no `path` names a line of no file, and a line below 1 is
// the zero-based habit ADR-013 §5 exists to keep out.
fn query_arg(value: MsgPackValue) -> Result(SymbolQuery, CapDenial) {
  use symbol <- result.try(args.string(value, "symbol"))
  use path <- result.try(optional_string(value, "path"))
  use line <- result.try(optional_int(value, "line"))
  use Nil <- result.try(check_line(path, line))
  Ok(query.SymbolQuery(symbol:, path:, line:))
}

fn check_line(
  path: Option(String),
  line: Option(Int),
) -> Result(Nil, CapDenial) {
  case path, line {
    _, None -> Ok(Nil)

    None, Some(_line) ->
      Error(args.invalid(
        "`line` narrows a file, so it needs a `path`; give both, or neither",
      ))

    Some(_path), Some(number) if number < 1 ->
      Error(args.invalid(
        "`line` is 1-based, as fs.read numbers lines, and must be at least 1",
      ))

    Some(_path), Some(_number) -> Ok(Nil)
  }
}

fn optional_string(
  value: MsgPackValue,
  key: String,
) -> Result(Option(String), CapDenial) {
  use found <- result.try(args.field(value, key))
  case found {
    msgpack.NilValue -> Ok(None)
    msgpack.StringValue(text) -> Ok(Some(text))
    msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) ->
      Error(args.invalid("`" <> key <> "` must be text or nil"))
  }
}

fn optional_int(
  value: MsgPackValue,
  key: String,
) -> Result(Option(Int), CapDenial) {
  use found <- result.try(args.field(value, key))
  case found {
    msgpack.NilValue -> Ok(None)
    msgpack.IntValue(number) -> Ok(Some(number))
    msgpack.BoolValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) ->
      Error(args.invalid("`" <> key <> "` must be a whole number or nil"))
  }
}

fn direction_arg(
  value: MsgPackValue,
) -> Result(query.CallDirection, CapDenial) {
  use direction <- result.try(args.string(value, "direction"))
  case direction {
    "incoming" -> Ok(query.Incoming)

    "outgoing" -> Ok(query.Outgoing)

    other ->
      Error(args.invalid(
        "`direction` must be \"incoming\" or \"outgoing\", not \""
        <> other
        <> "\"",
      ))
  }
}

fn mode_arg(value: MsgPackValue) -> Result(RenameMode, CapDenial) {
  use mode <- result.try(args.string(value, "mode"))
  case mode {
    "preview" -> Ok(Preview)

    "apply" -> Ok(Apply)

    other ->
      Error(args.invalid(
        "`mode` must be \"preview\" or \"apply\", not \"" <> other <> "\"",
      ))
  }
}

// --- the preview diff -----------------------------------------------------------------

/// The lines each file of a computed rename would change.
///
/// Line by line rather than a general diff, because a rename's edits each
/// replace one identifier with another and so never add or remove a line.
/// The walk still pairs a line present on one side only with an empty
/// line on the other, so a server that broke that rule shows up in the
/// preview instead of being lost from it. A `\r` left by a CRLF file is
/// trimmed from both sides, because it is a terminator and not content.
///
/// ## Examples
///
/// ```gleam
/// let edit =
///   query.FileEdit(path: "a.gleam", base: "x\ngreet\n", edited: "x\nhi\n", edits: 1)
/// assert lsp.preview([edit])
///   == [lsp.PlannedFile("a.gleam", 1, [lsp.LineChange(2, "greet", "hi")])]
/// ```
///
pub fn preview(file_edits: List(FileEdit)) -> List(PlannedFile) {
  list.map(file_edits, fn(file_edit) {
    let changes =
      changed_lines(
        string.split(file_edit.base, "\n"),
        string.split(file_edit.edited, "\n"),
        1,
        [],
      )
    PlannedFile(
      path: file_edit.path,
      edits: file_edit.edits,
      changes: list.take(changes, max_items),
    )
  })
}

// One step per line pair, accumulating changed lines in reverse; the list
// is turned round once when both sides run out.
fn changed_lines(
  before: List(String),
  after: List(String),
  line: Int,
  found: List(LineChange),
) -> List(LineChange) {
  case before, after {
    [], [] -> list.reverse(found)

    [old, ..before], [] ->
      changed_lines(before, [], line + 1, record(found, line, old, ""))

    [], [new, ..after] ->
      changed_lines([], after, line + 1, record(found, line, "", new))

    [old, ..before], [new, ..after] ->
      changed_lines(before, after, line + 1, record(found, line, old, new))
  }
}

fn record(
  found: List(LineChange),
  line: Int,
  old: String,
  new: String,
) -> List(LineChange) {
  let old = trim_cr(old)
  let new = trim_cr(new)
  case old == new {
    True -> found
    False -> [LineChange(line:, before: old, after: new), ..found]
  }
}

fn trim_cr(text: String) -> String {
  case string.ends_with(text, "\r") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}

// --- rendering an answer ----------------------------------------------------------------

// A door answer becomes a `cap_result`: the rendered fields on success,
// and on failure whichever of the two channels the module doc assigns it.
fn answer(
  outcome: Result(Served(a), QueryError),
  render: fn(a) -> List(#(String, MsgPackValue)),
) -> CapOutcome {
  case outcome {
    Ok(served) -> framing.CapOk(value: fields(render(served.value)))

    Error(error) -> refusal(error)
  }
}

/// The `cap_result` one `QueryError` travels as.
///
/// Public because it is half of a contract whose other half is
/// `cap/lsp`'s decoding, and the tools slice renders the same errors: a
/// sentence-only error is `CapErr` under `no_server_code`, `refused_code`
/// or `unavailable_code`; the three that carry structure are `CapOk`
/// answers tagged `unresolved` with `not_found`, `ambiguous` (candidates
/// capped at `max_items`) or `unsupported`.
///
/// ## Examples
///
/// ```gleam
/// assert lsp.refusal(query.NoServer("no server owns x.txt"))
///   == framing.CapErr(code: "no_server", message: "no server owns x.txt")
/// ```
///
pub fn refusal(error: QueryError) -> CapOutcome {
  case error {
    query.NoServer(reason:) ->
      framing.CapErr(code: no_server_code, message: reason)

    query.ServerRefused(message:) ->
      framing.CapErr(code: refused_code, message:)

    query.Unavailable(reason:) ->
      framing.CapErr(code: unavailable_code, message: reason)

    query.NotFound(query: asked) ->
      unresolved("not_found", [#("symbol", msgpack.StringValue(asked.symbol))])

    query.Ambiguous(candidates:) ->
      unresolved("ambiguous", [
        #(
          "candidates",
          msgpack.ArrayValue(list.map(
            list.take(candidates, max_items),
            site_value,
          )),
        ),
      ])

    query.Unsupported(server:, request:) ->
      unresolved("unsupported", [
        #("server", msgpack.StringValue(server)),
        #("request", msgpack.StringValue(request)),
      ])
  }
}

fn unresolved(tag: String, rest: List(#(String, MsgPackValue))) -> CapOutcome {
  framing.CapOk(
    value: fields([#("unresolved", msgpack.StringValue(tag)), ..rest]),
  )
}

// A capped list and its uncapped length. `list.length` walks the whole
// answer once; the door's own bounds keep that answer finite.
fn found_fields(
  key: String,
  items: List(item),
  render: fn(item) -> MsgPackValue,
) -> List(#(String, MsgPackValue)) {
  [
    #(key, msgpack.ArrayValue(list.map(list.take(items, max_items), render))),
    #("total", msgpack.IntValue(list.length(items))),
  ]
}

/// One site as it crosses the wire: 1-based line and codepoint column
/// exactly as the door reports them, and the hashline anchor of the line
/// as `fs_read` would show it.
///
/// The anchor is computed here because the door cannot: `lsp` does not
/// depend on `tools`. It is `hashline.anchor` of the terminator-free line
/// text, which is `fs_read`'s anchor for every LF file. For a CRLF file
/// `fs_read` anchors the line with its `\r`, so the two differ there.
///
/// ## Examples
///
/// ```gleam
/// // lsp.site_value(query.Site("a.gleam", 3, 5, "pub fn greet() {"))
/// ```
///
pub fn site_value(site: Site) -> MsgPackValue {
  fields([
    #("path", msgpack.StringValue(site.path)),
    #("line", msgpack.IntValue(site.line)),
    #("column", msgpack.IntValue(site.column)),
    #("text", msgpack.StringValue(site.text)),
    #("anchor", msgpack.StringValue(hashline.anchor(site.text))),
  ])
}

fn reference_value(reference: Reference) -> MsgPackValue {
  fields([
    #("site", site_value(reference.site)),
    #("container", optional_text(reference.container)),
  ])
}

fn symbol_value(entry: SymbolEntry) -> MsgPackValue {
  fields([
    #("name", msgpack.StringValue(entry.name)),
    #("kind", msgpack.StringValue(entry.kind)),
    #("detail", optional_text(entry.detail)),
    #("site", site_value(entry.site)),
    #("children", msgpack.ArrayValue(list.map(entry.children, symbol_value))),
  ])
}

fn call_value(call: Call) -> MsgPackValue {
  fields([
    #("name", msgpack.StringValue(call.name)),
    #("site", site_value(call.site)),
    #("at", msgpack.ArrayValue(list.map(call.at, site_value))),
  ])
}

// `state` is a name rather than a boolean: `cap/lsp` decodes it into two
// variants, and "unsettled" must never be one flipped bit from "clean".
fn diagnostics_fields(
  diagnostics: Diagnostics,
) -> List(#(String, MsgPackValue)) {
  let #(state, listed) = case diagnostics {
    query.Settled(diagnostics:) -> #("settled", diagnostics)

    query.Unsettled(seen:) -> #("unsettled", seen)
  }
  [
    #("state", msgpack.StringValue(state)),
    #("diagnostics", msgpack.ArrayValue(list.map(listed, diagnostic_value))),
  ]
}

fn diagnostic_value(diagnostic: Diagnostic) -> MsgPackValue {
  fields([
    #("site", site_value(diagnostic.site)),
    #("severity", msgpack.StringValue(severity_name(diagnostic.severity))),
    #("message", msgpack.StringValue(diagnostic.message)),
  ])
}

fn severity_name(severity: query.Severity) -> String {
  case severity {
    query.SeverityError -> "error"

    query.SeverityWarning -> "warning"

    query.SeverityInformation -> "information"

    query.SeverityHint -> "hint"
  }
}

// The answer names its own mode, so `cap/lsp` decodes `Previewed` or
// `Applied` from what happened rather than from what was asked.
fn preview_fields(planned: List(PlannedFile)) -> List(#(String, MsgPackValue)) {
  [
    #("mode", msgpack.StringValue("preview")),
    #("files", msgpack.ArrayValue(list.map(planned, planned_value))),
  ]
}

fn planned_value(planned: PlannedFile) -> MsgPackValue {
  fields([
    #("path", msgpack.StringValue(planned.path)),
    #("edits", msgpack.IntValue(planned.edits)),
    #("changes", msgpack.ArrayValue(list.map(planned.changes, change_value))),
  ])
}

fn change_value(change: LineChange) -> MsgPackValue {
  fields([
    #("line", msgpack.IntValue(change.line)),
    #("before", msgpack.StringValue(change.before)),
    #("after", msgpack.StringValue(change.after)),
  ])
}

fn applied_fields(report: RenameReport) -> List(#(String, MsgPackValue)) {
  [
    #("mode", msgpack.StringValue("apply")),
    #("files", msgpack.ArrayValue(list.map(report.files, landing_value))),
    #("diagnostics", fields(diagnostics_fields(report.diagnostics))),
  ]
}

fn landing_value(landing: Landing) -> MsgPackValue {
  case landing {
    query.Landed(path:, edits:) ->
      fields([
        #("outcome", msgpack.StringValue("landed")),
        #("path", msgpack.StringValue(path)),
        #("edits", msgpack.IntValue(edits)),
      ])

    query.Rejected(path:, reason:) ->
      fields([
        #("outcome", msgpack.StringValue("rejected")),
        #("path", msgpack.StringValue(path)),
        #("reason", msgpack.StringValue(reason)),
      ])

    query.NotAttempted(path:) ->
      fields([
        #("outcome", msgpack.StringValue("not_attempted")),
        #("path", msgpack.StringValue(path)),
      ])
  }
}

fn optional_text(value: Option(String)) -> MsgPackValue {
  case value {
    Some(text) -> msgpack.StringValue(text)
    None -> msgpack.NilValue
  }
}

fn fields(entries: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(entries, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
  )
}
