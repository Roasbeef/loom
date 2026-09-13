//// The navigation and search engine: `glob`, `grep`, `stat` and
//// `read_lines` over an already-contained region of the real
//// filesystem.
////
//// This module is the harness-side half of the `cap/search`
//// capability. A model running in code mode reaches it through the
//// satellite stub and the code-mode router; the router is what turns a
//// workspace-relative argument into the absolute, resolved path these
//// functions take. That split is deliberate and it is the whole of the
//// security argument here.
////
//// ## Containment is the caller's, and the walk keeps it
////
//// Nothing in this module performs path discipline. Every `root` and
//// `path` argument must already have come out of `tools/fs.resolve_real`,
//// which resolves a path component by component against the real
//// filesystem and refuses one that lands outside the workspace root.
//// Handing an unresolved path to `glob` reintroduces exactly the
//// symlink hole `resolve_real` closes.
////
//// What this module owns is the other half: keeping containment true
//// for everything the walk *reaches*. A resolved root is contained, and
//// a directory entry of a contained directory is contained — unless the
//// walk follows a symlink, at which point a link planted inside the
//// workspace becomes a door out of it. So the walk never follows one.
//// Classification is `simplifile.link_info`, which is `lstat`: a
//// symlink is reported as `Symlink(target:)` carrying its stored target
//// verbatim, is never descended into by `glob`, and is never read by
//// `grep`. Containment therefore holds by construction for the whole
//// traversal, from one `resolve_real` call at the boundary, rather than
//// by a check repeated at every entry that somebody could forget.
////
//// `read_lines` is the exception that proves the arrangement: it reads
//// one named file, so the router resolves that path exactly as
//// `fs_read` does, and reading *through* a contained link works while
//// an escaping one is refused before this module sees it.
////
//// ## Every bound is reported, never silent
////
//// A search that quietly stopped short is worse than no search: a model
//// reads an empty result as proof of absence and acts on it. So every
//// bound that ends a walk early shows up in the answer —
//// `Listing.completeness` is `Truncated`, `Found.coverage` is
//// `MatchesCapped` or `ScanTruncated`, and `Found.files_skipped` counts
//// the files that were passed over for being too large or not text.
//// The one thing a bound never does is silently shrink a caller's
//// request: asking for more than a ceiling allows is `InvalidQuery`,
//// not a clamp, because a clamp produces a truncated answer to a
//// question nobody asked.
////
//// ## Not in this version
////
//// `.gitignore` and other ignore files are **not** honoured; `prune`
//// and `hidden` are the whole of the exclusion vocabulary. There is no
//// option to follow symlinks, no case-insensitive matching, and no
//// character classes or brace alternation in the glob language.

import gleam/bool
import gleam/int
import gleam/list
import gleam/regexp
import gleam/result
import gleam/string
import simplifile
import tools/fs
import tools/tool

// --- bounds ---------------------------------------------------------------

/// Entries a `glob` returns when the caller states no preference.
pub const default_max_entries = 1000

/// The largest `max_entries` a `glob` may ask for. Asking for more is
/// `InvalidQuery` rather than a clamp: a silently shrunk request comes
/// back as a truncated answer to a question the caller did not put.
pub const max_entries_ceiling = 4096

/// Matches a `grep` returns when the caller states no preference.
pub const default_max_matches = 100

/// The largest `max_matches` a `grep` may ask for.
pub const max_matches_ceiling = 1000

/// The most context lines a `grep` may ask for on either side of a
/// match. The default is zero.
pub const max_context_lines = 10

/// Filesystem entries a single `glob` or `grep` may touch before the
/// walk stops and reports truncation. This is the bound that makes a
/// call over a pathological tree finite even when nothing matches.
pub const max_visited = 20_000

/// File content a single `grep` may read before it stops and reports
/// truncation: 64 MiB. Distinct from `max_visited` because a tree of a
/// hundred large files and a tree of a million empty ones are different
/// costs and only one of them is counted in entries.
pub const max_scan_bytes = 67_108_864

/// Lines a single `read_lines` window may span.
pub const max_line_span = 2000

/// The longest regex or glob pattern accepted, in graphemes.
pub const max_pattern_length = 1024

/// Directory names not descended into unless the caller passes its own
/// `prune` list. These are the build and metadata trees whose contents
/// are derived rather than authored, and searching them buries the
/// source a model was looking for. Pass `[]` to descend everything.
pub const default_prune = [
  ".git", "_build", "build", "node_modules", "target", "deps",
]

// --- results --------------------------------------------------------------

/// Whether entries whose name begins with `.` take part in a walk.
pub type Hidden {
  /// Skip dot-entries, and do not descend into dot-directories.
  SkipHidden

  /// Treat dot-entries as ordinary ones.
  IncludeHidden
}

/// What `lstat` found at a path. The path itself is inspected and never
/// followed, so a symlink is reported as a symlink whatever it points
/// at.
pub type Kind {
  /// A regular file.
  File

  /// A directory.
  Directory

  /// A symbolic link. `target` is the stored target verbatim, which may
  /// be relative to the link's own directory and may point at nothing.
  Symlink(target: String)

  /// Something else: a socket, a FIFO, a device node.
  Other
}

/// One filesystem entry as a search reports it.
pub type Entry {
  Entry(
    /// The entry's path relative to the workspace root, so it can be
    /// passed straight back to `fs.read`, `read_lines` or `stat`.
    path: String,
    /// What `lstat` found at the path.
    kind: Kind,
    /// Size in bytes, as `lstat` reports it.
    size: Int,
    /// Last modification time, in seconds since the Unix epoch. Present
    /// so a caller that wants recency ordering can sort for itself;
    /// this module only ever orders by path.
    mtime_seconds: Int,
  )
}

