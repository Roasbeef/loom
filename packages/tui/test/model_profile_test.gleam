//// The `--model-profile` launch flag and how it reaches a session creation
//// (protocol-change/076). It is not `--profile`, which the native launcher
//// consumes for BEAM profiling before the application starts.

import gleam/string
import tui
import tui/daemon/protocol

pub fn a_launch_without_the_flag_asks_for_the_default_roles_test() {
  let assert Ok(options) = tui.launch_options([])
  assert options.profile == ""
  let assert Ok(options) = tui.launch_options(["--config", "/etc/loom.toml"])
  assert options.profile == ""
}

pub fn the_flag_names_the_profile_and_leaves_the_other_options_alone_test() {
  let assert Ok(options) =
    tui.launch_options([
      "--workspace", "/work", "--model-profile", "deepseek", "--config",
      "/etc/loom.toml",
    ])
  assert options.profile == "deepseek"
  assert options.workspace == "/work"
  assert options.config == "/etc/loom.toml"
}

// The launcher's `--profile` takes no value and is removed before the
// application sees the arguments, so this flag must not be spelled that way: a
// bare `--profile` reaching the application is an unknown option.
pub fn the_beam_profiling_spelling_is_not_the_model_profile_test() {
  let assert Error(reason) = tui.launch_options(["--profile", "deepseek"])
  assert string.contains(reason, "unknown local launch option --profile")
}

pub fn a_missing_or_flag_shaped_profile_name_is_refused_test() {
  let assert Error(reason) = tui.launch_options(["--model-profile"])
  assert string.contains(reason, "missing value for --model-profile")
  let assert Error(reason) =
    tui.launch_options(["--model-profile", "--config", "/etc/loom.toml"])
  assert string.contains(reason, "--model-profile needs a profile name")
}

// An empty profile is not sent, so a daemon that predates profiles receives the
// request it always did; a named one is a field of its own.
pub fn creation_sends_the_profile_only_when_one_was_asked_for_test() {
  let fields = fn(profile) {
    let assert Ok(body) =
      protocol.encode(
        7,
        protocol.CreateSession(
          "key",
          "/work",
          "name",
          "/config",
          profile,
          "",
          "",
        ),
        protocol.Epoch("current"),
      )
    string.contains(body, "\"profile\"")
  }
  assert !fields("")
  assert fields("deepseek")
}

pub fn an_over_long_profile_name_is_refused_before_it_is_sent_test() {
  let assert Error(_) =
    protocol.encode(
      7,
      protocol.CreateSession(
        "key",
        "/work",
        "name",
        "",
        string.repeat("a", 65),
        "",
        "",
      ),
      protocol.Epoch("current"),
    )
  Nil
}
