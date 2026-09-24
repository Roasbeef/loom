//// The launch workspace is the jail root a picker-created session runs in.
//// These tests pin the chain from the launch to the `CreateSession` the
//// picker's `n` sends: an explicit `--workspace`, or the launch directory
//// without one, is canonicalized and kept as named, never widened to the
//// repository that happens to enclose it.

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

  // The flag is given relative, as an operator types it; the wire carries the
  // absolute path, because the daemon does not share the launcher's cwd.
  let options = bootstrap.Options(scratch, "", "", "", "")
  let assert Ok(project) = bootstrap.launch_workspace(options)
    as "an existing directory is a valid workspace"
  assert project == workspace.Context(canonical, Some("topic"))
  assert selection.creation("key", project, "/state/loom.toml")
    == protocol.CreateSession(
      "key",
      canonical,
      "scratch · topic",
      "/state/loom.toml",
    )
  let _ = simplifile.delete(root)
}

// The test runs in the package directory, which has no `.git` of its own
// but sits inside the checkout that does. That is the subdirectory launch:
// the workspace is the directory itself, the same one `bootstrap.resolve`
// keys the launcher's state on, and not the checkout root around it.
pub fn an_absent_flag_takes_the_launch_directory_itself_test() {
  let assert Ok(False) = simplifile.exists(".git", follow_links: False)
    as "the fixture needs a launch directory below its repository root"
  let assert Ok(launch_directory) = host_bootstrap.canonical_directory("")
  let assert Ok(project) =
    bootstrap.launch_workspace(bootstrap.Options("", "", "", "", ""))
  assert project.path == launch_directory
  assert filepath.base_name(project.path) == "tui"
}

pub fn a_flag_naming_no_directory_stops_the_launch_test() {
  let options =
    bootstrap.Options("build/launch-workspace-test-missing", "", "", "", "")
  let assert Error(reason) = bootstrap.launch_workspace(options)
    as "no fallback may choose a jail root the operator did not name"
  assert string.starts_with(reason, "resolve workspace: ")
}
