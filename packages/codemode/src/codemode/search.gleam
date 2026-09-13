//// The workspace seam's navigation and search router: `search.glob`,
//// `search.grep`, `search.stat` and `search.read_lines`, answered inside
//// the harness rather than inside a jail.
////
//// # Why this is its own module rather than four arms on `workspace`
////
//// The two routers service the same seam and could have been one. They
//// are two because the *module* a program imports is the unit of
//// authorization here, and `cap/search` grants strictly less than
//// `cap/fs`: there is no write arm on it at all. A program that needs to
//// find its way around a tree can import `cap/search` alone, and the
//// vetting seam — which reads imports — can see that it did. Folding
//// these four names into `codemode/workspace` would keep the capability
//// split on the satellite side and lose it on the harness side, where a
//// reader asking "what can a read-only program reach?" would have to
//// subtract the write arms out of one list by eye.
////
//// The seam is read-only in the other direction too: every closure
//// below answers a question and none of them writes anything, so
//// nothing here mints something that outlives the execution and there
//// is no `satellite.CapCeiling` on any of the four. A `glob` that ran a
//// thousand times spent a thousand walks, each bounded by
//// `tools/search`'s own budgets, and left nothing behind.
////
//// # Every plan is `ServedHere`
////
//// For the reason `codemode/workspace`'s module doc argues at length: a
//// walk over a directory the harness can already read spawns no
//// process, opens no socket and crosses no namespace, so a composed
//// `SandboxPolicy` would be a policy whose enforcer is not present. A
//// router that returns only `ServedHere` cannot state broker
//// coordinates at all, which is the boundary `codemode/identity` is
//// shaped around.
////
//// # Containment belongs entirely to the injected closures
////
//// This module holds no path logic. Every `root` and `path` it decodes
//// is a string it hands straight to a closure, and the production
//// closures (`client/codemode.search_seam_for`) put each one through
//// `tools/fs.resolve_real` — the harness's single filesystem boundary —
//// before `tools/search` sees it. `tools/search` then keeps containment
//// true for everything the walk *reaches* by never following a symlink.
//// A second path rule written here would be a second boundary to keep
//// correct, and the one that got it wrong would be the one nobody was
//// reading.
////
//// # Every bound is the engine's, and so is every bound check
////
//// `max_entries`, `max_matches`, `context` and the line span are decoded
//// here and checked nowhere here: `tools/search` refuses one past its
//// ceiling as `InvalidQuery`, which this module renders as
//// `invalid_argument`. Two places holding the same number is how the
//// wire and the enforcer come to disagree, and the enforcer is the one
//// that matters.

import broker/framing.{type CapOutcome}
import codemode/internal/args
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
  ServedHere,
}
import codemode/workspace
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/list
import gleam/result
import tools/fs
import tools/search

// --- the capability names ----------------------------------------------------

/// The capability a program lists paths matching a glob with.
pub const glob_cap = "search.glob"

/// The capability a program searches file contents with.
pub const grep_cap = "search.grep"

/// The capability a program inspects one path with, without following a
/// final symlink.
pub const stat_cap = "search.stat"

/// The capability a program reads a window of lines with.
pub const read_lines_cap = "search.read_lines"

/// Every capability this router services, in the order a program meets
/// them. Published so the tool description a model reads states the real
/// set rather than a copy that can drift.
pub const serviced_caps = [glob_cap, grep_cap, stat_cap, read_lines_cap]

// --- the seam ----------------------------------------------------------------

/// Why a search call could not be answered.
///
/// Two variants for two boundaries, and the split is where the decision
/// was made rather than what it was about. `PathRefused` is
/// `tools/fs.resolve_real`'s answer, reached before the engine runs at
/// all; `QueryRefused` is `tools/search`'s, reached once the path was
/// contained. Neither is this module's, which is why the sentences a
/// program reads are the harness's own words in both cases.
pub type SearchRefusal {
  /// `resolve_real` refused the `root` or the `path`.
  PathRefused(error: fs.PathError)

  /// The path was contained and the engine refused the query.
  QueryRefused(error: search.SearchError)
}

