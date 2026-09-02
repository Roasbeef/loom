//// Vetting a package rather than a program: which files may be installed,
//// what the project file may name, and how an intra-package import is
//// judged.
////
//// The sources here are inline rather than fixture directories. The
//// fixture extensions live beside the install pipeline that consumes them
//// (`packages/client/test/fixtures/extensions`); what is being pinned here
//// is the *rule*, and a rule reads better next to the one-line source that
//// breaks it.

import codemode/vet
import codemode/vet/package
import codemode/vet/policy
import gleam/list
import gleam/string

// A minimal well-formed extension package: a project file naming only
// permitted dependencies, and one module importing the prelude.
fn good_files() -> List(#(String, String)) {
  [
    #("extension.toml", "[extension]\nname = \"weather\"\n"),
    #(
      "gleam.toml",
      "name = \"weather\"\nversion = \"0.1.0\"\n\n"
        <> "[dependencies]\ngleam_stdlib = \">= 1.0.0\"\next = { path = \"x\" }\n",
    ),
    #("schema/weather.json", "{}"),
    #("README.md", "# weather\n"),
    #("src/weather/forecast.gleam", forecast_source()),
    #("src/weather/units.gleam", "pub fn label() -> String {\n  \"C\"\n}\n"),
  ]
}

fn forecast_source() -> String {
  "import ext
import weather/units

pub fn run() -> String {
  units.label()
}

pub fn describe() -> ext.Terminate {
  ext.ContinueRun
}
"
}

