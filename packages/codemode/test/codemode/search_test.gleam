//// The search router: what a `search.*` frame becomes, what the injected
//// closure is asked, what shape the answer comes back in, and what code a
//// refusal keeps.
////
//// These drive `search.routing` directly against scripted closures,
//// because everything worth proving *here* is carriage. Containment is
//// not carriage: it belongs to `tools/fs.resolve_real` inside the
//// production closures, and is tested against a real temporary workspace
//// on the `client` side, where a real path can actually escape. A
//// scripted closure could only prove that this module forwards a string.
////
//// The wire keys are asserted by name rather than by round-tripping
//// through `cap/search`, because the two packages share no dependency —
//// they are the two ends of one wire, not peers. Each side pins its own
//// half, and a key renamed here without being renamed there is a decode
//// failure a program reads as `SearchUnavailable`.

import broker/budget
import broker/exec
import broker/framing.{type CapOutcome}
import broker/policy
import codemode/identity.{type PhaseIdentity}
import codemode/satellite
import codemode/search
import codemode/workspace
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import tools/fs
import tools/search as engine
import tools/tool

const t = 1_700_000_000_000

// --- the scripted seam ---------------------------------------------------------

// What the scripted closures were asked, in the terms the arm decoded
// rather than the terms the wire carried: a test that recorded the raw
// map would pass while the decoding dropped a field on the floor.
type Seen {
  GlobAsked(root: String, query: engine.GlobQuery)
  GrepAsked(root: String, query: engine.GrepQuery)
  StatAsked(path: String)
  ReadLinesAsked(path: String, first: Int, last: Int)
}

fn recorder() -> Subject(Seen) {
  process.new_subject()
}

fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, within: 0) {
    Error(Nil) -> []
    Ok(one) -> [one, ..drain(seen)]
  }
}

// One entry of each kind the wire can carry, so a rendering that lost the
// symlink target or mislabelled a kind is visible in one assertion.
const symlink_entry_path = "notes/link"

const symlink_target = "../outside"

fn file_entry() -> engine.Entry {
  engine.Entry(
    path: "src/app.gleam",
    kind: engine.File,
    size: 812,
    mtime_seconds: 1_757_000_000,
  )
}

fn symlink_entry() -> engine.Entry {
  engine.Entry(
    path: symlink_entry_path,
    kind: engine.Symlink(target: symlink_target),
    size: 11,
    mtime_seconds: 1_757_000_001,
  )
}

// A seam whose every closure succeeds, recording what it was asked. The
// answers are fixed values: what this suite is about is the wire shape
// they come back in.
fn answering(seen: Subject(Seen)) -> search.Search {
  search.Search(
    glob: fn(root, query) {
      process.send(seen, GlobAsked(root:, query:))
      Ok(engine.Listing(
        entries: [file_entry(), symlink_entry()],
        completeness: engine.Truncated,
      ))
    },
    grep: fn(root, query) {
      process.send(seen, GrepAsked(root:, query:))
      Ok(engine.Found(
        matches: [
          engine.Match(
            path: "src/app.gleam",
            line: 12,
            column: 5,
            text: "  pub fn main() {",
            before: ["", "// the entry point"],
            after: ["    Nil"],
          ),
        ],
        files_scanned: 7,
        files_skipped: 2,
        coverage: engine.MatchesCapped,
      ))
    },
    stat: fn(path) {
      process.send(seen, StatAsked(path:))
      Ok(symlink_entry())
    },
    read_lines: fn(path, first, last) {
      process.send(seen, ReadLinesAsked(path:, first:, last:))
      Ok(engine.Lines(text: "one\ntwo", first: 3, last: 4, total: 90))
    },
  )
}

// A seam whose every closure refuses the same way, so one refusal can be
// driven through whichever arm reaches it.
fn refusing(refusal: search.SearchRefusal) -> search.Search {
  search.Search(
    glob: fn(_root, _query) { Error(refusal) },
    grep: fn(_root, _query) { Error(refusal) },
    stat: fn(_path) { Error(refusal) },
    read_lines: fn(_path, _first, _last) { Error(refusal) },
  )
}

// The router under test, over an inner arm that records nothing and
// answers a distinctive refusal, so "handed down untouched" is provable
// rather than indistinguishable from "refused here".
const passed_through = "reached_the_inner_router"

fn routed(seam: search.Search) -> satellite.CapRouter {
  search.routing(seam, over: fn(request: satellite.CapRequest) {
    Error(satellite.CapDenial(code: passed_through, message: request.cap))
  })
}

