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
