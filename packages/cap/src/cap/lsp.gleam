//// `cap/lsp` — semantic questions about the workspace's code, answered by
//// the language server the session runs for it (ADR-013).
////
//// # Why a program asks by symbol, never by position
////
//// The Language Server Protocol addresses code the way an editor does: a
//// document, a zero-based line and a zero-based offset counted in UTF-16
//// code units. A program has no cursor, and asking it for a UTF-16 offset
//// is asking it to be wrong (ADR-013 §5). So every question here is a
//// `Query`: a symbol *name*, optionally narrowed by a workspace path and a
//// 1-based line exactly as `fs.read` and `search.grep` number them. The
//// harness resolves the name to a position; the program never sees one.
//// Every answer comes back as a `Site` in that same 1-based form, with
//// the line's text and its hashline anchor, so a result reads like a
//// `grep` hit and can be handed straight back to the model for an edit.
////
//// # Why this module exists beside the `lsp_*` tools
////
//// The tools answer one question per call. A program composes them, and
//// the composition is the point: "every function in this file that is
//// referenced from outside it" is one outline and a loop of reference
//// queries here, and no single tool offers it (ADR-013 §6). The harness
//// answers every name below itself (`codemode/lsp`, `ServedHere`) over
//// the same door the tools use, so a program and a tool asking the same
//// question get the same resolution and the same server.
////
//// # Failure is in band, and says what to do next
////
//// A query that could not be answered is an `LspError`, never a crash,
//// and every variant is something a program can act on: `Ambiguous`
//// carries the candidates to narrow with, `Unsupported` names the request
//// the server does not offer, `NoServer` says why no server owns the
//// path. Two wire channels carry them, and `LspError`'s docs say which
//// variant travels on which.
////
//// # Lists are bounded, and the bound is reported
////
//// `definition` and `references` return at most `max_items` entries
//// inside a `Found`, whose `total` is how many there were. A program can
//// always tell a complete answer (`total == list.length(items)`) from a
//// capped one, which is what makes it safe to act on either.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/option.{type Option, None, Some}
import gleam/result

// --- constants: the bound and the wire codes -----------------------------------

/// The most entries a `definition` or `references` answer carries, and
/// the most candidates an `Ambiguous` refusal lists. The harness
/// (`codemode/lsp`) is the enforcer and holds the same number; `total`
/// in a `Found` says how many there were before the cap.
pub const max_items = 200

// The wire's refusal codes and `unresolved` tags, stated once. They are
// `codemode/lsp`'s strings, pinned on that side by whole-map assertions
// and on this side by `lsp_test`, and they are private because a program
// branches on `LspError`'s variants, never on the strings beneath them.
//
// `no_server` is `NoServer`; `server_refused` is `Refused`, the server's
// own words; `server_unavailable` is a server that did not answer in time
// or died, which becomes `LspUnavailable` because to a program it is the
// same fact as a lost channel. Any other code keeps itself in
// `LspDenied`. The three tags carry what a message cannot: a symbol, a
// list of candidate sites, a server and a request.
const no_server_code = "no_server"

const refused_code = "server_refused"

const unavailable_code = "server_unavailable"

// --- the query -------------------------------------------------------------------

/// What a program asks about: a symbol by name, optionally narrowed.
///
/// `symbol` is the name as code reads it, and may be qualified the way
/// code reads it too: `greet`, `Greet`, `util.Greet`, `probe.greet`. The
/// last dot-separated segment is the identifier; anything before it
/// narrows the candidates to definitions whose module path or directory
/// ends with that qualifier. The harness does the resolving; this module
/// passes the string through untouched.
///
/// With `path` and `line`, the first occurrence of the identifier on that
/// line is meant. With `path` alone, the file's outline is searched by
/// name. With neither, the whole project is searched, and more than one
/// distinct definition is `Ambiguous` rather than a guess. A `line`
/// without a `path` narrows nothing and is refused as `LspDenied` with
/// code `invalid_argument`, as is a line below 1.
pub type Query {
  Query(
    /// The symbol's name, plain or qualified.
    symbol: String,
    /// A workspace path, as `fs.read` accepts it.
    path: Option(String),
    /// A 1-based line number, as `fs.read` numbers it. Meaningful only
    /// together with `path`.
    line: Option(Int),
  )
}

