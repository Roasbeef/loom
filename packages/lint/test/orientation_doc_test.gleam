//// R13 and R14 read the module doc, which `glance` drops, so these tests go
//// through `lint.check` with real sources: a rule that cannot fail is worse
//// than no rule.

import gleam/list
import gleam/string
import lint
import lint/finding.{type Finding, type Rule}
import lint/module_doc
import lint/policy

// --- helpers ----------------------------------------------------------------

/// A policy whose spine threshold a small source can reach.
fn small() -> policy.Policy {
  policy.Policy(..policy.default(), spine_lines: 5)
}

fn run(code: String, rule: Rule) -> List(Finding) {
  lint.check("packages/x/src/x.gleam", code, small())
  |> list.filter(fn(found) { found.rule == rule })
}

fn spine(code: String) -> List(Finding) {
  run(code, finding.FlowSpine)
}

fn table(code: String) -> List(Finding) {
  run(code, finding.TransitionTable)
}

fn details(found: List(Finding)) -> String {
  found |> list.map(fn(f) { f.detail }) |> string.join("\n")
}

/// Three functions, one of them private, plus an import and an alias.
const body: String =
  "
import gleam/list
import gleam/option as opt

pub fn a() { 1 }

pub fn b() { 2 }

fn hidden() { 3 }
"

fn with_flow(flow: String) -> String {
  "//// Title.\n////\n//// ## Flow\n////\n" <> flow <> "\n" <> body
}

const good_flow: String = "//// `a` → `b` → `hidden`"

// --- module_doc -------------------------------------------------------------

pub fn doc_lines_carry_offsets_and_tidy_text_test() {
  let doc = module_doc.lines("//// ## Flow  \n////\n//// x\nfn f() { 1 }\n")
  assert doc
    == [
      module_doc.DocLine(0, "## Flow"),
      module_doc.DocLine(15, ""),
      module_doc.DocLine(20, "x"),
    ]
}

pub fn doc_ignores_quad_slash_inside_a_string_test() {
  assert module_doc.lines("const s = \"\n//// ## Flow\n\"\n") == []
}

pub fn section_stops_at_next_level_two_heading_test() {
  let doc =
    module_doc.lines(
      "//// ## Flow\n//// a\n//// ### sub\n//// b\n//// ## X\n//// c\n",
    )
  let assert Ok(section) = module_doc.section(doc, "## Flow")
  assert list.map(section.body, fn(line) { line.text }) == ["a", "### sub", "b"]
}

pub fn section_absent_is_error_test() {
  assert module_doc.section(module_doc.lines("//// ## Other\n"), "## Flow")
    == Error(Nil)
}

pub fn code_spans_pair_backticks_test() {
  assert module_doc.code_spans("`a` x `b(1)` y `c") == ["a", "b(1)"]
  assert module_doc.code_spans("none") == []
}

// --- R13 --------------------------------------------------------------------

pub fn large_module_without_flow_is_one_finding_at_the_top_test() {
  let code = "//// Title.\n" <> body
  let assert [found] = spine(code)
  assert found.line == 1
  assert found.function == ""
  assert string.contains(found.detail, "## Flow")
  assert string.contains(found.detail, "lines")
}

pub fn small_module_without_flow_is_fine_test() {
  assert spine("//// T.\npub fn a() { 1 }\n") == []
}

pub fn the_default_threshold_is_a_thousand_lines_test() {
  let code = "//// T.\n" <> string.repeat("pub fn a() { 1 }\n", 30)
  assert lint.check("t.gleam", code, policy.default())
    |> list.filter(fn(f) { f.rule == finding.FlowSpine })
    == []
}

pub fn good_spine_is_clean_test() {
  assert spine(with_flow(good_flow)) == []
}

pub fn private_function_resolves_test() {
  assert spine(with_flow("//// `a`, `b` and the private `hidden`")) == []
}

pub fn small_module_with_a_flow_section_is_still_checked_test() {
  let code =
    "//// ## Flow\n//// `ghost` `a` `b` `c`\npub fn a() { 1 }\npub fn b() { 1 }\npub fn c() { 1 }\n"
  let assert [found] =
    lint.check("t.gleam", code, policy.default())
    |> list.filter(fn(f) { f.rule == finding.FlowSpine })
  assert found.line == 2
  assert string.contains(found.detail, "ghost")
}

pub fn renamed_function_fails_the_spine_test() {
  let code = string.replace(with_flow(good_flow), "fn hidden()", "fn renamed()")
  // The stale name, and the spine now naming only two live functions.
  let found = spine(code)
  assert list.length(found) == 2
  assert string.contains(details(found), "`hidden`")
}

pub fn unresolved_name_is_reported_at_its_line_test() {
  let found = spine(with_flow("//// `a` `b` `hidden`\n//// then `nope`"))
  let assert [one] = found
  assert one.line == 6
  assert string.contains(one.detail, "nope")
}

