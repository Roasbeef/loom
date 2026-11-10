//// The unused repair reads the compiler's own text, so these tests run
//// over output captured from the pinned Gleam toolchain (1.19.0) rather
//// than over a model of it, with the build root path shortened to `/b`.
//// The captured unused-name diagnostics are the compiler's words for a
//// lambda argument, a `use` binding, a `let` binding and a labelled
//// parameter. Every refusal the module promises has a test: another warning
//// beside the unused ones (the transitive-dependency one above all), an
//// error, a cut-off output, an unparseable block, and a warning that
//// disagrees with the source.

import codemode/unused_repair.{Rewrite}
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
    unused_repair.rewrite(program, captured, file)
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
  assert unused_repair.rewrite(
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
  // An unused private function is a real warning this module does not
  // repair: removing code is the model's call.
  let function =
    "warning: Unused private function\n  ┌─ /b/src/loom_program.gleam:3:1\n  │\n"
    <> "3 │ fn helper() { 1 }\n  │ ^^^^^^^^^ This private function is never used\n\n"
    <> "Hint: You can safely remove it.\n\n"
  let diagnostics =
    module_warning(1, "import gleam/int")
    <> function
    <> "error: 2 warnings generated.\n"
  assert unused_repair.rewrite(
      "import gleam/int\n\nfn helper() { 1 }\n",
      diagnostics,
      file,
    )
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
  assert unused_repair.rewrite(
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
  assert unused_repair.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn an_output_that_does_not_account_for_every_warning_refuses_test() {
  // No closing summary: the output was cut, and a cut output cannot prove
  // it listed every warning.
  assert unused_repair.rewrite(
      "import gleam/int\n",
      module_warning(1, "import gleam/int"),
      file,
    )
    == Error(Nil)

  // A summary that counts more warnings than were listed.
  assert unused_repair.rewrite(
      "import gleam/int\n",
      module_warning(1, "import gleam/int") <> "error: 2 warnings generated.\n",
      file,
    )
    == Error(Nil)
}

pub fn text_that_is_not_a_diagnostic_refuses_test() {
  assert unused_repair.rewrite("import gleam/int\n", "", file) == Error(Nil)
  assert unused_repair.rewrite(
      "import gleam/int\n",
      "no diagnostics here",
      file,
    )
    == Error(Nil)
}

pub fn a_warning_that_disagrees_with_the_source_refuses_test() {
  // The echoed line is not the program's line 1.
  assert unused_repair.rewrite(
      "import gleam/float\n",
      module_warning(1, "import gleam/int") <> one_summary,
      file,
    )
    == Error(Nil)

  // The warning names a line the program does not have.
  assert unused_repair.rewrite(
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
  assert unused_repair.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn an_underline_that_misses_its_column_refuses_test() {
  // The location says column 3 and the underline starts at column 1.
  let diagnostics =
    "warning: Unused imported module\n  ┌─ /b/src/loom_program.gleam:1:3\n  │\n"
    <> "1 │ import gleam/int\n  │ ^^^^^^^^^^^^^^^^ This imported module is never used\n\n"
    <> one_summary
  assert unused_repair.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

pub fn an_import_list_split_over_lines_refuses_test() {
  let diagnostics =
    "warning: Unused imported value\n  ┌─ /b/src/loom_program.gleam:2:3\n  │\n"
    <> "2 │   map,\n  │   ^^^ This imported value is never used\n\n"
    <> one_summary
  assert unused_repair.rewrite(
      "import gleam/list.{\n  map,\n  length,\n}\n",
      diagnostics,
      file,
    )
    == Error(Nil)
}

// --- unused arguments and bindings ----------------------------------------

// Each fixture below is the compiler's own diagnostic for one line of the
// program quoted in `padded`, with the line number kept so the location,
// the echo and the program agree. The summary is appended separately.

const lambda_line = "  let _ = list.map([1], fn(e) { \"proc failed\" })"

const lambda_warning =
  "warning: Unused function argument
  ┌─ /b/src/loom_program.gleam:5:28
  │
5 │   let _ = list.map([1], fn(e) { \"proc failed\" })
  │                            ^ This argument is never used

Hint: You can ignore it with an underscore: `_e`.

"

const fold_line = "  let _ = list.fold([1], 0, fn(a, b) { 5 })"

const fold_warnings =
  "warning: Unused function argument
  ┌─ /b/src/loom_program.gleam:6:32
  │
6 │   let _ = list.fold([1], 0, fn(a, b) { 5 })
  │                                ^ This argument is never used

Hint: You can ignore it with an underscore: `_a`.

warning: Unused function argument
  ┌─ /b/src/loom_program.gleam:6:35
  │
6 │   let _ = list.fold([1], 0, fn(a, b) { 5 })
  │                                   ^ This argument is never used

Hint: You can ignore it with an underscore: `_b`.

"

const let_line = "  let count = 1"

const let_warning =
  "warning: Unused variable
  ┌─ /b/src/loom_program.gleam:7:7
  │
7 │   let count = 1
  │       ^^^^^ This variable is never used

Hint: You can ignore it with an underscore: `_count`.

"

const use_line = "    use in20 <- result.try(Ok(1))"

const use_warning =
  "warning: Unused function argument
  ┌─ /b/src/loom_program.gleam:9:9
  │
9 │     use in20 <- result.try(Ok(1))
  │         ^^^^ This argument is never used

Hint: You can ignore it with an underscore: `_in20`.

"

// Captured with Gleam 1.19.0 from a lambda on a `use` line, where the
// unused argument is not the `use` binding.
const use_lambda_line = "  use _ <- result.try(result.map(Ok(1), fn(y) { 1 }))"

const use_lambda_warning =
  "warning: Unused function argument
  ┌─ /b/src/loom_program.gleam:4:44
  │
4 │   use _ <- result.try(result.map(Ok(1), fn(y) { 1 }))
  │                                            ^ This argument is never used

Hint: You can ignore it with an underscore: `_y`.

"

const label_line = "pub fn labelled(label name: Int) -> Int {"

const label_warning =
  "warning: Unused function argument
   ┌─ /b/src/loom_program.gleam:16:23
   │
16 │ pub fn labelled(label name: Int) -> Int {
   │                       ^^^^ This argument is never used

Hint: You can ignore it with an underscore: `_name`.

"

const binding_suffix =
  "; nothing reads it, so a value the program meant to return may be missing"

// `line` as line `number` of a program whose other lines are blank.
fn padded(number: Int, line: String) -> String {
  string.repeat("\n", number - 1) <> line <> "\n"
}

pub fn an_unused_lambda_argument_is_underscored_test() {
  assert unused_repair.rewrite(
      padded(5, lambda_line),
      lambda_warning <> one_summary,
      file,
    )
    == Ok(
      Rewrite(
        source: padded(5, "  let _ = list.map([1], fn(_e) { \"proc failed\" })"),
        notes: ["renamed unused argument e to _e (line 5)"],
      ),
    )
}

pub fn an_unused_use_binding_is_underscored_with_a_warning_test() {
  // The compiler files an unused `use` binding under the argument title;
  // the note tells it apart by the `use` in the source line.
  assert unused_repair.rewrite(
      padded(9, use_line),
      use_warning <> one_summary,
      file,
    )
    == Ok(
      Rewrite(source: padded(9, "    use _in20 <- result.try(Ok(1))"), notes: [
        "renamed unused binding in20 to _in20 (line 9)" <> binding_suffix,
      ]),
    )
}

pub fn a_lambda_argument_on_a_use_line_is_an_argument_not_a_binding_test() {
  assert unused_repair.rewrite(
      padded(4, use_lambda_line),
      use_lambda_warning <> one_summary,
      file,
    )
    == Ok(
      Rewrite(
        source: padded(
          4,
          "  use _ <- result.try(result.map(Ok(1), fn(_y) { 1 }))",
        ),
        notes: ["renamed unused argument y to _y (line 4)"],
      ),
    )
}

pub fn an_unused_let_binding_is_underscored_with_a_warning_test() {
  assert unused_repair.rewrite(
      padded(7, let_line),
      let_warning <> one_summary,
      file,
    )
    == Ok(
      Rewrite(source: padded(7, "  let _count = 1"), notes: [
        "renamed unused binding count to _count (line 7)" <> binding_suffix,
      ]),
    )
}

pub fn a_labelled_parameter_is_renamed_and_its_label_kept_test() {
  assert unused_repair.rewrite(
      padded(16, label_line),
      label_warning <> one_summary,
      file,
    )
    == Ok(
      Rewrite(
        source: padded(16, "pub fn labelled(label _name: Int) -> Int {"),
        notes: ["renamed unused argument name to _name (line 16)"],
      ),
    )
}

pub fn two_unused_arguments_on_one_line_are_both_underscored_test() {
  // Applied right to left, so the second column is still right after the
  // first insertion has widened the line.
  assert unused_repair.rewrite(
      padded(6, fold_line),
      fold_warnings <> "error: 2 warnings generated.\n",
      file,
    )
    == Ok(
      Rewrite(
        source: padded(6, "  let _ = list.fold([1], 0, fn(_a, _b) { 5 })"),
        notes: [
          "renamed unused argument a to _a (line 6)",
          "renamed unused argument b to _b (line 6)",
        ],
      ),
    )
}

pub fn an_unused_import_and_unused_names_are_repaired_together_test() {
  let source = "import gleam/int\n\n\n\n" <> lambda_line <> "\n"
  let diagnostics =
    module_warning(1, "import gleam/int")
    <> lambda_warning
    <> "error: 2 warnings generated.\n"
  assert unused_repair.rewrite(source, diagnostics, file)
    == Ok(
      Rewrite(
        source: "\n\n\n  let _ = list.map([1], fn(_e) { \"proc failed\" })\n",
        notes: [
          "removed unused import gleam/int (line 1)",
          "renamed unused argument e to _e (line 5)",
        ],
      ),
    )
}

pub fn every_captured_name_in_one_build_is_repaired_in_source_order_test() {
  let source =
    "\n\n\n\n"
    <> lambda_line
    <> "\n"
    <> fold_line
    <> "\n"
    <> let_line
    <> "\n\n"
    <> use_line
    <> "\n"
  let diagnostics =
    lambda_warning
    <> fold_warnings
    <> let_warning
    <> use_warning
    <> "error: 5 warnings generated.\n"
  let assert Ok(Rewrite(source: repaired, notes:)) =
    unused_repair.rewrite(source, diagnostics, file)
  assert string.contains(repaired, "fn(_e)")
  assert string.contains(repaired, "fn(_a, _b)")
  assert string.contains(repaired, "let _count = 1")
  assert string.contains(repaired, "use _in20 <-")
  assert notes
    == [
      "renamed unused argument e to _e (line 5)",
      "renamed unused argument a to _a (line 6)",
      "renamed unused argument b to _b (line 6)",
      "renamed unused binding count to _count (line 7)" <> binding_suffix,
      "renamed unused binding in20 to _in20 (line 9)" <> binding_suffix,
    ]
}

pub fn an_unused_argument_beside_a_type_error_refuses_test() {
  let diagnostics =
    lambda_warning
    <> "error: Type mismatch\n  ┌─ /b/src/loom_program.gleam:6:3\n  │\n"
    <> "6 │   1 + \"a\"\n  │       ^^^ Expected Int, got String\n\n"
    <> "error: 1 warning generated.\n"
  assert unused_repair.rewrite(padded(5, lambda_line), diagnostics, file)
    == Error(Nil)
}

pub fn an_unused_argument_beside_a_transitive_dependency_warning_refuses_test() {
  let transitive =
    "warning: Transitive dependency imported\n  ┌─ /b/src/loom_program.gleam:1:1\n  │\n"
    <> "1 │ import gleam/erlang/process\n  │ ^^^^^^^^^^^^^^^^^^^^^^^^^^^ This imported module is from a transitive dependency\n\n"
  assert unused_repair.rewrite(
      "import gleam/erlang/process\n\n\n\n" <> lambda_line <> "\n",
      transitive <> lambda_warning <> "error: 2 warnings generated.\n",
      file,
    )
    == Error(Nil)
}

pub fn an_echoed_line_that_disagrees_with_the_source_refuses_test() {
  // Same column, different text: the program is not what was compiled.
  assert unused_repair.rewrite(
      padded(5, "  let _ = list.map([1], fn(f) { \"proc failed\" })"),
      lambda_warning <> one_summary,
      file,
    )
    == Error(Nil)
}

pub fn a_hint_that_names_something_else_refuses_test() {
  // The underline covers `e` and the hint offers `_x`.
  let diagnostics =
    string.replace(lambda_warning, "`_e`", "`_x`") <> one_summary
  assert unused_repair.rewrite(padded(5, lambda_line), diagnostics, file)
    == Error(Nil)
}

pub fn a_rename_warning_without_a_hint_refuses_test() {
  let diagnostics =
    string.replace(
      lambda_warning,
      "Hint: You can ignore it with an underscore: `_e`.\n\n",
      "",
    )
    <> one_summary
  assert unused_repair.rewrite(padded(5, lambda_line), diagnostics, file)
    == Error(Nil)
}

pub fn two_warnings_at_one_column_refuse_test() {
  // A repeated warning would otherwise insert the underscore twice.
  assert unused_repair.rewrite(
      padded(5, lambda_line),
      lambda_warning <> lambda_warning <> "error: 2 warnings generated.\n",
      file,
    )
    == Error(Nil)
}

pub fn a_rename_underline_that_misses_its_column_refuses_test() {
  // The location says column 29 and the underline starts at column 28.
  let diagnostics =
    string.replace(lambda_warning, ".gleam:5:28", ".gleam:5:29") <> one_summary
  assert unused_repair.rewrite(padded(5, lambda_line), diagnostics, file)
    == Error(Nil)
}

pub fn an_underline_with_no_text_under_it_refuses_test() {
  // The underline starts past the end of the echoed line, so it names no
  // text and the empty hinted name must not match it.
  let diagnostics =
    "warning: Unused variable\n  ┌─ /b/src/loom_program.gleam:1:5\n  │\n"
    <> "1 │ 1\n  │     ^ This variable is never used\n\n"
    <> "Hint: You can ignore it with an underscore: `_`.\n\n"
    <> one_summary
  assert unused_repair.rewrite("1\n", diagnostics, file) == Error(Nil)
}

pub fn a_rename_and_an_import_warning_on_one_line_refuse_test() {
  // Both warnings echo the same import line, so only the mixing refuses.
  let diagnostics =
    module_warning(1, "import gleam/int")
    <> "warning: Unused function argument\n  ┌─ /b/src/loom_program.gleam:1:8\n  │\n"
    <> "1 │ import gleam/int\n  │        ^^^^^ This argument is never used\n\n"
    <> "Hint: You can ignore it with an underscore: `_gleam`.\n\n"
    <> "error: 2 warnings generated.\n"
  assert unused_repair.rewrite("import gleam/int\n", diagnostics, file)
    == Error(Nil)
}

// --- pattern variables beside a real error ----------------------------------

// Captured with Gleam 1.19.0 from the program below: a `let`, a clause
// pattern, an alternative pattern and two clauses on one line, all unused,
// beside a type error. An erroring build prints no `N warnings generated`
// summary, so `rewrite` cannot account for the list and refuses it.
const mixed_program =
  "import gleam/int

pub fn main() {
  let unused = 1
  case int.parse(\"1\") {
    Ok(n) -> n
    Error(e) -> 0
  }
}

pub fn alt(r: Result(Int, Int)) -> Int {
  case r {
    Ok(x) | Error(x) -> 1
  }
}

pub fn bad() -> Int {
  1 + \"a\"
}

pub fn two(r: Result(Int, String)) -> Int {
  case r { Error(msg) -> 0 Ok(v) -> 1 }
}
"

const mixed_diagnostics =
  "  Compiling loom_codemode_program
warning: Unused variable
  ┌─ /b/src/loom_program.gleam:4:7
  │
4 │   let unused = 1
  │       ^^^^^^ This variable is never used

Hint: You can ignore it with an underscore: `_unused`.

warning: Unused variable
  ┌─ /b/src/loom_program.gleam:7:11
  │
7 │     Error(e) -> 0
  │           ^ This variable is never used

Hint: You can ignore it with an underscore: `_e`.

warning: Unused variable
   ┌─ /b/src/loom_program.gleam:13:8
   │
13 │     Ok(x) | Error(x) -> 1
   │        ^ This variable is never used

Hint: You can ignore it with an underscore: `_x`.

warning: Unused variable
   ┌─ /b/src/loom_program.gleam:22:18
   │
22 │   case r { Error(msg) -> 0 Ok(v) -> 1 }
   │                  ^^^ This variable is never used

Hint: You can ignore it with an underscore: `_msg`.

warning: Unused variable
   ┌─ /b/src/loom_program.gleam:22:31
   │
22 │   case r { Error(msg) -> 0 Ok(v) -> 1 }
   │                               ^ This variable is never used

Hint: You can ignore it with an underscore: `_v`.

error: Type mismatch
   ┌─ /b/src/loom_program.gleam:18:7
   │
18 │   1 + \"a\"
   │       ^^^

The + operator expects arguments of this type:

    Int

But this argument has this type:

    String

Hint: Strings can be joined using the `<>` operator.
"

pub fn the_whole_rewrite_still_refuses_the_mixed_build_test() {
  assert unused_repair.rewrite(mixed_program, mixed_diagnostics, file)
    == Error(Nil)
}

pub fn an_unused_clause_pattern_variable_beside_an_error_is_underscored_test() {
  let assert Ok(Rewrite(source: repaired, notes:)) =
    unused_repair.rewrite_patterns(mixed_program, mixed_diagnostics, file)
    as "the clause pattern variables must be repaired beside the error"

  // Exactly the two variables that are provably a clause's: the first
  // clause on its line each. The `let`, the alternative pattern, the second
  // clause on a line and the error line itself are untouched.
  assert repaired
    == string.replace(mixed_program, "Error(e) -> 0", "Error(_e) -> 0")
    |> string.replace("{ Error(msg) -> 0", "{ Error(_msg) -> 0")
  assert notes
    == [
      "renamed unused pattern variable e to _e (line 7)",
      "renamed unused pattern variable msg to _msg (line 22)",
    ]
}

pub fn repairing_the_repaired_source_again_is_refused_test() {
  let assert Ok(Rewrite(source: repaired, notes: _)) =
    unused_repair.rewrite_patterns(mixed_program, mixed_diagnostics, file)
    as "the first repair must succeed"

  // The stale diagnostics echo the old line, which the new one no longer is.
  assert unused_repair.rewrite_patterns(repaired, mixed_diagnostics, file)
    == Error(Nil)
}

pub fn a_let_and_an_alternative_pattern_alone_are_not_repaired_beside_an_error_test() {
  // The same output with the two clause-pattern warnings cut out, leaving
  // the `let`, the alternative pattern and the second clause on a line.
  let kept =
    string.replace(
      mixed_diagnostics,
      "warning: Unused variable
  ┌─ /b/src/loom_program.gleam:7:11
  │
7 │     Error(e) -> 0
  │           ^ This variable is never used

Hint: You can ignore it with an underscore: `_e`.

",
      "",
    )
    |> string.replace(
      "warning: Unused variable
   ┌─ /b/src/loom_program.gleam:22:18
   │
22 │   case r { Error(msg) -> 0 Ok(v) -> 1 }
   │                  ^^^ This variable is never used

Hint: You can ignore it with an underscore: `_msg`.

",
      "",
    )
  assert unused_repair.rewrite_patterns(mixed_program, kept, file) == Error(Nil)
}

pub fn a_build_with_no_unused_variable_is_not_repaired_as_patterns_test() {
  let diagnostics =
    "error: Type mismatch\n  ┌─ /b/src/loom_program.gleam:18:7\n  │\n"
    <> "18 │   1 + \"a\"\n  │       ^^^\n\nHint: Strings can be joined using the `<>` operator.\n"
  assert unused_repair.rewrite_patterns(mixed_program, diagnostics, file)
    == Error(Nil)
}

pub fn a_pattern_warning_about_another_module_is_not_repaired_test() {
  assert unused_repair.rewrite_patterns(
      mixed_program,
      mixed_diagnostics,
      "src/other.gleam",
    )
    == Error(Nil)
}

pub fn a_pattern_warning_that_disagrees_with_the_source_refuses_test() {
  // The program is not what was compiled: the line differs at the column.
  assert unused_repair.rewrite_patterns(
      string.replace(mixed_program, "Error(e) -> 0", "Error(e) -> 1"),
      mixed_diagnostics,
      file,
    )
    == Error(Nil)
}

pub fn a_clean_build_pattern_variable_is_noted_as_a_pattern_variable_test() {
  // Alone, the warning is the whole build and `rewrite` takes it, now with
  // a note that names what it was.
  let diagnostics =
    "warning: Unused variable\n  ┌─ /b/src/loom_program.gleam:2:11\n  │\n"
    <> "2 │     Error(e) -> 0\n  │           ^ This variable is never used\n\n"
    <> "Hint: You can ignore it with an underscore: `_e`.\n\n"
    <> "error: 1 warning generated.\n"
  assert unused_repair.rewrite("\n    Error(e) -> 0\n", diagnostics, file)
    == Ok(
      Rewrite(source: "\n    Error(_e) -> 0\n", notes: [
        "renamed unused pattern variable e to _e (line 2)",
      ]),
    )
}
