//// What `PATH` a project worker's jailed tools get, against the `PATH` the
//// daemon gives a project's `setup` and `check`.
////
//// A worker that cannot find the project's compiler concludes that the
//// environment is broken and goes looking for one, which cost a run about forty
//// model calls. The check finds its tools on the daemon's own `PATH`
//// (`executor_plane.Machine.check_path`), so the worker has to find the same
//// ones. A worker session is built by the same `workspace_policy.tool_environment`
//// as every session: the owner's `[tools] path` comes first, then the daemon's
//// `PATH`, then the system directories. These tests pin that order for a worker,
//// so a change to how a session's `PATH` is assembled cannot give the check
//// tools the worker lacks without a test saying so.

import client/catalog
import client/workspace_policy
import gleam/list
import gleam/option.{None}
import gleam/string

// The daemon's `PATH` as a shell would hold it, with a toolchain directory that
// no system default names.
const daemon_path = "/opt/toolchains/go/bin:/usr/local/bin:/usr/bin:/bin"

fn daemon_reading(name: String) -> Result(String, Nil) {
  case name {
    "PATH" -> Ok(daemon_path)
    _other -> Error(Nil)
  }
}

fn path_of(tools: catalog.ToolsConfig) -> String {
  let #(environment, _unset) =
    workspace_policy.tool_environment(
      "/state/projects/p1/tickets/t-a",
      None,
      None,
      tools,
      reading: daemon_reading,
    )
  let assert Ok(path) = list.key_find(environment, "PATH")
    as "every tool environment names a PATH"
  path
}

pub fn a_workers_path_carries_the_directory_the_daemons_check_finds_its_tools_in_test() {
  let path = path_of(catalog.default_tools())
  assert list.contains(dirs_of(path), "/opt/toolchains/go/bin")
}

pub fn the_owners_tools_path_comes_first_and_the_daemons_follows_test() {
  let tools =
    catalog.ToolsConfig(..catalog.default_tools(), path: ["/owner/bin"])
  let dirs = dirs_of(path_of(tools))
  let assert [first, ..rest] = dirs
  assert first == "/owner/bin"
  assert list.contains(rest, "/opt/toolchains/go/bin")
}

pub fn a_daemon_with_no_path_leaves_the_system_directories_test() {
  let #(environment, _unset) =
    workspace_policy.tool_environment(
      "/state/projects/p1/tickets/t-a",
      None,
      None,
      catalog.default_tools(),
      reading: fn(_name) { Error(Nil) },
    )
  let assert Ok(path) = list.key_find(environment, "PATH")
  assert dirs_of(path) == ["/usr/local/bin", "/usr/bin", "/bin"]
}

fn dirs_of(path: String) -> List(String) {
  string.split(path, ":")
}