pub fn call_and_arity_suffixes_are_names_test() {
  assert spine(with_flow("//// `a()` `b(x, y)` `hidden/2`")) == []
  let found = spine(with_flow("//// `a()` `b/2` `hidden` `gone(1)` `gone/3`"))
  assert list.length(found) == 2
}

pub fn qualified_name_with_imported_alias_resolves_test() {
  assert spine(with_flow(good_flow <> " `list.map` `opt.map`")) == []
}

pub fn qualified_name_with_other_alias_fails_test() {
  let found = spine(with_flow(good_flow <> " `option.map`"))
  let assert [one] = found
  assert string.contains(one.detail, "option.map")
}

pub fn aliased_import_hides_its_path_segment_test() {
  // `gleam/option as opt` is reachable only as `opt`.
  let found = spine(with_flow(good_flow <> " `option.some`"))
  assert list.length(found) == 1
}

pub fn prose_spans_are_not_checked_test() {
  let flow =
    good_flow
    <> " `Msg` `Ok(x)` `a b` `gleam/list` `Foo.bar` `42` `x-y` `not_a_thing.Type`"
  assert spine(with_flow(flow)) == []
}

pub fn too_few_local_functions_is_a_finding_at_the_heading_test() {
  let found = spine(with_flow("//// `a` `b` `Msg`"))
  let assert [one] = found
  assert one.line == 3
  assert string.contains(one.detail, "2")
}

pub fn repeating_one_function_does_not_make_a_spine_test() {
  let found = spine(with_flow("//// `a` `a` `a` `a`"))
  assert list.length(found) == 1
}

pub fn qualified_names_do_not_count_toward_the_minimum_test() {
  let found = spine(with_flow("//// `a` `b` `list.map`"))
  assert list.length(found) == 1
}

pub fn fenced_block_is_a_finding_and_hides_nothing_test() {
  let flow = good_flow <> "\n//// ```\n//// `ghost`\n//// ```"
  let found = spine(with_flow(flow))
  let assert [one] = found
  assert one.line == 6
  assert string.contains(one.detail, "code listing")
}

/// A `text` fence is a diagram, the form the language-server modules draw a
/// branching path in. It is read by shape, so prose around the names passes.
pub fn a_text_diagram_is_a_spine_test() {
  let flow =
    "//// ```text\n//// a query: a → b → hidden(Ask) → the answer\n//// ```"
  assert spine(with_flow(flow)) == []
}

/// A name-shaped word in a diagram must resolve, so a renamed function still
/// fails the gate when the spine is drawn rather than listed.
pub fn a_stale_name_in_a_diagram_is_a_finding_test() {
  let flow = "//// ```text\n//// a → b → hidden → begin_server\n//// ```"
  let assert [one] = spine(with_flow(flow))
  assert string.contains(one.detail, "begin_server")
}

/// A call-shaped word is a name even without an underscore.
pub fn a_call_in_a_diagram_must_resolve_test() {
  let flow = "//// ```text\n//// a → b → hidden → ghost(x)\n//// ```"
  let assert [one] = spine(with_flow(flow))
  assert string.contains(one.detail, "ghost")
}

/// Qualified words are field calls as often as imports, and a pattern names
/// a family; neither is checked inside a diagram.
pub fn qualified_words_and_patterns_pass_in_a_diagram_test() {
  let flow =
    "//// ```text\n//// a → b → hidden → backend.connect → decode_<name> → render_*\n//// ```"
  assert spine(with_flow(flow)) == []
}

/// Plain words count toward the minimum only when they are functions, so a
/// diagram of prose is not a spine.
pub fn a_diagram_of_prose_is_too_few_test() {
  let flow = "//// ```text\n//// the request goes to the answer\n//// ```"
  let assert [one] = spine(with_flow(flow))
  assert string.contains(one.detail, "0")
}

pub fn names_in_the_next_section_are_not_checked_test() {
  let code =
    "//// ## Flow\n//// `a` `b` `c`\n//// ## Notes\n//// `ghost`\npub fn a() { 1 }\npub fn b() { 1 }\npub fn c() { 1 }\n"
  assert lint.check("t.gleam", code, policy.default())
    |> list.filter(fn(f) { f.rule == finding.FlowSpine })
    == []
}

pub fn flow_heading_in_a_string_is_not_a_section_test() {
  let code = "//// T.\nconst s = \"\n//// ## Flow\n\"\n" <> body
  let assert [found] = spine(code)
  assert found.line == 1
}

// --- R14 --------------------------------------------------------------------

const phase_type: String =
  "
pub type Phase {
  Idle
  Running
  Done
}
"

fn with_table(table_lines: String) -> String {
  "//// T.\n////\n" <> table_lines <> phase_type
}

const full_table: String =
  "//// <!-- transitions: x.Phase -->
////
//// | state | go | stop |
//// | --- | --- | --- |
//// | `Idle` | `Running` | refused |
//// | `Running` | refused | `Done` |
//// | `Done` | refused | refused |
"

