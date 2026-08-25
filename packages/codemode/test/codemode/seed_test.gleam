//// Seed tests: the layout a hermetic build is cloned from, and the check
//// that refuses a seed which would silently build against something other
//// than what the compile service pinned. Filling the seed's `build/` is an
//// online `gleam build` and belongs to `scripts/codemode_seed.sh`; what is
//// tested here is everything either side of it.

import codemode/compile
import codemode/seed
import gleam/string
import simplifile

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let dir = here <> "/build/cmtest/seed-" <> name
  let _cleared = simplifile.delete(dir)
  dir
}

fn lay_out(dir: String) -> Result(Nil, String) {
  seed.prepare(
    root: dir,
    vendored: seed.default_vendored(),
    dependencies: compile.default_dependencies(),
  )
}

pub fn prepare_writes_the_compile_services_own_project_file_test() {
  let dir = fresh_dir("layout")
  assert lay_out(dir) == Ok(Nil)
  let assert Ok(project) = simplifile.read(dir <> "/gleam.toml")
  // Byte-identical, not merely equivalent: this is the file the builder
  // compares against before it will run offline.
  assert project == compile.project_toml(compile.default_dependencies())
}

pub fn prepare_vendors_the_prelude_and_its_local_dependency_test() {
  let dir = fresh_dir("vendor")
  assert lay_out(dir) == Ok(Nil)
  // The prelude sits where the generated project file points, and `core`
  // beside it — `cap`'s own `gleam.toml` names it as `../core`, which only
  // resolves once both are vendored.
  assert simplifile.is_file(dir <> "/" <> compile.prelude_path <> "/gleam.toml")
    == Ok(True)
  assert simplifile.is_file(
      dir <> "/" <> compile.prelude_path <> "/src/cap/runtime.gleam",
    )
    == Ok(True)
  assert simplifile.is_file(dir <> "/vendor/core/gleam.toml") == Ok(True)
  // A dependency's own build artifacts belong to a different project root
  // and must not come along.
  assert simplifile.is_directory(dir <> "/" <> compile.prelude_path <> "/build")
    != Ok(True)
}

pub fn prepare_writes_the_generated_entry_verbatim_test() {
  let dir = fresh_dir("entry")
  assert lay_out(dir) == Ok(Nil)
  let assert Ok(entry) =
    simplifile.read(dir <> "/src/" <> compile.entry_module <> ".gleam")
  // The seed is built with the same entry every build root gets, so the
  // seed's compiled prelude is the one the real entry links against.
  assert entry == compile.entry_source()
}

pub fn an_unbuilt_seed_is_refused_test() {
  let dir = fresh_dir("unbuilt")
  assert lay_out(dir) == Ok(Nil)
  // Laid out but never built: no resolved manifest, no package cache. A
  // build against it would re-resolve, and re-resolution needs the network
  // the jail does not have.
  let assert Error(reason) = seed.verify(dir, compile.default_dependencies())
  assert string.contains(reason, "manifest.toml")
  assert string.contains(reason, "make codemode-seed")
}

pub fn a_seed_pinned_to_other_dependencies_is_refused_test() {
  let dir = fresh_dir("mismatch")
  assert lay_out(dir) == Ok(Nil)
  let assert Ok(Nil) =
    simplifile.write(to: dir <> "/manifest.toml", contents: "packages = []\n")
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/build/packages")
  let assert Ok(Nil) =
    simplifile.write(
      to: dir <> "/build/packages/packages.toml",
      contents: "[packages]\n",
    )
  // Everything a built seed has — but resolved from a different dependency
  // table, so its cache pins something other than what the compile service
  // says it pins.
  let other = [
    compile.HexDependency(name: "gleam_stdlib", requirement: "1.0.4"),
    compile.PathDependency(name: "cap", path: compile.prelude_path),
  ]
  let assert Ok(Nil) =
    simplifile.write(
      to: dir <> "/gleam.toml",
      contents: compile.project_toml(other),
    )
  let assert Error(reason) = seed.verify(dir, compile.default_dependencies())
  assert string.contains(reason, "different dependency table")
}

pub fn a_missing_seed_names_the_command_that_makes_one_test() {
  let assert Error(reason) =
    seed.verify("/nonexistent/codemode-seed", compile.default_dependencies())
  assert string.contains(reason, "make codemode-seed")
}
