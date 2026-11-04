//// The launcher's decision to render the TLS options file for a daemon, and the
//// command that names it. The decisions are pure and tested as values. The
//// render itself runs against a stand-in `loomd` script, because the real
//// renderer lives in a package this one cannot depend on; the client suite
//// and the shipped-daemon fixtures run the real one.

import gleam/int
import gleam/string
import host/bootstrap as host
import simplifile
import tui/bootstrap
import tui/daemon/bootstrap as daemon_bootstrap
import tui/distribution_launch.{NotDistributed, OperatorProvided, Render}

const table = "[distribution]\nnode = \"a@b.c\"\n"

fn scratch(name: String) -> String {
  let assert Ok(path) =
    host.absolute_path(
      "build/distribution-launch-"
      <> name
      <> "-"
      <> int.to_string(host.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
    )
    as "the scratch directory has an absolute path"
  let assert Ok(Nil) = host.ensure_private_directory(path)
    as "the scratch directory is private"
  path
}

// A stand-in for `loomd`. It records its arguments, refuses a configuration
// whose path contains `bad` with the renderer's kind of sentence, and otherwise
// writes a private file at the output path.
fn stand_in_server(directory: String) -> String {
  let path = directory <> "/loomd"
  let script =
    "#!/bin/sh\n"
    <> "printf '%s\\n' \"$@\" > \""
    <> directory
    <> "/arguments\"\n"
    <> "[ \"$1 $2\" = \"distribution options\" ] || exit 9\n"
    <> "case \"$3\" in *bad*) echo 'refused: distribution.node is required'; exit 1;; esac\n"
    <> "printf rendered > \"$4\"\n"
    <> "chmod 600 \"$4\"\n"
  let assert Ok(Nil) = simplifile.write(path, script)
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
  path
}

fn recorded(directory: String) -> List(String) {
  let assert Ok(text) = simplifile.read(directory <> "/arguments")
    as "the stand-in server ran"
  string.split(string.trim(text), "\n")
}

fn config(directory: String, name: String, text: String) -> String {
  let path = directory <> "/" <> name
  let assert Ok(Nil) = simplifile.write(path, text)
  path
}

pub fn a_table_is_rendered_and_no_table_is_not_test() {
  assert distribution_launch.decide("", Error(Nil), "/state") == NotDistributed
  assert distribution_launch.decide(
      "[daemon]\nbind = \"127.0.0.1:0\"\n",
      Error(Nil),
      "/state",
    )
    == NotDistributed
  assert distribution_launch.decide(table, Error(Nil), "/state")
    == Render("/state/distribution-launch.options")
}

pub fn a_malformed_table_is_still_rendered_so_the_renderer_names_the_key_test() {
  // The daemon's own test is the presence of the key, so a table that fails its
  // decoder, or a key that is not a table at all, reaches the renderer's
  // refusal here and not a boot refusal after the VM is up.
  assert distribution_launch.decide("distribution = 3\n", Error(Nil), "/s")
    == Render("/s/distribution-launch.options")
  assert distribution_launch.decide(
      "[distribution]\nnode = 1\n",
      Error(Nil),
      "/s",
    )
    == Render("/s/distribution-launch.options")
}

pub fn text_that_is_not_toml_is_left_to_the_daemon_test() {
  assert distribution_launch.decide("[distribution\n", Error(Nil), "/s")
    == NotDistributed
}

pub fn an_options_file_in_the_environment_is_never_replaced_test() {
  assert distribution_launch.decide(table, Ok("/operator/dist.options"), "/s")
    == OperatorProvided
}

pub fn an_empty_variable_counts_as_unset_as_the_shell_launcher_reads_it_test() {
  assert distribution_launch.decide(table, Ok(""), "/s")
    == Render("/s/distribution-launch.options")
}

pub fn the_options_file_has_its_own_name_in_the_state_root_test() {
  assert distribution_launch.options_path("/home/me/.loom")
    == "/home/me/.loom/distribution-launch.options"
}

pub fn no_environment_launches_the_daemon_directly_test() {
  assert distribution_launch.command("/bin/loomd", ["--state-dir", "/s"], [])
    == #("/bin/loomd", ["--state-dir", "/s"])
}

pub fn an_environment_is_set_by_env_which_then_runs_the_daemon_test() {
  assert distribution_launch.command("/bin/loomd", ["--state-dir", "/s"], [
      #("LOOM_DISTRIBUTION_OPTFILE", "/s/x.options"),
    ])
    == #("/usr/bin/env", [
      "LOOM_DISTRIBUTION_OPTFILE=/s/x.options", "/bin/loomd", "--state-dir",
      "/s",
    ])
}

