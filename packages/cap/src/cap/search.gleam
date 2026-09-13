//// `cap/search` — read-only workspace navigation and search, as typed
//// calls over the capability channel.
////
//// Importing this module is the permission, and it is a strictly smaller
//// permission than `import cap/fs`: there is no write arm here at all. A
//// program that only needs to find its way around a tree can say so in
//// its imports, and the vetting seam can see that it said so.
////
//// Containment is the same single boundary `cap/fs` goes through. Every
//// `root` and `path` is resolved component by component against the
//// workspace root on the far side of the channel, and one that escapes
//// comes back as `PermissionDenied`, never as a silent read. Nothing
//// here spawns a process: the traversal and the matching are Gleam in
//// the harness, not a shelled-out `find` or `grep`, so there is no
//// command line for a pattern to escape into.
////
//// Every call is bounded and the bound is reported rather than hidden. A
//// `glob` that stopped early answers `Truncated`; a `grep` that hit its
//// match cap or its scan budget answers `MatchesCapped` or
//// `ScanTruncated`; `read_lines` reports the `total` line count beside
//// the span it returned. A caller can always tell a complete answer from
//// a partial one, which is what makes it safe to act on either.
////
//// Two behaviours a reader coming from ripgrep will expect and not get.
//// `.gitignore` and its relatives are **not** honoured: the only things
//// skipped are dot-prefixed names (unless `IncludeHidden`) and the
//// directory names in `prune`. And symlinks are **never followed** during
//// a walk — a link is reported as `Symlink(target:)` and neither
//// descended nor searched — so a tree cannot be made to loop or to widen
//// itself through a link. `read_lines` and `fs.read` do resolve through
//// a link, because there the target is checked for containment first.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/result

/// The number of entries a `glob_query` asks for when the caller does not
/// say. The harness module `tools/search` is the enforcer and holds the
/// same number plus the ceiling above it; asking for more than that
/// ceiling is refused as `InvalidArgument` rather than quietly clamped.
pub const default_max_entries = 1000

/// The number of matches a `grep_query` asks for when the caller does not
/// say. `tools/search` is the enforcer, as for `default_max_entries`.
pub const default_max_matches = 100

/// The context lines a `grep_query` asks for when the caller does not
/// say: none. `tools/search` caps how many may be asked for.
pub const default_context = 0

/// The directory names a `glob_query` or `grep_query` refuses to descend
/// when the caller does not say. Pass `prune: []` to walk everything.
/// `tools/search` holds the same list and is the enforcer.
pub const default_prune = [
  ".git", "_build", "build", "node_modules", "target", "deps",
]

/// Why a search call failed. The descriptive variants are the causes a
/// program branches on; `SearchFailed` carries any other broker code
/// verbatim; `SearchUnavailable` is a transport failure or a result the
/// harness sent in a shape this module cannot read.
pub type SearchError {
  /// No such path.
  NotFound(path: String)

  /// The path is outside the workspace, or the policy refuses it.
  PermissionDenied(path: String)

  /// An operation/kind mismatch: a `glob` root that is a file, a
  /// `read_lines` target that is a directory.
  WrongKind(path: String, message: String)

  /// A structurally invalid argument: a bound past its ceiling, a glob
  /// or regex that does not compile, a line span that is inverted or
  /// too wide.
  InvalidArgument(message: String)

  /// Any other in-band broker refusal, code preserved.
  SearchFailed(code: String, message: String)

  /// The capability channel could not carry the call, or its answer was
  /// not the shape this module decodes.
  SearchUnavailable(reason: String)
}

/// What an entry is, as `lstat` reports the final component — so a link
/// is a link here and not the thing it points at.
pub type Kind {
  /// A regular file.
  File

  /// A directory.
  Directory

  /// A symbolic link, carrying the stored target verbatim. The target is
  /// as written on disk, so it may be relative and may not resolve.
  Symlink(target: String)

  /// Anything else: a socket, a fifo, a device node.
  Other
}

/// One entry a walk reached, or one `stat` answer.
pub type Entry {
  Entry(
    /// The entry's path relative to the workspace root, so it can be
    /// handed straight back to `fs.read`, `stat` or `read_lines`.
    path: String,
    /// What the entry is, by `lstat`.
    kind: Kind,
    /// The size in bytes as `lstat` reports it.
    size: Int,
    /// The modification time in whole seconds since the unix epoch.
    mtime_seconds: Int,
  )
}

/// Whether a walk visits entries whose name begins with a dot.
pub type Hidden {
  /// Skip dot-prefixed names. The default.
  SkipHidden

  /// Visit dot-prefixed names too. `prune` still applies, so this alone
  /// does not walk into `.git`.
  IncludeHidden
}