/// Whether a listing is the whole answer.
pub type Completeness {
  /// The walk ran to the end of what it could read. A subdirectory the
  /// harness cannot open, or an entry removed while the walk was under
  /// way, is passed over rather than reported: neither is a bound.
  Complete

  /// A bound stopped the walk: either `max_entries` filled or
  /// `max_visited` entries were touched. Entries beyond this point
  /// exist and were not looked at.
  Truncated
}

/// The result of a `glob`.
pub type Listing {
  Listing(
    /// Matching entries, ordered by the walk: each directory's entries
    /// are sorted by name before descent, so the order is deterministic
    /// across runs and across filesystems.
    entries: List(Entry),
    /// Whether a bound cut the walk short.
    completeness: Completeness,
  )
}

/// One matching line found by `grep`.
pub type Match {
  Match(
    /// The file's path relative to the workspace root.
    path: String,
    /// The 1-based line number.
    line: Int,
    /// The 1-based grapheme offset of the first match within the line.
    column: Int,
    /// The whole matching line, without its newline.
    text: String,
    /// Up to `context` lines immediately before, in file order.
    before: List(String),
    /// Up to `context` lines immediately after, in file order.
    after: List(String),
  )
}

/// How much of the requested search actually happened.
pub type Coverage {
  /// Every candidate file under the root was read to its end.
  Exhaustive

  /// `max_matches` filled and at least one further match existed, so
  /// the search stopped there. A scan whose matches fill the bound
  /// exactly with nothing after them is `Exhaustive`.
  MatchesCapped

  /// `max_visited` entries or `max_scan_bytes` of content were reached,
  /// so the search stopped before it ran out of tree.
  ScanTruncated
}

/// The result of a `grep`.
pub type Found {
  Found(
    /// Matches in walk order, then in line order within a file.
    matches: List(Match),
    /// Files whose content was read and searched.
    files_scanned: Int,
    /// Candidate files passed over unread: larger than
    /// `fs.max_read_bytes`, not valid UTF-8, or unreadable. They are
    /// counted rather than dropped so an empty result is never mistaken
    /// for proof of absence.
    files_skipped: Int,
    /// Whether a bound cut the search short.
    coverage: Coverage,
  )
}

/// A window of lines read out of one file.
pub type Lines {
  Lines(
    /// The selected lines joined with `\n`, with no trailing newline.
    text: String,
    /// The 1-based number of the first line in `text`.
    first: Int,
    /// The 1-based number of the last line in `text`, clamped to the
    /// end of the file. A window starting past the end of the file has
    /// `last` below `first` and empty `text`.
    last: Int,
    /// The file's total line count.
    total: Int,
  )
}

/// Why a search was refused, before or during the walk.
pub type SearchError {
  /// A bound was past its ceiling, or a glob or regex did not compile.
  /// `message` is the caller-facing sentence, and for a regex it is the
  /// engine's own text rather than a paraphrase.
  InvalidQuery(message: String)

  /// The `root` of a `glob` or `grep` is not a directory.
  NotADirectory(path: String)

  /// `read_lines` was pointed at a directory.
  NotAFile(path: String)

  /// `read_lines` was pointed at a file larger than
  /// `fs.max_read_bytes`.
  TooLarge(path: String, size: Int)

  /// `read_lines` was pointed at a file whose bytes are not valid
  /// UTF-8.
  NotText(path: String)

  /// `stat` or `read_lines` found nothing at the path.
  Missing(path: String)

  /// Anything else the filesystem said, carrying the backend's own
  /// description.
  Backend(error: tool.FsError)
}

// --- queries --------------------------------------------------------------

/// What a `glob` is asked to do under an already-resolved root.
pub type GlobQuery {
  GlobQuery(
    /// The glob pattern; see `compile_glob` for the language.
    pattern: String,
    /// The most entries to return, at most `max_entries_ceiling`.
    max_entries: Int,
    /// Whether dot-entries take part.
    hidden: Hidden,
    /// Directory names never descended into.
    prune: List(String),
  )
}

/// What a `grep` is asked to do under an already-resolved root.
pub type GrepQuery {
  GrepQuery(
    /// The regex, compiled case-sensitively and without multi-line
    /// mode, so `^` and `$` anchor the whole subject rather than each
    /// line. Each line is matched on its own regardless.
    pattern: String,
    /// Globs limiting which files are read. An empty list reads every
    /// file; otherwise a file is read when any glob matches it.
    globs: List(String),
    /// Lines of context on either side of a match, at most
    /// `max_context_lines`.
    context: Int,
    /// The most matches to return, at most `max_matches_ceiling`.
    max_matches: Int,
    /// Whether dot-entries take part.
    hidden: Hidden,
    /// Directory names never descended into.
    prune: List(String),
  )
}

// --- the glob language ----------------------------------------------------

/// A compiled glob pattern. Pure: compiling and matching touch no
/// filesystem, so the matcher is testable as a table of strings.
pub opaque type Glob {
  Glob(scope: Scope, segments: List(Segment))
}

// What a pattern is matched against. A pattern with no `/` in it is a
// question about a file's name wherever it sits, which is the
// gitignore and ripgrep `-g` reading and the one a model expects when
// it writes `*.gleam`. A pattern with a `/` is a question about a
// position in the tree.
type Scope {
  WholePath
  Basename
}

