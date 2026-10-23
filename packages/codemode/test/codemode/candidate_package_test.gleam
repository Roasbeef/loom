import codemode/vet/package
import codemode/vet/policy
import gleeunit/should

pub fn author_tests_are_vetted_in_extension_seam_test() {
  let files = [
    #("gleam.toml", "name = \"example\"\n"),
    #("src/example.gleam", "pub fn run() { 1 }"),
    #(
      "test/example_test.gleam",
      "@external(erlang, \"erlang\", \"halt\")\npub fn forbidden() -> Nil",
    ),
  ]
  package.vet_candidate(files, policy.for_seam(policy.ExtensionSeam))
  |> should.be_error
  package.installed_subset(files)
  |> should.equal(
    Ok([
      #("gleam.toml", "name = \"example\"\n"),
      #("src/example.gleam", "pub fn run() { 1 }"),
    ]),
  )
}

pub fn native_test_files_and_module_collisions_refuse_test() {
  let project = #("gleam.toml", "name = \"example\"\n")
  package.vet_candidate(
    [project, #("test/hidden.erl", "-module(hidden).")],
    policy.for_seam(policy.ExtensionSeam),
  )
  |> should.be_error
  package.vet_candidate(
    [
      project,
      #("src/example.gleam", "pub fn run() { 1 }"),
      #("test/example.gleam", "pub fn run() { 2 }"),
    ],
    policy.for_seam(policy.ExtensionSeam),
  )
  |> should.be_error
}

pub fn candidate_tests_cannot_import_host_or_shadow_prelude_test() {
  let project = #("gleam.toml", "name = \"example\"\n")
  package.vet_candidate(
    [
      project,
      #(
        "test/escape.gleam",
        "import simplifile\npub fn run() { simplifile.read(\"/etc/passwd\") }",
      ),
    ],
    policy.for_seam(policy.ExtensionSeam),
  )
  |> should.be_error
  package.vet_candidate(
    [project, #("test/cap/fs.gleam", "pub fn run() { 1 }")],
    policy.for_seam(policy.ExtensionSeam),
  )
  |> should.be_error
}

pub fn candidate_cannot_shadow_generated_satellite_entry_test() {
  package.vet_candidate(
    [
      #("gleam.toml", "name = \"example\"\n"),
      #("test/loom_satellite.gleam", "pub fn main() { 1 }"),
    ],
    policy.for_seam(policy.ExtensionSeam),
  )
  |> should.be_error
}