/// A query for `name` anywhere in the project.
///
/// ## Examples
///
/// ```gleam
/// let query = lsp.symbol("greet")
/// let qualified = lsp.symbol("util.Greet")
/// ```
///
pub fn symbol(name: String) -> Query {
  Query(symbol: name, path: None, line: None)
}

/// Narrows a query to one file.
///
/// ## Examples
///
/// ```gleam
/// let query = lsp.symbol("greet") |> lsp.in("src/app.gleam")
/// ```
///
pub fn in(query: Query, path: String) -> Query {
  Query(..query, path: Some(path))
}

/// Narrows a query to one line of its file, 1-based as `fs.read` shows
/// it. Pair it with `in`.
///
/// ## Examples
///
/// ```gleam
/// let query = lsp.symbol("greet") |> lsp.in("src/app.gleam") |> lsp.at_line(12)
/// ```
///
pub fn at_line(query: Query, line: Int) -> Query {
  Query(..query, line: Some(line))
}

// --- the answers -----------------------------------------------------------------

/// A place in a workspace file, in the form `fs.read` and `search.grep`
/// use.
pub type Site {
  Site(
    /// The workspace-relative path when the file is inside the workspace,
    /// otherwise the absolute path.
    path: String,
    /// The 1-based line.
    line: Int,
    /// The 1-based column, counted in Unicode codepoints.
    column: Int,
    /// The text of that line with its `\n` terminator removed. A CRLF
    /// line keeps its `\r`, as `fs.read` does, so that `anchor` is the
    /// anchor of exactly this text.
    text: String,
    /// The hashline anchor of that line, as `fs_read` shows it, so a
    /// result the program reports can be edited without another read.
    anchor: String,
  )
}

/// One reference to a symbol, with the symbol whose body holds it.
pub type Reference {
  Reference(
    /// Where the reference is.
    site: Site,
    /// The innermost enclosing symbol, qualified by its parents
    /// (`Server.handle`), or `None` at top level (an import, a module
    /// attribute). This is what lets a program group "who uses this"
    /// without a second query.
    container: Option(String),
  )
}

/// A bounded list and how long it was before the bound.
pub type Found(item) {
  Found(
    /// At most `max_items` entries, in the server's order.
    items: List(item),
    /// How many entries there were in all. Greater than the length of
    /// `items` exactly when the answer was capped.
    total: Int,
  )
}

/// One entry of a file's outline, nested as the server nests it.
pub type Symbol {
  Symbol(
    /// The symbol's name as declared.
    name: String,
    /// The kind as a lowercase word: `function`, `type`, `constant`, and
    /// so on. Passed through from the harness, which renders LSP's
    /// numbered kinds, so a kind this module has never heard of still
    /// arrives.
    kind: String,
    /// The server's detail string, such as a signature, when it sent one.
    detail: Option(String),
    /// Where the symbol is declared.
    site: Site,
    /// The symbols declared inside this one.
    children: List(Symbol),
  )
}

/// Which way a call-hierarchy query walks.
pub type CallDirection {
  /// Who calls the symbol.
  Incoming

  /// What the symbol calls.
  Outgoing
}

/// One edge of a call hierarchy.
pub type Call {
  Call(
    /// The caller (for `Incoming`) or the callee (for `Outgoing`).
    name: String,
    /// Where that caller or callee is defined.
    site: Site,
    /// Where each call itself appears.
    at: List(Site),
  )
}

/// A diagnostic's severity, in LSP's order.
pub type Severity {
  /// The code does not compile.
  SeverityError

  /// The code compiles, and the server has an objection.
  SeverityWarning

  /// Information the server thought worth saying.
  SeverityInformation

  /// A suggestion.
  SeverityHint
}

/// One diagnostic from the server.
pub type Diagnostic {
  Diagnostic(
    /// Where the diagnostic starts.
    site: Site,
    /// How serious it is.
    severity: Severity,
    /// The server's message, verbatim.
    message: String,
  )
}

/// Diagnostics, and whether they are known to be current.
///
/// Two variants rather than a flag, because the two are different claims
/// and a program must not read one as the other: `Settled([])` is clean
/// code, and `Unsettled([])` is only that nothing had arrived yet.
pub type Diagnostics {
  /// The server finished reacting to the latest change. An empty list is
  /// a clean result.
  Settled(diagnostics: List(Diagnostic))

  /// The harness's wait ran out first. `seen` is whatever arrived, which
  /// may be stale or partial. Never read this as clean code.
  Unsettled(seen: List(Diagnostic))
}