// One `/`-delimited piece of a pattern.
type Segment {
  // `**`: zero or more whole path segments.
  AnySegments

  // An ordinary segment, as a list of single-grapheme tokens.
  Tokens(tokens: List(Token))
}

// One grapheme of an ordinary segment, or a wildcard standing where one
// would be. Compiling down to single graphemes rather than to runs of
// literal text keeps the matcher to seven arms; patterns are bounded at
// `max_pattern_length`, so the cost is not worth a faster shape.
type Token {
  Lit(grapheme: String)
  AnyOne
  AnyRun
}

/// Compiles a glob pattern, or says in one sentence why it will not
/// compile.
///
/// The language is deliberately small. `*` matches any run of
/// characters within one path segment, `?` matches exactly one
/// character, and `**` matches zero or more whole segments — but only
/// written as a whole segment itself (`**/x`, `x/**`, or `**` alone);
/// `a**b` is refused rather than quietly read as `a*b`. There are no
/// character classes and no brace alternation, so `[` and `{` are
/// ordinary characters. Matching is case-sensitive.
///
/// A pattern containing no `/` is matched against an entry's basename
/// at any depth, so `*.gleam` finds every Gleam file in the tree. A
/// pattern containing a `/` is matched against the entry's path
/// relative to the search root. A leading `./` is stripped from both
/// the pattern and the subject.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(g) = compile_glob("src/**/*.gleam")
/// glob_matches(g, "src/tools/search.gleam")
/// // -> True
/// ```
///
/// ```gleam
/// compile_glob("a**b")
/// // -> Error("`**` is only meaningful as a whole path segment")
/// ```
///
pub fn compile_glob(pattern: String) -> Result(Glob, String) {
  use <- bool.lazy_guard(when: over_length(pattern), return: fn() {
    Error(
      "glob pattern longer than "
      <> int.to_string(max_pattern_length)
      <> " characters",
    )
  })
  let subject = strip_dot_slash(pattern)
  use <- bool.guard(when: subject == "", return: Error("empty glob pattern"))

  // The scope decision is made on the stripped pattern, so `./x` is the
  // basename question `x` rather than a two-segment path question.
  let scope = case string.contains(subject, "/") {
    True -> WholePath
    False -> Basename
  }

  use segments <- result.try(
    string.split(subject, "/") |> list.try_map(compile_segment),
  )
  Ok(Glob(scope:, segments:))
}

// Compiles one `/`-delimited piece. The `**` checks come first and in
// this order: an exact `**` is the wildcard segment, and any other
// occurrence of `**` is a pattern whose author meant something the
// language does not express, which is worth a refusal rather than a
// reading they did not intend.
fn compile_segment(segment: String) -> Result(Segment, String) {
  use <- bool.guard(when: segment == "**", return: Ok(AnySegments))
  use <- bool.guard(
    when: segment == "",
    return: Error("glob pattern has an empty path segment"),
  )
  use <- bool.guard(
    when: string.contains(segment, "**"),
    return: Error("`**` is only meaningful as a whole path segment"),
  )
  Ok(Tokens(tokens: list.map(string.to_graphemes(segment), token_of)))
}

fn token_of(grapheme: String) -> Token {
  case grapheme {
    "*" -> AnyRun
    "?" -> AnyOne
    literal -> Lit(grapheme: literal)
  }
}

/// Whether a compiled glob matches a path.
///
/// `relative_path` is relative to the search root, using `/`
/// separators. Which part of it is tested depends on the pattern: see
/// `compile_glob`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(g) = compile_glob("*.gleam")
/// glob_matches(g, "deep/down/here.gleam")
/// // -> True
/// ```
///
pub fn glob_matches(glob: Glob, relative_path: String) -> Bool {
  let subject = case glob.scope {
    WholePath -> strip_dot_slash(relative_path)
    Basename -> basename(relative_path)
  }
  match_segments(glob.segments, string.split(subject, "/"))
}

// Matches a pattern's segments against a path's segments.
//
// The `AnySegments` arm is the only one that backtracks: `**` first
// tries to consume nothing, and failing that consumes one segment and
// asks itself again. That ordering is what makes `**/x` match `x` at
// the root as well as at depth.
fn match_segments(pattern: List(Segment), path: List(String)) -> Bool {
  case pattern, path {
    [], [] -> True
    [], [_extra, ..] -> False
    [AnySegments, ..rest], remaining ->
      match_segments(rest, remaining) || descend_star(pattern, remaining)
    [Tokens(tokens:), ..rest], [head, ..tail] ->
      match_tokens(tokens, string.to_graphemes(head))
      && match_segments(rest, tail)
    [Tokens(tokens: _), ..], [] -> False
  }
}

// The consuming half of `**`: give up one path segment and try the same
// pattern again. Split out so `match_segments` stays one `case` deep.
fn descend_star(pattern: List(Segment), path: List(String)) -> Bool {
  case path {
    [] -> False
    [_consumed, ..tail] -> match_segments(pattern, tail)
  }
}

// Matches one segment's tokens against one segment's graphemes. `AnyRun`
// backtracks the same way `**` does, one grapheme at a time.
fn match_tokens(tokens: List(Token), chars: List(String)) -> Bool {
  case tokens, chars {
    [], [] -> True
    [], [_extra, ..] -> False
    [AnyRun, ..rest], remaining ->
      match_tokens(rest, remaining) || consume_one(tokens, remaining)
    [AnyOne, ..rest], [_any, ..tail] -> match_tokens(rest, tail)
    [AnyOne, ..], [] -> False
    [Lit(grapheme:), ..rest], [head, ..tail] ->
      grapheme == head && match_tokens(rest, tail)
    [Lit(grapheme: _), ..], [] -> False
  }
}

