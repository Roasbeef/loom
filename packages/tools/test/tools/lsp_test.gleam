//// The `lsp_*` tools over a fake door: what each answer looks like, how
//// every door error reads, the arguments refused before the door is
//// asked, and the rename landing — all pre-checks before any write, a
//// half-landed rename reported exactly, and diagnostics that never read
//// as clean unless they settled clean.
////
//// No language server and no process: the door is a record of closures
//// built here, and the rename tests land on a real temporary directory
//// under the package build directory, as `fs_test` does.

import core/json
import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/query
import simplifile
import support/fake_broker
import tools/fs
import tools/hashline
import tools/lsp
import tools/tool

// --- fixtures ------------------------------------------------------------

// A door where every closure answers `Unavailable`, so a test overrides
// exactly the closure it is about and any other call shows up as a
// failure it did not expect.
fn door() -> query.Door {
  let unused = query.Unavailable("not part of this test")
  query.Door(
    definition: fn(_) { Error(unused) },
    references: fn(_) { Error(unused) },
    hover: fn(_) { Error(unused) },
    outline: fn(_) { Error(unused) },
    calls: fn(_, _) { Error(unused) },
    diagnostics: fn(_) { Error(unused) },
    prepare_rename: fn(_, _) { Error(unused) },
    after_write: fn(_) { None },
  )
}

fn warm(value: a) -> Result(query.Served(a), query.QueryError) {
  Ok(query.Served(value:, warmth: query.Warm))
}

fn site(path: String, line: Int, text: String) -> query.Site {
  query.Site(path:, line:, column: 1, text:)
}

// The rendered form of a site, built independently of the module: a grep
// hit with the anchor fs_read prints spliced in.
fn hit(path: String, line: Int, text: String) -> String {
  path
  <> ":"
  <> int.to_string(line)
  <> ":"
  <> hashline.anchor(text)
  <> "|"
  <> text
}

fn named(door: query.Door, name: String) -> tool.Tool {
  let assert Ok(found) =
    lsp.tools(door) |> list.find(fn(candidate) { candidate.name == name })
    as "the tool list names every lsp tool"
  found
}

fn args(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object(fields)
}

fn symbol(name: String) -> #(String, json.JsonValue) {
  #("symbol", json.String(name))
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  let assert [message.ToolResultText(text:, text_signature: _)] =
    outcome.content
    as "expected a single text block"
  text
}

// A real temporary workspace under the package build directory, and a
// ctx rooted in it.
fn workspace(name: String) -> #(tool.Ctx, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runs in a directory"
  let root = here <> "/build/lsp_test/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the scratch root can be made"
  let ctx =
    fake_broker.ctx(
      workspace: root,
      filesystem: fs.real_filesystem(),
      now: 1000,
      script: [],
      recorded: process.new_subject(),
    )
  #(ctx, root)
}

fn put(root: String, path: String, content: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(root <> "/" <> path, content)
    as "the fixture file can be written"
  Nil
}

fn disk(root: String, path: String) -> String {
  let assert Ok(content) = simplifile.read(root <> "/" <> path)
    as "the file can be read back"
  content
}

// The target maker a code-mode caller would pass: `fs.write_target` over
// the workspace, with nothing protected.
fn targets(root: String) -> fn(String) -> Result(fs.WriteTarget, String) {
  fn(path) {
    fs.write_target(
      filesystem: fs.real_filesystem(),
      workspace: root,
      roots: [],
      protected: [],
      path:,
    )
    |> result.replace_error("unwritable: " <> path)
  }
}

fn rename_edit(path: String, base: String) -> query.FileEdit {
  query.FileEdit(
    path:,
    base:,
    edited: string.replace(base, "greet", "hello"),
    edits: list.length(string.split(base, "greet")) - 1,
  )
}

// The numbers 1 to `last`, in order.
fn one_to(last: Int) -> List(Int) {
  int.range(from: last, to: 0, with: [], run: list.prepend)
}

// Every path `after_write` was told of, in order.
fn told(subject: process.Subject(String)) -> List(String) {
  case process.receive(subject, 0) {
    Ok(path) -> [path, ..told(subject)]
    Error(Nil) -> []
  }
}