/// The harness-side closures this router calls.
///
/// Injected rather than implemented here for the reason every seam in
/// this package is: `codemode` must not learn where a session's
/// workspace root is or how a path is resolved against it. The types are
/// `tools/search`'s directly — `codemode` already depends on `tools`, and
/// a private copy of a four-type search vocabulary would be a second
/// place to keep an entry's fields in step for no isolation gained.
///
/// Constructor invariants: each closure receives the arguments exactly as
/// the wire carried them — workspace-relative or absolute, unresolved —
/// and owns the resolution. `glob` and `grep` take the query's `root`
/// first; `read_lines` takes the path and the inclusive 1-based window.
pub type Search {
  Search(
    /// Lists the entries under `root` whose path matches the query.
    glob: fn(String, search.GlobQuery) -> Result(search.Listing, SearchRefusal),
    /// Searches the content of the files under `root`.
    grep: fn(String, search.GrepQuery) -> Result(search.Found, SearchRefusal),
    /// Reports what `lstat` finds at one path.
    stat: fn(String) -> Result(search.Entry, SearchRefusal),
    /// Reads an inclusive, 1-based window of lines out of one file.
    read_lines: fn(String, Int, Int) -> Result(search.Lines, SearchRefusal),
  )
}

/// The search router, in front of `inner`.
///
/// Composed rather than total, for the reason `codemode/workspace.routing`
/// is: the workspace seam is served by several arms and this one answers
/// four names. Everything else is handed down untouched.
///
/// ## Examples
///
/// ```gleam
/// // search.routing(seam, over: satellite.default_router)
/// ```
///
pub fn routing(seam: Search, over inner: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    // Gleam patterns cannot name a constant, so the arms below are string
    // literals while `serviced_caps` holds the constants — two lists that
    // could drift. `search_test` walks `serviced_caps` and asserts each
    // one routes, which is what keeps them the same list.
    case request.cap {
      "search.glob" -> glob_plan(seam, request)
      "search.grep" -> grep_plan(seam, request)
      "search.stat" -> stat_plan(seam, request)
      "search.read_lines" -> read_lines_plan(seam, request)
      _other -> inner(request)
    }
  }
}

// --- the arms -----------------------------------------------------------------

fn glob_plan(seam: Search, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use root <- result.try(args.string(request.args, "root"))
  use pattern <- result.try(args.string(request.args, "pattern"))
  use max_entries <- result.try(args.int(request.args, "max_entries"))
  use hidden <- result.try(hidden_arg(request.args))
  use prune <- result.try(args.string_array(request.args, "prune"))
  let query = search.GlobQuery(pattern:, max_entries:, hidden:, prune:)
  Ok(
    ServedHere(fn() {
      case seam.glob(root, query) {
        Error(refusal) -> refused(refusal)
        Ok(search.Listing(entries:, completeness:)) ->
          answered([
            #("entries", msgpack.ArrayValue(list.map(entries, entry_value))),
            #("truncated", msgpack.BoolValue(truncated(completeness))),
          ])
      }
    }),
  )
}

fn grep_plan(seam: Search, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use root <- result.try(args.string(request.args, "root"))
  use pattern <- result.try(args.string(request.args, "pattern"))
  use globs <- result.try(args.string_array(request.args, "globs"))
  use context <- result.try(args.int(request.args, "context"))
  use max_matches <- result.try(args.int(request.args, "max_matches"))
  use hidden <- result.try(hidden_arg(request.args))
  use prune <- result.try(args.string_array(request.args, "prune"))
  let query =
    search.GrepQuery(pattern:, globs:, context:, max_matches:, hidden:, prune:)
  Ok(
    ServedHere(fn() {
      case seam.grep(root, query) {
        Error(refusal) -> refused(refusal)
        Ok(search.Found(matches:, files_scanned:, files_skipped:, coverage:)) ->
          answered([
            #("matches", msgpack.ArrayValue(list.map(matches, match_value))),
            #("files_scanned", msgpack.IntValue(files_scanned)),
            #("files_skipped", msgpack.IntValue(files_skipped)),
            #("coverage", msgpack.StringValue(coverage_name(coverage))),
          ])
      }
    }),
  )
}