fn consume_one(tokens: List(Token), chars: List(String)) -> Bool {
  case chars {
    [] -> False
    [_consumed, ..tail] -> match_tokens(tokens, tail)
  }
}

// Whether a pattern is longer than `max_pattern_length`, answered
// without walking past the bound: `string.length` counts every grapheme
// of a megabyte of pasted text to settle a question the first thousand
// already answer (lint R5).
fn over_length(pattern: String) -> Bool {
  string.drop_start(pattern, max_pattern_length) != ""
}

fn strip_dot_slash(path: String) -> String {
  case string.starts_with(path, "./") {
    True -> string.drop_start(path, 2)
    False -> path
  }
}

fn basename(path: String) -> String {
  string.split(path, "/") |> list.last() |> result.unwrap(path)
}

// --- the walk -------------------------------------------------------------

// One entry the walk has classified, in both the form the matcher wants
// (root-relative) and the form the reader wants (absolute).
type WalkEntry {
  WalkEntry(
    absolute: String,
    relative: String,
    kind: Kind,
    info: simplifile.FileInfo,
  )
}

// What a visitor tells the walk to do next. `Halt` is how a consumer's
// own bound — `max_entries`, `max_matches`, `max_scan_bytes` — ends the
// traversal; the reason lives in the accumulator, because the walk has
// no vocabulary for its consumers' bounds.
type Step(acc) {
  Continue(state: acc)
  Halt(state: acc)
}

// Why the walk stopped.
type Limit {
  // The tree ran out.
  Completed

  // `max_visited` entries were touched.
  VisitLimit

  // A visitor said `Halt`.
  VisitorStopped
}

type Cursor(acc) {
  Cursor(state: acc, visited: Int, limit: Limit)
}

// Everything the recursion needs that does not change between entries.
type Walker(acc) {
  Walker(
    hidden: Hidden,
    prune: List(String),
    visit: fn(WalkEntry, acc) -> Step(acc),
  )
}

// Walks a resolved directory, pre-order, entries sorted within each
// directory, never following a symlink.
//
// The root is checked with `link_info` before anything else so a root
// that is a file answers `NotADirectory` — the refusal a caller can act
// on, since it names `read_lines` as the call that was wanted — rather
// than a bare errno out of `read_directory`.
fn walk_tree(
  root root: String,
  walker walker: Walker(acc),
  from initial: acc,
) -> Result(Cursor(acc), SearchError) {
  use info <- result.try(
    simplifile.link_info(root)
    |> result.map_error(missing_or_backend(root, _)),
  )
  use <- bool.guard(
    when: simplifile.file_info_type(info) != simplifile.Directory,
    return: Error(NotADirectory(path: root)),
  )
  use names <- result.try(
    simplifile.read_directory(root) |> result.map_error(root_error(root, _)),
  )
  Ok(walk_names(
    root,
    "",
    list.sort(names, string.compare),
    walker,
    Cursor(state: initial, visited: 0, limit: Completed),
  ))
}

// Walks the sorted names of one directory, stopping the moment a bound
// has been reached so a halt does not have to unwind through the rest
// of the tree.
fn walk_names(
  dir: String,
  prefix: String,
  names: List(String),
  walker: Walker(acc),
  cursor: Cursor(acc),
) -> Cursor(acc) {
  case names, cursor.limit {
    [], _reached -> cursor
    [_pending, ..], VisitLimit -> cursor
    [_pending, ..], VisitorStopped -> cursor
    [name, ..rest], Completed ->
      walk_names(
        dir,
        prefix,
        rest,
        walker,
        walk_name(dir, prefix, name, walker, cursor),
      )
  }
}

// The hidden rule and the visit budget, in that order: a dot-entry the
// caller excluded is not an entry the walk touched, so it must not
// spend a visit.
fn walk_name(
  dir: String,
  prefix: String,
  name: String,
  walker: Walker(acc),
  cursor: Cursor(acc),
) -> Cursor(acc) {
  use <- bool.lazy_guard(when: hidden_here(name, walker.hidden), return: fn() {
    cursor
  })
  case cursor.visited >= max_visited {
    True -> Cursor(..cursor, limit: VisitLimit)
    False -> visit_name(dir, prefix, name, walker, cursor)
  }
}

fn hidden_here(name: String, hidden: Hidden) -> Bool {
  case hidden {
    IncludeHidden -> False
    SkipHidden -> string.starts_with(name, ".")
  }
}

// Classifies one entry and offers it to the visitor.
//
// An entry that cannot be `lstat`ed — it was unlinked between the
// `read_directory` and here, or its directory is not searchable — still
// spends a visit and is otherwise passed over. The alternative, failing
// the whole search on one racing entry, turns an ordinary concurrent
// write in the workspace into a failed query.
fn visit_name(
  dir: String,
  prefix: String,
  name: String,
  walker: Walker(acc),
  cursor: Cursor(acc),
) -> Cursor(acc) {
  let absolute = dir <> "/" <> name
  let relative = case prefix {
    "" -> name
    parent -> parent <> "/" <> name
  }

  case simplifile.link_info(absolute) {
    Error(_vanished) -> Cursor(..cursor, visited: cursor.visited + 1)
    Ok(info) ->
      offer(
        WalkEntry(absolute:, relative:, kind: classify(absolute, info), info:),
        name,
        walker,
        Cursor(..cursor, visited: cursor.visited + 1),
      )
  }
}

