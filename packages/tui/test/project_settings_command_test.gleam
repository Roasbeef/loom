//// `loom project settings`, `set`, `unset` and `init`: what the launcher
//// accepts, and what each verb says and sends against a stand-in daemon
//// (protocol-change/106, "Settings held per project").

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/project_settings_cli as cli

pub fn init_takes_a_check_and_a_setup_test() {
  assert tui.launch_project([
      "init", "--check", "make unit", "--setup", "go mod download",
    ])
    == Ok(tui.ProjectInit(Some("make unit"), Some("go mod download")))
}

pub fn the_settings_verbs_parse_test() {
  assert tui.launch_project(["settings"]) == Ok(tui.ProjectSettings)
  assert tui.launch_project(["set", "check", "make check"])
    == Ok(tui.ProjectSet("check", ["make check"], None))
  assert tui.launch_project(["unset", "setup"]) == Ok(tui.ProjectUnset("setup"))
}

pub fn set_takes_every_word_before_the_flags_test() {
  assert tui.launch_project([
      "set", "protected_paths", "Makefile", ".github/**", "--config",
      "loom.toml",
    ])
    == Ok(tui.ProjectSet("protected_paths", ["Makefile", ".github/**"], None))
}

pub fn publish_is_named_with_its_url_flag_test() {
  assert tui.launch_project([
      "set", "publish", "pull_request", "--publish-to", "https://github.com/o/r",
    ])
    == Ok(tui.ProjectSet(
      "publish",
      ["pull_request"],
      Some("https://github.com/o/r"),
    ))
}

pub fn set_without_a_value_is_refused_test() {
  let assert Error(words) = tui.launch_project(["set", "check"])
  assert string.contains(words, "set needs a value")
}

// A stand-in daemon: `projects.settings` answers a project whose publish is
// off and whose remote is a known URL, and every other command is recorded in
// the order it was sent.
fn settings_body(publish: String) -> json.JsonValue {
  let row = fn(key: String, value: List(String), source: String) {
    json.Object([
      #("key", json.String(key)),
      #("value", json.Array(list.map(value, json.String))),
      #("source", json.String(source)),
    ])
  }
  json.Object([
    #("project", json.String("p-1")),
    #("revision", json.Int(3)),
    #("publish_url", json.String("https://github.com/o/r")),
    #(
      "settings",
      json.Array([
        row("check", ["make check"], "project"),
        row("publish", [publish], "default"),
      ]),
    ),
  ])
}

fn daemon(
  name: String,
  fields: List(#(String, json.JsonValue)),
) -> Result(json.JsonValue, String) {
  case name {
    "projects.settings" -> Ok(settings_body("off"))
    "projects.set_settings" ->
      case list.key_find(fields, "revision") {
        Ok(json.Int(3)) -> Ok(settings_body("off"))
        _ -> Error("the settings changed since you read them")
      }
    "projects.propose" ->
      Ok(
        json.Object([
          #(
            "check",
            json.Object([
              #("command", json.String("make unit")),
              #("because", json.String("Makefile target unit")),
            ]),
          ),
          #("setup", json.Null),
          #("notes", json.Array([])),
        ]),
      )
    _ -> Error("unexpected command " <> name)
  }
}

pub fn show_prints_each_key_with_its_source_test() {
  let assert Ok(text) = cli.show(daemon, "p-1")
  assert string.contains(text, "check = make check  (set for this project)")
  assert string.contains(text, "publish = off  (the default)")
  assert string.contains(text, "publish would go to https://github.com/o/r")
}

pub fn turning_publish_on_names_the_url_and_changes_nothing_test() {
  let assert Error(words) =
    cli.set(daemon, "p-1", "publish", ["pull_request"], None)
  assert string.contains(words, "https://github.com/o/r")
  assert string.contains(words, "--publish-to")
}

pub fn publish_with_its_url_is_sent_test() {
  let assert Ok(_) =
    cli.set(
      daemon,
      "p-1",
      "publish",
      ["pull_request"],
      Some("https://github.com/o/r"),
    )
}

pub fn init_without_a_terminal_prints_what_it_would_use_test() {
  // No one can be asked, so nothing is set and the output says how to.
  let refuse = fn(_prompt) { Error("not a terminal") }
  let assert Ok(text) = cli.init_settings(daemon, refuse, "p-1", None, None)
  assert string.contains(text, "would use `make unit` (Makefile target unit)")
  assert string.contains(text, "loom project set check 'make unit'")
  assert string.contains(text, "setup: nothing in this repository suggests one")
}

pub fn init_confirmed_at_a_terminal_sets_the_proposal_test() {
  let yes = fn(_prompt) { Ok("") }
  let assert Ok(text) = cli.init_settings(daemon, yes, "p-1", None, None)
  assert string.contains(text, "revision 3")
}