fn error_diagnostic(path: String, line: Int, text: String) -> query.Diagnostic {
  query.Diagnostic(
    site: site(path, line, text),
    severity: query.SeverityError,
    message: "Unknown variable `greet`",
  )
}

// --- the definitions -----------------------------------------------------

pub fn seven_tools_with_declared_replay_and_concurrency_test() {
  let tools = lsp.tools(door())
  assert list.map(tools, fn(entry) { entry.name })
    == [
      "lsp_definition", "lsp_references", "lsp_hover", "lsp_symbols",
      "lsp_calls", "lsp_diagnostics", "lsp_rename",
    ]

  // Rename writes and must not replay; every other tool is a read.
  list.each(tools, fn(entry) {
    case entry.name {
      "lsp_rename" -> {
        assert entry.replay == tool.Never
        assert entry.execution_mode == tool.Exclusive
      }
      _ -> {
        assert entry.replay == tool.Safe
        assert entry.execution_mode == tool.Concurrent
      }
    }
    assert option.is_some(entry.prompt_snippet)
  })
}

// --- happy paths ---------------------------------------------------------

pub fn references_count_first_then_group_by_file_and_container_test() {
  let references = [
    query.Reference(site("src/probe.gleam", 3, "pub fn greet() {"), None),
    query.Reference(
      site("src/other.gleam", 5, "  probe.greet()"),
      Some("other.twice"),
    ),
    query.Reference(
      site("src/other.gleam", 6, "  probe.greet()"),
      Some("other.twice"),
    ),
    query.Reference(site("src/other.gleam", 1, "import probe.{greet}"), None),
  ]
  let fake = query.Door(..door(), references: fn(_) { warm(references) })
  let outcome =
    named(fake, "lsp_references").run(
      workspace("references").0,
      args([symbol("greet")]),
    )

  assert !outcome.is_error
  assert text_of(outcome)
    == string.join(
      [
        "4 references to `greet` in 2 files",
        "src/probe.gleam (1 reference):",
        "  at top level:",
        "    " <> hit("src/probe.gleam", 3, "pub fn greet() {"),
        "src/other.gleam (3 references):",
        "  in other.twice:",
        "    " <> hit("src/other.gleam", 5, "  probe.greet()"),
        "    " <> hit("src/other.gleam", 6, "  probe.greet()"),
        "  at top level:",
        "    " <> hit("src/other.gleam", 1, "import probe.{greet}"),
      ],
      "\n",
    )
}

pub fn references_past_the_bound_say_how_many_were_left_out_test() {
  let references =
    one_to(51)
    |> list.map(fn(line) {
      query.Reference(site("src/a.gleam", line, "greet()"), Some("a.main"))
    })
  let text = lsp.render_references("greet", references)
  let lines = string.split(text, "\n")
  let hits = list.count(lines, fn(line) { string.starts_with(line, "    ") })

  assert list.first(lines)
    == Ok("51 references to `greet` in 1 file; showing 50")
  assert hits == 50
  assert list.last(lines)
    == Ok(
      "… 1 more; narrow with path/line or use code mode (cap/lsp) for the "
      <> "full list",
    )
  assert string.contains(text, "src/a.gleam (51 references):")
}

pub fn exactly_the_bound_lists_everything_test() {
  let references =
    one_to(50)
    |> list.map(fn(line) {
      query.Reference(site("src/a.gleam", line, "greet()"), None)
    })
  let text = lsp.render_references("greet", references)
  assert string.starts_with(text, "50 references to `greet` in 1 file\n")
  assert !string.contains(text, "more;")
}

pub fn definition_says_when_a_server_was_started_for_it_test() {
  let fake =
    query.Door(..door(), definition: fn(_) {
      Ok(query.Served(
        value: [site("src/probe.gleam", 3, "pub fn greet() {")],
        warmth: query.Started(server: "gleam"),
      ))
    })
  let outcome =
    named(fake, "lsp_definition").run(
      workspace("definition").0,
      args([symbol("probe.greet")]),
    )
  assert text_of(outcome)
    == "(started the gleam language server for this query; later queries "
    <> "are fast)\n1 definition of `probe.greet`:\n"
    <> hit("src/probe.gleam", 3, "pub fn greet() {")
}