// Hands an entry to the visitor and, if it said `Continue`, descends.
// Descent happens after the visit so a directory is reported before its
// contents, which is what makes the order a stable pre-order.
fn offer(
  entry: WalkEntry,
  name: String,
  walker: Walker(acc),
  cursor: Cursor(acc),
) -> Cursor(acc) {
  case walker.visit(entry, cursor.state) {
    Halt(state:) -> Cursor(..cursor, state:, limit: VisitorStopped)
    Continue(state:) -> descend(entry, name, walker, Cursor(..cursor, state:))
  }
}

// Descends into a directory, unless it is pruned.
//
// The kind test is what keeps containment: a symlink to a directory is
// `Symlink`, not `Directory`, so it is reported and left alone. A
// directory that cannot be read is passed over for the same reason a
// racing entry is.
fn descend(
  entry: WalkEntry,
  name: String,
  walker: Walker(acc),
  cursor: Cursor(acc),
) -> Cursor(acc) {
  use <- bool.lazy_guard(when: entry.kind != Directory, return: fn() { cursor })
  use <- bool.lazy_guard(when: list.contains(walker.prune, name), return: fn() {
    cursor
  })
  case simplifile.read_directory(entry.absolute) {
    Error(_unreadable) -> cursor
    Ok(names) ->
      walk_names(
        entry.absolute,
        entry.relative,
        list.sort(names, string.compare),
        walker,
        cursor,
      )
  }
}

// Turns `lstat`'s mode bits into the reported kind, reading a symlink's
// stored target through the `tools/fs` seam rather than resolving it.
fn classify(absolute: String, info: simplifile.FileInfo) -> Kind {
  case simplifile.file_info_type(info) {
    simplifile.File -> File
    simplifile.Directory -> Directory
    simplifile.Symlink -> Symlink(target: link_target(absolute))
    simplifile.Other -> Other
  }
}

// A dangling or unreadable link still has a kind worth reporting, so a
// target that cannot be read becomes the empty string rather than an
// error that loses the entry.
fn link_target(absolute: String) -> String {
  case fs.real_filesystem().read_link(absolute) {
    Ok(tool.LinkTarget(target:)) -> target
    Ok(tool.NotALink) -> ""
    Ok(tool.LinkMissing) -> ""
    Error(_unreadable) -> ""
  }
}

// --- glob -----------------------------------------------------------------

// The accumulator carries its own count because `max_entries` is checked
// once per match: `list.length` there would make the walk quadratic in
// the number of matches for a question the counter already answers
// (lint R5).
type Collected {
  Collected(entries: List(Entry), count: Int)
}

/// Lists the entries under a resolved root whose path matches a glob.
///
/// `root` is absolute and already resolved by `tools/fs.resolve_real`;
/// `workspace` is the equally resolved workspace root, used only to
/// render each `Entry.path` workspace-relative so it can be handed
/// straight back to another call.
///
/// Directories match and are reported like anything else. Symlinks are
/// reported with their stored target and never descended.
///
/// ## Examples
///
/// ```gleam
/// glob(
///   workspace: "/work",
///   root: "/work/src",
///   query: GlobQuery(
///     pattern: "**/*.gleam",
///     max_entries: default_max_entries,
///     hidden: SkipHidden,
///     prune: default_prune,
///   ),
/// )
/// // -> Ok(Listing(entries: [Entry(path: "src/app.gleam", ..)], completeness: Complete))
/// ```
///
pub fn glob(
  workspace workspace: String,
  root root: String,
  query query: GlobQuery,
) -> Result(Listing, SearchError) {
  use <- bool.lazy_guard(
    when: query.max_entries < 1 || query.max_entries > max_entries_ceiling,
    return: fn() {
      Error(InvalidQuery(
        message: "max_entries must be between 1 and "
        <> int.to_string(max_entries_ceiling),
      ))
    },
  )
  use compiled <- result.try(
    compile_glob(query.pattern) |> result.map_error(InvalidQuery),
  )

  let walker =
    Walker(
      hidden: query.hidden,
      prune: query.prune,
      visit: glob_visitor(
        compiled,
        display_prefix(workspace:, root:),
        query.max_entries,
      ),
    )
  use cursor <- result.try(walk_tree(
    root:,
    walker:,
    from: Collected(entries: [], count: 0),
  ))

  // The visitor collected one entry past the bound if the tree held one,
  // so the overflow is what distinguishes a listing that filled exactly
  // from one that had more to give. Dropping it here rather than never
  // taking it is what keeps the answer exactly `max_entries` long.
  let collected = list.reverse(cursor.state.entries)
  case cursor.state.count > query.max_entries {
    True ->
      Ok(Listing(
        entries: list.take(collected, query.max_entries),
        completeness: Truncated,
      ))
    False ->
      Ok(Listing(entries: collected, completeness: completeness(cursor.limit)))
  }
}

