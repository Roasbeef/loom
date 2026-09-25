//// `lsp/query` — the vocabulary the harness speaks to a language server
//// in, as opposed to the vocabulary the server speaks back.
////
//// # Why this module exists
////
//// The Language Server Protocol addresses code the way an editor does: a
//// document URI, a zero-based line, and a zero-based character offset
//// counted in UTF-16 code units. An editor always knows its cursor. A
//// model does not, and asking it for a UTF-16 offset is asking it to be
//// wrong (ADR-013 §5). So nothing above this package ever sees an LSP
//// position. A tool, a code-mode capability and the post-edit hook all
//// ask in terms of a *symbol name* — optionally narrowed by a path and a
//// 1-based line exactly as `fs_read` and `grep` print them — and get back
//// `Site`s in that same 1-based form, so an answer can be fed straight
//// into an edit.
////
//// # Who fills the door, and who calls it
////
//// `Door` is a record of closures. `packages/client` fills it over the
//// session's one language-server manager, which owns the jailed server,
//// document sync and symbol resolution. `packages/tools` renders it as
//// the `lsp_*` tools, and `packages/codemode` serves it as the `lsp.*`
//// capabilities. Neither caller can reach a server except through these
//// closures, which is what keeps one resolution rule and one sync rule
//// for both surfaces.
////
//// Rename is split on purpose. `prepare_rename` asks the server and
//// returns the edited text per file without writing anything; the
//// caller lands it through the hashline path it already owns
//// (`tools/fs`), so a concurrent modification rejects exactly as a stale
//// `fs_edit` does (ADR-013 §4), and then reports each landed file back
//// through `after_write` so the server's view follows the disk.
////
//// This module is types only: no process, no I/O.

import gleam/option.{type Option}

/// What the model asked about: a symbol by name, optionally narrowed.
///
/// With `path` and `line`, the first occurrence of `symbol` on that line
/// (on identifier boundaries) is the position. With `path` alone, the
/// file's outline is searched by name. With neither, the manager searches
/// the server's project root and asks the server where each hit is
/// defined; more than one distinct definition is `Ambiguous`, never a
/// guess.
pub type SymbolQuery {
  SymbolQuery(
    /// The identifier as written in source, e.g. `greet` or `Greet`.
    symbol: String,
    /// A workspace path, as `fs_read` accepts it.
    path: Option(String),
    /// A 1-based line number, as `fs_read` prints it. Meaningful only
    /// together with `path`.
    line: Option(Int),
  )
}

/// A place in a workspace file, in the harness's form.
pub type Site {
  Site(
    /// The workspace-relative path when the file is inside the
    /// workspace, otherwise the absolute path.
    path: String,
    /// 1-based line.
    line: Int,
    /// 1-based column counted in Unicode codepoints, never UTF-16 units.
    column: Int,
    /// The text of that line with its terminator removed, so a result
    /// reads like a `grep` hit.
    text: String,
  )
}

/// Why a query produced no answer. Every variant is something the model
/// can act on, which is why none of them is a bare string.
pub type QueryError {
  /// No configured server owns this path, the path's real location is
  /// outside the owning server's root, or the server could not be
  /// started. `reason` says which.
  NoServer(reason: String)

  /// The owning server did not advertise the request this query needs,
  /// so it was never sent. A server may leave an unadvertised request
  /// unanswered forever (ADR-013, measured).
  Unsupported(server: String, request: String)

  /// The symbol was not found where the query said to look.
  NotFound(query: SymbolQuery)

  /// More than one distinct definition matched; the model narrows with a
  /// path or a line.
  Ambiguous(candidates: List(Site))

  /// The server answered with an error. Its own words are kept, because
  /// a refused rename's reason ("would make it unexported") is the
  /// useful part.
  ServerRefused(message: String)

  /// The request did not complete before its deadline, or the server
  /// died while it was outstanding.
  Unavailable(reason: String)
}

/// Whether the answer paid for a server (re)start. A restart is a
/// handshake plus a full project compile, seconds rather than
/// milliseconds, and a result that silently took that long reads as a
/// hang (ADR-013 §1).
pub type Warmth {
  /// The server was already running.
  Warm

  /// The server was started or restarted for this query.
  Started(server: String)
}

/// An answer together with what it cost to produce.
pub type Served(a) {
  Served(value: a, warmth: Warmth)
}