// Routes one call and runs the plan it produced, which is what the host's
// worker process does.
fn serviced(
  seam: search.Search,
  cap: String,
  args: MsgPackValue,
) -> CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) = routed(seam)(request(cap, args))
    as { "the search router must service " <> cap }
  serve()
}

fn refused(
  seam: search.Search,
  cap: String,
  args: MsgPackValue,
) -> satellite.CapDenial {
  let assert Error(denial) = routed(seam)(request(cap, args))
    as { "the search router must refuse " <> cap }
  denial
}

fn request(cap: String, args: MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: phase(),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal: 0,
  )
}

fn phase() -> PhaseIdentity {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, generator) = ids.mint_op(generator)
  let #(entry, _generator) = ids.mint_entry(generator)
  identity.run_phase(identity.for_execution(
    op_id: op,
    step_id: ids.entry_id_to_string(entry),
    budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
  ))
}

fn map(fields: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(fields, fn(field) { #(msgpack.StringValue(field.0), field.1) }),
  )
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

fn int(value: Int) -> MsgPackValue {
  msgpack.IntValue(value)
}

fn flag(value: Bool) -> MsgPackValue {
  msgpack.BoolValue(value)
}

fn strings(values: List(String)) -> MsgPackValue {
  msgpack.ArrayValue(list.map(values, msgpack.StringValue))
}

fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _other -> Error(Nil)
  }
}

fn ok_value(outcome: CapOutcome) -> MsgPackValue {
  let assert framing.CapOk(value:) = outcome
    as "the call must have been serviced"
  value
}

// --- what the arms carry in ------------------------------------------------------

fn glob_args() -> MsgPackValue {
  map([
    #("root", text("src")),
    #("pattern", text("**/*.gleam")),
    #("max_entries", int(250)),
    #("include_hidden", flag(True)),
    #("prune", strings(["_build", "deps"])),
  ])
}

pub fn a_glob_routes_with_every_argument_decoded_test() {
  let seen = recorder()
  let _answer = serviced(answering(seen), "search.glob", glob_args())
  assert drain(seen)
    == [
      GlobAsked(
        root: "src",
        query: engine.GlobQuery(
          pattern: "**/*.gleam",
          max_entries: 250,
          // The wire's boolean becomes the seam's two-variant type here
          // and nowhere else; the engine never sees a boolean.
          hidden: engine.IncludeHidden,
          prune: ["_build", "deps"],
        ),
      ),
    ]
}

pub fn a_glob_without_hidden_asks_for_the_narrower_walk_test() {
  let seen = recorder()
  let args =
    map([
      #("root", text(".")),
      #("pattern", text("*.toml")),
      #("max_entries", int(10)),
      #("include_hidden", flag(False)),
      #("prune", strings([])),
    ])
  let _answer = serviced(answering(seen), "search.glob", args)
  let assert [GlobAsked(root: _root, query:)] = drain(seen)
    as "the glob arm must reach its closure"
  assert query.hidden == engine.SkipHidden
  // An empty `prune` is the caller saying "descend everything", not a
  // missing argument, so it reaches the engine as the empty list.
  assert query.prune == []
}

pub fn a_grep_routes_with_every_argument_decoded_test() {
  let seen = recorder()
  let args =
    map([
      #("root", text(".")),
      #("pattern", text("pub fn")),
      #("globs", strings(["*.gleam", "*.erl"])),
      #("context", int(2)),
      #("max_matches", int(40)),
      #("include_hidden", flag(False)),
      #("prune", strings([".git"])),
    ])
  let _answer = serviced(answering(seen), "search.grep", args)
  assert drain(seen)
    == [
      GrepAsked(
        root: ".",
        query: engine.GrepQuery(
          pattern: "pub fn",
          globs: ["*.gleam", "*.erl"],
          context: 2,
          max_matches: 40,
          hidden: engine.SkipHidden,
          prune: [".git"],
        ),
      ),
    ]
}

