//// The pointer to a capability reference is a pure decision over a failure.
//// These tests pin which failures name which modules, and the cases that
//// must stay silent: no capability mentioned, a name that only ends in a
//// module's name, and a module the host does not admit.

import gleam/option.{None}
import tools/call_record
import tools/codemode_pointer

const admitted = ["cap/fs", "cap/lsp", "cap/lsp_sql", "cap/report", "gleam/int"]

fn failed(capability: String) -> call_record.CallRecord {
  call_record.CallRecord(
    cap: capability,
    args: None,
    status: call_record.CallFailed,
    error: None,
    start_ms: 0,
    duration_ms: 0,
  )
}

fn succeeded(capability: String) -> call_record.CallRecord {
  call_record.CallRecord(..failed(capability), status: call_record.CallOk)
}

fn log(items: List(call_record.CallRecord)) -> call_record.CallLog {
  call_record.CallLog(..call_record.empty(), total: 3, failed: 1, items:)
}

pub fn a_qualified_use_in_a_diagnostic_names_its_module_test() {
  let diagnostics =
    "error: Unknown record field\n  ┌─ src/loom_program.gleam:7:9\n"
    <> "7 │   lsp_sql.Plan(server: \"gopls\")\n"
  assert codemode_pointer.compile_modules(diagnostics, admitted)
    == ["cap/lsp_sql"]
}

pub fn an_import_path_in_a_diagnostic_names_its_module_test() {
  assert codemode_pointer.compile_modules(
      "The module `cap/lsp` does not have a `Foo` value.",
      admitted,
    )
    == ["cap/lsp"]
}

pub fn the_qualified_use_of_a_longer_name_does_not_count_test() {
  // `my_fs.read` and `tools.fs.read` do not use `cap/fs`, and `lsp.` must
  // not be found inside `lsp_sql.`.
  assert codemode_pointer.compile_modules("my_fs.read tools.fs.read", admitted)
    == []
  assert codemode_pointer.compile_modules("lsp_sql.query(", admitted)
    == ["cap/lsp_sql"]
}

pub fn modules_come_in_the_order_they_appear_and_at_most_two_test() {
  assert codemode_pointer.compile_modules(
      "report.string(x) then fs.read(y) then lsp.symbol(z)",
      admitted,
    )
    == ["cap/report", "cap/fs"]
}

pub fn a_diagnostic_about_no_capability_names_nothing_test() {
  assert codemode_pointer.compile_modules(
      "error: Unused variable `count`\n  let count = 1",
      admitted,
    )
    == []
}

pub fn a_module_the_host_does_not_admit_is_never_named_test() {
  assert codemode_pointer.compile_modules("proc.run(x)", admitted) == []
}

pub fn a_stdlib_import_is_never_named_test() {
  assert codemode_pointer.compile_modules("int.parse(x)", admitted) == []
}

pub fn the_failed_calls_name_their_owning_modules_test() {
  let calls =
    log([
      succeeded("fs.read"),
      failed("lsp.snapshot"),
      failed("lsp.snapshot"),
      failed("fs.write"),
    ])
  assert codemode_pointer.failed_call_modules(calls, admitted)
    == ["cap/lsp_sql", "cap/fs"]
}

pub fn a_snapshot_is_lsp_sql_and_every_other_lsp_call_is_lsp_test() {
  assert codemode_pointer.failed_call_modules(
      log([failed("lsp.references")]),
      admitted,
    )
    == ["cap/lsp"]
}

pub fn a_run_with_no_failed_call_names_nothing_test() {
  assert codemode_pointer.failed_call_modules(
      log([succeeded("fs.read")]),
      admitted,
    )
    == []
}

pub fn a_failed_call_of_an_unadmitted_module_names_nothing_test() {
  assert codemode_pointer.failed_call_modules(
      log([failed("net.get")]),
      admitted,
    )
    == []
}