/// Type information and documentation for a symbol.
pub type Hover {
  Hover(site: Site, contents: String)
}

/// One entry of a file's outline, nested as the server nests it.
pub type SymbolEntry {
  SymbolEntry(
    name: String,
    /// The LSP `SymbolKind` rendered as a lowercase word (`function`,
    /// `type`, `constant`, ...), never the raw integer.
    kind: String,
    /// The server's detail string, e.g. a function's signature, when
    /// it sent one.
    detail: Option(String),
    site: Site,
    children: List(SymbolEntry),
  )
}

/// Which way a call-hierarchy query walks.
pub type CallDirection {
  /// Who calls this symbol.
  Incoming

  /// What this symbol calls.
  Outgoing
}

/// One edge of a call hierarchy.
pub type Call {
  Call(
    /// The caller (for `Incoming`) or callee (for `Outgoing`).
    name: String,
    /// Where that caller or callee is defined.
    site: Site,
    /// Where the call itself appears.
    at: List(Site),
  )
}

/// A diagnostic's severity, in LSP's order.
pub type Severity {
  SeverityError
  SeverityWarning
  SeverityInformation
  SeverityHint
}

/// One diagnostic from the server.
pub type Diagnostic {
  Diagnostic(site: Site, severity: Severity, message: String)
}

/// Diagnostics after a change, and whether they are known to be current.
///
/// "Settled" is ADR-013 §3's two rules: the barrier request answered and,
/// for a server that versions its diagnostics, a publication at least as
/// new as the change arrived. An unsettled block is reported as such and
/// never as clean code.
pub type Diagnostics {
  /// Current as of the change. An empty list is a clean result.
  Settled(diagnostics: List(Diagnostic))

  /// The bound expired first. `seen` is whatever arrived, which may be
  /// stale or partial.
  Unsettled(seen: List(Diagnostic))
}

/// One file's share of a rename, computed but not yet written.
pub type FileEdit {
  FileEdit(
    /// The workspace path to write.
    path: String,
    /// The exact text the server's answer was computed against. Its
    /// hashline digest is the landing's concurrency check: if the disk no
    /// longer holds this text, the file rejects as stale.
    base: String,
    /// The text after applying every edit the server returned for the
    /// file.
    edited: String,
    /// How many of the server's edits fell in this file.
    edits: Int,
  )
}

/// What landing one file of a rename did.
pub type Landing {
  /// Written through the hashline path.
  Landed(path: String, edits: Int)

  /// Refused before or during its write; nothing was written to it.
  Rejected(path: String, reason: String)

  /// Not attempted, because a pre-check on some file failed before any
  /// write started.
  NotAttempted(path: String)
}

/// A rename's outcome, file by file, with the diagnostics that followed
/// it. Landing across files is not atomic; this record is how the model
/// learns exactly what landed.
pub type RenameReport {
  RenameReport(files: List(Landing), diagnostics: Diagnostics)
}

/// The door the session's language-server manager offers. Every closure
/// is safe to call from any process; none blocks longer than its own
/// deadline.
pub type Door {
  Door(
    /// Where the queried symbol is defined.
    definition: fn(SymbolQuery) -> Result(Served(List(Site)), QueryError),
    /// Every reference to the queried symbol, its declaration included.
    references: fn(SymbolQuery) -> Result(Served(List(Site)), QueryError),
    /// Type information and documentation for the queried symbol.
    hover: fn(SymbolQuery) -> Result(Served(Hover), QueryError),
    /// A file's outline, by workspace path.
    outline: fn(String) -> Result(Served(List(SymbolEntry)), QueryError),
    /// One level of the call hierarchy around the queried symbol.
    calls: fn(SymbolQuery, CallDirection) ->
      Result(Served(List(Call)), QueryError),
    /// Settled diagnostics for one file, or for every file the server has
    /// published about when the path is `None`.
    diagnostics: fn(Option(String)) -> Result(Served(Diagnostics), QueryError),
    /// Ask the server to rename the queried symbol to `new_name`, and
    /// return every file's edited text without writing any of it.
    prepare_rename: fn(SymbolQuery, String) ->
      Result(Served(List(FileEdit)), QueryError),
    /// Tell the manager a workspace path was just written, and wait (at
    /// most ADR-013's bound) for settled diagnostics. `None` when no
    /// configured server owns the path, which costs nothing.
    after_write: fn(String) -> Option(Diagnostics),
  )
}
