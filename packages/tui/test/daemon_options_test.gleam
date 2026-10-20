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
  let assert Ok(#(command, options)) =
    tui.launch_sessions_command([
      "--server", "/bin/loomd", "sessions", "list", "--all", "--local",
    ])
  assert command == tui.ListRegistrations(tui.Every, tui.ThisDaemonOnly)
  assert tui.launch_sessions_command([
      "sessions", "list", "--all", "--local", "--server", "/bin/loomd",
    ])
    == Ok(#(command, options))
}

pub fn the_web_view_reads_options_before_its_verb_test() {
  let assert Ok(request) =
    tui.launch_view(["--state-dir", "/s", "ui", "--session", "x"])
  assert request.session == option.Some("x")
}

// A flag takes the next word as its value, so `--server sessions` consumes the
// verb and the stray `list` is what the launch parser then refuses.
pub fn a_flag_that_swallows_the_verb_leaves_a_stray_word_refused_test() {
  let assert Error(stray) =
    tui.launch_daemon_options(["--server", "sessions", "list"])
  assert string.contains(stray, "missing value for list")
}

pub fn an_unknown_option_is_still_refused_test() {
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
