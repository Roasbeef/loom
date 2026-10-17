//// `loom sessions elsewhere` and the other orchestrators' section of
//// `loom sessions list` (protocol-change/085): how the launcher parses them,
//// what goes on the wire, how a refusal is worded, and how the reply is drawn.
//// The daemon's side is `daemon_elsewhere_test` in the client package.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/elsewhere_view

const id_one = "0198c1aa-0000-7000-8000-000000000001"

const id_two = "0198c1aa-0000-7000-8000-000000000002"

fn member(key: String, value: json.JsonValue) {
  #(key, value)
}

fn row(id: String, workspace: String, name: String) -> json.JsonValue {
  json.Object([
    member("session_id", json.String(id)),
    member("workspace", json.String(workspace)),
    member("name", json.String(name)),
    member("created_at", json.Int(1_756_000_100_000)),
    member("status", json.Object([member("state", json.String("saved"))])),
  ])
}

fn answered(
  name: String,
  rows: List(json.JsonValue),
  more: Bool,
) -> json.JsonValue {
  json.Object([
    member("name", json.String(name)),
    member("node", json.String(name <> "@10.0.0.4")),
    member("state", json.String("answered")),
    member("address", json.String("ws://10.0.0.4:7000")),
    member("more", json.Bool(more)),
    member("sessions", json.Array(rows)),
  ])
}

fn silent(name: String) -> json.JsonValue {
  json.Object([
    member("name", json.String(name)),
    member("node", json.String(name <> "@10.0.0.7")),
    member("state", json.String("silent")),
    member("more", json.Bool(False)),
    member("sessions", json.Array([])),
  ])
}

fn body(groups: List(json.JsonValue)) -> json.JsonValue {
  json.Object([member("orchestrators", json.Array(groups))])
}

// --- the launcher ---------------------------------------------------------------

pub fn a_listing_reaches_the_other_orchestrators_unless_it_is_local_test() {
  let assert Ok(tui.ListRegistrations(reach: tui.AllOrchestrators, ..)) =
    tui.launch_sessions(["list"])
  let assert Ok(tui.ListRegistrations(
    showing: tui.Every,
    reach: tui.ThisDaemonOnly,
  )) = tui.launch_sessions(["list", "--all", "--local"])
  let assert Ok(tui.ListRegistrations(reach: tui.ThisDaemonOnly, ..)) =
    tui.launch_sessions(["list", "--local", "--state-dir", "/var/tmp/x"])
}

pub fn the_elsewhere_verb_takes_a_key_a_cursor_and_json_test() {
  let assert Ok(tui.ListElsewhere(None, None, tui.AsText)) =
    tui.launch_sessions(["elsewhere"])
  let assert Ok(tui.ListElsewhere(None, None, tui.AsJson)) =
    tui.launch_sessions(["elsewhere", "--json"])
  let assert Ok(tui.ListElsewhere(Some("desk"), Some(after), tui.AsJson)) =
    tui.launch_sessions([
      "elsewhere", "--orchestrator", "desk", "--after", id_one, "--json",
    ])
  assert after == id_one
  let assert Ok(tui.ListElsewhere(Some("desk"), None, tui.AsText)) =
    tui.launch_sessions(["elsewhere", "--orchestrator", "desk"])
}

pub fn a_cursor_without_its_orchestrator_or_a_node_name_is_refused_test() {
  let assert Error(without) =
    tui.launch_sessions(["elsewhere", "--after", id_one])
  assert string.contains(without, "--after needs --orchestrator")
  let assert Error(node) =
    tui.launch_sessions(["elsewhere", "--orchestrator", "desk@10.0.0.8"])
  assert string.contains(node, "--orchestrator must be the name of an")
  let assert Error(twice) =
    tui.launch_sessions([
      "elsewhere", "--orchestrator", "desk", "--orchestrator", "laptop",
    ])
  assert string.contains(twice, "more than once")
}

pub fn the_usage_names_both_commands_and_local_test() {
  let assert Error(usage) = tui.launch_sessions(["bogus"])
  assert string.contains(usage, "loom sessions elsewhere")
  assert string.contains(usage, "--local")
}

// --- the control protocol -----------------------------------------------------

pub fn the_command_is_a_read_that_names_its_group_only_when_asked_test() {
  let epoch = protocol.Epoch("current")
  assert protocol.name(protocol.SessionsElsewhere(None, None))
    == "sessions.elsewhere"
  assert !protocol.mutates(protocol.SessionsElsewhere(None, None))
  assert protocol.encode(3, protocol.SessionsElsewhere(None, None), epoch)
    == Ok("{\"v\":2,\"id\":3,\"cmd\":\"sessions.elsewhere\",\"body\":{}}")
  assert protocol.encode(
      4,
      protocol.SessionsElsewhere(Some("desk"), Some(id_one)),
      epoch,
    )
    == Ok(
      "{\"v\":2,\"id\":4,\"cmd\":\"sessions.elsewhere\",\"body\":{\"orchestrator\":\"desk\",\"after\":\""
      <> id_one
      <> "\"}}",
    )

  // A cursor with no group, a node name and a cursor that is not an identity
  // never reach the wire.
  let assert Error(_) =
    protocol.encode(5, protocol.SessionsElsewhere(None, Some(id_one)), epoch)
  let assert Error(_) =
    protocol.encode(
      6,
      protocol.SessionsElsewhere(Some("desk@10.0.0.8"), None),
      epoch,
    )
  let assert Error(_) =
    protocol.encode(
      7,
      protocol.SessionsElsewhere(Some("desk"), Some("later")),
      epoch,
    )
}