pub fn prepare_renders_with_the_daemons_command_and_names_the_file_test() {
  let directory = scratch("render")
  let server = stand_in_server(directory)
  let path = config(directory, "loom.toml", table)
  let output = distribution_launch.options_path(directory)

  assert distribution_launch.prepare(server, path, directory, Error(Nil))
    == Ok([#("LOOM_DISTRIBUTION_OPTFILE", output)])
  assert recorded(directory) == ["distribution", "options", path, output]
  assert simplifile.read(output) == Ok("rendered")

  // The file is private, which the daemon requires of it.
  assert host.read_private_bounded(output, 100) |> result_is_ok
  assert simplifile.delete(directory) == Ok(Nil)
}

fn result_is_ok(value: Result(a, b)) -> Bool {
  case value {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn prepare_replaces_a_file_left_by_an_earlier_launch_test() {
  let directory = scratch("fresh")
  let server = stand_in_server(directory)
  let path = config(directory, "loom.toml", table)
  let output = distribution_launch.options_path(directory)
  assert simplifile.write(output, "stale") == Ok(Nil)

  let assert Ok(_) =
    distribution_launch.prepare(server, path, directory, Error(Nil))
  assert simplifile.read(output) == Ok("rendered")
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn a_refused_render_fails_the_launch_and_leaves_no_stale_file_test() {
  let directory = scratch("refused")
  let server = stand_in_server(directory)
  let path = config(directory, "bad.toml", table)
  let output = distribution_launch.options_path(directory)
  assert simplifile.write(output, "stale") == Ok(Nil)

  let assert Error(reason) =
    distribution_launch.prepare(server, path, directory, Error(Nil))
    as "a table the renderer refuses must not start a daemon"
  assert string.contains(reason, "failed with status 1")
  assert string.contains(reason, "refused: distribution.node is required")
  assert simplifile.is_file(output) == Ok(False)
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn an_unrunnable_server_fails_the_launch_with_its_name_test() {
  let directory = scratch("missing")
  let path = config(directory, "loom.toml", table)
  let assert Error(reason) =
    distribution_launch.prepare(
      directory <> "/no-such-loomd",
      path,
      directory,
      Error(Nil),
    )
    as "a server that cannot run cannot render"
  assert string.contains(reason, "no-such-loomd")
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn prepare_runs_nothing_without_a_table_or_with_an_explicit_file_test() {
  let directory = scratch("quiet")
  let server = stand_in_server(directory)
  let plain = config(directory, "plain.toml", "[daemon]\nbind = \"x\"\n")
  let marker = directory <> "/arguments"

  assert distribution_launch.prepare(server, plain, directory, Error(Nil))
    == Ok([])
  assert distribution_launch.prepare(server, "", directory, Error(Nil))
    == Ok([])
  let with_table = config(directory, "loom.toml", table)
  assert distribution_launch.prepare(
      server,
      with_table,
      directory,
      Ok("/operator/dist.options"),
    )
    == Ok([])

  // The stand-in records its arguments whenever it runs, so none were run.
  assert simplifile.is_file(marker) == Ok(False)
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn the_daemon_launch_carries_the_options_file_in_its_environment_test() {
  let directory = scratch("launch")
  let server = stand_in_server(directory)
  let path = config(directory, "loom.toml", table)
  let output = distribution_launch.options_path(directory)

  let assert Ok(daemon_bootstrap.Launch(executable:, arguments:)) =
    bootstrap.daemon_launch(directory, server, path, ["--ui"], Error(Nil))
  assert executable == "/usr/bin/env"
  assert arguments
    == [
      "LOOM_DISTRIBUTION_OPTFILE=" <> output,
      server,
      "--state-dir",
      directory,
      "--config",
      path,
      "--ui",
    ]
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn the_daemon_launch_is_unchanged_without_a_table_test() {
  let directory = scratch("direct")
  let server = stand_in_server(directory)
  let path = config(directory, "loom.toml", "[daemon]\nbind = \"x\"\n")

  assert bootstrap.daemon_launch(directory, server, path, [], Error(Nil))
    == Ok(
      daemon_bootstrap.Launch(server, [
        "--state-dir",
        directory,
        "--config",
        path,
      ]),
    )
  assert simplifile.delete(directory) == Ok(Nil)
}

pub fn the_daemon_launch_fails_when_the_render_is_refused_test() {
  let directory = scratch("launch-refused")
  let server = stand_in_server(directory)
  let path = config(directory, "bad.toml", table)

  let assert Error(reason) =
    bootstrap.daemon_launch(directory, server, path, [], Error(Nil))
    as "a refused render stops the launch before a daemon is spawned"
  assert string.contains(reason, "refused: distribution.node is required")
  assert simplifile.delete(directory) == Ok(Nil)
}