/// Whether a listing is everything that matched, or everything the call
/// was allowed to reach.
pub type Completeness {
  /// The walk finished and the listing is every match.
  Complete

  /// The walk stopped on a bound — `max_entries`, or the harness's
  /// ceiling on entries visited — and there may be more.
  Truncated
}

/// The answer to a `glob`.
pub type Listing {
  Listing(
    /// The matching entries, ordered by path.
    entries: List(Entry),
    /// Whether those entries are all of them.
    completeness: Completeness,
  )
}

/// A path-pattern walk. Build one with `glob_query` and override fields
/// with record update syntax.
pub type GlobQuery {
  GlobQuery(
    /// Where the walk starts, workspace-relative or absolute. Must be a
    /// directory.
    root: String,
    /// The pattern. `*` and `?` match within one path segment, `**`
    /// matches zero or more whole segments. A pattern with no `/`
    /// matches an entry's basename at any depth; one with a `/` matches
    /// the path relative to `root`, so `src/**/*.gleam` is spelled
    /// `**/*.gleam` when `root` is already `src`. Matching is
    /// case-sensitive.
    pattern: String,
    /// How many entries to return at most.
    max_entries: Int,
    /// Whether dot-prefixed names are visited.
    hidden: Hidden,
    /// Directory names never descended into, matched on the name alone
    /// at any depth.
    prune: List(String),
  )
}

/// A query that walks `root` for `pattern` with every bound at its
/// default: `default_max_entries`, `SkipHidden`, `default_prune`.
///
/// ## Examples
///
/// ```gleam
/// let query = search.glob_query(under: "src", matching: "**/*.gleam")
/// let assert Ok(listing) = search.glob(query)
/// ```
///
/// ```gleam
/// // Widen one field and leave the rest alone.
/// let query =
///   search.GlobQuery(
///     ..search.glob_query(under: ".", matching: "*.toml"),
///     hidden: search.IncludeHidden,
///   )
/// ```
///
pub fn glob_query(under root: String, matching pattern: String) -> GlobQuery {
  GlobQuery(
    root:,
    pattern:,
    max_entries: default_max_entries,
    hidden: SkipHidden,
    prune: default_prune,
  )
}

/// Walks `root` and returns the entries whose path matches the query's
/// pattern, ordered by path. Symlinks are reported and never descended.
///
/// The pattern language is ripgrep's `-g` subset: `*` and `?` match
/// within one path segment and `**` spans whole segments. A pattern
/// with no `/` matches an entry's basename at any depth, so `*.gleam`
/// finds every Gleam file under `root`; a pattern with a `/` matches
/// the path relative to `root`, so under `root: "src"` write
/// `**/*.gleam`, not `src/**/*.gleam`. `grep` filters its files with
/// the same language.
///
/// Capability: `search.glob`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(search.Listing(entries:, completeness: search.Complete)) =
///   search.glob(search.glob_query(under: "src", matching: "*.gleam"))
/// ```
///
pub fn glob(query: GlobQuery) -> Result(Listing, SearchError) {
  let args =
    wire.args([
      #("root", wire.string(query.root)),
      #("pattern", wire.string(query.pattern)),
      #("max_entries", wire.int(query.max_entries)),
      #("include_hidden", wire.bool(query.hidden == IncludeHidden)),
      #("prune", wire.string_array(query.prune)),
    ])
  use value <- result.try(
    dispatch.call("search.glob", args)
    |> result.map_error(map_error(_, query.root)),
  )
  decode_listing(value)
  |> result.map_error(fn(reason) {
    SearchUnavailable("bad search.glob result: " <> reason)
  })
}

/// One line that matched a `grep` pattern, with the context lines around
/// it that the query asked for.
pub type Match {
  Match(
    /// The file's path relative to the workspace root.
    path: String,
    /// The 1-based line number of the matching line.
    line: Int,
    /// The 1-based grapheme offset of the first match within the line.
    column: Int,
    /// The whole matching line, without its newline.
    text: String,
    /// Up to `context` lines before the match, in file order.
    before: List(String),
    /// Up to `context` lines after the match, in file order.
    after: List(String),
  )
}

/// How complete a `grep`'s answer is.
pub type Coverage {
  /// Every candidate file was scanned to the end.
  Exhaustive

  /// The scan stopped because `max_matches` was reached; there may be
  /// more matches in files or lines not yet reached.
  MatchesCapped

  /// The scan stopped on the harness's budget for entries visited or
  /// bytes read, short of the match cap.
  ScanTruncated
}

