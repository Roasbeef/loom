//// Round trips for `cap/search`: the exact arguments each stub puts on
//// the wire, the decoding of each result shape, and the error mapping.
////
//// The channel is faked rather than driven, as in `cap_test`, so what is
//// under test is only this module's marshalling. The argument assertions
//// are deliberately written as whole-map comparisons: a key renamed on
//// one side of the wire is the failure this suite exists to catch, and a
//// per-field check would let an extra key through.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/search
import core/msgpack
import gleam/erlang/process
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- helpers ------------------------------------------------------------

// Install a fake channel whose `call` is the given function.
fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

fn text(value: String) -> msgpack.MsgPackValue {
  msgpack.StringValue(value)
}

fn number(value: Int) -> msgpack.MsgPackValue {
  msgpack.IntValue(value)
}

// A fake that answers every call with `reply`, handing back a reader for
// the arguments it was given. The fake runs on the calling process, so a
// subject is enough to carry the arguments back out of the closure.
fn answering(
  reply: msgpack.MsgPackValue,
) -> fn() -> Result(msgpack.MsgPackValue, Nil) {
  let sent = process.new_subject()
  install_fake(with: fn(_cap, args, _deadline) {
    process.send(sent, args)
    Ok(reply)
  })
  fn() { process.receive(sent, 100) }
}

// --- search.glob --------------------------------------------------------

/// A default `glob_query` puts every default on the wire, and the result
/// decodes into a complete listing.
pub fn glob_defaults_round_trip_test() {
  let take =
    answering(
      map([
        #(
          "entries",
          msgpack.ArrayValue([
            map([
              #("path", text("src/app.gleam")),
              #("kind", text("file")),
              #("size", number(120)),
              #("mtime", number(1_700_000_000)),
            ]),
            map([
              #("path", text("src/sub")),
              #("kind", text("directory")),
              #("size", number(64)),
              #("mtime", number(1_700_000_001)),
            ]),
          ]),
        ),
        #("truncated", msgpack.BoolValue(False)),
      ]),
    )

  let found = search.glob(search.glob_query(under: "src", matching: "*.gleam"))

  assert found
    == Ok(search.Listing(
      entries: [
        search.Entry(
          path: "src/app.gleam",
          kind: search.File,
          size: 120,
          mtime_seconds: 1_700_000_000,
        ),
        search.Entry(
          path: "src/sub",
          kind: search.Directory,
          size: 64,
          mtime_seconds: 1_700_000_001,
        ),
      ],
      completeness: search.Complete,
    ))

  assert take()
    == Ok(
      map([
        #("root", text("src")),
        #("pattern", text("*.gleam")),
        #("max_entries", number(search.default_max_entries)),
        #("include_hidden", msgpack.BoolValue(False)),
        #("prune", wire.string_array(search.default_prune)),
      ]),
    )
}

/// Overridden fields reach the wire, and `truncated` becomes `Truncated`.
pub fn glob_overrides_and_truncation_test() {
  let take =
    answering(
      map([
        #("entries", msgpack.ArrayValue([])),
        #("truncated", msgpack.BoolValue(True)),
      ]),
    )

  let query =
    search.GlobQuery(
      ..search.glob_query(under: ".", matching: "**/*.toml"),
      max_entries: 7,
      hidden: search.IncludeHidden,
      prune: [],
    )

  assert search.glob(query)
    == Ok(search.Listing(entries: [], completeness: search.Truncated))

  assert take()
    == Ok(
      map([
        #("root", text(".")),
        #("pattern", text("**/*.toml")),
        #("max_entries", number(7)),
        #("include_hidden", msgpack.BoolValue(True)),
        #("prune", wire.string_array([])),
      ]),
    )
}

/// A result field of the wrong shape is a transport-class failure, not a
/// silently missing entry.
pub fn glob_bad_result_is_unavailable_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #("entries", msgpack.ArrayValue([])),
        #("truncated", text("no")),
      ]),
    )
  })

  assert search.glob(search.glob_query(under: "src", matching: "*"))
    == Error(search.SearchUnavailable(
      "bad search.glob result: field truncated is not a boolean",
    ))
}