pub fn hover_shows_the_site_then_the_type_test() {
  let fake =
    query.Door(..door(), hover: fn(_) {
      warm(query.Hover(
        site: site("src/probe.gleam", 3, "pub fn greet() {"),
        contents: "fn() -> String\n\nSays hello.\n",
      ))
    })
  let outcome =
    named(fake, "lsp_hover").run(workspace("hover").0, args([symbol("greet")]))
  assert text_of(outcome)
    == hit("src/probe.gleam", 3, "pub fn greet() {")
    <> "\n\nfn() -> String\n\nSays hello."
}

// The server decides how long a hover is, so the tool shows at most
// `max_hover_bytes` of it and says how much it left out.
pub fn hover_is_clipped_at_its_bound_test() {
  let line = "documentation line\n"
  let long = string.repeat(line, 1000)
  let fake =
    query.Door(..door(), hover: fn(_) {
      warm(query.Hover(
        site: site("src/probe.gleam", 3, "pub fn greet() {"),
        contents: long,
      ))
    })
  let shown =
    text_of(named(fake, "lsp_hover").run(
      workspace("hover_clip").0,
      args([symbol("greet")]),
    ))
  let heading = hit("src/probe.gleam", 3, "pub fn greet() {") <> "\n\n"
  let kept_lines = lsp.max_hover_bytes / string.byte_size(line)
  let kept = string.repeat(line, kept_lines) |> string.drop_end(1)
  let cut = string.byte_size(string.trim(long)) - string.byte_size(kept)
  assert shown
    == heading <> kept <> "\n[" <> int.to_string(cut) <> " more bytes cut]"
}

pub fn clip_cuts_on_a_line_then_a_character_boundary_test() {
  assert lsp.clip("short", 10) == "short"
  assert lsp.clip("one\ntwo\nthree", 9) == "one\ntwo\n[6 more bytes cut]"

  // One line longer than the bound is cut inside it, but never inside a
  // character: `é` is two bytes and does not fit in the third.
  assert lsp.clip("abé", 3) == "ab\n[2 more bytes cut]"
}