/// The answer to a `grep`.
pub type Found {
  Found(
    /// The matches, in walk order.
    matches: List(Match),
    /// How many files were opened and searched.
    files_scanned: Int,
    /// How many candidate files were skipped for being too large or not
    /// valid UTF-8.
    files_skipped: Int,
    /// Whether the scan finished, and if not, why it stopped.
    coverage: Coverage,
  )
}

/// A content search. Build one with `grep_query` and override fields with
/// record update syntax.
pub type GrepQuery {
  GrepQuery(
    /// Where the walk starts, workspace-relative or absolute. Must be a
    /// directory.
    root: String,
    /// The regular expression, matched case-sensitively against each
    /// line on its own.
    pattern: String,
    /// Path globs limiting which files are opened, in `GlobQuery`'s
    /// pattern language. Empty means every file under `root`.
    globs: List(String),
    /// How many lines of context to return either side of a match.
    context: Int,
    /// How many matches to return at most.
    max_matches: Int,
    /// Whether dot-prefixed names are visited.
    hidden: Hidden,
    /// Directory names never descended into.
    prune: List(String),
  )
}

/// A query that searches `root` for `pattern` with every bound at its
/// default: no globs, `default_context`, `default_max_matches`,
/// `SkipHidden`, `default_prune`.
///
/// ## Examples
///
/// ```gleam
/// let query = search.grep_query(under: "src", matching: "pub fn start")
/// let assert Ok(found) = search.grep(query)
/// ```
///
/// ```gleam
/// // Two lines of context, gleam files only.
/// let query =
///   search.GrepQuery(
///     ..search.grep_query(under: ".", matching: "TODO"),
///     globs: ["*.gleam"],
///     context: 2,
///   )
/// ```
///
pub fn grep_query(under root: String, matching pattern: String) -> GrepQuery {
  GrepQuery(
    root:,
    pattern:,
    globs: [],
    context: default_context,
    max_matches: default_max_matches,
    hidden: SkipHidden,
    prune: default_prune,
  )
}

/// Searches the files under `root` for lines matching the query's regular
/// expression. Files that are too large or not valid UTF-8 are counted in
/// `files_skipped` rather than failing the call.
///
/// Capability: `search.grep`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(found) =
///   search.grep(search.grep_query(under: "src", matching: "panic"))
/// let count = found.files_scanned
/// ```
///
pub fn grep(query: GrepQuery) -> Result(Found, SearchError) {
  let args =
    wire.args([
      #("root", wire.string(query.root)),
      #("pattern", wire.string(query.pattern)),
      #("globs", wire.string_array(query.globs)),
      #("context", wire.int(query.context)),
      #("max_matches", wire.int(query.max_matches)),
      #("include_hidden", wire.bool(query.hidden == IncludeHidden)),
      #("prune", wire.string_array(query.prune)),
    ])
  use value <- result.try(
    dispatch.call("search.grep", args)
    |> result.map_error(map_error(_, query.root)),
  )
  decode_found(value)
  |> result.map_error(fn(reason) {
    SearchUnavailable("bad search.grep result: " <> reason)
  })
}