/// Whether a rename only reports what it would do, or does it.
pub type RenameMode {
  /// Compute the rename and write nothing.
  Preview

  /// Compute the rename and land it, file by file, through the same
  /// anchor-checked write path `fs_edit` uses.
  Apply
}

/// One line a previewed rename would change.
pub type LineChange {
  LineChange(
    /// The 1-based line number.
    line: Int,
    /// The line as it reads now.
    before: String,
    /// The line as it would read after the rename.
    after: String,
  )
}

/// One file a previewed rename would change.
pub type PlannedFile {
  PlannedFile(
    /// The workspace path.
    path: String,
    /// How many of the server's edits fall in this file.
    edits: Int,
    /// The changed lines, at most `max_items` of them, in line order.
    changes: List(LineChange),
  )
}

/// What landing one file of an applied rename did.
pub type Landing {
  /// Written.
  Landed(path: String, edits: Int)

  /// Refused before or during its write; nothing was written to it. A
  /// file changed since the server computed the rename rejects here,
  /// exactly as a stale `fs_edit` does.
  Rejected(path: String, reason: String)

  /// Not attempted, because a check on some file failed before any write
  /// began.
  NotAttempted(path: String)
}

/// A rename's outcome.
///
/// Landing across files is not atomic, which is why `Applied` reports
/// every file and the diagnostics that followed: a half-landed rename
/// shows up in both.
pub type RenameReport {
  /// What `Preview` would change, file by file. Nothing was written.
  Previewed(files: List(PlannedFile))

  /// What `Apply` did, file by file, and the diagnostics afterwards.
  Applied(files: List(Landing), diagnostics: Diagnostics)
}

/// Why a query produced no answer. Every variant is something a program
/// can act on, which is why none of them is a bare string.
pub type LspError {
  /// No configured server owns the path, the path's real location is
  /// outside the server's root, or the server could not start.
  NoServer(reason: String)

  /// The server does not offer `request` (for example call hierarchy),
  /// so it was never sent.
  Unsupported(server: String, request: String)

  /// The symbol was not found where the query said to look.
  NotFound(symbol: String)

  /// More than one distinct definition matched. Narrow the query with
  /// `in` or `at_line` using one of these.
  Ambiguous(candidates: List(Site))

  /// The server answered with an error, kept in its own words: a refused
  /// rename's reason is the useful part.
  Refused(message: String)

  /// The harness refused the call in band, under `code`.
  LspDenied(code: String, message: String)

  /// The call could not be carried, the server did not answer in time,
  /// or the answer was not a shape this module reads.
  LspUnavailable(reason: String)
}

// --- the capabilities ------------------------------------------------------------

/// Where the queried symbol is defined.
///
/// Capability: `lsp.definition`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(lsp.Found(items: [site, ..], total: _)) =
///   lsp.definition(lsp.symbol("util.Greet"))
/// let where = site.path
/// ```
///
pub fn definition(query: Query) -> Result(Found(Site), LspError) {
  ask("lsp.definition", query_args(query, []), fn(value) {
    decode_found(value, "sites", decode_site)
  })
}

/// Every reference to the queried symbol, its declaration included, each
/// with the symbol whose body holds it.
///
/// Capability: `lsp.references`.
///
/// ## Examples
///
/// The case code mode exists for: every public function in a file with
/// at least one reference from outside that file.
///
/// ```gleam
/// let path = "src/app.gleam"
/// let assert Ok(outline) = lsp.outline(path)
/// let used_elsewhere =
///   list.filter(outline, fn(entry) {
///     entry.kind == "function"
///     && case lsp.references(lsp.symbol(entry.name) |> lsp.in(path)) {
///       Ok(found) -> list.any(found.items, fn(r) { r.site.path != path })
///       Error(_) -> False
///     }
///   })
/// ```
///
pub fn references(query: Query) -> Result(Found(Reference), LspError) {
  ask("lsp.references", query_args(query, []), fn(value) {
    decode_found(value, "references", decode_reference)
  })
}

/// Type information and documentation for the queried symbol, as the
/// server renders it (usually markdown).
///
/// At most 64 KiB of it. A longer answer is cut at the last line break
/// inside that bound and ends with a line saying how many bytes were cut,
/// because the server chooses how much it sends.
///
/// Capability: `lsp.hover`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) =
///   lsp.hover(lsp.symbol("greet") |> lsp.in("src/app.gleam"))
/// ```
///
pub fn hover(query: Query) -> Result(String, LspError) {
  ask("lsp.hover", query_args(query, []), fn(value) {
    wire.string_field(value, "contents")
  })
}