pub fn symbols_render_a_nested_outline_with_anchored_lines_test() {
  let method =
    query.SymbolEntry(
      name: "handle",
      kind: "method",
      detail: None,
      site: site("src/s.go", 4, "func (s Server) handle() {"),
      children: [],
    )
  let server =
    query.SymbolEntry(
      name: "Server",
      kind: "struct",
      detail: Some("struct{...}"),
      site: site("src/s.go", 2, "type Server struct {}"),
      children: [method],
    )
  let fake = query.Door(..door(), outline: fn(_) { warm([server]) })
  let outcome =
    named(fake, "lsp_symbols").run(
      workspace("symbols").0,
      args([#("path", json.String("src/s.go"))]),
    )
  assert text_of(outcome)
    == string.join(
      [
        "2 symbols in src/s.go:",
        "struct Server — struct{...}",
        "  2:"
          <> hashline.anchor("type Server struct {}")
          <> "|type Server struct {}",
        "  method handle",
        "    4:"
          <> hashline.anchor("func (s Server) handle() {")
          <> "|func (s Server) handle() {",
      ],
      "\n",
    )
}

pub fn calls_render_each_caller_with_its_call_sites_test() {
  let caller =
    query.Call(
      name: "other.twice",
      site: site("src/other.gleam", 4, "pub fn twice() {"),
      at: [site("src/other.gleam", 5, "  greet()")],
    )
  let fake =
    query.Door(..door(), calls: fn(_, direction) {
      case direction {
        query.Incoming -> warm([caller])
        query.Outgoing -> warm([])
      }
    })
  let calls = named(fake, "lsp_calls")
  let ctx = workspace("calls").0
  let incoming =
    calls.run(
      ctx,
      args([symbol("greet"), #("direction", json.String("incoming"))]),
    )
  let outgoing =
    calls.run(
      ctx,
      args([symbol("greet"), #("direction", json.String("outgoing"))]),
    )

  assert text_of(incoming)
    == "1 caller of `greet`:\nother.twice\n  defined at "
    <> hit("src/other.gleam", 4, "pub fn twice() {")
    <> "\n  called at "
    <> hit("src/other.gleam", 5, "  greet()")
  assert text_of(outgoing)
    == "`greet` calls nothing the language server can resolve"
}

pub fn diagnostics_tool_renders_a_settled_block_test() {
  let fake =
    query.Door(..door(), diagnostics: fn(_) {
      warm(query.Settled([error_diagnostic("src/a.gleam", 2, "  greet()")]))
    })
  let outcome =
    named(fake, "lsp_diagnostics").run(workspace("diagnostics").0, args([]))
  assert text_of(outcome)
    == "diagnostics (settled): 1 (1 error)\nerror at "
    <> hit("src/a.gleam", 2, "  greet()")
    <> "\n  Unknown variable `greet`"
}

// --- errors --------------------------------------------------------------

fn failing(error: query.QueryError) -> String {
  let fake = query.Door(..door(), definition: fn(_) { Error(error) })
  let outcome =
    named(fake, "lsp_definition").run(
      workspace("errors").0,
      args([symbol("greet")]),
    )
  assert outcome.is_error
  text_of(outcome)
}

pub fn ambiguous_lists_the_candidates_as_anchored_sites_test() {
  let text =
    failing(
      query.Ambiguous([
        site("src/a.gleam", 1, "pub fn greet() {"),
        site("src/b.gleam", 7, "pub fn greet(name) {"),
      ]),
    )
  assert text
    == "the name is ambiguous: 2 distinct definitions match:\n"
    <> hit("src/a.gleam", 1, "pub fn greet() {")
    <> "\n"
    <> hit("src/b.gleam", 7, "pub fn greet(name) {")
    <> "\nAsk again with `path` (and `line`) naming one of them, or qualify "
    <> "the name (`module.name`)."
}

pub fn every_query_error_says_what_to_do_next_test() {
  let unsupported =
    failing(query.Unsupported(server: "gleam", request: "callHierarchy"))
  assert string.contains(unsupported, "gleam language server")
  assert string.contains(unsupported, "callHierarchy")
  assert string.contains(unsupported, "lsp_references")

  let no_server = failing(query.NoServer("no server owns .txt files"))
  assert string.contains(no_server, "no server owns .txt files")
  assert string.contains(no_server, "[lsp.<name>]")
  assert string.contains(no_server, "loom.toml")

  let not_found =
    failing(
      query.NotFound(query.SymbolQuery(
        symbol: "greet",
        path: Some("src/a.gleam"),
        line: Some(4),
      )),
    )
  assert string.starts_with(
    not_found,
    "`greet` was not found on line 4 of src/a.gleam",
  )

  assert failing(query.ServerRefused("would make it unexported"))
    == "the language server refused: would make it unexported"

  let unavailable = failing(query.Unavailable("deadline passed"))
  assert string.contains(unavailable, "did not answer: deadline passed")
}

// --- arguments refused in band -------------------------------------------

pub fn an_unknown_direction_is_refused_before_the_door_test() {
  let outcome =
    named(door(), "lsp_calls").run(
      workspace("direction").0,
      args([symbol("greet"), #("direction", json.String("sideways"))]),
    )
  assert outcome.is_error
  assert text_of(outcome)
    == "invalid arguments: `direction` must be \"incoming\" or "
    <> "\"outgoing\", not \"sideways\""
}

pub fn an_unknown_mode_is_refused_before_the_door_test() {
  let outcome =
    named(door(), "lsp_rename").run(
      workspace("mode").0,
      args([
        symbol("greet"),
        #("new_name", json.String("hello")),
        #("mode", json.String("yes")),
      ]),
    )
  assert outcome.is_error
  assert text_of(outcome)
    == "invalid arguments: `mode` must be \"preview\" or \"apply\", not "
    <> "\"yes\""
}

pub fn a_line_without_a_path_is_refused_test() {
  let outcome =
    named(door(), "lsp_hover").run(
      workspace("line").0,
      args([symbol("greet"), #("line", json.Int(3))]),
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "`line` narrows a `path`")
}

// --- rename --------------------------------------------------------------

pub fn rename_preview_shows_every_changed_line_and_writes_nothing_test() {
  let #(ctx, root) = workspace("preview")
  let a = "import probe\n\npub fn main() {\n  probe.greet()\n}\n"
  let b = "pub fn greet() {\n  \"hi\"\n}\n"
  put(root, "a.gleam", a)
  put(root, "b.gleam", b)
  let fake =
    query.Door(..door(), prepare_rename: fn(_, _) {
      warm([rename_edit("b.gleam", b), rename_edit("a.gleam", a)])
    })
  let outcome =
    named(fake, "lsp_rename").run(
      ctx,
      args([symbol("greet"), #("new_name", json.String("hello"))]),
    )

  assert !outcome.is_error
  assert text_of(outcome)
    == string.join(
      [
        "Preview: renaming `greet` to `hello` changes 2 lines in 2 files "
          <> "(2 edits). Nothing was written; to write it, call lsp_rename "
          <> "again with mode \"apply\".",
        "a.gleam (1 edit):",
        "  - 4:" <> hashline.anchor("  probe.greet()") <> "|  probe.greet()",
        "  + 4:" <> hashline.anchor("  probe.hello()") <> "|  probe.hello()",
        "b.gleam (1 edit):",
        "  - 1:" <> hashline.anchor("pub fn greet() {") <> "|pub fn greet() {",
        "  + 1:" <> hashline.anchor("pub fn hello() {") <> "|pub fn hello() {",
      ],
      "\n",
    )
  assert disk(root, "a.gleam") == a
  assert disk(root, "b.gleam") == b
}

pub fn rename_apply_through_the_tool_lands_every_file_test() {
  let #(ctx, root) = workspace("apply_tool")
  let a = "pub fn greet() {\n  1\n}\n"
  let b = "fn main() {\n  greet()\n}\n"
  put(root, "a.gleam", a)
  put(root, "b.gleam", b)
  let fake =
    query.Door(
      ..door(),
      prepare_rename: fn(_, _) {
        warm([rename_edit("a.gleam", a), rename_edit("b.gleam", b)])
      },
      after_write: fn(_) { Some(query.Settled([])) },
    )
  let outcome =
    named(fake, "lsp_rename").run(
      ctx,
      args([
        symbol("greet"),
        #("new_name", json.String("hello")),
        #("mode", json.String("apply")),
      ]),
    )

  assert !outcome.is_error
  assert text_of(outcome)
    == "Renamed `greet` to `hello`: wrote 2 files.\n"
    <> "a.gleam: written (1 edit)\n"
    <> "b.gleam: written (1 edit)\n\n"
    <> "diagnostics: clean (settled)"
  assert disk(root, "a.gleam") == "pub fn hello() {\n  1\n}\n"
  assert disk(root, "b.gleam") == "fn main() {\n  hello()\n}\n"
}

pub fn land_writes_every_file_and_tells_the_server_in_path_order_test() {
  let #(_ctx, root) = workspace("land_all")
  let a = "greet\n"
  let b = "x\ngreet greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", b)
  let calls = process.new_subject()
  let settled = query.Settled([error_diagnostic("b.txt", 2, "hello hello")])
  let report =
    lsp.land(
      edits: [rename_edit("b.txt", b), rename_edit("a.txt", a)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(path) {
        process.send(calls, path)
        Some(settled)
      },
    )

  assert report
    == query.RenameReport(
      files: [query.Landed("a.txt", 1), query.Landed("b.txt", 2)],
      diagnostics: settled,
    )
  assert told(calls) == ["a.txt", "b.txt"]
  assert disk(root, "a.txt") == "hello\n"
  assert disk(root, "b.txt") == "x\nhello hello\n"
}

// The concurrency check runs over every file before the first write: a
// file changed since the server looked stops the whole rename, and the
// file that sorts before it is left exactly as it was.
pub fn a_stale_file_stops_every_write_test() {
  let #(_ctx, root) = workspace("land_stale")
  let a = "greet\n"
  let b = "greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", "greet\nsomeone else's line\n")
  let calls = process.new_subject()
  let report =
    lsp.land(
      edits: [rename_edit("a.txt", a), rename_edit("b.txt", b)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(path) {
        process.send(calls, path)
        Some(query.Settled([]))
      },
    )

  let assert [query.NotAttempted("a.txt"), query.Rejected("b.txt", reason)] =
    report.files
    as "the stale file is rejected and the other not attempted"
  assert string.contains(reason, "the file changed after the language server")
  assert report.diagnostics == query.Unsettled([])
  assert told(calls) == []
  assert disk(root, "a.txt") == a
  assert disk(root, "b.txt") == "greet\nsomeone else's line\n"

  // The report says nothing was written, and carries no diagnostics
  // block, since there is no change to diagnose.
  let text = lsp.render_report("greet", "hello", report)
  assert string.starts_with(text, "Renaming `greet` to `hello` wrote nothing")
  assert !string.contains(text, "diagnostics")
}

// Landing is not atomic across files: a write that fails after an earlier
// one landed leaves the earlier one written, and the report says exactly
// which. The server is told only about files that were written.
pub fn a_later_write_failure_keeps_the_earlier_landing_test() {
  let #(_ctx, root) = workspace("land_partial")
  let a = "greet\n"
  let b = "greet\n"
  let c = "greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", b)
  put(root, "c.txt", c)
  let real = fs.real_filesystem()
  let failing_b =
    tool.FileSystem(..real, write: fn(path, bytes) {
      case string.ends_with(path, "/b.txt") {
        True -> Error(tool.FsPermissionDenied(path))
        False -> real.write(path, bytes)
      }
    })
  let calls = process.new_subject()
  let report =
    lsp.land(
      edits: [
        rename_edit("c.txt", c),
        rename_edit("a.txt", a),
        rename_edit("b.txt", b),
      ],
      target: targets(root),
      filesystem: failing_b,
      after_write: fn(path) {
        process.send(calls, path)
        Some(query.Settled([]))
      },
    )

  let assert [
    query.Landed("a.txt", 1),
    query.Rejected("b.txt", reason),
    query.Landed("c.txt", 1),
  ] = report.files
    as "each file's fate is reported in path order"
  assert reason != ""
  assert told(calls) == ["a.txt", "c.txt"]
  assert disk(root, "a.txt") == "hello\n"
  assert disk(root, "b.txt") == "greet\n"
  assert disk(root, "c.txt") == "hello\n"

  let text = lsp.render_report("greet", "hello", report)
  assert string.starts_with(
    text,
    "Renaming `greet` to `hello` was only partly written: 2 of 3 files.",
  )
  assert string.contains(text, "b.txt: rejected — ")
}

// One unsettled answer makes the whole block unsettled, and an unsettled
// block never renders as clean — not even an empty one.
pub fn unsettled_diagnostics_never_read_as_clean_test() {
  let #(_ctx, root) = workspace("land_unsettled")
  let a = "greet\n"
  let b = "greet\n"
  put(root, "a.txt", a)
  put(root, "b.txt", b)
  let report =
    lsp.land(
      edits: [rename_edit("a.txt", a), rename_edit("b.txt", b)],
      target: targets(root),
      filesystem: fs.real_filesystem(),
      after_write: fn(path) {
        case path {
          "a.txt" -> Some(query.Unsettled([]))
          _ -> Some(query.Settled([]))
        }
      },
    )

  assert report.diagnostics == query.Unsettled([])
  let text = lsp.render_report("greet", "hello", report)
  assert string.contains(text, "NOT settled")
  assert !string.contains(text, "clean")
  assert !string.contains(lsp.render_diagnostics(query.Unsettled([])), "clean")
}

// --- the post-write observer ---------------------------------------------

pub fn the_observer_renders_the_door_answer_test() {
  let answers = fn(path) {
    case path {
      "/w/none.txt" -> None
      "/w/clean.gleam" -> Some(query.Settled([]))
      _ ->
        Some(query.Unsettled(
          one_to(25)
          |> list.map(fn(line) { error_diagnostic("a.gleam", line, "x") }),
        ))
    }
  }
  let observe =
    lsp.diagnostics_observer(query.Door(..door(), after_write: answers))

  assert observe("/w/none.txt") == None
  assert observe("/w/clean.gleam") == Some("diagnostics: clean (settled)")

  let assert Some(block) = observe("/w/broken.gleam")
    as "an owned path answers a block"
  let lines = string.split(block, "\n")
  assert list.first(lines)
    == Ok(
      "diagnostics: NOT settled — the language server had not finished when "
      <> "the wait expired, so these may be stale or incomplete: 25 (25 "
      <> "errors)",
    )
  assert list.count(lines, fn(line) { string.starts_with(line, "error at ") })
    == 20
  assert list.last(lines) == Ok("… 5 more not shown")
  assert !string.contains(block, "clean")
}
