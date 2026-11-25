//// The rules of a project's page (`web_view/project_page`): which settings a form
//// changes, how publishing names its URL, and how the composer takes a request.

import core/json
import gleam/option.{None, Some}
import session_view/project_settings_view as settings_view
import web_view/project_page.{Form, Page}
import web_view/projects

fn held() -> settings_view.Settings {
  let assert Ok(decoded) =
    settings_view.decode_settings(
      json.Object([
        #("project", json.String("p1")),
        #("revision", json.Int(4)),
        #("publish_url", json.String("https://github.com/o/n")),
        #(
          "settings",
          json.Array([
            row("check", ["make check"], "project"),
            row("setup", [], "default"),
            row("max_workers", ["4"], "default"),
            row("protected_paths", ["Makefile", ".github/**"], "default"),
          ]),
        ),
      ]),
    )
  decoded
}

fn row(key: String, value: List(String), source: String) -> json.JsonValue {
  json.Object([
    #("key", json.String(key)),
    #("value", json.Array(list_of(value))),
    #("source", json.String(source)),
  ])
}

fn list_of(words: List(String)) -> List(json.JsonValue) {
  case words {
    [] -> []
    [word, ..rest] -> [json.String(word), ..list_of(rest)]
  }
}

// A form that holds what is in force asks for nothing.
pub fn an_unchanged_form_asks_for_nothing_test() {
  assert project_page.changes(
      held(),
      Form("make check", "", "4", "Makefile .github/**"),
    )
    == []
}

// Only a key whose text differs is sent, a new command is its one word, a list is
// its patterns, and a blank box releases a key the project holds and leaves a key
// it does not hold alone.
pub fn only_a_key_that_differs_is_sent_test() {
  assert project_page.changes(
      held(),
      Form("make verify", " make deps ", "6", "docs/** Makefile"),
    )
    == [
      #("check", Some(["make verify"])),
      #("setup", Some(["make deps"])),
      #("max_workers", Some(["6"])),
      #("protected_paths", Some(["docs/**", "Makefile"])),
    ]

  assert project_page.changes(held(), Form("", "", "4", "Makefile .github/**"))
    == [#("check", None)]
}

// Turning publishing on names the URL the settings showed, and turning it off
// names none.
pub fn publishing_on_names_the_url_the_daemon_showed_test() {
  assert project_page.publishing(held(), project_page.PublishOn)
    == #([#("publish", Some(["pull_request"]))], Some("https://github.com/o/n"))
  assert project_page.publishing(held(), project_page.PublishOff)
    == #([#("publish", Some(["off"]))], None)
}

// The composer takes a request once, refuses an empty one and a long one, and
// counts a recorded one so the box empties and the next id differs.
pub fn the_composer_sends_once_and_counts_a_recorded_request_test() {
  let page = project_page.open("p1")

  assert project_page.posting(page, "  ") == Error(page)
  let assert Error(Page(notice: Some(project_page.Refusal(_)), ..)) =
    project_page.posting(page, string_of(project_page.request_limit + 1))

  let assert Ok(#(waiting, "fix the flaky test")) =
    project_page.posting(page, " fix the flaky test ")
  assert waiting.composing == project_page.Sending
  assert project_page.posting(waiting, "again") == Error(waiting)

  let recorded = project_page.post_settled(waiting, projects.Posted("tr-1"))
  assert recorded.sent == 1
  assert project_page.request_id(page) == "web-p1-0"
  assert project_page.request_id(recorded) == "web-p1-1"

  let refused =
    project_page.post_settled(waiting, projects.NotPosted("not_found"))
  assert refused.sent == 0
  assert refused.composing == project_page.Ready
}

fn string_of(count: Int) -> String {
  case count {
    0 -> ""
    _ -> "x" <> string_of(count - 1)
  }
}

// A stored write replaces the settings the page holds; a refusal keeps them and
// says why in the daemon's words.
pub fn a_stored_write_replaces_the_settings_and_a_refusal_keeps_them_test() {
  let page = project_page.open("p1")
  let body =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(5)),
      #("settings", json.Array([row("check", ["make verify"], "project")])),
    ])

  let stored =
    project_page.settings_settled(page, projects.SettingsStored(body))
  let assert project_page.Held(now) = stored.settings
  assert now.revision == 5

  let refused =
    project_page.settings_settled(
      stored,
      projects.SettingsDeclined("bad_request", "project.check is not a command"),
    )
  assert refused.settings == stored.settings
  assert refused.notice
    == Some(project_page.Refusal("project.check is not a command"))
}