/// Reports what is at `path`, without following a final symlink: a link
/// answers `Symlink(target:)` rather than the kind of its target.
///
/// Capability: `search.stat`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(entry) = search.stat("gleam.toml")
/// let assert search.File = entry.kind
/// ```
///
pub fn stat(path: String) -> Result(Entry, SearchError) {
  let args = wire.args([#("path", wire.string(path))])
  use value <- result.try(
    dispatch.call("search.stat", args) |> result.map_error(map_error(_, path)),
  )
  decode_entry(value)
  |> result.map_error(fn(reason) {
    SearchUnavailable("bad search.stat result: " <> reason)
  })
}

/// A span of lines read out of one file.
pub type Lines {
  Lines(
    /// The selected lines joined with `\n`, with no trailing newline.
    text: String,
    /// The 1-based number of the first line returned.
    first: Int,
    /// The 1-based number of the last line returned. Lower than the `to`
    /// that was asked for when the request ran past the end of the file.
    last: Int,
    /// The file's total line count.
    total: Int,
  )
}

/// Reads the lines of `path` from `first` to `last`, both 1-based and
/// inclusive. `last` past the end of the file is clamped and the clamped
/// value comes back in `Lines.last`; an inverted or over-wide span is
/// `InvalidArgument`.
///
/// Unlike a walk, this resolves through symlinks exactly as `fs.read`
/// does, so a contained link reads its target and an escaping one is
/// refused.
///
/// Capability: `search.read_lines`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(lines) = search.read_lines("src/app.gleam", from: 1, to: 40)
/// let shown = lines.last
/// ```
///
pub fn read_lines(
  path: String,
  from first: Int,
  to last: Int,
) -> Result(Lines, SearchError) {
  let args =
    wire.args([
      #("path", wire.string(path)),
      #("from", wire.int(first)),
      #("to", wire.int(last)),
    ])
  use value <- result.try(
    dispatch.call("search.read_lines", args)
    |> result.map_error(map_error(_, path)),
  )
  decode_lines(value)
  |> result.map_error(fn(reason) {
    SearchUnavailable("bad search.read_lines result: " <> reason)
  })
}

// --- total decoders ------------------------------------------------------

fn decode_listing(value: MsgPackValue) -> Result(Listing, String) {
  use entries <- result.try(wire.array_of(value, "entries", of: decode_entry))
  use truncated <- result.try(wire.bool_field(value, "truncated"))
  let completeness = case truncated {
    True -> Truncated
    False -> Complete
  }
  Ok(Listing(entries:, completeness:))
}

fn decode_entry(value: MsgPackValue) -> Result(Entry, String) {
  use path <- result.try(wire.string_field(value, "path"))
  use kind <- result.try(decode_kind(value))
  use size <- result.try(wire.int_field(value, "size"))
  use mtime_seconds <- result.try(wire.int_field(value, "mtime"))
  Ok(Entry(path:, kind:, size:, mtime_seconds:))
}

// An unrecognised `kind` string is a decode failure and not `Other`.
// `Other` means the harness looked and found a socket or a device node;
// a string this module does not know means the two ends disagree about
// the wire, which a caller must not read as a successful stat.
fn decode_kind(value: MsgPackValue) -> Result(Kind, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  case kind {
    "file" -> Ok(File)

    "directory" -> Ok(Directory)

    "symlink" -> {
      use target <- result.try(wire.string_field(value, "target"))
      Ok(Symlink(target:))
    }

    "other" -> Ok(Other)

    unknown -> Error("unknown kind " <> unknown)
  }
}

fn decode_found(value: MsgPackValue) -> Result(Found, String) {
  use matches <- result.try(wire.array_of(value, "matches", of: decode_match))
  use files_scanned <- result.try(wire.int_field(value, "files_scanned"))
  use files_skipped <- result.try(wire.int_field(value, "files_skipped"))
  use coverage <- result.try(decode_coverage(value))
  Ok(Found(matches:, files_scanned:, files_skipped:, coverage:))
}

fn decode_match(value: MsgPackValue) -> Result(Match, String) {
  use path <- result.try(wire.string_field(value, "path"))
  use line <- result.try(wire.int_field(value, "line"))
  use column <- result.try(wire.int_field(value, "column"))
  use text <- result.try(wire.string_field(value, "text"))
  use before <- result.try(wire.array_of(value, "before", of: as_string))
  use after <- result.try(wire.array_of(value, "after", of: as_string))
  Ok(Match(path:, line:, column:, text:, before:, after:))
}

// As with `kind`, an unrecognised coverage string is a disagreement about
// the wire rather than a coverage this module can safely round down.
fn decode_coverage(value: MsgPackValue) -> Result(Coverage, String) {
  use coverage <- result.try(wire.string_field(value, "coverage"))
  case coverage {
    "exhaustive" -> Ok(Exhaustive)

    "matches_capped" -> Ok(MatchesCapped)

    "scan_truncated" -> Ok(ScanTruncated)

    unknown -> Error("unknown coverage " <> unknown)
  }
}

fn decode_lines(value: MsgPackValue) -> Result(Lines, String) {
  use text <- result.try(wire.string_field(value, "text"))
  use first <- result.try(wire.int_field(value, "first"))
  use last <- result.try(wire.int_field(value, "last"))
  use total <- result.try(wire.int_field(value, "total"))
  Ok(Lines(text:, first:, last:, total:))
}

// `wire` extracts strings from a map's fields; a bare string inside an
// array has no field name, so the element decoder is here.
fn as_string(value: MsgPackValue) -> Result(String, String) {
  case value {
    msgpack.StringValue(text) -> Ok(text)

    _ -> Error("context line is not a string")
  }
}

fn map_error(error: CallError, path: String) -> SearchError {
  case error {
    Unreachable(reason:) -> SearchUnavailable(reason:)

    Denied(code:, message:) ->
      case code {
        "not_found" -> NotFound(path:)

        "denied" | "policy" | "permission_denied" -> PermissionDenied(path:)

        "wrong_kind" | "not_a_directory" | "is_a_directory" ->
          WrongKind(path:, message:)

        "invalid_argument" -> InvalidArgument(message:)

        _ -> SearchFailed(code:, message:)
      }
  }
}
