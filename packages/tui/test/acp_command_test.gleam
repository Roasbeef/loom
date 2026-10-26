//// `loom acp`'s command line: which words reach the server's configuration,
//// that a refused line says why and shows the usage, and that the verb is
//// routed like the other headless clients.

import gleam/string
import tui
import tui/acp/server

pub fn no_arguments_leave_every_default_to_the_server_test() {
  let assert Ok(config) = server.parse([], "9.9")

  assert config.roots == []
  assert config.options.workspace == ""
  assert config.version == "9.9"
}

pub fn every_flag_lands_where_it_belongs_test() {
  let assert Ok(config) =
    server.parse(
      [
        "--workspace-root", "/a", "--workspace-root", "/b", "--workspace", "/w",
        "--config", "/c.toml", "--server", "/s", "--state-dir", "/st",
        "--model-profile", "fast",
      ],
      "1",
    )

  assert config.roots == ["/a", "/b"]
  assert config.options.workspace == "/w"
  assert config.options.config == "/c.toml"
  assert config.options.server == "/s"
  assert config.options.state_directory == "/st"
  assert config.options.profile == "fast"
}

pub fn an_unknown_or_dangling_flag_is_refused_test() {
  let assert Error(unknown) = server.parse(["--wat", "x"], "1")
  let assert Error(dangling) = server.parse(["--workspace-root"], "1")

  assert string.contains(unknown, "--wat")
  assert string.contains(dangling, "--workspace-root")
}

pub fn the_usage_names_the_verb_and_the_stdout_contract_test() {
  assert string.contains(server.usage(), "loom acp")
  assert string.contains(server.usage(), "standard output carries only")
}

pub fn the_launcher_routes_acp_and_hoists_daemon_options_test() {
  let assert Ok(plain) = tui.launch_acp(["acp", "--workspace-root", "/w"])
  assert plain.roots == ["/w"]

  let assert Ok(hoisted) =
    tui.launch_acp(["--server", "/s", "--state-dir", "/st", "acp"])
  assert hoisted.options.server == "/s"
  assert hoisted.options.state_directory == "/st"
}

pub fn a_refused_line_carries_the_reason_and_the_usage_test() {
  let assert Error(reason) = tui.launch_acp(["acp", "--wat", "x"])

  assert string.contains(reason, "--wat")
  assert string.contains(reason, "usage: loom acp")
}

pub fn other_verbs_are_not_an_acp_launch_test() {
  let assert Error(_) = tui.launch_acp(["run", "-p", "hi"])
}