pub fn complete_table_is_clean_test() {
  assert table(with_table(full_table)) == []
}

fn table_at(path: String, marker_module: String) -> List(Finding) {
  let code =
    with_table(string.replace(full_table, "x.Phase", marker_module <> ".Phase"))
  lint.check(path, code, small())
  |> list.filter(fn(f) { f.rule == finding.TransitionTable })
}

pub fn marker_may_use_the_last_segment_test() {
  assert table_at("packages/p/src/a/x.gleam", "x") == []
}

pub fn marker_may_use_the_full_module_path_test() {
  assert table_at("packages/p/src/a/x.gleam", "a/x") == []
}

pub fn marker_naming_a_different_path_to_the_same_name_fails_test() {
  assert list.length(table_at("packages/p/src/a/x.gleam", "b/x")) == 1
}

pub fn marker_for_another_module_is_one_finding_test() {
  let found =
    table(with_table(string.replace(full_table, "x.Phase", "y.Phase")))
  let assert [one] = found
  assert one.line == 3
  assert string.contains(one.detail, "`y`")
}

pub fn marker_for_a_non_type_is_a_finding_test() {
  let found = table(with_table(string.replace(full_table, "x.Phase", "x.Nope")))
  let assert [one] = found
  assert string.contains(one.detail, "Nope")
}

pub fn marker_for_an_alias_is_not_a_custom_type_test() {
  let code = "//// T.\n////\n" <> full_table <> "pub type Phase = Int\n"
  assert list.length(table(code)) == 1
}

pub fn marker_without_dot_is_a_finding_test() {
  let found = table(with_table(string.replace(full_table, "x.Phase", "Phase")))
  assert list.length(found) == 1
}

pub fn marker_with_no_table_is_a_finding_test() {
  let code =
    with_table("//// <!-- transitions: x.Phase -->\n////\n//// just prose\n")
  let assert [one] = table(code)
  assert string.contains(one.detail, "table")
}

pub fn marker_followed_by_a_header_but_no_separator_is_no_table_test() {
  let code =
    with_table(
      "//// <!-- transitions: x.Phase -->\n//// | state | go |\n//// | `Idle` | x |\n",
    )
  assert list.length(table(code)) == 1
  assert string.contains(details(table(code)), "no markdown table")
}

pub fn missing_variant_is_one_finding_naming_it_test() {
  let code =
    string.replace(full_table, "//// | `Done` | refused | refused |\n", "")
  let assert [one] = table(with_table(code))
  assert string.contains(one.detail, "`Done`")
  assert one.line == 3
}

pub fn extra_row_is_a_finding_at_the_row_test() {
  let code = full_table <> "//// | `Ghost` | refused | refused |\n"
  let assert [one] = table(with_table(code))
  assert one.line == 10
  assert string.contains(one.detail, "Ghost")
}

pub fn duplicated_row_is_a_finding_at_the_second_test() {
  let code = full_table <> "//// | `Idle` | refused | refused |\n"
  let assert [one] = table(with_table(code))
  assert one.line == 10
  assert string.contains(one.detail, "more than one")
}

pub fn wrong_cell_count_is_a_finding_test() {
  let code =
    string.replace(
      full_table,
      "| `Done` | refused | refused |",
      "| `Done` | refused |",
    )
  let assert [one] = table(with_table(code))
  assert one.line == 9
  assert string.contains(one.detail, "2 cells")
}

pub fn empty_cell_is_a_finding_test() {
  let code =
    string.replace(
      full_table,
      "| `Done` | refused | refused |",
      "| `Done` |  | refused |",
    )
  let assert [one] = table(with_table(code))
  assert string.contains(one.detail, "empty cell")
}

pub fn backticks_and_space_are_stripped_from_the_name_test() {
  let code = string.replace(full_table, "| `Idle` |", "|   Idle   |")
  assert table(with_table(code)) == []
}

pub fn table_ends_at_the_first_non_table_line_test() {
  let code = full_table <> "////\n//// | `Ghost` | x | y |\n"
  assert table(with_table(code)) == []
}

pub fn a_marker_in_a_string_is_not_a_marker_test() {
  let code =
    "//// T.\nconst s = \"\n//// <!-- transitions: y.Nope -->\n\"\n"
    <> phase_type
  assert table(code) == []
}

pub fn prose_mentioning_the_marker_is_not_a_marker_test() {
  let code =
    "//// Write `<!-- transitions: y.Nope -->` above a table.\n" <> phase_type
  assert table(code) == []
}

pub fn two_markers_are_checked_independently_test() {
  let second =
    "//// <!-- transitions: x.Other -->\n////\n//// | s | e |\n//// | --- | --- |\n//// | `Only` | x |\n"
  let code =
    "//// T.\n////\n"
    <> full_table
    <> "////\n"
    <> second
    <> phase_type
    <> "pub type Other {\n  Only\n  Twin\n}\n"
  let found = table(code)
  assert list.length(found) == 1
  assert string.contains(details(found), "`Twin`")
}