pub fn the_answer_keeps_the_daemons_document_whole_test() {
  let frame =
    "{\"v\":2,\"reply_to\":3,\"event\":\"sessions.elsewhere\",\"body\":{\"orchestrators\":[],\"future\":1}}"
  let assert Ok(protocol.Answer(
    3,
    "sessions.elsewhere",
    protocol.ElsewhereReply(document),
  )) = protocol.decode(frame)
  assert document
    == json.Object([
      member("orchestrators", json.Array([])),
      member("future", json.Int(1)),
    ])
}

pub fn a_daemon_that_predates_the_command_is_not_at_fault_test() {
  assert selection.elsewhere_failure(daemon.Refused(
      "bad_request",
      "unsupported control command",
    ))
    == selection.NoElsewhereViews
  assert selection.elsewhere_failure(daemon.Refused("not_found", "not found"))
    == selection.ElsewhereFailed(
      "the daemon's configuration has no orchestrator under that name",
    )
  let assert selection.ElsewhereFailed(words) =
    selection.elsewhere_failure(daemon.Refused("forbidden", "owner only"))
  assert string.contains(words, "forbidden")
}

// --- the reading ------------------------------------------------------------------

pub fn an_answered_group_lists_its_sessions_under_its_name_test() {
  let document =
    body([
      answered(
        "desk",
        [row(id_one, "/src/loom", "docs pass"), row(id_two, "/src/web", "ui")],
        False,
      ),
    ])
  assert tui.format_elsewhere(document, tui.AsText)
    == Ok(
      "on other orchestrators:\n"
      <> "desk  desk@10.0.0.4  ws://10.0.0.4:7000\n"
      <> "  "
      <> id_one
      <> "  saved  /src/loom  docs pass\n"
      <> "  "
      <> id_two
      <> "  saved  /src/web  ui",
    )
}

pub fn a_silent_group_is_one_line_and_not_an_empty_one_test() {
  let assert Ok(text) =
    tui.format_elsewhere(
      body([silent("laptop"), answered("desk", [], False)]),
      tui.AsText,
    )
  assert text
    == "on other orchestrators:\n"
    <> "laptop  laptop@10.0.0.7\n"
    <> "  no answer\n"
    <> "desk  desk@10.0.0.4  ws://10.0.0.4:7000\n"
    <> "  no sessions"
}

pub fn a_group_with_more_names_the_command_for_its_next_page_test() {
  let assert Ok(text) =
    tui.format_elsewhere(
      body([answered("desk", [row(id_one, "/w", "n")], True)]),
      tui.AsText,
    )
  assert string.ends_with(
    text,
    "  more: loom sessions elsewhere --orchestrator desk --after " <> id_one,
  )
}

pub fn the_json_output_is_the_document_as_it_was_sent_test() {
  let document = body([silent("laptop")])
  assert tui.format_elsewhere(document, tui.AsJson)
    == Ok(json.to_string(document))
}

pub fn no_other_orchestrators_is_said_in_words_test() {
  assert tui.format_elsewhere(body([]), tui.AsText)
    == Ok("no other orchestrators")
}

pub fn control_characters_in_a_name_do_not_start_a_row_test() {
  let assert Ok(text) =
    tui.format_elsewhere(
      body([answered("desk", [row(id_one, "/w", "a\nb\u{1b}[2Jc")], False)]),
      tui.AsText,
    )
  assert list.length(string.split(text, "\n")) == 3
  assert !string.contains(text, "\u{1b}")
}

pub fn a_reply_that_is_not_shaped_as_the_protocol_says_is_not_drawn_test() {
  let bad = [
    json.Object([]),
    body([json.Object([member("name", json.String("desk"))])]),
    body([
      json.Object([
        member("name", json.String("desk")),
        member("node", json.String("desk@10.0.0.4")),
        member("state", json.String("maybe")),
        member("more", json.Bool(False)),
        member("sessions", json.Array([])),
      ]),
    ]),
    body([
      answered(
        "desk",
        [json.Object([member("session_id", json.Int(1))])],
        False,
      ),
    ]),
    body(list.repeat(silent("desk"), 129)),
  ]
  list.each(bad, fn(document) {
    let assert Error(reason) = tui.format_elsewhere(document, tui.AsText)
    assert string.contains(reason, "was not understood")
  })
  let assert Error(_) = elsewhere_view.decode(json.Null)
}