fn vet_good() -> Result(
  package.VettedPackage,
  List(#(String, package.Rejection)),
) {
  package.vet_package(good_files(), policy.extension())
}

// --- the happy path -------------------------------------------------------

pub fn a_well_formed_package_passes_test() {
  let assert Ok(vetted) = vet_good() as "the fixture package must vet"
  assert package.module_names(vetted) == ["weather/forecast", "weather/units"]
}

/// The modules come back in a deterministic order, because the build root
/// is written from them and an artifact's content address must not depend
/// on the order an archive happened to list its files in.
pub fn the_modules_are_sorted_test() {
  let shuffled =
    list.reverse(good_files())
    |> package.vet_package(policy.extension())
  let assert Ok(vetted) = shuffled as "file order must not decide the outcome"
  assert package.module_names(vetted) == ["weather/forecast", "weather/units"]
}

// --- layout ---------------------------------------------------------------

/// The refusal that motivates the whole layout check. Gleam compiles a
/// native module found under `src/` and links it into the artifact, so an
/// `.erl` there is `@external` with the declaration moved out of the
/// source the lint reads.
pub fn a_native_file_under_src_is_refused_test() {
  let files = [#("src/weather/nif.erl", "-module(nif).\n"), ..good_files()]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "a native module under src/ must refuse the package"
  assert names_file(refusals, "src/weather/nif.erl")
  assert reason_for(refusals, "src/weather/nif.erl") |> string.contains("src/")
}

pub fn a_test_directory_is_refused_test() {
  let files = [
    #("test/weather_test.gleam", "pub fn main() { 1 }\n"),
    ..good_files()
  ]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "test/ must refuse the package"
  assert names_file(refusals, "test/weather_test.gleam")
}

pub fn a_file_outside_the_layout_is_refused_test() {
  let files = [#("Makefile", "all:\n"), ..good_files()]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "an unexpected file must refuse the package"
  assert names_file(refusals, "Makefile")
}

pub fn schema_and_skills_are_admitted_test() {
  let files = [
    #("skills/weather/SKILL.md", "# weather\n"),
    #("LICENSE", "MIT\n"),
    ..good_files()
  ]
  assert is_ok(package.vet_package(files, policy.extension()))
}

/// A module named for one the seam already allows would be compiled under
/// that name and a sibling's import would resolve to it. Refused by name,
/// before the intra-package widening can make it look legitimate.
pub fn a_module_shadowing_the_prelude_is_refused_test() {
  let files = [
    #("src/cap/fs.gleam", "pub fn read(p: String) { p }\n"),
    ..good_files()
  ]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "a module shadowing cap/fs must refuse the package"
  assert reason_for(refusals, "src/cap/fs.gleam") |> string.contains("shadow")
}

// --- the project file -----------------------------------------------------

pub fn a_forbidden_dependency_is_refused_test() {
  let files =
    replace(
      good_files(),
      "gleam.toml",
      "name = \"w\"\n\n[dependencies]\nsimplifile = \">= 2.0.0\"\n",
    )
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "a dependency the jail does not provide must refuse the package"
  assert reason_for(refusals, "gleam.toml")
    |> string.contains("simplifile")
}

pub fn an_unknown_project_key_is_refused_test() {
  let files =
    replace(
      good_files(),
      "gleam.toml",
      "name = \"w\"\nerlang = { application_start_module = \"x\" }\n",
    )
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "an unknown gleam.toml key must refuse the package"
  assert reason_for(refusals, "gleam.toml") |> string.contains("erlang")
}

pub fn a_missing_project_file_is_refused_test() {
  let files = list.filter(good_files(), fn(file) { file.0 != "gleam.toml" })
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "a package without a gleam.toml is not a package"
  assert names_file(refusals, "gleam.toml")
}

pub fn dev_dependencies_are_ignored_test() {
  let files =
    replace(
      good_files(),
      "gleam.toml",
      "name = \"w\"\n\n[dependencies]\next = { path = \"x\" }\n\n"
        <> "[dev_dependencies]\ngleeunit = \">= 1.0.0\"\n",
    )
  assert is_ok(package.vet_package(files, policy.extension()))
}

// --- the modules ----------------------------------------------------------

pub fn a_foreign_interface_refuses_its_own_file_test() {
  let files = [
    #(
      "src/weather/nif.gleam",
      "@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String\n",
    ),
    ..good_files()
  ]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "an @external must refuse the package"
  let assert Ok(#(_path, package.SourceRejected(rejection:))) =
    find(refusals, "src/weather/nif.gleam")
    as "the refusal must be charged to the source lint"
  assert rejection.rule == vet.NoForeignInterface
}

pub fn a_forbidden_import_refuses_its_own_file_test() {
  let files = [
    #(
      "src/weather/spawn.gleam",
      "import gleam/erlang/process\npub fn go() { process.self() }\n",
    ),
    ..good_files()
  ]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "gleam/erlang/process must refuse the package"
  assert names_file(refusals, "src/weather/spawn.gleam")
}

/// The widening is by the package's own module names and *exactly* those,
/// so a sibling that does not exist is refused here rather than at the
/// compiler — which is the difference between a vetting refusal naming the
/// import and a build failure naming a missing module.
pub fn an_import_of_an_absent_sibling_is_refused_test() {
  let files = [
    #(
      "src/weather/lookup.gleam",
      "import weather/absent\npub fn go() { absent.x() }\n",
    ),
    ..good_files()
  ]
  let assert Error(refusals) = package.vet_package(files, policy.extension())
    as "an import of a module the package does not ship must be refused"
  assert reason_for(refusals, "src/weather/lookup.gleam")
    |> string.contains("weather/absent")
}

/// The seam is an argument, not a constant: the same package judged
/// against the workspace seam is refused for importing `ext`.
pub fn the_seam_decides_test() {
  let assert Error(refusals) =
    package.vet_package(good_files(), policy.default())
    as "an extension must not vet against the workspace seam"
  assert reason_for(refusals, "src/weather/forecast.gleam")
    |> string.contains("ext")
}

// --- helpers --------------------------------------------------------------

fn is_ok(
  outcome: Result(package.VettedPackage, List(#(String, package.Rejection))),
) -> Bool {
  case outcome {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn find(
  refusals: List(#(String, package.Rejection)),
  path: String,
) -> Result(#(String, package.Rejection), Nil) {
  list.find(refusals, fn(entry) { entry.0 == path })
}

fn names_file(
  refusals: List(#(String, package.Rejection)),
  path: String,
) -> Bool {
  case find(refusals, path) {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

fn reason_for(
  refusals: List(#(String, package.Rejection)),
  path: String,
) -> String {
  refusals
  |> list.filter(fn(entry) { entry.0 == path })
  |> list.map(fn(entry) { package.describe(entry.1) })
  |> string.join(" | ")
}

fn replace(
  files: List(#(String, String)),
  path: String,
  contents: String,
) -> List(#(String, String)) {
  [#(path, contents), ..list.filter(files, fn(file) { file.0 != path })]
}