/// An unrecognised `kind` string is a decode failure rather than `Other`.
pub fn glob_unknown_kind_is_unavailable_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "entries",
          msgpack.ArrayValue([
            map([
              #("path", text("odd")),
              #("kind", text("fifo")),
              #("size", number(0)),
              #("mtime", number(1)),
            ]),
          ]),
        ),
        #("truncated", msgpack.BoolValue(False)),
      ]),
    )
  })

  assert search.glob(search.glob_query(under: "src", matching: "*"))
    == Error(search.SearchUnavailable(
      "bad search.glob result: unknown kind fifo",
    ))
}

/// A dead channel is `SearchUnavailable`, carrying the transport's reason.
pub fn glob_channel_down_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("channel gone"))
  })

  assert search.glob(search.glob_query(under: "src", matching: "*"))
    == Error(search.SearchUnavailable("channel gone"))
}

// --- search.grep --------------------------------------------------------

/// A default `grep_query` puts every default on the wire, and a match with
/// context decodes whole.
pub fn grep_defaults_round_trip_test() {
  let take =
    answering(
      map([
        #(
          "matches",
          msgpack.ArrayValue([
            map([
              #("path", text("src/app.gleam")),
              #("line", number(12)),
              #("column", number(3)),
              #("text", text("  panic as \"unreachable\"")),
              #("before", msgpack.ArrayValue([text("fn boom() {")])),
              #("after", msgpack.ArrayValue([text("}")])),
            ]),
          ]),
        ),
        #("files_scanned", number(9)),
        #("files_skipped", number(1)),
        #("coverage", text("exhaustive")),
      ]),
    )

  let found = search.grep(search.grep_query(under: "src", matching: "panic"))

  assert found
    == Ok(search.Found(
      matches: [
        search.Match(
          path: "src/app.gleam",
          line: 12,
          column: 3,
          text: "  panic as \"unreachable\"",
          before: ["fn boom() {"],
          after: ["}"],
        ),
      ],
      files_scanned: 9,
      files_skipped: 1,
      coverage: search.Exhaustive,
    ))

  assert take()
    == Ok(
      map([
        #("root", text("src")),
        #("pattern", text("panic")),
        #("globs", wire.string_array([])),
        #("context", number(search.default_context)),
        #("max_matches", number(search.default_max_matches)),
        #("include_hidden", msgpack.BoolValue(False)),
        #("prune", wire.string_array(search.default_prune)),
      ]),
    )
}

/// Overridden globs and context reach the wire, and each coverage string
/// decodes to its variant.
pub fn grep_overrides_and_coverage_test() {
  let take =
    answering(
      map([
        #("matches", msgpack.ArrayValue([])),
        #("files_scanned", number(0)),
        #("files_skipped", number(0)),
        #("coverage", text("matches_capped")),
      ]),
    )

  let query =
    search.GrepQuery(
      ..search.grep_query(under: ".", matching: "TODO"),
      globs: ["*.gleam", "*.md"],
      context: 2,
      max_matches: 5,
      hidden: search.IncludeHidden,
      prune: ["vendor"],
    )

  let found = search.grep(query)
  assert found
    == Ok(search.Found(
      matches: [],
      files_scanned: 0,
      files_skipped: 0,
      coverage: search.MatchesCapped,
    ))

  assert take()
    == Ok(
      map([
        #("root", text(".")),
        #("pattern", text("TODO")),
        #("globs", wire.string_array(["*.gleam", "*.md"])),
        #("context", number(2)),
        #("max_matches", number(5)),
        #("include_hidden", msgpack.BoolValue(True)),
        #("prune", wire.string_array(["vendor"])),
      ]),
    )
}

/// The third coverage string decodes too.
pub fn grep_scan_truncated_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #("matches", msgpack.ArrayValue([])),
        #("files_scanned", number(3)),
        #("files_skipped", number(0)),
        #("coverage", text("scan_truncated")),
      ]),
    )
  })

  let assert Ok(found) = search.grep(search.grep_query(".", "x"))
  assert found.coverage == search.ScanTruncated
}

/// An unrecognised coverage string is a decode failure.
pub fn grep_unknown_coverage_is_unavailable_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #("matches", msgpack.ArrayValue([])),
        #("files_scanned", number(0)),
        #("files_skipped", number(0)),
        #("coverage", text("partial")),
      ]),
    )
  })

  assert search.grep(search.grep_query(".", "x"))
    == Error(search.SearchUnavailable(
      "bad search.grep result: unknown coverage partial",
    ))
}

