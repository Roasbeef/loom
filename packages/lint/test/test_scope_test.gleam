//// R19 (a SKIP diagnostic printed to stdout) and R20 (a test reaching Lustre
//// through its import graph): the two rules scoped to `test/`.
////
//// Each has the cases its predecessor's guard had, because those were the
//// ways the guard was once wrong: a call written in a comment or a string is
//// not a call, a `//` inside a URL does not hide the code after it, and a
//// forbidden import two modules down is as fatal as one in the test itself.
//// Both gate, so each also asserts the `#(errors, warnings)` split rather than
//// only that the rule fired.

import gleam/dict
import gleam/list
import gleam/string
import lint
import lint/finding.{type Finding}
import lint/policy
import lint/test_imports

// --- helpers ----------------------------------------------------------------

const test_path: String = "packages/core/test/skip_test.gleam"

fn skips(code: String) -> List(Finding) {
  lint.check_tests(test_path, code)
}

fn wall() -> policy.Wall {
  let assert [wall] = policy.import_walls()
    as "web_client is the one walled package"
  wall
}

const a_test: String = "packages/web_client/test/a_test.gleam"

/// The walk over a test and a set of `#(module, source)` package modules.
fn walk(test_code: String, modules: List(#(String, String))) -> List(Finding) {
  let held =
    list.map(modules, fn(entry) {
      #(entry.0, #("packages/web_client/src/" <> entry.0 <> ".gleam", entry.1))
    })
  test_imports.findings(wall(), [#(a_test, test_code)], dict.from_list(held))
}

// --- R19: what is reported --------------------------------------------------

pub fn a_skip_printed_with_println_is_reported_test() {
  let assert [found] =
    skips(
      "import gleam/io
pub fn t() { io.println(\"SKIP example: absent\") }
",
    )
  assert found.rule == finding.StdoutSkip
  assert found.function == "t"
  assert found.line == 2
}

pub fn a_skip_printed_with_print_is_reported_test() {
  assert list.length(skips(
      "import gleam/io\npub fn t() { io.print(\"SKIP x: y\") }\n",
    ))
    == 1
}

pub fn a_skip_message_built_by_concatenation_is_reported_test() {
  let code =
    "import gleam/io
pub fn t(name, reason) {
  io.println(
    \"SKIP \" <> name <> \": \" <> reason,
  )
}
"
  assert list.length(skips(code)) == 1
}

pub fn a_skip_with_a_comment_before_the_literal_is_reported_test() {
  let code =
    "import gleam/io
pub fn t() {
  io.println( // Prerequisite absent.
    \"SKIP example\")
}
"
  assert list.length(skips(code)) == 1
}

pub fn a_skip_piped_into_println_is_reported_test() {
  assert list.length(skips(
      "import gleam/io\npub fn t() { \"SKIP x: y\" |> io.println }\n",
    ))
    == 1
}

pub fn a_skip_through_an_import_alias_is_reported_test() {
  let code =
    "import gleam/io as out
pub fn t() { out.println(\"SKIP x: y\") }
"
  assert list.length(skips(code)) == 1
}

pub fn a_skip_through_an_unqualified_import_is_reported_test() {
  let code =
    "import gleam/io.{println as say}
pub fn t() { say(\"SKIP x: y\") }
"
  assert list.length(skips(code)) == 1
}

pub fn a_skip_in_a_nested_closure_is_reported_test() {
  let code =
    "import gleam/io
pub fn t() { fn() { case True { True -> io.println(\"SKIP x\") False -> Nil } } }
"
  assert list.length(skips(code)) == 1
}

pub fn a_url_in_a_string_does_not_hide_the_call_test() {
  let code =
    "import gleam/io
pub fn t() {
  let url = \"https://example.invalid\"
  io.println(\"SKIP example\")
}
"
  assert list.length(skips(code)) == 1
}

// --- R19: what is not -------------------------------------------------------

pub fn the_stderr_emitter_is_silent_test() {
  assert skips(
      "import gleam/io\npub fn t() { io.println_error(\"SKIP example\") }\n",
    )
    == []
}

pub fn ordinary_output_mentioning_skip_is_silent_test() {
  assert skips(
      "import gleam/io\npub fn t() { io.println(\"ordinary output mentioning SKIP\") }\n",
    )
    == []
}

pub fn a_longer_word_is_not_the_marker_test() {
  assert skips("import gleam/io\npub fn t() { io.println(\"SKIPPED x\") }\n")
    == []
}

pub fn a_call_in_a_comment_is_silent_test() {
  let code =
    "import gleam/io
pub fn t() {
  // io.println(\"SKIP example\")
  let x = 1 // io.println(\"SKIP example\")
  x
}
"
  assert skips(code) == []
}

pub fn a_call_quoted_in_a_string_is_silent_test() {
  let code =
    "pub fn t() {
  \"io.println(\\\"SKIP example\\\")\"
}
"
  assert skips(code) == []
}

pub fn another_modules_println_is_silent_test() {
  let code =
    "import logger
pub fn t() { logger.println(\"SKIP example\") }
"
  assert skips(code) == []
}

pub fn an_unimported_println_is_silent_test() {
  assert skips("pub fn t() { println(\"SKIP example\") }\n") == []
}

pub fn a_skip_in_the_middle_of_a_message_is_silent_test() {
  let code =
    "import gleam/io
pub fn t(name) { io.println(name <> \"SKIP x\") }
"
  assert skips(code) == []
}

// --- R19: scope and gate ----------------------------------------------------

pub fn an_unparseable_test_is_reported_as_r0_test() {
  let assert [found] = skips("pub fn t( { \"SKIP\"")
  assert found.rule == finding.Unparseable
}

pub fn the_ordinary_rules_do_not_read_a_stdout_skip_test() {
  let code = "import gleam/io\npub fn t() { io.println(\"SKIP x: y\") }\n"
  assert lint.check(test_path, code, policy.for_tests())
    |> list.filter(fn(found) { found.rule == finding.StdoutSkip })
    == []
}

pub fn r19_gates_test() {
  let code = "import gleam/io\npub fn t() { io.println(\"SKIP x: y\") }\n"
  assert finding.gate(skips(code), finding.error_by_default()) == #(1, 0)
}

// --- R20: what is reported --------------------------------------------------

const lustre_import: String =
  "import lustre/element\n\npub fn view() { element.none() }\n"

pub fn a_test_importing_lustre_directly_is_reported_test() {
  let assert [found] = walk("import lustre\n\npub fn t() { Nil }\n", [])
  assert found.rule == finding.TestImportWall
  assert found.path == a_test
  assert found.line == 1
  assert string.contains(found.detail, "`lustre`")
}

pub fn a_test_importing_an_internal_module_is_reported_test() {
  let assert [found] =
    walk("import web_client/internal/dom\n\npub fn t() { Nil }\n", [])
  assert string.contains(found.detail, "`web_client/internal/dom`")
}

pub fn a_rule_module_importing_lustre_is_reported_in_its_own_file_test() {
  let assert [found] =
    walk("import web_client/follow_rule\n", [
      #("web_client/follow_rule", lustre_import),
    ])
  assert found.path == "packages/web_client/src/web_client/follow_rule.gleam"
  assert found.line == 1
  assert string.contains(found.detail, "a_test.gleam -> web_client/follow_rule")
}

pub fn a_forbidden_import_two_modules_down_is_reported_with_its_chain_test() {
  let assert [found] =
    walk("import web_client/outer\n", [
      #("web_client/outer", "import web_client/inner\n"),
      #("web_client/inner", "import lustre/event\n"),
    ])
  assert found.path == "packages/web_client/src/web_client/inner.gleam"
  assert string.contains(
    found.detail,
    "a_test.gleam -> web_client/outer -> web_client/inner",
  )
}

pub fn a_multi_line_import_list_is_followed_test() {
  let test_code =
    "import web_client/composer_rule.{
  type Intent, Send,
}
"
  assert list.length(
      walk(test_code, [#("web_client/composer_rule", "import lustre\n")]),
    )
    == 1
}

pub fn a_module_reached_by_two_paths_reports_each_import_once_test() {
  let test_code = "import web_client/left\nimport web_client/right\n"
  let found =
    walk(test_code, [
      #("web_client/left", "import web_client/shared\n"),
      #("web_client/right", "import web_client/shared\n"),
      #("web_client/shared", "import lustre\n"),
    ])
  assert list.length(found) == 1
}

pub fn a_cycle_between_package_modules_terminates_test() {
  let found =
    walk("import web_client/a\n", [
      #("web_client/a", "import web_client/b\n"),
      #("web_client/b", "import web_client/a\nimport lustre\n"),
    ])
  assert list.length(found) == 1
}

// --- R20: what is not -------------------------------------------------------

pub fn a_test_that_imports_only_decision_modules_is_silent_test() {
  let found =
    walk("import gleam/list\nimport web_client/follow_rule\n", [
      #("web_client/follow_rule", "import gleam/int\n"),
    ])
  assert found == []
}

pub fn a_prefix_is_a_path_segment_not_a_substring_test() {
  assert walk("import lustrous\nimport web_client/internals\n", []) == []
}

pub fn lustre_named_in_a_comment_or_a_string_is_silent_test() {
  let code =
    "// import lustre
pub fn t() { \"import lustre\" }
"
  assert walk(code, []) == []
}

pub fn an_import_of_a_module_outside_the_package_ends_the_branch_test() {
  assert walk("import other/thing\n", [
      #("other/thing", "import lustre\n"),
    ])
    == []
}

pub fn an_unparseable_module_in_the_walk_is_not_this_rules_finding_test() {
  assert walk("import web_client/broken\n", [#("web_client/broken", "import (")])
    == []
}

pub fn r20_gates_test() {
  let found = walk("import lustre\n", [])
  assert finding.gate(found, finding.error_by_default()) == #(1, 0)
}

pub fn a_test_without_the_marker_is_not_parsed_test() {
  assert skips("pub fn t( {\n  no marker, and not Gleam") == []
}
