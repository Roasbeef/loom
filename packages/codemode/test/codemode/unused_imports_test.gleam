//// Unused-import removal reads the compiler's own text, so these tests run
//// over output captured from the pinned Gleam toolchain (1.19.0) rather
//// than over a model of it, with the build root path shortened to `/b`.
//// Every refusal the module promises has a test: another warning beside the
//// unused imports (the transitive-dependency one above all), an error, a
//// cut-off output, an unparseable block, and a warning that disagrees with
//// the source.

import codemode/unused_imports.{Rewrite}
import gleam/string

const file = "src/loom_program.gleam"

// A program with one of each kind of unused import, in the order the
// compiler reported them.
const program =
  "import gleam/int
import gleam/list.{map, filter as keep, length}
import gleam/option.{type Option, None, Some}
import gleam/string as str
import gleam/float

pub fn main() {
  let _ = Some(1)
  length([1])
}
"

const captured =
  "  Compiling loom_codemode_program
warning: Unused imported module
  ┌─ /b/src/loom_program.gleam:1:1
  │
1 │ import gleam/int
  │ ^^^^^^^^^^^^^^^^ This imported module is never used

Hint: You can safely remove it.

warning: Unused imported value
  ┌─ /b/src/loom_program.gleam:2:20
  │
2 │ import gleam/list.{map, filter as keep, length}
  │                    ^^^ This imported value is never used

Hint: You can safely remove it.

warning: Unused imported value
  ┌─ /b/src/loom_program.gleam:2:25
  │
2 │ import gleam/list.{map, filter as keep, length}
  │                         ^^^^^^^^^^^^^^ This imported value is never used

Hint: You can safely remove it.

warning: Unused imported type
  ┌─ /b/src/loom_program.gleam:3:22
  │
3 │ import gleam/option.{type Option, None, Some}
  │                      ^^^^^^^^^^^ This imported type is never used

Hint: You can safely remove it.

warning: Unused imported item
  ┌─ /b/src/loom_program.gleam:3:35
  │
3 │ import gleam/option.{type Option, None, Some}
  │                                   ^^^^ This imported constructor is never used

Hint: You can safely remove it.

warning: Unused imported module
  ┌─ /b/src/loom_program.gleam:4:1
  │
4 │ import gleam/string as str
  │ ^^^^^^^^^^^^^^^^^^^^^^^^^^ This imported module is never used

Hint: You can safely remove it.

warning: Unused imported module
  ┌─ /b/src/loom_program.gleam:5:1
  │
5 │ import gleam/float
  │ ^^^^^^^^^^^^^^^^^^ This imported module is never used

Hint: You can safely remove it.

error: 7 warnings generated.

Your project was compiled with the `--warnings-as-errors` flag.
Fix the warnings and try again."

fn module_warning(line: Int, source: String) -> String {
  "warning: Unused imported module\n  ┌─ /b/src/loom_program.gleam:"
  <> string.inspect(line)
  <> ":1\n  │\n"
  <> string.inspect(line)
  <> " │ "
  <> source
  <> "\n  │ "
  <> string.repeat("^", string.length(source))
  <> " This imported module is never used\n\nHint: You can safely remove it.\n\n"
}

const one_summary =
  "error: 1 warning generated.\n\nYour project was compiled with the `--warnings-as-errors` flag.\n"

pub fn every_kind_of_unused_import_is_removed_test() {
  let assert Ok(Rewrite(source:, notes:)) =
    unused_imports.rewrite(program, captured, file)
  assert source == "import gleam/list.{length}
import gleam/option.{Some}

pub fn main() {
  let _ = Some(1)
  length([1])
}
"
  assert notes
    == [
      "removed unused import gleam/int (line 1)",
      "removed unused import gleam/list.{map} (line 2)",
      "removed unused import gleam/list.{filter as keep} (line 2)",
      "removed unused import gleam/option.{type Option} (line 3)",
      "removed unused import gleam/option.{None} (line 3)",
      "removed unused import gleam/string as str (line 4)",
      "removed unused import gleam/float (line 5)",
    ]
}

pub fn emptying_a_list_drops_its_braces_and_keeps_the_module_alias_test() {
  let diagnostics =
    "warning: Unused imported value\n  ┌─ /b/src/loom_program.gleam:1:20\n  │\n"
    <> "1 │ import gleam/list.{map} as l\n  │                    ^^^ This imported value is never used\n\n"
    <> one_summary
  assert unused_imports.rewrite(
      "import gleam/list.{map} as l\n",
      diagnostics,
      file,
    )
    == Ok(
      Rewrite(source: "import gleam/list as l\n", notes: [
        "removed unused import gleam/list.{map} (line 1)",
      ]),
    )
}