// Collects matching entries and halts the walk one entry *past* the
// bound the caller asked for.
//
// Halting on the last entry asked for would be cheaper by one `lstat`
// and would report `Truncated` for a tree that filled the request
// exactly and held nothing more — telling a program it missed entries
// when it missed none, which is the reading a model acts on. So the walk
// looks one further, and `glob` drops the overflow.
fn glob_visitor(
  compiled: Glob,
  base: String,
  max_entries: Int,
) -> fn(WalkEntry, Collected) -> Step(Collected) {
  fn(entry: WalkEntry, collected: Collected) {
    use <- bool.lazy_guard(
      when: !glob_matches(compiled, entry.relative),
      return: fn() { Continue(state: collected) },
    )
    let taken =
      Collected(
        entries: [
          Entry(
            path: base <> entry.relative,
            kind: entry.kind,
            size: entry.info.size,
            mtime_seconds: entry.info.mtime_seconds,
          ),
          ..collected.entries
        ],
        count: collected.count + 1,
      )
    case taken.count > max_entries {
      True -> Halt(state: taken)
      False -> Continue(state: taken)
    }
  }
}

fn completeness(limit: Limit) -> Completeness {
  case limit {
    Completed -> Complete
    VisitLimit -> Truncated
    VisitorStopped -> Truncated
  }
}

// --- grep -----------------------------------------------------------------

// Why a `grep` visitor stopped, kept beside the counters because the
// walk itself has no vocabulary for a byte budget or a match cap.
type Stop {
  Running
  HitMatches
  HitBytes
}

// Everything a line scan needs that is fixed for the whole file: the
// compiled regex, the path a match will name, and the two query bounds
// the line loop enforces. Passing one record rather than four
// parameters keeps the loop and the recorder honest about which
// argument is which.
type Lens {
  Lens(
    expression: regexp.Regexp,
    display: String,
    context: Int,
    max_matches: Int,
  )
}

type Scan {
  Scan(
    matches: List(Match),
    taken: Int,
    files_scanned: Int,
    files_skipped: Int,
    bytes: Int,
    stopped: Stop,
  )
}

/// Searches the content of files under a resolved root for a regex.
///
/// `root` and `workspace` are as `glob`'s. Only regular files are read:
/// a symlink is a `Symlink`, not a `File`, so `grep` never reads through
/// one, and containment holds for the whole search from the single
/// `resolve_real` the caller performed.
///
/// Each candidate file is read whole through `fs.read_text_file`, the
/// same guard `fs_read` uses, so a file over `fs.max_read_bytes` or one
/// that is not valid UTF-8 is passed over and counted in
/// `files_skipped` rather than failing the search.
///
/// The regex is compiled with `case_insensitive: False` and
/// `multi_line: False`, and each line is matched separately.
///
/// ## Examples
///
/// ```gleam
/// grep(
///   workspace: "/work",
///   root: "/work",
///   query: GrepQuery(
///     pattern: "pub fn resolve_real",
///     globs: ["*.gleam"],
///     context: 0,
///     max_matches: default_max_matches,
///     hidden: SkipHidden,
///     prune: default_prune,
///   ),
/// )
/// // -> Ok(Found(matches: [Match(path: "src/tools/fs.gleam", line: 201, ..)], ..))
/// ```
///
pub fn grep(
  workspace workspace: String,
  root root: String,
  query query: GrepQuery,
) -> Result(Found, SearchError) {
  use <- bool.lazy_guard(
    when: query.max_matches < 1 || query.max_matches > max_matches_ceiling,
    return: fn() {
      Error(InvalidQuery(
        message: "max_matches must be between 1 and "
        <> int.to_string(max_matches_ceiling),
      ))
    },
  )
  use <- bool.lazy_guard(
    when: query.context < 0 || query.context > max_context_lines,
    return: fn() {
      Error(InvalidQuery(
        message: "context must be between 0 and "
        <> int.to_string(max_context_lines),
      ))
    },
  )
  use expression <- result.try(compile_regexp(query.pattern))
  use filters <- result.try(
    list.try_map(query.globs, compile_glob) |> result.map_error(InvalidQuery),
  )

  let walker =
    Walker(
      hidden: query.hidden,
      prune: query.prune,
      visit: grep_visitor(
        expression,
        filters,
        display_prefix(workspace:, root:),
        query,
      ),
    )
  use cursor <- result.try(walk_tree(root:, walker:, from: fresh_scan()))

  // The visitor recorded one match past the bound if the tree held one,
  // so the overflow is what distinguishes a scan that filled exactly from
  // one that was cut short. Dropping it here keeps the answer exactly
  // `max_matches` long and the coverage honest in both directions.
  let scan = cursor.state
  let matches = list.reverse(scan.matches)
  case scan.taken > query.max_matches {
    True ->
      Ok(Found(
        matches: list.take(matches, query.max_matches),
        files_scanned: scan.files_scanned,
        files_skipped: scan.files_skipped,
        coverage: MatchesCapped,
      ))
    False ->
      Ok(Found(
        matches:,
        files_scanned: scan.files_scanned,
        files_skipped: scan.files_skipped,
        coverage: coverage(scan.stopped, cursor.limit),
      ))
  }
}

fn fresh_scan() -> Scan {
  Scan(
    matches: [],
    taken: 0,
    files_scanned: 0,
    files_skipped: 0,
    bytes: 0,
    stopped: Running,
  )
}

// The visitor's own bounds, checked before the read that would breach
// them. `max_scan_bytes` is tested against the running total rather than
// against the total plus this file's size, so the budget is a floor a
// search is allowed to cross once and never a reason to skip a file that
// would have fitted.
fn grep_visitor(
  expression: regexp.Regexp,
  filters: List(Glob),
  base: String,
  query: GrepQuery,
) -> fn(WalkEntry, Scan) -> Step(Scan) {
  fn(entry: WalkEntry, scan: Scan) {
    use <- bool.lazy_guard(when: entry.kind != File, return: fn() {
      Continue(state: scan)
    })
    use <- bool.lazy_guard(
      when: !selected(filters, entry.relative),
      return: fn() { Continue(state: scan) },
    )
    case scan.bytes >= max_scan_bytes {
      True -> Halt(state: Scan(..scan, stopped: HitBytes))
      False -> scan_file(entry, expression, base, query, scan)
    }
  }
}

