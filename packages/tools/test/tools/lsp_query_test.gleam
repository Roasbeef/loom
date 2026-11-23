//// The opt-in `lsp_*` tools: argument decoding, bounded rendering and the
//// typed errors, over a fake door.
////
//// The tools are thin over `lsp/query.Door`, so these tests hold the part
//// that is theirs: what a malformed call costs (no door request), what a
//// refused or unreachable server reads as to the model, and that every list
//// counts, stops at its bound and says it stopped. The live door, with a
//// real server, is `conformance/lsp_e2e_test`.

import core/json
import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lsp/query
import support/fake_broker
import support/memory_fs
import tools/hashline
import tools/lsp_query
import tools/tool

// A door where every closure answers `Unavailable`, so a test overrides
// exactly the closure it is about.
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

// 1 through `count`.
fn numbered(count: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, count), fn(_, index) { index + 1 })
}

fn served(value: a) -> Result(query.Served(a), query.QueryError) {
  Ok(query.Served(value:, warmth: query.Warm))
}

fn find(door: query.Door, name: String) -> tool.Tool {
  let assert Ok(found) =
    list.find(lsp_query.tools(door, []), fn(each) { each.name == name })
    as "the tool must be registered"
  found
}

fn call(door: query.Door, name: String, args: List(#(String, json.JsonValue))) {
  let found = find(door, name)
  found.run(ctx(), json.Object(args))
}

fn ctx() -> tool.Ctx {
  fake_broker.ctx(
    workspace: "/work",
    filesystem: memory_fs.filesystem(memory_fs.start()),
    now: 0,
    script: [],
    recorded: process.new_subject(),
  )
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn symbol(name: String) -> #(String, json.JsonValue) {
  #("symbol", json.String(name))
}

// --- the registry entry ------------------------------------------------------

pub fn the_five_tools_register_in_order_test() {
  assert list.map(lsp_query.tools(door(), []), fn(each) { each.name })
    == [
      "lsp_definition", "lsp_references", "lsp_hover", "lsp_symbols",
      "lsp_diagnostics",
    ]
  assert lsp_query.tool_names
    == list.map(lsp_query.tools(door(), []), fn(each) { each.name })
}

pub fn every_tool_is_a_concurrent_replay_safe_read_test() {
  list.each(lsp_query.tools(door(), []), fn(each) {
    assert each.replay == tool.Safe
    assert each.execution_mode == tool.Concurrent
  })
}

pub fn hints_reach_only_the_definition_description_test() {
  let with_hints = lsp_query.tools(door(), [#("go", "qualify as pkg.Name")])
  let plain = lsp_query.tools(door(), [])
  let assert [definition, ..rest] = with_hints
  let assert [plain_definition, ..plain_rest] = plain
  assert string.contains(
    definition.description,
    "Language notes:\ngo: qualify as pkg.Name",
  )
  assert !string.contains(plain_definition.description, "Language notes")
  assert rest == plain_rest
}

// --- decoding costs no request -----------------------------------------------

// A door whose every closure reports to the test, so a call that should
// not have reached the door is seen.
fn spying_door(spy: process.Subject(String)) -> query.Door {
  query.Door(
    ..door(),
    definition: fn(asked: query.SymbolQuery) {
      process.send(spy, "definition:" <> asked.symbol)
      served([])
    },
    outline: fn(path) {
      process.send(spy, "outline:" <> path)
      served([])
    },
    diagnostics: fn(_) {
      process.send(spy, "diagnostics")
      served(query.Settled([]))
    },
  )
}

pub fn a_malformed_call_never_reaches_the_door_test() {
  let spy = process.new_subject()
  let door = spying_door(spy)
  let refusals = [
    call(door, "lsp_definition", []),
    call(door, "lsp_definition", [symbol("   ")]),
    call(door, "lsp_definition", [symbol("greet"), #("line", json.Int(3))]),
    call(door, "lsp_definition", [
      symbol("greet"),
      #("path", json.String("a.go")),
      #("line", json.Int(0)),
    ]),
    call(door, "lsp_definition", [symbol("greet"), #("line", json.String("3"))]),
    call(door, "lsp_definition", [symbol("x"), #("path", json.String(" "))]),
    call(door, "lsp_symbols", []),
    call(door, "lsp_symbols", [#("path", json.String(" "))]),
    call(door, "lsp_diagnostics", [#("path", json.String(""))]),
    call(door, "lsp_diagnostics", [#("path", json.Int(4))]),
  ]
  list.each(refusals, fn(outcome) {
    assert outcome.is_error
  })
  assert process.receive(spy, 0) == Error(Nil)
}

pub fn a_line_with_its_path_narrows_the_query_test() {
  let spy = process.new_subject()
  let door =
    query.Door(..door(), definition: fn(asked) {
      process.send(spy, asked)
      served([site("a.go", 4, "func Greet() {")])
    })
  let outcome =
    call(door, "lsp_definition", [
      symbol(" util.Greet "),
      #("path", json.String("main.go")),
      #("line", json.Int(7)),
    ])
  assert !outcome.is_error
  assert process.receive(spy, 0)
    == Ok(query.SymbolQuery(
      symbol: "util.Greet",
      path: Some("main.go"),
      line: Some(7),
    ))
}

// --- definition ---------------------------------------------------------------

pub fn definition_lists_anchored_sites_test() {
  let door =
    query.Door(..door(), definition: fn(_) {
      served([site("util/util.go", 4, "func Greet(name string) string {")])
    })
  let text = text_of(call(door, "lsp_definition", [symbol("Greet")]))
  assert text
    == "1 definition of `Greet`:\n"
    <> hit("util/util.go", 4, "func Greet(name string) string {")
}

pub fn definition_says_when_a_server_started_test() {
  let door =
    query.Door(..door(), definition: fn(_) {
      Ok(query.Served(value: [], warmth: query.Started(server: "go")))
    })
  let text = text_of(call(door, "lsp_definition", [symbol("Greet")]))
  assert string.starts_with(text, "(started the go language server")
  assert string.ends_with(text, "no definition found for `Greet`")
}

pub fn definition_is_bounded_and_says_so_test() {
  let sites =
    numbered(lsp_query.max_definition_sites + 5)
    |> list.map(fn(line) { site("a.go", line, "x") })
  let text = lsp_query.render_definitions("x", sites)
  let listed = string.split(text, "\n") |> list.filter(string.contains(_, "|x"))
  assert list.length(listed) == lsp_query.max_definition_sites
  assert string.contains(text, "… 5 more")
}

// --- references ---------------------------------------------------------------

fn reference(
  path: String,
  line: Int,
  container: Option(String),
) -> query.Reference {
  query.Reference(site: site(path, line, "use()"), container:)
}

pub fn references_group_by_file_and_container_test() {
  let text =
    lsp_query.render_references("Greet", [
      reference("main.go", 6, Some("main")),
      reference("main.go", 7, Some("main")),
      reference("util/util.go", 4, None),
    ])
  assert string.starts_with(text, "3 references to `Greet` in 2 files\n")
  assert string.contains(text, "main.go (2 references):\n  in main:\n")
  assert string.contains(text, "util/util.go (1 reference):\n  at top level:")
  assert string.contains(text, hit("main.go", 7, "use()"))
}

pub fn references_stop_at_the_bound_and_say_how_many_test() {
  let many =
    numbered(lsp_query.max_reference_hits + 7)
    |> list.map(fn(line) { reference("a.go", line, Some("f")) })
  let text = lsp_query.render_references("x", many)
  let shown =
    string.split(text, "\n") |> list.filter(string.contains(_, "|use()"))
  assert list.length(shown) == lsp_query.max_reference_hits
  assert string.contains(text, "showing 50")
  assert string.contains(text, "… 7 more not shown")
  // The file heading still counts every reference, shown or not.
  assert string.contains(text, "a.go (57 references):")
}

pub fn no_references_is_said_plainly_test() {
  assert lsp_query.render_references("x", []) == "no references to `x` found"
}

// --- hover and symbols --------------------------------------------------------

pub fn hover_clips_long_text_test() {
  let long = string.repeat("line of documentation\n", 400)
  let text =
    lsp_query.render_hover(query.Hover(
      site: site("a.go", 1, "func F()"),
      contents: long,
    ))
  assert string.contains(text, "more bytes cut]")
  assert string.byte_size(text) < lsp_query.max_hover_bytes + 200
}

pub fn hover_without_text_says_so_test() {
  let text =
    lsp_query.render_hover(query.Hover(
      site: site("a.go", 1, "func F()"),
      contents: "  ",
    ))
  assert string.contains(text, "no type or documentation")
}

fn entry(name: String, children: List(query.SymbolEntry)) -> query.SymbolEntry {
  query.SymbolEntry(
    name:,
    kind: "function",
    detail: Some("func()"),
    site: site("a.go", 1, name),
    children:,
  )
}

pub fn outline_nests_and_anchors_test() {
  let text =
    lsp_query.render_outline("a.go", [
      entry("Server", [entry("Handle", [])]),
    ])
  assert text
    == "2 symbols in a.go:\n"
    <> "function Server — func()\n"
    <> "  1:"
    <> hashline.anchor("Server")
    <> "|Server\n"
    <> "  function Handle — func()\n"
    <> "    1:"
    <> hashline.anchor("Handle")
    <> "|Handle"
}

pub fn outline_cuts_at_an_entry_boundary_and_says_so_test() {
  let entries =
    numbered(lsp_query.max_outline_entries + 3)
    |> list.map(fn(index) { entry("f" <> int.to_string(index), []) })
  let text = lsp_query.render_outline("a.go", entries)
  assert string.contains(text, "103 symbols in a.go:")
  assert string.contains(text, "… 3 more symbols not shown")
  assert string.contains(text, "f100 — func()")
  assert !string.contains(text, "f101 —")
}

// --- diagnostics ---------------------------------------------------------------

pub fn diagnostics_keep_the_settlement_state_test() {
  let diagnostic =
    query.Diagnostic(
      site: site("a.go", 3, "x := 1"),
      severity: query.SeverityError,
      message: "declared and not used: x",
    )
  let settled =
    query.Door(..door(), diagnostics: fn(_) {
      served(query.Settled([diagnostic]))
    })
  let text = text_of(call(settled, "lsp_diagnostics", []))
  assert string.starts_with(text, "diagnostics (settled): 1 (1 error)")
  assert string.contains(text, "declared and not used: x")

  let unsettled =
    query.Door(..door(), diagnostics: fn(_) { served(query.Unsettled([])) })
  let text = text_of(call(unsettled, "lsp_diagnostics", []))
  assert string.contains(text, "NOT settled")
}

// --- typed errors ---------------------------------------------------------------

pub fn an_unreachable_server_reads_as_unavailable_test() {
  let outcomes = [
    query.NoServer("no server owns notes.txt"),
    query.NoServer("/etc/passwd resolves outside the server's root"),
    query.Unavailable("the request timed out"),
  ]
  list.each(outcomes, fn(error) {
    let door = query.Door(..door(), definition: fn(_) { Error(error) })
    let outcome = call(door, "lsp_definition", [symbol("x")])
    assert outcome.is_error
    assert string.starts_with(text_of(outcome), "language server unavailable: ")
  })
}

pub fn every_tool_answers_the_typed_error_in_band_test() {
  let down = query.NoServer("no language server is configured for .go")
  let door =
    query.Door(
      ..door(),
      definition: fn(_) { Error(down) },
      references: fn(_) { Error(down) },
      hover: fn(_) { Error(down) },
      outline: fn(_) { Error(down) },
      diagnostics: fn(_) { Error(down) },
    )
  list.each(
    [
      #("lsp_definition", [symbol("x")]),
      #("lsp_references", [symbol("x")]),
      #("lsp_hover", [symbol("x")]),
      #("lsp_symbols", [#("path", json.String("a.go"))]),
      #("lsp_diagnostics", []),
    ],
    fn(pair) {
      let outcome = call(door, pair.0, pair.1)
      assert outcome.is_error as pair.0
      assert string.starts_with(text_of(outcome), "language server unavailable")
    },
  )
}

pub fn not_found_names_where_it_looked_test() {
  let asked = query.SymbolQuery(symbol: "Nope", path: None, line: None)
  assert string.contains(
    lsp_query.render_error(query.NotFound(
      asked,
      Some("the go server rooted at /work/app"),
    )),
    "`Nope` was not found in the go server rooted at /work/app.",
  )
  assert string.contains(
    lsp_query.render_error(query.NotFound(
      query.SymbolQuery(..asked, path: Some("a.go"), line: Some(9)),
      None,
    )),
    "on line 9 of a.go",
  )
}

pub fn an_ambiguous_name_lists_the_candidates_test() {
  let text =
    lsp_query.render_error(
      query.Ambiguous([
        site("a/a.go", 1, "func Init()"),
        site("b/b.go", 2, "func Init()"),
      ]),
    )
  assert string.contains(text, "2 distinct definitions match")
  assert string.contains(text, hit("b/b.go", 2, "func Init()"))
}

// --- bounded output -----------------------------------------------------------

pub fn a_very_long_source_line_is_cut_after_its_anchor_is_taken_test() {
  let long = "x := \"" <> string.repeat("é", 200_000) <> "\""
  let text =
    lsp_query.render_references("x", [
      query.Reference(site: site("gen.go", 3, long), container: None),
    ])
  assert string.contains(text, ":" <> hashline.anchor(long) <> "|x := ")
  assert string.contains(text, "more bytes]")
  assert string.byte_size(text) < 1500
}

pub fn the_whole_answer_is_bounded_even_when_every_entry_is_long_test() {
  // 20 diagnostics, each with a huge message: each entry is within its own
  // count cap, so only the overall bound limits the answer.
  let message = string.repeat("m", 40_000)
  let entries =
    numbered(20)
    |> list.map(fn(line) {
      query.Diagnostic(
        site: site("a.go", line, "x"),
        severity: query.SeverityError,
        message:,
      )
    })
  let door =
    query.Door(..door(), diagnostics: fn(_) { served(query.Settled(entries)) })
  let outcome = call(door, "lsp_diagnostics", [])
  assert !outcome.is_error
  let text = text_of(outcome)
  assert string.contains(text, "saved to")
  assert string.byte_size(text) < 10_000
}

pub fn an_ambiguous_list_says_how_many_more_test() {
  let sites =
    numbered(lsp_query.max_definition_sites + 3)
    |> list.map(fn(line) { site("a.go", line, "func Init()") })
  assert string.contains(
    lsp_query.render_error(query.Ambiguous(sites)),
    "… 3 more",
  )
}