pub fn a_read_lines_routes_with_its_window_test() {
  let seen = recorder()
  let args =
    map([#("path", text("src/app.gleam")), #("from", int(3)), #("to", int(4))])
  let _answer = serviced(answering(seen), "search.read_lines", args)
  assert drain(seen)
    == [ReadLinesAsked(path: "src/app.gleam", first: 3, last: 4)]
}

pub fn a_stat_routes_with_its_path_test() {
  let seen = recorder()
  let _answer =
    serviced(
      answering(seen),
      "search.stat",
      map([#("path", text("notes/link"))]),
    )
  assert drain(seen) == [StatAsked(path: "notes/link")]
}

// --- what the arms carry out -----------------------------------------------------

pub fn a_glob_answers_entries_and_truncated_test() {
  // `cap/search.decode_listing` reads exactly `entries` and `truncated`
  // and refuses anything else as `bad search.glob result`, so the two
  // field names are the contract.
  let seen = recorder()
  let value = ok_value(serviced(answering(seen), "search.glob", glob_args()))
  assert field(value, "truncated") == Ok(msgpack.BoolValue(True))
  let assert Ok(msgpack.ArrayValue(items: [first, second])) =
    field(value, "entries")
    as "a glob must answer an array of entries"
  assert field(first, "path") == Ok(text("src/app.gleam"))
  assert field(first, "kind") == Ok(text("file"))
  assert field(first, "size") == Ok(int(812))
  assert field(first, "mtime") == Ok(int(1_757_000_000))
  // A file carries no `target`. `cap/search` reads that field only after
  // it has seen a `kind` of `symlink`, so one beside a file would be a
  // claim nothing checks and nothing reads.
  assert field(first, "target") == Error(Nil)
  assert field(second, "kind") == Ok(text("symlink"))
  assert field(second, "target") == Ok(text(symlink_target))
}

pub fn a_complete_glob_answers_truncated_false_test() {
  let seen = recorder()
  let seam =
    search.Search(..answering(seen), glob: fn(_root, _query) {
      Ok(engine.Listing(entries: [], completeness: engine.Complete))
    })
  let value = ok_value(serviced(seam, "search.glob", glob_args()))
  assert field(value, "truncated") == Ok(msgpack.BoolValue(False))
  assert field(value, "entries") == Ok(msgpack.ArrayValue([]))
}

pub fn a_stat_answers_the_entry_fields_at_the_top_level_test() {
  // Not nested under an `entry` key: `cap/search.stat` decodes the result
  // map with the very reader it uses for one element of a glob's array,
  // so the two shapes are one decoder and cannot drift apart.
  let seen = recorder()
  let value =
    ok_value(serviced(
      answering(seen),
      "search.stat",
      map([#("path", text("notes/link"))]),
    ))
  assert field(value, "path") == Ok(text(symlink_entry_path))
  assert field(value, "kind") == Ok(text("symlink"))
  assert field(value, "target") == Ok(text(symlink_target))
  assert field(value, "size") == Ok(int(11))
  assert field(value, "mtime") == Ok(int(1_757_000_001))
}

pub fn a_grep_answers_matches_counts_and_coverage_test() {
  let seen = recorder()
  let args =
    map([
      #("root", text(".")),
      #("pattern", text("pub fn")),
      #("globs", strings([])),
      #("context", int(1)),
      #("max_matches", int(40)),
      #("include_hidden", flag(False)),
      #("prune", strings([])),
    ])
  let value = ok_value(serviced(answering(seen), "search.grep", args))
  assert field(value, "files_scanned") == Ok(int(7))
  assert field(value, "files_skipped") == Ok(int(2))
  assert field(value, "coverage") == Ok(text("matches_capped"))
  let assert Ok(msgpack.ArrayValue(items: [found])) = field(value, "matches")
    as "a grep must answer an array of matches"
  assert field(found, "path") == Ok(text("src/app.gleam"))
  assert field(found, "line") == Ok(int(12))
  assert field(found, "column") == Ok(int(5))
  assert field(found, "text") == Ok(text("  pub fn main() {"))
  assert field(found, "before") == Ok(strings(["", "// the entry point"]))
  assert field(found, "after") == Ok(strings(["    Nil"]))
}

pub fn every_coverage_has_its_own_name_test() {
  // The three names are a closed set on the far side: `cap/search`
  // refuses an unknown one rather than rounding it down, so a name
  // misspelled here is a call a program cannot read at all.
  let rows = [
    #(engine.Exhaustive, "exhaustive"),
    #(engine.MatchesCapped, "matches_capped"),
    #(engine.ScanTruncated, "scan_truncated"),
  ]
  list.each(rows, fn(row) {
    let seen = recorder()
    let seam =
      search.Search(..answering(seen), grep: fn(_root, _query) {
        Ok(engine.Found(
          matches: [],
          files_scanned: 0,
          files_skipped: 0,
          coverage: row.0,
        ))
      })
    let args =
      map([
        #("root", text(".")),
        #("pattern", text("x")),
        #("globs", strings([])),
        #("context", int(0)),
        #("max_matches", int(1)),
        #("include_hidden", flag(False)),
        #("prune", strings([])),
      ])
    assert field(ok_value(serviced(seam, "search.grep", args)), "coverage")
      == Ok(text(row.1))
  })
}

pub fn every_kind_has_its_own_name_test() {
  let rows = [
    #(engine.File, "file"),
    #(engine.Directory, "directory"),
    #(engine.Symlink(target: "elsewhere"), "symlink"),
    #(engine.Other, "other"),
  ]
  list.each(rows, fn(row) {
    let seen = recorder()
    let seam =
      search.Search(..answering(seen), stat: fn(_path) {
        Ok(engine.Entry(path: "x", kind: row.0, size: 0, mtime_seconds: 0))
      })
    let value =
      ok_value(serviced(seam, "search.stat", map([#("path", text("x"))])))
    assert field(value, "kind") == Ok(text(row.1))
  })
}

pub fn a_read_lines_answers_the_window_and_the_total_test() {
  let seen = recorder()
  let args =
    map([#("path", text("src/app.gleam")), #("from", int(3)), #("to", int(4))])
  let value = ok_value(serviced(answering(seen), "search.read_lines", args))
  assert field(value, "text") == Ok(text("one\ntwo"))
  assert field(value, "first") == Ok(int(3))
  assert field(value, "last") == Ok(int(4))
  assert field(value, "total") == Ok(int(90))
}

// --- what the arms refuse --------------------------------------------------------

pub fn a_missing_argument_is_invalid_in_band_test() {
  // Refused at *plan* time, before any closure runs: a call that cannot
  // be decoded has nothing to ask anybody.
  let seen = recorder()
  let seam = answering(seen)
  list.each(
    [
      #("search.glob", map([#("root", text("src"))])),
      #("search.grep", map([#("root", text("src"))])),
      #("search.stat", map([])),
      #("search.read_lines", map([#("path", text("x")), #("from", int(1))])),
    ],
    fn(row) {
      let denial = refused(seam, row.0, row.1)
      assert denial.code == workspace.invalid_argument_code
      assert string.contains(denial.message, "is missing")
    },
  )
  assert drain(seen) == []
}

pub fn a_wrong_typed_argument_is_invalid_in_band_test() {
  let seen = recorder()
  let seam = answering(seen)
  let rows = [
    #(
      map([
        #("root", text("src")),
        #("pattern", text("*")),
        #("max_entries", text("lots")),
        #("include_hidden", flag(False)),
        #("prune", strings([])),
      ]),
      "must be a whole number",
    ),
    #(
      map([
        #("root", text("src")),
        #("pattern", text("*")),
        #("max_entries", int(10)),
        #("include_hidden", int(1)),
        #("prune", strings([])),
      ]),
      "must be true or false",
    ),
    #(
      map([
        #("root", text("src")),
        #("pattern", text("*")),
        #("max_entries", int(10)),
        #("include_hidden", flag(False)),
        #("prune", text("_build")),
      ]),
      "must be an array of text",
    ),
    #(
      map([
        #("root", text("src")),
        #("pattern", text("*")),
        #("max_entries", int(10)),
        #("include_hidden", flag(False)),
        #("prune", msgpack.ArrayValue([int(7)])),
      ]),
      "must be text",
    ),
  ]
  list.each(rows, fn(row) {
    let denial = refused(seam, "search.glob", row.0)
    assert denial.code == workspace.invalid_argument_code
    assert string.contains(denial.message, row.1)
  })
  assert drain(seen) == []
}

pub fn arguments_that_are_not_a_map_are_invalid_test() {
  let seen = recorder()
  let denial = refused(answering(seen), "search.stat", msgpack.IntValue(1))
  assert denial.code == workspace.invalid_argument_code
  assert string.contains(denial.message, "must be a map")
  assert drain(seen) == []
}

pub fn a_path_outside_the_workspace_keeps_the_tools_own_vocabulary_test() {
  // The router does not decide containment and does not word it: the
  // decision is `tools/fs.resolve_real`'s, the sentence is the harness's
  // own — the very one `codemode/workspace` renders for `fs.read` — and
  // the code is the one `cap/search.map_error` turns back into
  // `PermissionDenied` so a program can branch on it.
  let assert framing.CapErr(code:, message:) =
    serviced(
      refusing(search.PathRefused(fs.EscapesWorkspace(path: "../etc"))),
      "search.glob",
      map([
        #("root", text("../etc")),
        #("pattern", text("*")),
        #("max_entries", int(10)),
        #("include_hidden", flag(False)),
        #("prune", strings([])),
      ]),
    )
    as "an escaping root is refused in band, not at plan time"
  assert code == workspace.permission_denied_code
  assert string.contains(message, "../etc")
  assert string.contains(message, "outside the workspace root")
}

pub fn each_refusal_keeps_its_own_code_test() {
  // The whole table at once, because what matters is the
  // *correspondence*: a code `cap/search` does not decode arrives as its
  // catch-all, so a row wired to the wrong one is a named variant a
  // program silently stops seeing.
  let rows = [
    #(search.PathRefused(fs.EmptyPath), workspace.invalid_argument_code),
    #(
      search.PathRefused(fs.EscapesWorkspace(path: "x")),
      workspace.permission_denied_code,
    ),
    #(
      search.PathRefused(fs.Unresolvable(path: "x", reason: "loop")),
      workspace.unresolvable_code,
    ),
    #(
      search.QueryRefused(engine.InvalidQuery(message: "max_entries")),
      workspace.invalid_argument_code,
    ),
    #(
      search.QueryRefused(engine.NotADirectory(path: "x")),
      workspace.not_a_directory_code,
    ),
    #(
      search.QueryRefused(engine.NotAFile(path: "x")),
      workspace.wrong_kind_code,
    ),
    #(
      search.QueryRefused(engine.TooLarge(path: "x", size: 99)),
      workspace.too_large_code,
    ),
    #(search.QueryRefused(engine.NotText(path: "x")), workspace.wrong_kind_code),
    #(search.QueryRefused(engine.Missing(path: "x")), workspace.not_found_code),
    #(
      search.QueryRefused(engine.Backend(tool.FsNotFound(path: "x"))),
      workspace.not_found_code,
    ),
    #(
      search.QueryRefused(engine.Backend(tool.FsPermissionDenied(path: "x"))),
      workspace.permission_denied_code,
    ),
    #(
      search.QueryRefused(
        engine.Backend(tool.FsFailure(path: "x", reason: "eio")),
      ),
      workspace.fs_failure_code,
    ),
  ]
  list.each(rows, fn(row) {
    assert search.denial(row.0).code == row.1
  })
}

