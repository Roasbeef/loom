//// `loom distribution` is a passthrough to `loomd`, exactly as `loom ext` is
//// (the provisioning command lives in the server package, which the terminal
//// package cannot import). These tests pin what the launcher hands the
//// server, including that `dist` is the same command, and that the launcher's
//// own commands are not forwarded. The shipped acceptance in
//// `scripts/cli_help_test.sh` runs the built binaries for the rest.

import gleam/option.{None, Some}
import gleam/string
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

// The forwarded `loomd` has a pipe for stdin, so it cannot ask for the
// passphrase. The launcher says so before it spawns anything.
pub fn a_ledger_provision_with_no_passphrase_source_is_refused_test() {
  let refused = fn(arguments) {
    assert tui.server_arguments(arguments) == None
    let assert Error(reason) = tui.launch_options(arguments)
    assert string.contains(reason, "--passphrase-file PATH or --drop-authority")
    assert string.contains(reason, "loomd distribution provision")
  }
  refused(["distribution", "provision", "plan.toml", "out", "--ledger"])
  refused(["dist", "provision", "--ledger", "plan.toml", "out", "--force"])
}

pub fn a_ledger_provision_with_a_passphrase_source_is_forwarded_test() {
  assert tui.server_arguments([
      "distribution",
      "provision",
      "plan.toml",
      "out",
      "--ledger",
      "--passphrase-file",
      "pass.txt",
    ])
    == Some([
      "distribution",
      "provision",
      "plan.toml",
      "out",
      "--ledger",
      "--passphrase-file",
      "pass.txt",
    ])
  assert tui.server_arguments([
      "distribution",
      "provision",
      "plan.toml",
      "out",
      "--ledger",
      "--drop-authority",
    ])
    != None

  // Without `--ledger` there is no prompt to refuse, and other commands never
  // ask for a passphrase.
  assert tui.server_arguments(["distribution", "provision", "plan.toml", "out"])
    != None
  assert tui.server_arguments(["distribution", "show", "out", "--ledger"])
    != None
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