/// A context line that is not a string fails the decode of the match.
pub fn grep_bad_context_line_is_unavailable_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "matches",
          msgpack.ArrayValue([
            map([
              #("path", text("a")),
              #("line", number(1)),
              #("column", number(1)),
              #("text", text("hit")),
              #("before", msgpack.ArrayValue([number(3)])),
              #("after", msgpack.ArrayValue([])),
            ]),
          ]),
        ),
        #("files_scanned", number(1)),
        #("files_skipped", number(0)),
        #("coverage", text("exhaustive")),
      ]),
    )
  })

  assert search.grep(search.grep_query(".", "x"))
    == Error(search.SearchUnavailable(
      "bad search.grep result: context line is not a string",
    ))
}

// --- search.stat --------------------------------------------------------

/// `stat` sends the path and decodes a top-level entry map.
pub fn stat_round_trip_test() {
  let take =
    answering(
      map([
        #("path", text("gleam.toml")),
        #("kind", text("file")),
        #("size", number(42)),
        #("mtime", number(1_699_999_999)),
      ]),
    )

  assert search.stat("gleam.toml")
    == Ok(search.Entry(
      path: "gleam.toml",
      kind: search.File,
      size: 42,
      mtime_seconds: 1_699_999_999,
    ))

  assert take() == Ok(map([#("path", text("gleam.toml"))]))
}

/// A symlink carries its stored target verbatim.
pub fn stat_symlink_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #("path", text("link")),
        #("kind", text("symlink")),
        #("size", number(11)),
        #("mtime", number(5)),
        #("target", text("../elsewhere")),
      ]),
    )
  })

  assert search.stat("link")
    == Ok(search.Entry(
      path: "link",
      kind: search.Symlink(target: "../elsewhere"),
      size: 11,
      mtime_seconds: 5,
    ))
}

/// A symlink entry with no `target` is a decode failure, so a caller can
/// never read an absent target as an empty one.
pub fn stat_symlink_without_target_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #("path", text("link")),
        #("kind", text("symlink")),
        #("size", number(11)),
        #("mtime", number(5)),
      ]),
    )
  })

  assert search.stat("link")
    == Error(search.SearchUnavailable(
      "bad search.stat result: missing field target",
    ))
}

/// The `other` kind decodes.
pub fn stat_other_kind_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #("path", text("sock")),
        #("kind", text("other")),
        #("size", number(0)),
        #("mtime", number(1)),
      ]),
    )
  })

  let assert Ok(entry) = search.stat("sock")
  assert entry.kind == search.Other
}

// --- search.read_lines --------------------------------------------------

/// `read_lines` sends the 1-based span and decodes the clamped answer.
pub fn read_lines_round_trip_test() {
  let take =
    answering(
      map([
        #("text", text("one\ntwo")),
        #("first", number(1)),
        #("last", number(2)),
        #("total", number(2)),
      ]),
    )

  assert search.read_lines("src/app.gleam", from: 1, to: 40)
    == Ok(search.Lines(text: "one\ntwo", first: 1, last: 2, total: 2))

  assert take()
    == Ok(
      map([
        #("path", text("src/app.gleam")),
        #("from", number(1)),
        #("to", number(40)),
      ]),
    )
}

// --- error mapping ------------------------------------------------------

/// Every broker refusal code maps to the variant a program branches on,
/// and an unknown code survives verbatim.
pub fn error_mapping_test() {
  assert refused("not_found", "gone") == search.NotFound("p")
  assert refused("denied", "no") == search.PermissionDenied("p")
  assert refused("policy", "no") == search.PermissionDenied("p")
  assert refused("permission_denied", "no") == search.PermissionDenied("p")
  assert refused("wrong_kind", "a file") == search.WrongKind("p", "a file")
  assert refused("not_a_directory", "a file") == search.WrongKind("p", "a file")
  assert refused("is_a_directory", "a dir") == search.WrongKind("p", "a dir")
  assert refused("invalid_argument", "span too wide")
    == search.InvalidArgument("span too wide")
  assert refused("fs_failure", "disk on fire")
    == search.SearchFailed("fs_failure", "disk on fire")
}

// Drive one refusal through `stat`, whose path argument is the "p" the
// path-carrying variants above are asserted against.
fn refused(code: String, message: String) -> search.SearchError {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Denied(code, message))
  })
  let assert Error(error) = search.stat("p")
  error
}

/// A dead channel fails `read_lines` the same way it fails `glob`.
pub fn read_lines_channel_down_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("broker exited"))
  })

  assert search.read_lines("p", from: 1, to: 2)
    == Error(search.SearchUnavailable("broker exited"))
}
