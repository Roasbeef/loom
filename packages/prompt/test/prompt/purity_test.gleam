//// Structural guards on the package itself.
////
//// The system prompt's whole value rests on it being byte-identical for
//// a session, and the cheapest way to break that is to reach for a clock
//// — or a file, or an id, or a random value — from inside `src`. These
//// tests read this package's own sources and fail if the reach is even
//// available: no external, no impure dependency, no numeric field on
//// `Environment` for a millisecond to arrive disguised as.
////
//// A test that reads files is not a pure test, but `test/` may import
//// anything and `broker` sets the precedent. `gleam test` runs with the
//// package root as its working directory.

import gleam/list
import gleam/string
import simplifile

// Every module under src, as #(path, code). `code` is the file with its
// comment lines removed: these checks are about what the code does, and
// prose that names a forbidden construct in order to forbid it must not
// trip them.
fn sources() -> List(#(String, String)) {
  let assert Ok(names) = simplifile.read_directory("src/prompt")
  list.map(names, fn(name) {
    let path = "src/prompt/" <> name
    let assert Ok(text) = simplifile.read(path)
    #(path, without_comments(text))
  })
}

fn without_comments(text: String) -> String {
  string.split(text, on: "\n")
  |> list.filter(fn(line) { !string.starts_with(string.trim_start(line), "//") })
  |> string.join("\n")
}

fn import_lines(text: String) -> List(String) {
  string.split(text, on: "\n")
  |> list.filter(string.starts_with(_, "import "))
  |> list.map(fn(line) {
    string.drop_start(line, 7)
    |> string.split_once(on: ".")
    |> fn(split) {
      case split {
        Ok(#(module, _)) -> module
        Error(Nil) -> line |> string.drop_start(7)
      }
    }
    |> string.trim
  })
}

pub fn sources_are_all_read_test() {
  // Guards the guard: a typo in the directory would make every check
  // below pass vacuously over an empty list.
  let paths = list.map(sources(), fn(source) { source.0 })
  assert list.contains(paths, "src/prompt/pack.gleam")
  assert list.contains(paths, "src/prompt/default.gleam")
  assert list.contains(paths, "src/prompt/summary.gleam")
}

pub fn src_imports_only_stdlib_and_core_test() {
  // Purity is structural, not a convention: `prompt` is `core` plus
  // `gleam_stdlib`, so no time source exists in its graph to reach for.
  // A module of this package may of course reach another one.
  list.each(sources(), fn(source) {
    list.each(import_lines(source.1), fn(module) {
      assert string.starts_with(module, "gleam/")
        || string.starts_with(module, "core/")
        || string.starts_with(module, "prompt/")
    })
  })
}

pub fn src_imports_nothing_volatile_test() {
  // The named modules are the ones that would put a clock, an id, a
  // process or a file behind `render`.
  let forbidden = [
    "core/clock", "core/ids", "gleam/time", "gleam/erlang", "gleam/otp",
    "simplifile", "envoy", "gleam/http",
  ]
  list.each(sources(), fn(source) {
    list.each(import_lines(source.1), fn(module) {
      list.each(forbidden, fn(bad) {
        assert !string.starts_with(module, bad)
      })
    })
  })
}

pub fn src_declares_no_externals_test() {
  // FFI confinement: `@external` belongs in `*/internal/ffi_*.gleam`
  // modules, and this package has none and must not grow one.
  list.each(sources(), fn(source) {
    assert !string.contains(source.1, "@external")
  })
}

pub fn src_contains_no_crash_ladder_test() {
  // Spec §0.2: no `panic` or `let assert` outside tests. A pack is
  // decoded from an operator-supplied file; a crash here takes down a
  // session at open.
  list.each(sources(), fn(source) {
    assert !string.contains(source.1, "let assert")
    assert !string.contains(source.1, "panic as")
  })
}

pub fn environment_has_no_numeric_field_test() {
  // The structural half of the stability contract. A timestamp, an
  // elapsed count, a cost and a token total all arrive as an `Int`; the
  // record has none and this is what says so out loud.
  let assert Ok(#(_, after)) =
    string.split_once(pack_source(), on: "pub opaque type Environment {")
  let assert Ok(#(fields, _)) = string.split_once(after, on: "\n}")
  assert !string.contains(fields, "Int")
  assert !string.contains(fields, "Float")
}

pub fn dependencies_are_only_stdlib_and_core_test() {
  let assert Ok(manifest) = simplifile.read("gleam.toml")
  let assert Ok(#(_, after)) = string.split_once(manifest, on: "[dependencies]")
  let assert Ok(#(block, _)) =
    string.split_once(after, on: "[dev_dependencies]")
  let declared =
    string.split(block, on: "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
    |> list.filter_map(string.split_once(_, on: " "))
    |> list.map(fn(pair) { pair.0 })
  assert list.sort(declared, string.compare) == ["core", "gleam_stdlib"]
}

fn pack_source() -> String {
  let assert Ok(text) = simplifile.read("src/prompt/pack.gleam")
  without_comments(text)
}
