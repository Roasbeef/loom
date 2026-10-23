import codemode/vet/migration
import codemode/vet/package
import codemode/vet/policy
import gleeunit/should

pub fn helper_cannot_hide_capability_test() {
  let files = [
    #("gleam.toml", "name = \"counter\"\nversion = \"1.0.0\"\n"),
    #(
      "src/counter/migrate.gleam",
      "import counter/helper\npub fn migrate() { helper.run() }",
    ),
    #("src/counter/helper.gleam", "import cap/proc\npub fn run() { Nil }"),
  ]
  let assert Ok(vetted) = package.vet_package(files, policy.extension())
    as "ordinary extension source is admitted"
  migration.check(vetted, "counter/migrate") |> should.be_error
}

pub fn recursive_pure_helpers_are_admitted_test() {
  let files = [
    #("gleam.toml", "name = \"counter\"\nversion = \"1.0.0\"\n"),
    #(
      "src/counter/migrate.gleam",
      "import counter/helper\npub fn migrate() { helper.run() }",
    ),
    #(
      "src/counter/helper.gleam",
      "import counter/migrate\npub fn run() { Nil }",
    ),
  ]
  let assert Ok(vetted) = package.vet_package(files, policy.extension())
    as "ordinary extension source is admitted"
  migration.check(vetted, "counter/migrate") |> should.equal(Ok(Nil))
}