// No globs is every file, which is the reading a caller who passed none
// meant; any glob matching is enough, so the list is a union.
fn selected(filters: List(Glob), relative: String) -> Bool {
  case filters {
    [] -> True
    chosen -> list.any(chosen, glob_matches(_, relative))
  }
}

// Reads one candidate whole and scans its lines. Every read failure —
// too large, not text, or an errno — is one skipped file rather than a
// failed search, because a single unreadable file in a tree is not a
// reason to answer nothing.
fn scan_file(
  entry: WalkEntry,
  expression: regexp.Regexp,
  base: String,
  query: GrepQuery,
  scan: Scan,
) -> Step(Scan) {
  case
    fs.read_text_file(
      filesystem: fs.real_filesystem(),
      resolved: entry.absolute,
    )
  {
    Error(_unusable) ->
      Continue(state: Scan(..scan, files_skipped: scan.files_skipped + 1))
    Ok(text) ->
      scan_lines(
        split_lines(text),
        [],
        1,
        Lens(
          expression:,
          display: base <> entry.relative,
          context: query.context,
          max_matches: query.max_matches,
        ),
        Scan(
          ..scan,
          files_scanned: scan.files_scanned + 1,
          bytes: scan.bytes + string.byte_size(text),
        ),
      )
  }
}

// Walks one file's lines, carrying the preceding `context` lines in
// reverse so a match can render its `before` without indexing back into
// the list.
fn scan_lines(
  remaining: List(String),
  preceding: List(String),
  number: Int,
  lens: Lens,
  scan: Scan,
) -> Step(Scan) {
  case remaining {
    [] -> Continue(state: scan)
    [line, ..rest] ->
      case record_line(line, rest, preceding, number, lens, scan) {
        Halt(state:) -> Halt(state:)
        Continue(state:) ->
          scan_lines(
            rest,
            list.take([line, ..preceding], lens.context),
            number + 1,
            lens,
            state,
          )
      }
  }
}

// Records one line if it matches, and halts the scan on the last match
// the caller asked for.
fn record_line(
  line: String,
  rest: List(String),
  preceding: List(String),
  number: Int,
  lens: Lens,
  scan: Scan,
) -> Step(Scan) {
  use <- bool.lazy_guard(
    when: !regexp.check(with: lens.expression, content: line),
    return: fn() { Continue(state: scan) },
  )
  let found =
    Match(
      path: lens.display,
      line: number,
      column: first_column(lens.expression, line),
      text: line,
      before: list.reverse(preceding),
      after: list.take(rest, lens.context),
    )
  let taken =
    Scan(..scan, matches: [found, ..scan.matches], taken: scan.taken + 1)
  // One match past the bound is taken on purpose: it is what tells a
  // scan that filled exactly from one that had more to give, the same
  // way `glob` looks one entry past `max_entries`. `grep` drops it.
  case taken.taken > lens.max_matches {
    True -> Halt(state: Scan(..taken, stopped: HitMatches))
    False -> Continue(state: taken)
  }
}

// The 1-based grapheme column of the first match in a line.
//
// `gleam_regexp.Match` carries the matched text but no offset, so the
// column is derived instead: `regexp.split` cuts the line at every
// match, and the first piece is exactly the text before the first one,
// whose grapheme count plus one is the column. A pattern that can match
// the empty string makes that first piece empty and the answer 1, which
// is where a zero-width match at the start of the line is; that is the
// one case where the derivation is a convention rather than a
// measurement, and it is stated here rather than hidden.
fn first_column(expression: regexp.Regexp, line: String) -> Int {
  case regexp.split(with: expression, content: line) {
    [prefix, _rest, ..] -> string.length(prefix) + 1
    [_whole] -> 1
    [] -> 1
  }
}

// Splits text into lines, treating a final newline as a terminator
// rather than as the start of an empty last line — so "a\nb\n" is two
// lines, and the empty file is no lines at all.
fn split_lines(text: String) -> List(String) {
  case text == "", string.ends_with(text, "\n") {
    True, _terminated -> []
    False, True -> string.split(string.drop_end(text, 1), "\n")
    False, False -> string.split(text, "\n")
  }
}

fn coverage(stopped: Stop, limit: Limit) -> Coverage {
  case stopped, limit {
    HitMatches, _reached -> MatchesCapped
    HitBytes, _reached -> ScanTruncated
    Running, VisitLimit -> ScanTruncated
    Running, VisitorStopped -> ScanTruncated
    Running, Completed -> Exhaustive
  }
}

fn compile_regexp(pattern: String) -> Result(regexp.Regexp, SearchError) {
  use <- bool.lazy_guard(when: over_length(pattern), return: fn() {
    Error(InvalidQuery(
      message: "regex longer than "
      <> int.to_string(max_pattern_length)
      <> " characters",
    ))
  })
  regexp.compile(
    pattern,
    with: regexp.Options(case_insensitive: False, multi_line: False),
  )
  |> result.map_error(fn(failure) { InvalidQuery(message: failure.error) })
}

// --- stat and read_lines --------------------------------------------------

