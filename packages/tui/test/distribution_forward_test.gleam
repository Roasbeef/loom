//// `loom distribution` is a passthrough to `loomd`, exactly as `loom ext` is
//// (the provisioning command lives in the server package, which the terminal
//// package cannot import). These tests pin what the launcher hands the
//// server, including that `dist` is the same command, and that the launcher's
//// own commands are not forwarded. The shipped acceptance in
//// `scripts/cli_help_test.sh` runs the built binaries for the rest.

import gleam/list
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
      "--static",
    ])
    == Some([
      "distribution",
      "provision",
      "plan.toml",
      "out",
      "--force",
      "--static",
    ])
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
// passphrase. A provision seals a key unless it is static or drops the key, and
// `enroll`, `revoke` and `renew` open one. The launcher says so before it spawns
// anything.
pub fn a_command_that_needs_the_passphrase_and_has_no_source_is_refused_test() {
  let refused = fn(arguments, fragment) {
    assert tui.server_arguments(arguments) == None
    let assert Error(reason) = tui.launch_options(arguments)
    assert string.contains(reason, fragment)
  }
  refused(
    ["distribution", "provision", "plan.toml", "out"],
    "--passphrase-file PATH, --drop-authority or --static",
  )
  refused(
    ["dist", "provision", "plan.toml", "out", "--force"],
    "loomd distribution provision",
  )
  refused(
    ["distribution", "enroll", "laptop2", "--node", "loom@l.example"],
    "distribution enroll needs --passphrase-file PATH",
  )
  refused(["dist", "revoke", "laptop2", "--force"], "loomd distribution revoke")
  refused(["dist", "renew", "laptop2"], "distribution renew needs")
}

pub fn a_command_with_a_passphrase_source_or_none_to_ask_is_forwarded_test() {
  let forwarded = fn(arguments) {
    assert tui.server_arguments(arguments)
      == Some(["distribution", ..list.drop(arguments, 1)])
  }
  forwarded([
    "distribution", "provision", "plan.toml", "out", "--passphrase-file",
    "pass.txt",
  ])
  forwarded([
    "distribution",
    "provision",
    "plan.toml",
    "out",
    "--drop-authority",
  ])
  forwarded(["distribution", "provision", "plan.toml", "out", "--static"])
  forwarded(["distribution", "enroll", "l", "--passphrase-file", "pass.txt"])
  forwarded(["distribution", "revoke", "l", "--passphrase-file", "pass.txt"])
  forwarded(["distribution", "renew", "l", "--passphrase-file", "pass.txt"])

  // Help never asks for anything, and the commands that read the ledger or
  // install a bundle have no passphrase to give.
  forwarded(["distribution", "provision", "--help"])
  forwarded(["distribution", "enroll", "-h"])
  forwarded(["distribution", "log", "--json"])
  forwarded(["distribution", "import", "ledger.log"])
  forwarded(["distribution", "install", "n.loombundle"])
  forwarded(["distribution", "show", "out"])
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
