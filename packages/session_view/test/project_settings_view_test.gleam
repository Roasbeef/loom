//// A project's settings and proposals as a client reads them: the decoders
//// are total, a source this client does not know is kept as text, and every
//// string is drawn as one safe line.

import core/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/project_settings_view as view

fn row(key: String, value: List(String), source: String) -> json.JsonValue {
  json.Object([
    #("key", json.String(key)),
    #("value", json.Array(list_of(value))),
    #("source", json.String(source)),
    #("changed_by", json.Null),
    #("changed_ms", json.Null),
  ])
}

fn list_of(words: List(String)) -> List(json.JsonValue) {
  case words {
    [] -> []
    [first, ..rest] -> [json.String(first), ..list_of(rest)]
  }
}

fn body() -> json.JsonValue {
  json.Object([
    #("project", json.String("p-1")),
    #("revision", json.Int(4)),
    #("publish_url", json.String("https://github.com/o/r")),
    #(
      "settings",
      json.Array([
        row("check", ["make check"], "project"),
        row("setup", [], "default"),
        row("max_workers", ["6"], "file"),
        row("publish", ["off"], "newer-source"),
      ]),
    ),
  ])
}

pub fn the_settings_decode_with_their_sources_test() {
  let assert Ok(settings) = view.decode_settings(body())
  assert settings.revision == 4
  assert settings.publish_url == Some("https://github.com/o/r")
  let assert [check, setup, workers, publish] = settings.settings
  assert check.source == view.FromProject
  assert setup.source == view.FromDefault
  assert workers.source == view.FromFile
  assert publish.source == view.UnknownSource("newer-source")
  assert view.value_text(setup) == "none"
}

pub fn the_lines_say_where_each_value_came_from_test() {
  let assert Ok(settings) = view.decode_settings(body())
  let lines = view.lines(settings)
  assert lines
    == [
      "check = make check  (set for this project)",
      "setup = none  (the default)",
      "max_workers = 6  (from loom.toml)",
      "publish = off  (from newer-source)",
      "publish would go to https://github.com/o/r",
      "revision 4",
    ]
}

pub fn a_reply_that_is_not_the_shape_is_an_error_not_a_crash_test() {
  assert result.is_error(view.decode_settings(json.Null))
  assert result.is_error(view.decode_settings(json.Object([])))
  assert result.is_error(
    view.decode_settings(
      json.Object([#("project", json.String("p")), #("revision", json.Int(1))]),
    ),
  )
}

pub fn a_row_with_no_key_is_dropped_test() {
  let weird =
    json.Object([
      #("project", json.String("p")),
      #("revision", json.Int(0)),
      #("settings", json.Array([json.Null, json.Object([])])),
    ])
  let assert Ok(settings) = view.decode_settings(weird)
  assert settings.settings == []
}

pub fn text_is_made_safe_to_draw_test() {
  let hostile =
    json.Object([
      #("project", json.String("p")),
      #("revision", json.Int(0)),
      #(
        "settings",
        json.Array([row("check", ["a\u{1b}[31mred\nline"], "file")]),
      ),
    ])
  let assert Ok(settings) = view.decode_settings(hostile)
  let assert [only] = settings.settings
  let text = view.value_text(only)
  assert !string.contains(text, "\u{1b}")
  assert !string.contains(text, "\n")
}

pub fn a_proposal_decodes_and_prints_test() {
  let proposed =
    json.Object([
      #(
        "check",
        json.Object([
          #("command", json.String("make unit")),
          #("because", json.String("Makefile target unit")),
        ]),
      ),
      #("setup", json.Null),
      #("notes", json.Array([json.String("Makefile is a symbolic link")])),
    ])
  let assert Ok(found) = view.decode_proposed(proposed)
  assert found.check
    == Some(view.Suggestion("make unit", "Makefile target unit"))
  assert found.setup == None
  assert view.proposal_lines(found)
    == [
      "check = make unit  (Makefile target unit)",
      "setup: nothing in this repository suggests one",
      "note: Makefile is a symbolic link",
    ]
}