fn stat_plan(seam: Search, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use path <- result.try(args.string(request.args, "path"))
  Ok(
    ServedHere(fn() {
      case seam.stat(path) {
        Error(refusal) -> refused(refusal)

        // The entry's fields are the whole answer here rather than a
        // field inside it: `cap/search.stat` decodes the result map with
        // the same reader it uses for an element of `glob`'s array, so
        // the two shapes are one decoder and cannot drift apart.
        Ok(entry) -> answered(entry_fields(entry))
      }
    }),
  )
}

fn read_lines_plan(
  seam: Search,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use path <- result.try(args.string(request.args, "path"))
  use first <- result.try(args.int(request.args, "from"))
  use last <- result.try(args.int(request.args, "to"))
  Ok(
    ServedHere(fn() {
      case seam.read_lines(path, first, last) {
        Error(refusal) -> refused(refusal)
        Ok(search.Lines(text:, first:, last:, total:)) ->
          answered([
            #("text", msgpack.StringValue(text)),
            #("first", msgpack.IntValue(first)),
            #("last", msgpack.IntValue(last)),
            #("total", msgpack.IntValue(total)),
          ])
      }
    }),
  )
}

// The wire carries `include_hidden` as a msgpack boolean in both
// directions, which is what `cap/search` marshals. The type starts at
// this line and the engine never sees the boolean.
fn hidden_arg(value: MsgPackValue) -> Result(search.Hidden, CapDenial) {
  use include_hidden <- result.try(args.bool(value, "include_hidden"))
  case include_hidden {
    True -> Ok(search.IncludeHidden)
    False -> Ok(search.SkipHidden)
  }
}

// --- rendering ------------------------------------------------------------------

fn answered(fields: List(#(String, MsgPackValue))) -> CapOutcome {
  framing.CapOk(
    value: msgpack.MapValue(
      list.map(fields, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
    ),
  )
}

fn entry_value(entry: search.Entry) -> MsgPackValue {
  msgpack.MapValue(
    list.map(entry_fields(entry), fn(field) {
      #(msgpack.StringValue(field.0), field.1)
    }),
  )
}

// The entry fields, as one list so `glob`'s array element and `stat`'s
// top-level answer are built from one place.
//
// `target` is present only on a symlink, and its absence elsewhere is
// load-bearing: `cap/search.decode_kind` reads `target` only after it has
// seen `kind == "symlink"`, so a `target` beside a `kind` of `file` would
// be a field nothing reads and a claim nothing checked.
fn entry_fields(entry: search.Entry) -> List(#(String, MsgPackValue)) {
  let fields = [
    #("path", msgpack.StringValue(entry.path)),
    #("kind", msgpack.StringValue(kind_name(entry.kind))),
    #("size", msgpack.IntValue(entry.size)),
    #("mtime", msgpack.IntValue(entry.mtime_seconds)),
  ]
  case entry.kind {
    search.Symlink(target:) ->
      list.append(fields, [#("target", msgpack.StringValue(target))])

    search.File | search.Directory | search.Other -> fields
  }
}

fn kind_name(kind: search.Kind) -> String {
  case kind {
    search.File -> "file"

    search.Directory -> "directory"

    search.Symlink(target: _target) -> "symlink"

    search.Other -> "other"
  }
}

fn match_value(found: search.Match) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("path"), msgpack.StringValue(found.path)),
    #(msgpack.StringValue("line"), msgpack.IntValue(found.line)),
    #(msgpack.StringValue("column"), msgpack.IntValue(found.column)),
    #(msgpack.StringValue("text"), msgpack.StringValue(found.text)),
    #(msgpack.StringValue("before"), lines_value(found.before)),
    #(msgpack.StringValue("after"), lines_value(found.after)),
  ])
}