pub fn another_warning_beside_the_imports_refuses_everything_test() {
  // An unused variable is not the compiler naming an import.
  let variable =
    "warning: Unused variable\n  ┌─ /b/src/loom_program.gleam:6:7\n  │\n"
    <> "6 │   let count = 1\n  │       ^^^^^ This variable is never used\n\n"
  let diagnostics =
    module_warning(1, "import gleam/int")
    <> variable
    <> "error: 2 warnings generated.\n"
  assert unused_imports.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn the_transitive_dependency_warning_is_never_rewritten_away_test() {
  // This warning is what closes `gleam/erlang/*` and `core/*` at the
  // compiler. It stays an error even beside an unused import.
  let transitive =
    "warning: Transitive dependency imported\n  ┌─ /b/src/loom_program.gleam:2:1\n  │\n"
    <> "2 │ import gleam/erlang/process\n  │ ^^^^^^^^^^^^^^^^^^^^^^^^^^^ This imported module is from a transitive dependency\n\n"
  let diagnostics =
    module_warning(1, "import gleam/int")
    <> transitive
    <> "error: 2 warnings generated.\n"
  assert unused_imports.rewrite(
      "import gleam/int\nimport gleam/erlang/process\n",
      diagnostics,
      file,
    )
    == Error(Nil)
}

pub fn a_compile_error_refuses_the_rewrite_test() {
  let diagnostics =
    module_warning(1, "import gleam/int")
    <> "error: Unknown variable\n  ┌─ /b/src/loom_program.gleam:4:3\n  │\n"
    <> "4 │   x\n  │   ^ Did you mean `y`?\n\n"
    <> "error: 1 warning generated.\n"
  assert unused_imports.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn an_output_that_does_not_account_for_every_warning_refuses_test() {
  // No closing summary: the output was cut, and a cut output cannot prove
  // it listed every warning.
  assert unused_imports.rewrite(
      "import gleam/int\n",
      module_warning(1, "import gleam/int"),
      file,
    )
    == Error(Nil)

  // A summary that counts more warnings than were listed.
  assert unused_imports.rewrite(
      "import gleam/int\n",
      module_warning(1, "import gleam/int") <> "error: 2 warnings generated.\n",
      file,
    )
    == Error(Nil)
}

pub fn text_that_is_not_a_diagnostic_refuses_test() {
  assert unused_imports.rewrite("import gleam/int\n", "", file) == Error(Nil)
  assert unused_imports.rewrite(
      "import gleam/int\n",
      "no diagnostics here",
      file,
    )
    == Error(Nil)
}

pub fn a_warning_that_disagrees_with_the_source_refuses_test() {
  // The echoed line is not the program's line 1.
  assert unused_imports.rewrite(
      "import gleam/float\n",
      module_warning(1, "import gleam/int") <> one_summary,
      file,
    )
    == Error(Nil)

  // The warning names a line the program does not have.
  assert unused_imports.rewrite(
      "import gleam/int\n",
      module_warning(9, "import gleam/int") <> one_summary,
      file,
    )
    == Error(Nil)
}

pub fn a_warning_about_another_module_refuses_test() {
  let diagnostics =
    "warning: Unused imported module\n  ┌─ /b/src/loom_satellite.gleam:1:1\n  │\n"
    <> "1 │ import gleam/int\n  │ ^^^^^^^^^^^^^^^^ This imported module is never used\n\n"
    <> one_summary
  assert unused_imports.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn an_underline_that_misses_its_column_refuses_test() {
  // The location says column 3 and the underline starts at column 1.
  let diagnostics =
    "warning: Unused imported module\n  ┌─ /b/src/loom_program.gleam:1:3\n  │\n"
    <> "1 │ import gleam/int\n  │ ^^^^^^^^^^^^^^^^ This imported module is never used\n\n"
    <> one_summary
  assert unused_imports.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn an_import_list_split_over_lines_refuses_test() {
  let diagnostics =
    "warning: Unused imported value\n  ┌─ /b/src/loom_program.gleam:2:3\n  │\n"
    <> "2 │   map,\n  │   ^^^ This imported value is never used\n\n"
    <> one_summary
  assert unused_imports.rewrite(
      "import gleam/list.{\n  map,\n  length,\n}\n",
      diagnostics,
      file,
    )
    == Error(Nil)
}
