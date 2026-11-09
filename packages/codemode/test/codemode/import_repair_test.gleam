//// The import repair reads the compiler's own text, so these tests run over
//// output captured from the pinned Gleam toolchain (1.19.0), with the build
//// root path shortened to `/b`. Every refusal the module promises has a
//// test: an unknown module the compiler cannot suggest, a hint that
//// disagrees with the name, a module the program already imports under an
//// alias, a diagnostic about another file, and output with no missing
//// import at all.

import codemode/import_repair
import codemode/unused_repair.{Rewrite}

const file = "src/loom_program.gleam"

const program =
  "import gleam/io

pub fn main() {
  let n = list.length([1, 2])
  io.println(int.to_string(n) <> string.uppercase(\"x\"))
}
"

const captured =
  "  Compiling loom_codemode_program
error: Unknown module
  ┌─ /b/src/loom_program.gleam:4:11
  │
4 │   let n = list.length([1, 2])
  │           ^^^^

No module has been found with the name `list`.

Hint: Did you mean to import `gleam/list`?

error: Unknown module
  ┌─ /b/src/loom_program.gleam:5:14
  │
5 │   io.println(int.to_string(n) <> string.uppercase(\"x\"))
  │              ^^^

No module has been found with the name `int`.

Hint: Did you mean to import `gleam/int`?

error: Unknown module
  ┌─ /b/src/loom_program.gleam:5:34
  │
5 │   io.println(int.to_string(n) <> string.uppercase(\"x\"))
  │                                  ^^^^^^

No module has been found with the name `string`.

Hint: Did you mean to import `gleam/string`?
"

// Each hinted module is added once, after the last line, in the order the
// compiler named them, so no line the diagnostics name moves.
pub fn hinted_imports_are_appended_in_order_test() {
  assert import_repair.rewrite(program, captured, file)
    == Ok(
      Rewrite(
        source: program
          <> "import gleam/list\nimport gleam/int\nimport gleam/string\n",
        notes: [
          "added missing import gleam/list (line 7)",
          "added missing import gleam/int (line 8)",
          "added missing import gleam/string (line 9)",
        ],
      ),
    )
}

// The same module named at two places is added once.
pub fn a_module_named_twice_is_added_once_test() {
  let twice = captured <> "\n" <> second_int
  let assert Ok(rewrite) = import_repair.rewrite(program, twice, file)

  assert rewrite.notes
    == [
      "added missing import gleam/list (line 7)",
      "added missing import gleam/int (line 8)",
      "added missing import gleam/string (line 9)",
    ]
}

const second_int =
  "error: Unknown module
  ┌─ /b/src/loom_program.gleam:4:3
  │
4 │   int.add(1, 2)
  │   ^^^

No module has been found with the name `int`.

Hint: Did you mean to import `gleam/int`?
"

// A source with no trailing newline gets none added.
pub fn a_source_without_a_final_newline_keeps_none_test() {
  let assert Ok(rewrite) =
    import_repair.rewrite(
      "pub fn main() {\n  int.add(1, 2)\n}",
      second_int,
      file,
    )

  assert rewrite.source
    == "pub fn main() {\n  int.add(1, 2)\n}\nimport gleam/int"
  assert rewrite.notes == ["added missing import gleam/int (line 4)"]
}

// Other diagnostics, such as an unused variable or an error that follows
// from the missing module, are left for the second build.
pub fn other_diagnostics_are_left_alone_test() {
  let mixed = "warning: Unused variable
  ┌─ /b/src/loom_program.gleam:22:11
   │
22 │     Error(e) -> report.text(\"err\")
   │           ^ This variable is never used

Hint: You can ignore it with an underscore: `_e`.

" <> captured <> "
error: Unknown type for record access
  ┌─ /b/src/loom_program.gleam:15:64
   │
15 │   m.path
   │   ^ I don't know what type this is
"
  let assert Ok(rewrite) = import_repair.rewrite(program, mixed, file)

  assert rewrite.notes
    == [
      "added missing import gleam/list (line 7)",
      "added missing import gleam/int (line 8)",
      "added missing import gleam/string (line 9)",
    ]
}

// A name the compiler can suggest no module for leaves nothing to add that
// would make the build pass, so nothing is added at all.
pub fn an_unknown_module_without_a_hint_refuses_test() {
  let unhinted = captured <> "
error: Unknown module
  ┌─ /b/src/loom_program.gleam:2:3
  │
2 │   frobnicate.go(1)
  │   ^^^^^^^^^^

No module has been found with the name `frobnicate`.
"

  assert import_repair.rewrite(program, unhinted, file) == Error(Nil)
}

// Under an alias the compiler still hints the module for a bare use of its
// name, and a second import of it would not compile.
pub fn a_module_imported_under_an_alias_refuses_test() {
  let aliased =
    "import gleam/int as i
pub fn main() {
  int.to_string(i.add(1, 2))
}
"
  let diagnostics =
    "error: Unknown module
  ┌─ /b/src/loom_program.gleam:3:3
  │
3 │   int.to_string(i.add(1, 2))
  │   ^^^

No module has been found with the name `int`.

Hint: Did you mean to import `gleam/int`?
"

  assert import_repair.rewrite(aliased, diagnostics, file) == Error(Nil)
  assert import_repair.rewrite(
      "import gleam/int.{add}\n" <> aliased,
      diagnostics,
      file,
    )
    == Error(Nil)
}

// A hint whose last segment is not the unknown name, or that is not a module
// path, describes another module, and the rewrite refuses.
pub fn a_hint_that_disagrees_refuses_test() {
  let disagrees =
    "error: Unknown module
  ┌─ /b/src/loom_program.gleam:3:3
  │
3 │   int.to_string(1)
  │   ^^^

No module has been found with the name `int`.

Hint: Did you mean to import `gleam/float`?
"
  let not_a_path =
    "error: Unknown module
  ┌─ /b/src/loom_program.gleam:3:3
  │
3 │   int.to_string(1)
  │   ^^^

No module has been found with the name `int`.

Hint: Did you mean to import `gleam/int\nimport evil/int`?
"

  assert import_repair.rewrite(program, disagrees, file) == Error(Nil)
  assert import_repair.rewrite(program, not_a_path, file) == Error(Nil)
}

// A diagnostic about another module is not this program's to fix.
pub fn a_diagnostic_about_another_file_refuses_test() {
  let elsewhere =
    "error: Unknown module
  ┌─ /b/src/other.gleam:3:3
  │
3 │   int.to_string(1)
  │   ^^^

No module has been found with the name `int`.

Hint: Did you mean to import `gleam/int`?
"

  assert import_repair.rewrite(program, elsewhere, file) == Error(Nil)
}

// Output that names no missing import is not a rewrite.
pub fn no_missing_import_is_no_rewrite_test() {
  let arity =
    "error: Incorrect arity
  ┌─ /b/src/loom_program.gleam:6:26
  │
6 │   search.grep(1)
  │   ^^^^^^^^^^^^^^ Expected 2 arguments, got 1
"

  assert import_repair.rewrite(program, arity, file) == Error(Nil)
  assert import_repair.rewrite(program, "", file) == Error(Nil)
}