/// Reports what `lstat` finds at one absolute path.
///
/// The final component is never followed: a symlink answers
/// `Symlink(target:)` with its stored target verbatim, whatever it
/// points at and whether or not it points at anything. `display` is the
/// workspace-relative rendering the caller wants echoed back in
/// `Entry.path`.
///
/// ## Examples
///
/// ```gleam
/// stat(path: "/work/src/app.gleam", display: "src/app.gleam")
/// // -> Ok(Entry(path: "src/app.gleam", kind: File, size: 812, mtime_seconds: 1_757_000_000))
/// ```
///
pub fn stat(
  path path: String,
  display display: String,
) -> Result(Entry, SearchError) {
  use info <- result.try(
    simplifile.link_info(path) |> result.map_error(missing_or_backend(path, _)),
  )
  Ok(Entry(
    path: display,
    kind: classify(path, info),
    size: info.size,
    mtime_seconds: info.mtime_seconds,
  ))
}

/// Reads an inclusive, 1-based window of lines out of one file.
///
/// `path` is absolute and already resolved, as `fs_read`'s is, so
/// reading through a contained symlink works and an escaping one was
/// refused before this call. The window must satisfy
/// `1 <= from <= to` and span at most `max_line_span` lines; anything
/// else is `InvalidQuery` rather than a quietly adjusted request. A
/// `to` past the end of the file is clamped and the clamp is reported
/// in `Lines.last`.
///
/// ## Examples
///
/// ```gleam
/// read_lines(path: "/work/src/app.gleam", from: 10, to: 12)
/// // -> Ok(Lines(text: "one\ntwo\nthree", first: 10, last: 12, total: 400))
/// ```
///
pub fn read_lines(
  path path: String,
  from first: Int,
  to last: Int,
) -> Result(Lines, SearchError) {
  use <- bool.guard(
    when: first < 1,
    return: Error(InvalidQuery(message: "from must be at least 1")),
  )
  use <- bool.guard(
    when: last < first,
    return: Error(InvalidQuery(message: "from must not be greater than to")),
  )
  use <- bool.lazy_guard(when: last - first + 1 > max_line_span, return: fn() {
    Error(InvalidQuery(
      message: "a window spans at most "
      <> int.to_string(max_line_span)
      <> " lines",
    ))
  })

  // The kind is settled before the read so a directory answers
  // `NotAFile`, which names the call that was wanted, rather than
  // whatever errno reading a directory produces on this system.
  use info <- result.try(
    simplifile.link_info(path) |> result.map_error(missing_or_backend(path, _)),
  )
  use <- bool.guard(
    when: simplifile.file_info_type(info) == simplifile.Directory,
    return: Error(NotAFile(path:)),
  )

  use text <- result.try(
    fs.read_text_file(filesystem: fs.real_filesystem(), resolved: path)
    |> result.map_error(read_failure(path, _)),
  )
  Ok(window(text, first, last))
}

// Cuts the window out of the decoded text.
//
// `list.length` is an O(n) walk, and here that is the answer rather than
// lint R5's complaint: `total` is the file's line count, which is the
// very thing being walked.
fn window(text: String, first: Int, last: Int) -> Lines {
  let lines = split_lines(text)
  let total = list.length(lines)
  let stop = int.min(last, total)
  let selected = lines |> list.drop(first - 1) |> list.take(stop - first + 1)
  Lines(text: string.join(selected, "\n"), first:, last: stop, total:)
}

fn read_failure(path: String, error: fs.ReadError) -> SearchError {
  case error {
    fs.TooLarge(size:, limit: _limit) -> TooLarge(path:, size:)
    fs.NotText -> NotText(path:)
    fs.ReadFailed(error:) -> Backend(error:)
  }
}

// --- error vocabulary -----------------------------------------------------

// `ENOTDIR` on a lookup means an ancestor component is not a directory,
// so nothing exists at the path; both it and `ENOENT` are the same
// answer to the caller.
fn missing_or_backend(
  path: String,
  error: simplifile.FileError,
) -> SearchError {
  case error {
    simplifile.Enoent -> Missing(path:)
    simplifile.Enotdir -> Missing(path:)
    other -> backend_error(path, other)
  }
}

// `ENOTDIR` from `read_directory` on the root means the path is there
// and `read_lines` is the call that was wanted, which is a repair the
// caller can act on.
fn root_error(root: String, error: simplifile.FileError) -> SearchError {
  case error {
    simplifile.Enotdir -> NotADirectory(path: root)

    // The root was there for the lstat a moment ago; a directory removed
    // between the two calls is still a missing path, not a backend fault.
    simplifile.Enoent -> Missing(path: root)
    other -> backend_error(root, other)
  }
}

// Everything else keeps the backend's own description: inventing a
// sentence for an errno nobody anticipated is how a refusal starts
// lying.
fn backend_error(path: String, error: simplifile.FileError) -> SearchError {
  case error {
    simplifile.Eacces -> Backend(error: tool.FsPermissionDenied(path:))
    simplifile.Eperm -> Backend(error: tool.FsPermissionDenied(path:))
    other ->
      Backend(error: tool.FsFailure(
        path:,
        reason: simplifile.describe_error(other),
      ))
  }
}

// --- paths ----------------------------------------------------------------

// The prefix that turns a root-relative path into a workspace-relative
// one. A root that is the workspace itself contributes nothing; a root
// below it contributes its own workspace-relative path and a separator.
fn display_prefix(workspace workspace: String, root root: String) -> String {
  case string.starts_with(root, workspace <> "/") {
    True -> string.drop_start(root, string.length(workspace) + 1) <> "/"
    False -> ""
  }
}
