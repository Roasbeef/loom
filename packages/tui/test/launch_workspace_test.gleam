//// An explicit `--workspace` is the jail root a picker-created session runs
//// in. These tests pin the chain from the launch flag to the `CreateSession`
//// the picker's `n` sends: the flag is canonicalized and kept as named, never
//// widened to the repository that happens to enclose it, and never replaced
//// by the repository the terminal was launched from.

import filepath
import gleam/option.{Some}
import gleam/string
import host/bootstrap as host_bootstrap
import simplifile
import tui/bootstrap
import tui/daemon/protocol
import tui/daemon/selection
import tui/workspace

// The fixture is a repository with a scratch directory inside it, under the
// package's build directory and so also inside the checkout running the test.
// That is the reported shape: two enclosing repositories, either of which the
// old discovery would have substituted for the directory the operator named.
fn fixture(name: String) -> #(String, String) {
  let root =
    "build/launch-workspace-test-"
    <> name
    <> "-"
    <> string.inspect(host_bootstrap.system_time_ms())
  let repository = filepath.join(root, "repo")
  let scratch = filepath.join(repository, "scratch")
  let assert Ok(Nil) =
    simplifile.create_directory_all(filepath.join(repository, ".git"))
  let assert Ok(Nil) = simplifile.create_directory_all(scratch)
  let assert Ok(Nil) =
    simplifile.write(
      filepath.join(repository, ".git/HEAD"),
      "ref: refs/heads/topic\n",
    )
    as "the enclosing repository supplies the branch label"
  #(root, scratch)
}

pub fn explicit_workspace_survives_into_the_create_request_test() {
  let #(root, scratch) = fixture("explicit")
  let assert Ok(canonical) = host_bootstrap.canonical_directory(scratch)
  let launched_from = workspace.discover()

  // The flag is given relative, as an operator types it; the wire carries the
  // absolute path, because the daemon does not share the launcher's cwd.
  let options = bootstrap.Options(scratch, "", "", "", "")
  let assert Ok(project) = bootstrap.launch_workspace(options, launched_from)
    as "an existing directory is a valid workspace"
  assert project == workspace.Context(canonical, Some("topic"))

  // The repository walk is what the launch used to apply to the flag, and
  // it would have created the session over the whole enclosing repository.
  assert workspace.discover_from(canonical).path
    == filepath.directory_name(canonical)

  assert selection.creation("key", project, "/state/loom.toml")
    == protocol.CreateSession(
      "key",
      canonical,
      "scratch · topic",
      "/state/loom.toml",
    )
  let _ = simplifile.delete(root)
}

pub fn an_absent_flag_keeps_the_launch_directory_context_test() {
  let launched_from = workspace.Context("/work/loom", Some("main"))
  assert bootstrap.launch_workspace(
      bootstrap.Options("", "", "", "", ""),
      launched_from,
    )
    == Ok(launched_from)
}

pub fn a_flag_naming_no_directory_stops_the_launch_test() {
  let options =
    bootstrap.Options("build/launch-workspace-test-missing", "", "", "", "")
  let assert Error(reason) =
    bootstrap.launch_workspace(options, workspace.discover())
    as "no fallback may choose a jail root the operator did not name"
  assert string.starts_with(reason, "resolve workspace: ")
}
