//// `/profile` and its alias `/model-profile` (protocol-change/082): both
//// spellings parse to the same session command, the palette and the help text
//// offer them, the frames match the wire, the lane accepts each answer, and the
//// answer is written to the transcript in the words an operator reads.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/command
import session_view/event_fold
import session_view/model as session_model
import session_view/protocol
import session_view/session_channel
import session_view/transcript_line
import tui_test/pushed

pub fn both_spellings_show_the_profile_test() {
  assert command.parse("/profile") == command.Session(command.ProfileShow)
  assert command.parse("/model-profile") == command.Session(command.ProfileShow)
  assert command.parse("  /profile  ") == command.Session(command.ProfileShow)
}

pub fn both_spellings_switch_to_a_named_profile_test() {
  assert command.parse("/profile codex")
    == command.Session(command.ProfileSelect(Some("codex")))
  assert command.parse("/model-profile codex-blue")
    == command.Session(command.ProfileSelect(Some("codex-blue")))
}

// `default` is the word for the default roles, so it never reaches the daemon as
// a name. Any other word is sent as typed for the daemon to judge, since only it
// knows which names the file defines now.
pub fn default_is_the_default_roles_and_other_words_go_to_the_daemon_test() {
  assert command.parse("/profile default")
    == command.Session(command.ProfileSelect(None))
  assert command.parse("/model-profile default")
    == command.Session(command.ProfileSelect(None))
  assert command.parse("/profile Default")
    == command.Session(command.ProfileSelect(Some("Default")))
  assert command.parse("/profile nope")
    == command.Session(command.ProfileSelect(Some("nope")))
}

pub fn model_keeps_its_own_commands_test() {
  assert command.parse("/model") == command.Surface(command.Models)
  assert command.parse("/model fast") == command.Session(command.Model("fast"))
}

pub fn the_palette_offers_both_spellings_and_the_default_word_test() {
  let commands = fn(input) {
    list.map(command.suggestions(input), fn(row) { row.command })
  }
  assert list.contains(commands("/pro"), "/profile")
  assert list.contains(commands("/model-"), "/model-profile")
  assert list.contains(commands("/mod"), "/model-profile")
  assert commands("/profile ") == ["/profile default"]
  assert commands("/model-profile d") == ["/model-profile default"]
  assert commands("/profile x") == []

  // Choosing the head leaves room for the name.
  assert command.selected(command.suggestions("/profile"), 0)
    == Some("/profile ")
}

pub fn the_help_text_lists_both_spellings_test() {
  let help = command.help_text()
  assert string.contains(help, "/profile <name>")
  assert string.contains(help, "/model-profile")
}

pub fn the_frames_match_the_wire_test() {
  assert protocol.profile_get(12)
    == "{\"v\":2,\"id\":12,\"cmd\":\"profile_get\",\"body\":{}}"
  assert protocol.profile_set(13, Some("codex"))
    == "{\"v\":2,\"id\":13,\"cmd\":\"profile_set\",\"body\":{\"profile\":\"codex\"}}"
  assert protocol.profile_set(14, None)
    == "{\"v\":2,\"id\":14,\"cmd\":\"profile_set\",\"body\":{}}"
}

fn snapshot_body(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object([#("mode", json.String("profile")), ..fields])
}

fn profile_event(body: json.JsonValue) -> protocol.Event {
  let text =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(7)),
        #("event", json.String("snapshot")),
        #("body", body),
      ]),
    )
  let assert Ok(event) = protocol.decode_v2_presentation(text)
    as "a profile snapshot is a live presentation"
  event
}

pub fn the_snapshot_decodes_with_and_without_a_profile_test() {
  assert profile_event(
      snapshot_body([
        #("profile", json.String("codex")),
        #("available", json.Array([json.String("codex")])),
      ]),
    )
    == protocol.ProfileSnapshot(
      current: Some("codex"),
      available: ["codex"],
      switched: None,
    )
  assert profile_event(
      snapshot_body([
        #("available", json.Array([])),
        #("moved", json.Int(2)),
      ]),
    )
    == protocol.ProfileSnapshot(current: None, available: [], switched: Some(2))
}

// Each name is a read or a mutation on the lane and is answered by the snapshot,
// which the lane delivers as the reply to exactly that command. An unlisted read
// would default to the mutation lane and hold the composer.
pub fn the_lane_accepts_each_answer_test() {
  let model = pushed.attached()
  let assert Some(channel) = model.shared.channel
    as "the fixture has a synchronized channel"
  let answer = fn(id) {
    pushed.reply(
      id,
      "snapshot",
      snapshot_body([
        #("profile", json.String("codex")),
        #("available", json.Array([json.String("codex")])),
      ]),
    )
  }
  let #(channel, disposition) =
    session_channel.submit(channel, protocol.profile_get(900), now: 0)
  let assert session_channel.Sent("profile_get", read_id) = disposition
    as "the read is issued once"
  assert session_channel.mutation_available(channel)
    as "a read never holds the composer's own lane"
  let #(channel, updates) =
    session_channel.receive(channel, answer(read_id), now: 0)
  let assert [session_channel.Auxiliary(protocol.ProfileSnapshot(..))] = updates
    as "the read is answered by the snapshot"

  let #(channel, disposition) =
    session_channel.submit(
      channel,
      protocol.profile_set(901, Some("codex")),
      now: 0,
    )
  let assert session_channel.Sent("profile_set", set_id) = disposition
    as "the switch is issued on the mutation lane"
  let #(_, updates) = session_channel.receive(channel, answer(set_id), now: 0)
  let assert [session_channel.Auxiliary(protocol.ProfileSnapshot(..))] = updates
    as "the switch is answered by the snapshot"
}

fn system_lines(shared: session_model.Shared(a, b, c, d)) -> List(String) {
  list.filter_map(shared.transcript, fn(line) {
    case line {
      transcript_line.Line(speaker: transcript_line.System, text:) -> Ok(text)
      transcript_line.Line(..) -> Error(Nil)
    }
  })
}

pub fn a_read_lists_the_profile_and_the_names_with_default_first_test() {
  let shared = pushed.attached().shared
  let shown =
    event_fold.apply_event(
      shared,
      protocol.ProfileSnapshot(
        current: Some("codex"),
        available: ["codex", "codex-blue"],
        switched: None,
      ),
    )
  let lines = system_lines(shown)
  assert list.contains(lines, "model profile: codex")
  assert list.contains(
    lines,
    "available: default, codex, codex-blue · /profile <name> switches the session",
  )
}

pub fn a_read_of_the_default_roles_says_so_test() {
  let shown =
    event_fold.apply_event(
      pushed.attached().shared,
      protocol.ProfileSnapshot(current: None, available: [], switched: None),
    )
  let lines = system_lines(shown)
  assert list.contains(lines, "model profile: default roles")
  assert list.contains(
    lines,
    "available: default · /profile <name> switches the session",
  )
}

pub fn a_switch_says_what_was_saved_and_that_the_session_restarts_test() {
  let shown =
    event_fold.apply_event(
      pushed.attached().shared,
      protocol.ProfileSnapshot(
        current: Some("codex-blue"),
        available: ["codex", "codex-blue"],
        switched: Some(1),
      ),
    )
  assert list.contains(
    system_lines(shown),
    "model profile set to codex-blue · 1 strand(s) moved · restarting the session to apply it",
  )
  assert shown.notice == "model profile: codex-blue"
}
