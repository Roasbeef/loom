//// The daemon options a subcommand shares with a local launch may be written
//// before the verb as well as after it, with the same meaning.

import gleam/option
import gleam/string
import tui

pub fn options_before_the_verb_mean_the_same_as_after_it_test() {
  let assert Ok(before) =
    tui.launch_daemon_options(["--server", "/bin/loomd", "sessions", "list"])
  let assert Ok(after) =
    tui.launch_daemon_options(["sessions", "list", "--server", "/bin/loomd"])
  assert before == after
  assert before.server == "/bin/loomd"
}

pub fn every_shared_option_is_read_before_the_verb_test() {
  let assert Ok(options) =
    tui.launch_daemon_options([
      "--state-dir", "/var/tmp/s", "--config", "/etc/loom.toml", "--server",
      "/bin/loomd", "deployment", "status", "--json",
    ])
  assert options.state_directory == "/var/tmp/s"
  assert options.config == "/etc/loom.toml"
  assert options.server == "/bin/loomd"
  let assert Ok(directory) =
    tui.launch_daemon_options(["--state-dir", "/d", "directory", "status"])
  assert directory.state_directory == "/d"
}

pub fn the_verbs_own_flags_survive_the_move_test() {
  let assert Ok(tui.ListRegistrations(
    showing: tui.Every,
    reach: tui.ThisDaemonOnly,
  )) =
    tui.launch_sessions(["list", "--all", "--local", "--server", "/bin/loomd"])
  let assert Ok(options) =
    tui.launch_daemon_options([
      "--server", "/bin/loomd", "sessions", "list", "--all", "--local",
    ])
  assert options.server == "/bin/loomd"
}

pub fn the_web_view_reads_options_before_its_verb_test() {
  let assert Ok(request) =
    tui.launch_view(["--state-dir", "/s", "ui", "--session", "x"])
  assert request.session == option.Some("x")
}

pub fn a_valueless_or_unknown_option_is_still_refused_test() {
  let assert Error(missing) =
    tui.launch_daemon_options(["--server", "sessions", "list"])
  assert string.contains(missing, "missing value")
  let assert Error(unknown) =
    tui.launch_daemon_options(["sessions", "list", "--bogus", "x"])
  assert string.contains(unknown, "unknown local launch option")
}

pub fn a_terminal_launch_is_left_as_written_test() {
  let assert Ok(options) =
    tui.launch_options(["--server", "/bin/loomd", "--state-dir", "/s"])
  assert options.server == "/bin/loomd"
  assert options.state_directory == "/s"
}