pub fn the_line_is_one_sentence_and_empty_when_nothing_applies_test() {
  assert codemode_pointer.line([]) == ""
  assert codemode_pointer.line(["cap/lsp_sql"])
    == "see fs_read cap://lsp_sql for its types, functions and error helpers"
  assert codemode_pointer.line(["cap/lsp_sql", "cap/lsp", "cap/fs"])
    == "see fs_read cap://lsp_sql and cap://lsp for their types, functions and error helpers"
}

pub fn an_import_path_is_not_found_inside_a_longer_one_test() {
  // `cap/lsp` is the front of `cap/lsp_sql`, and the compiler writes the
  // longer path.
  assert codemode_pointer.compile_modules(
      "The module `cap/lsp_sql` does not have a `Plann` value.",
      admitted,
    )
    == ["cap/lsp_sql"]
}

// --- unknown module values --------------------------------------------------

const allowed = ["cap/proc", "cap/git", "gleam/int", "gleam/string"]

const surfaces = [
  #(
    "cap/proc",
    "### cap/proc\npub fn run(Command) -> Result(Output, ProcError)\n",
  ),
  #(
    "cap/git",
    "### cap/git\npub fn current_branch() -> Result(String, GitError)\n",
  ),
]

fn missing(module: String, value: String) -> String {
  "error: Unknown module value\n   ┌─ src/loom_program.gleam:28:17\n"
  <> "   │\n28 │         <> proc.thing(out.exit_code)\n   │ ^^^\n\n"
  <> "The module `"
  <> module
  <> "` does not have a `"
  <> value
  <> "` value.\n"
}

pub fn a_function_of_another_module_is_named_flatly_test() {
  assert codemode_pointer.suggestions(
      missing("cap/proc", "current_branch"),
      surfaces,
      allowed,
    )
    == ["`current_branch` is in cap/git, not cap/proc"]
}

pub fn a_standard_library_guess_is_marked_unchecked_test() {
  assert codemode_pointer.suggestions(
      missing("cap/proc", "int_to_string"),
      surfaces,
      allowed,
    )
    == ["`int_to_string`: maybe `int.to_string` from gleam/int (unchecked)"]
}

pub fn a_checked_owner_wins_over_a_guess_test() {
  let with_int = [
    #("gleam/int", "pub fn int_to_string(Int) -> String"),
    ..surfaces
  ]
  assert codemode_pointer.suggestions(
      missing("cap/proc", "int_to_string"),
      with_int,
      allowed,
    )
    == ["`int_to_string` is in gleam/int, not cap/proc"]
}

pub fn a_name_with_no_candidate_gets_no_line_test() {
  assert codemode_pointer.suggestions(
      missing("cap/proc", "frobnicate"),
      surfaces,
      allowed,
    )
    == []
  assert codemode_pointer.suggestions(
      missing("cap/proc", "float_to_string"),
      surfaces,
      allowed,
    )
    == []
}

pub fn a_module_the_program_may_not_import_gets_no_line_test() {
  assert codemode_pointer.suggestions(
      missing("cap/runtime", "current_branch"),
      surfaces,
      allowed,
    )
    == []
}

pub fn at_most_three_suggestions_are_made_in_order_test() {
  let diagnostics =
    missing("cap/proc", "int_to_string")
    <> missing("cap/proc", "current_branch")
    <> missing("cap/proc", "string_length")
    <> missing("cap/proc", "string_trim")
  assert codemode_pointer.suggestions(diagnostics, surfaces, allowed)
    == [
      "`int_to_string`: maybe `int.to_string` from gleam/int (unchecked)",
      "`current_branch` is in cap/git, not cap/proc",
      "`string_length`: maybe `string.length` from gleam/string (unchecked)",
    ]
}

pub fn other_diagnostics_get_no_line_test() {
  assert codemode_pointer.suggestions(
      "error: Type mismatch\nExpected Int, got String",
      surfaces,
      allowed,
    )
    == []
}