pub fn a_refusal_reaches_every_arm_test() {
  // One refusal driven through all four arms, because each arm names its
  // own closure and one wired to a neighbour's would answer the
  // neighbour's fixed value instead of refusing.
  let seam = refusing(search.QueryRefused(engine.Missing(path: "gone")))
  let rows = [
    #("search.glob", well_formed("search.glob")),
    #("search.grep", well_formed("search.grep")),
    #("search.stat", well_formed("search.stat")),
    #("search.read_lines", well_formed("search.read_lines")),
  ]
  list.each(rows, fn(row) {
    let assert framing.CapErr(code:, message:) = serviced(seam, row.0, row.1)
      as { row.0 <> " must carry the refusal in band" }
    assert code == workspace.not_found_code
    assert string.contains(message, "gone")
  })
}

// --- the router's own shape -------------------------------------------------------

pub fn every_serviced_cap_routes_and_none_builds_a_clearance_test() {
  // Two properties in one walk. The list `serviced_caps` publishes — and
  // therefore the list the model reads in the tool description — is
  // exactly what the arms answer, which is what keeps the constants and
  // the string-literal patterns from drifting. And every plan is
  // `ServedHere`: a router that builds no `CallSpec` cannot state broker
  // coordinates at all.
  let seen = recorder()
  let served =
    list.map(search.serviced_caps, fn(cap) {
      case routed(answering(seen))(request(cap, well_formed(cap))) {
        Ok(satellite.ServedHere(..)) -> True
        Ok(satellite.ClearedCall(..)) -> False
        Error(_denial) -> False
      }
    })
  assert served == list.repeat(True, list.length(search.serviced_caps))
  assert list.length(search.serviced_caps) == 4
}

pub fn an_unrouted_cap_is_handed_to_the_inner_router_test() {
  // This arm sits above the workspace bridge and the shipped table, so
  // everything it does not answer must pass down untouched rather than
  // being refused here.
  let seen = recorder()
  list.each(["proc.run", "fs.read", "mcp.github", "report.emit"], fn(cap) {
    let denial = refused(answering(seen), cap, map([]))
    assert denial.code == passed_through
    assert denial.message == cap
  })
  assert drain(seen) == []
}

fn well_formed(cap: String) -> MsgPackValue {
  case cap {
    "search.glob" -> glob_args()
    "search.grep" ->
      map([
        #("root", text("src")),
        #("pattern", text("pub fn")),
        #("globs", strings([])),
        #("context", int(0)),
        #("max_matches", int(10)),
        #("include_hidden", flag(False)),
        #("prune", strings([])),
      ])
    "search.stat" -> map([#("path", text("notes/link"))])
    "search.read_lines" ->
      map([#("path", text("src/app.gleam")), #("from", int(1)), #("to", int(2))])
    _other -> map([])
  }
}