/// A file's outline: its declared symbols, nested.
///
/// Capability: `lsp.outline`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(symbols) = lsp.outline("src/app.gleam")
/// let names = list.map(symbols, fn(symbol) { symbol.name })
/// ```
///
pub fn outline(path: String) -> Result(List(Symbol), LspError) {
  ask("lsp.outline", wire.args([#("path", wire.string(path))]), fn(value) {
    wire.array_of(value, "symbols", of: decode_symbol)
  })
}

/// One level of the call hierarchy around the queried symbol. Servers
/// that do not offer call hierarchy answer `Unsupported`; `references`
/// with its `container` is the portable way to ask who calls a symbol.
///
/// Capability: `lsp.calls`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(callers) = lsp.calls(lsp.symbol("greet"), lsp.Incoming)
/// ```
///
pub fn calls(
  query: Query,
  direction: CallDirection,
) -> Result(List(Call), LspError) {
  let args =
    query_args(query, [#("direction", wire.string(direction_name(direction)))])
  ask("lsp.calls", args, fn(value) {
    wire.array_of(value, "calls", of: decode_call)
  })
}

/// Diagnostics for one file, or for every file the server has reported
/// on when `path` is `None`.
///
/// Capability: `lsp.diagnostics`.
///
/// ## Examples
///
/// ```gleam
/// case lsp.diagnostics(Some("src/app.gleam")) {
///   Ok(lsp.Settled([])) -> "clean"
///   Ok(lsp.Settled(_)) -> "broken"
///   Ok(lsp.Unsettled(_)) -> "unknown: the server had not settled"
///   Error(_) -> "no answer"
/// }
/// ```
///
pub fn diagnostics(path: Option(String)) -> Result(Diagnostics, LspError) {
  let args = wire.args([#("path", optional_string(path))])
  ask("lsp.diagnostics", args, decode_diagnostics)
}

/// Renames the queried symbol to `new_name` across the project.
///
/// `Preview` writes nothing and answers `Previewed`, the lines each file
/// would change. `Apply` lands the rename through the anchor-checked write
/// path and answers `Applied`: what landed in each file, and the
/// diagnostics that followed. A file changed since the server computed
/// the rename is `Rejected`, never overwritten.
///
/// Capability: `lsp.rename`.
///
/// ## Examples
///
/// ```gleam
/// let query = lsp.symbol("greet") |> lsp.in("src/app.gleam")
/// let assert Ok(lsp.Previewed(files:)) = lsp.rename(query, "welcome", lsp.Preview)
/// let assert Ok(lsp.Applied(files: landed, diagnostics: lsp.Settled([]))) =
///   lsp.rename(query, "welcome", lsp.Apply)
/// ```
///
pub fn rename(
  query: Query,
  new_name: String,
  mode: RenameMode,
) -> Result(RenameReport, LspError) {
  let args =
    query_args(query, [
      #("new_name", wire.string(new_name)),
      #("mode", wire.string(mode_name(mode))),
    ])
  ask("lsp.rename", args, decode_rename)
}

// --- marshalling ------------------------------------------------------------------

// Every symbol query puts the same three keys on the wire, always present
// and `nil` when unset: the harness decodes them as required fields, so a
// key missing here is a disagreement it refuses rather than a default.
fn query_args(
  query: Query,
  extra: List(#(String, MsgPackValue)),
) -> MsgPackValue {
  wire.args([
    #("symbol", wire.string(query.symbol)),
    #("path", optional_string(query.path)),
    #("line", optional_int(query.line)),
    ..extra
  ])
}

fn optional_string(value: Option(String)) -> MsgPackValue {
  case value {
    Some(text) -> wire.string(text)
    None -> msgpack.NilValue
  }
}

fn optional_int(value: Option(Int)) -> MsgPackValue {
  case value {
    Some(number) -> wire.int(number)
    None -> msgpack.NilValue
  }
}

fn direction_name(direction: CallDirection) -> String {
  case direction {
    Incoming -> "incoming"

    Outgoing -> "outgoing"
  }
}

fn mode_name(mode: RenameMode) -> String {
  case mode {
    Preview -> "preview"

    Apply -> "apply"
  }
}

// One call, three ways to fail. A refusal maps through `map_error`; an
// answer tagged `unresolved` is the harness saying it looked and found no
// single symbol; anything the decoder cannot read is `LspUnavailable`,
// naming the capability, because a program must never mistake a wire
// disagreement for an empty answer.
fn ask(
  cap: String,
  args: MsgPackValue,
  decoder: fn(MsgPackValue) -> Result(a, String),
) -> Result(a, LspError) {
  use value <- result.try(
    dispatch.call(cap, args) |> result.map_error(map_error),
  )
  decode_reply(value, decoder)
  |> result.map_error(fn(reason) {
    LspUnavailable("bad " <> cap <> " result: " <> reason)
  })
  |> result.flatten
}

// The outer `Result` is "could the answer be read"; the inner one is
// "did it answer the question".
fn decode_reply(
  value: MsgPackValue,
  decoder: fn(MsgPackValue) -> Result(a, String),
) -> Result(Result(a, LspError), String) {
  case wire.optional_field(value, "unresolved") {
    None -> result.map(decoder(value), Ok)

    Some(_tag) -> result.map(decode_unresolved(value), Error)
  }
}

// An unrecognised tag is a decode failure rather than `NotFound`: a tag
// this module does not know means the two ends disagree about the wire,
// and "not found" would be a claim about the code nobody made.
fn decode_unresolved(value: MsgPackValue) -> Result(LspError, String) {
  use tag <- result.try(wire.string_field(value, "unresolved"))
  case tag {
    "not_found" -> {
      use symbol <- result.try(wire.string_field(value, "symbol"))
      Ok(NotFound(symbol:))
    }

    "ambiguous" -> {
      use candidates <- result.try(wire.array_of(
        value,
        "candidates",
        of: decode_site,
      ))
      Ok(Ambiguous(candidates:))
    }

    "unsupported" -> {
      use server <- result.try(wire.string_field(value, "server"))
      use request <- result.try(wire.string_field(value, "request"))
      Ok(Unsupported(server:, request:))
    }

    unknown -> Error("unknown unresolved tag " <> unknown)
  }
}

fn decode_found(
  value: MsgPackValue,
  key: String,
  decoder: fn(MsgPackValue) -> Result(item, String),
) -> Result(Found(item), String) {
  use items <- result.try(wire.array_of(value, key, of: decoder))
  use total <- result.try(wire.int_field(value, "total"))
  Ok(Found(items:, total:))
}

fn decode_site(value: MsgPackValue) -> Result(Site, String) {
  use path <- result.try(wire.string_field(value, "path"))
  use line <- result.try(wire.int_field(value, "line"))
  use column <- result.try(wire.int_field(value, "column"))
  use text <- result.try(wire.string_field(value, "text"))
  use anchor <- result.try(wire.string_field(value, "anchor"))
  Ok(Site(path:, line:, column:, text:, anchor:))
}

fn site_field(value: MsgPackValue, key: String) -> Result(Site, String) {
  use found <- result.try(wire.field(value, key))
  decode_site(found)
}

fn decode_reference(value: MsgPackValue) -> Result(Reference, String) {
  use site <- result.try(site_field(value, "site"))
  use container <- result.try(optional_text(value, "container"))
  Ok(Reference(site:, container:))
}

// A present field that is not text is a fault, not `None`: `nil` is how
// the harness says "absent", and anything else is a disagreement.
fn optional_text(
  value: MsgPackValue,
  key: String,
) -> Result(Option(String), String) {
  case wire.optional_field(value, key) {
    None -> Ok(None)

    Some(msgpack.StringValue(text)) -> Ok(Some(text))

    Some(_other) -> Error("field " <> key <> " is not a string")
  }
}

fn decode_symbol(value: MsgPackValue) -> Result(Symbol, String) {
  use name <- result.try(wire.string_field(value, "name"))
  use kind <- result.try(wire.string_field(value, "kind"))
  use detail <- result.try(optional_text(value, "detail"))
  use site <- result.try(site_field(value, "site"))
  use children <- result.try(wire.array_of(value, "children", of: decode_symbol))
  Ok(Symbol(name:, kind:, detail:, site:, children:))
}

fn decode_call(value: MsgPackValue) -> Result(Call, String) {
  use name <- result.try(wire.string_field(value, "name"))
  use site <- result.try(site_field(value, "site"))
  use at <- result.try(wire.array_of(value, "at", of: decode_site))
  Ok(Call(name:, site:, at:))
}

// `state` is a string rather than a boolean for the reason `Diagnostics`
// is two variants: a flag's polarity is one more thing both ends must
// agree on, and a name is not.
fn decode_diagnostics(value: MsgPackValue) -> Result(Diagnostics, String) {
  use state <- result.try(wire.string_field(value, "state"))
  use diagnostics <- result.try(wire.array_of(
    value,
    "diagnostics",
    of: decode_diagnostic,
  ))
  case state {
    "settled" -> Ok(Settled(diagnostics:))

    "unsettled" -> Ok(Unsettled(seen: diagnostics))

    unknown -> Error("unknown diagnostics state " <> unknown)
  }
}

fn decode_diagnostic(value: MsgPackValue) -> Result(Diagnostic, String) {
  use site <- result.try(site_field(value, "site"))
  use severity <- result.try(wire.string_field(value, "severity"))
  use severity <- result.try(severity_from_name(severity))
  use message <- result.try(wire.string_field(value, "message"))
  Ok(Diagnostic(site:, severity:, message:))
}

// An unknown severity is a decode failure, not a guess at the nearest
// level: rounding it down would under-report, and rounding it up would
// invent an error.
fn severity_from_name(name: String) -> Result(Severity, String) {
  case name {
    "error" -> Ok(SeverityError)

    "warning" -> Ok(SeverityWarning)

    "information" -> Ok(SeverityInformation)

    "hint" -> Ok(SeverityHint)

    unknown -> Error("unknown severity " <> unknown)
  }
}

// The answer names its own mode rather than this module trusting the one
// it asked for, so a harness that previewed when asked to apply is a
// visible decode of `Previewed`, never a silent claim that files landed.
fn decode_rename(value: MsgPackValue) -> Result(RenameReport, String) {
  use mode <- result.try(wire.string_field(value, "mode"))
  case mode {
    "preview" -> {
      use files <- result.try(wire.array_of(value, "files", of: decode_planned))
      Ok(Previewed(files:))
    }

    "apply" -> {
      use files <- result.try(wire.array_of(value, "files", of: decode_landing))
      use found <- result.try(wire.field(value, "diagnostics"))
      use diagnostics <- result.try(decode_diagnostics(found))
      Ok(Applied(files:, diagnostics:))
    }

    unknown -> Error("unknown rename mode " <> unknown)
  }
}

fn decode_planned(value: MsgPackValue) -> Result(PlannedFile, String) {
  use path <- result.try(wire.string_field(value, "path"))
  use edits <- result.try(wire.int_field(value, "edits"))
  use changes <- result.try(wire.array_of(
    value,
    "changes",
    of: decode_line_change,
  ))
  Ok(PlannedFile(path:, edits:, changes:))
}

fn decode_line_change(value: MsgPackValue) -> Result(LineChange, String) {
  use line <- result.try(wire.int_field(value, "line"))
  use before <- result.try(wire.string_field(value, "before"))
  use after <- result.try(wire.string_field(value, "after"))
  Ok(LineChange(line:, before:, after:))
}

fn decode_landing(value: MsgPackValue) -> Result(Landing, String) {
  use outcome <- result.try(wire.string_field(value, "outcome"))
  use path <- result.try(wire.string_field(value, "path"))
  case outcome {
    "landed" -> {
      use edits <- result.try(wire.int_field(value, "edits"))
      Ok(Landed(path:, edits:))
    }

    "rejected" -> {
      use reason <- result.try(wire.string_field(value, "reason"))
      Ok(Rejected(path:, reason:))
    }

    "not_attempted" -> Ok(NotAttempted(path:))

    unknown -> Error("unknown landing outcome " <> unknown)
  }
}

// The refusal half of the mapping `LspError`'s docs state. A code this
// module does not name keeps its code in `LspDenied`, so a program can
// still branch on it.
fn map_error(error: CallError) -> LspError {
  case error {
    Unreachable(reason:) -> LspUnavailable(reason:)

    Denied(code:, message:) ->
      case code {
        code if code == no_server_code -> NoServer(reason: message)

        code if code == refused_code -> Refused(message:)

        code if code == unavailable_code -> LspUnavailable(reason: message)

        _ -> LspDenied(code:, message:)
      }
  }
}