fn lines_value(lines: List(String)) -> MsgPackValue {
  msgpack.ArrayValue(list.map(lines, msgpack.StringValue))
}

fn truncated(completeness: search.Completeness) -> Bool {
  case completeness {
    search.Complete -> False

    search.Truncated -> True
  }
}

fn coverage_name(coverage: search.Coverage) -> String {
  case coverage {
    search.Exhaustive -> "exhaustive"

    search.MatchesCapped -> "matches_capped"

    search.ScanTruncated -> "scan_truncated"
  }
}

// --- refusals -------------------------------------------------------------------

fn refused(refusal: SearchRefusal) -> CapOutcome {
  let CapDenial(code:, message:) = denial(refusal)
  framing.CapErr(code:, message:)
}

/// The in-band code and message one search refusal travels under.
///
/// Public because it is half of a contract whose other half is
/// `cap/search.map_error`: each code is turned back into the variant of
/// the same name on the far side, and where there is no named variant the
/// sentence is what a program reads. The codes are
/// `codemode/workspace`'s own constants rather than a second set, because
/// a program that meets `permission_denied` through `fs.read` and through
/// `search.glob` has met one fact and must not have to learn two names
/// for it.
///
/// ## Examples
///
/// ```gleam
/// // search.denial(PathRefused(fs.EmptyPath)).code == "invalid_argument"
/// ```
///
pub fn denial(refusal: SearchRefusal) -> CapDenial {
  case refusal {
    // The path vocabulary is `codemode/workspace`'s and is reused rather
    // than restated: `resolve_real` is one boundary, so the sentence a
    // refusal from it carries must be one sentence.
    PathRefused(error:) -> workspace.fs_denial(workspace.PathRefused(error:))

    QueryRefused(error:) -> query_denial(error)
  }
}

fn query_denial(error: search.SearchError) -> CapDenial {
  case error {
    // Every bound check is the engine's, so every message about one is
    // the engine's sentence verbatim: it names the ceiling that was
    // passed, which is the repair.
    search.InvalidQuery(message:) ->
      CapDenial(code: workspace.invalid_argument_code, message:)

    search.NotADirectory(path:) ->
      CapDenial(
        code: workspace.not_a_directory_code,
        message: "path `"
          <> path
          <> "` is not a directory, so there is nothing to walk; read it "
          <> "with search.read_lines or fs.read",
      )

    search.NotAFile(path:) ->
      CapDenial(
        code: workspace.wrong_kind_code,
        message: "path `"
          <> path
          <> "` is a directory, and search.read_lines reads files; list it "
          <> "with search.glob or fs.list",
      )

    search.TooLarge(path:, size:) ->
      CapDenial(
        code: workspace.too_large_code,
        message: "the file `"
          <> path
          <> "` is "
          <> int.to_string(size)
          <> " bytes, larger than search.read_lines may open; read it in "
          <> "pieces with proc.run",
      )

    search.NotText(path:) ->
      CapDenial(
        code: workspace.wrong_kind_code,
        message: "the file `"
          <> path
          <> "` is not valid UTF-8 text, and search.read_lines answers "
          <> "text; read binary content with proc.run",
      )

    search.Missing(path:) ->
      CapDenial(
        code: workspace.not_found_code,
        message: "nothing exists at path `" <> path <> "`",
      )

    // The backend vocabulary is `codemode/workspace`'s, so a missing file
    // reaches `cap/search.NotFound` under the same code `fs.*` uses.
    search.Backend(error:) ->
      CapDenial(
        code: workspace.fs_error_code(error),
        message: workspace.fs_error_text(error),
      )
  }
}
