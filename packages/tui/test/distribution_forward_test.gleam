//// `loom distribution` is a passthrough to `loomd`, exactly as `loom ext` is
//// (the provisioning command lives in the server package, which the terminal
//// package cannot import). These tests pin what the launcher hands the
//// server, including that `dist` is the same command, and that the launcher's
//// own commands are not forwarded. The shipped acceptance in
//// `scripts/cli_help_test.sh` runs the built binaries for the rest.

import gleam/option.{None, Some}
import tui

pub fn distribution_is_forwarded_with_its_arguments_untouched_test() {
  assert tui.server_arguments([
      "distribution",
      "provision",
      "plan.toml",
      "out",
      "--force",
    ])
    == Some(["distribution", "provision", "plan.toml", "out", "--force"])
  assert tui.server_arguments([
      "distribution",
      "install",
      "n.loombundle",
      "--home",
      "/h",
    ])
    == Some(["distribution", "install", "n.loombundle", "--home", "/h"])
}

pub fn dist_is_the_same_command_as_distribution_test() {
  assert tui.server_arguments(["dist", "init"])
    == Some(["distribution", "init"])
  assert tui.server_arguments(["dist", "init"])
    == tui.server_arguments(["distribution", "init"])
  assert tui.server_arguments(["dist", "install", "b.loombundle"])
    == Some(["distribution", "install", "b.loombundle"])
  assert tui.server_arguments(["help", "dist"])
    == Some(["distribution", "--help"])
  assert tui.server_arguments(["help", "distribution"])
    == Some(["distribution", "--help"])
}

pub fn ext_is_still_forwarded_the_same_way_test() {
  assert tui.server_arguments(["ext", "list"]) == Some(["ext", "list"])
  assert tui.server_arguments(["help", "ext"]) == Some(["ext", "--help"])
}

pub fn launcher_commands_are_not_forwarded_test() {
  assert tui.server_arguments(["version"]) == None
  assert tui.server_arguments(["replay", "recording.jsonl"]) == None
  assert tui.server_arguments(["sessions", "list"]) == None
}

pub fn executor_is_forwarded_with_its_arguments_untouched_test() {
  assert tui.server_arguments([
      "executor",
      "release",
      "7f3a9c1e",
      "--state-dir",
      "/var/lib/loom",
    ])
    == Some(["executor", "release", "7f3a9c1e", "--state-dir", "/var/lib/loom"])
  assert tui.server_arguments(["help", "executor"])
    == Some(["executor", "--help"])
}
