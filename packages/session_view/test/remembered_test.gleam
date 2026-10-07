//// What a session remembers, as a client reads it: the board's total decoder,
//// the words both hosts use for a row, and the frames a forget becomes.

import core/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/protocol
import session_view/remembered

fn network() -> json.JsonValue {
  json.Object([
    #("type", json.String("network")),
    #("network", json.Object([#("mode", json.String("full"))])),
  ])
}

fn path(kind: String, text: String) -> json.JsonValue {
  json.Object([#("type", json.String(kind)), #("path", json.String(text))])
}

fn approved(name: String, via: json.JsonValue) -> json.JsonValue {
  json.Object([
    #(
      "by",
      json.Object([
        #("principal", json.String("alice")),
        #("name", json.String(name)),
      ]),
    ),
    #("via", via),
    #("at_ms", json.Int(1_790_000_000_000)),
  ])
}

fn login() -> json.JsonValue {
  json.Object([
    #("kind", json.String("login")),
    #("fingerprint", json.String("9c1e0f2ab3d4e5f6")),
  ])
}

fn board(grants: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("seq", json.Int(7)),
    #("grants", json.Array(grants)),
    #("actions", json.Array([])),
  ])
}

fn row(grant: json.JsonValue, provenance: json.JsonValue) -> json.JsonValue {
  json.Object([#("grant", grant), #("provenance", provenance)])
}

pub fn a_board_decodes_with_who_approved_each_row_test() {
  let assert Ok(decoded) =
    remembered.decode(
      board([
        row(path("readable_root", "/repo"), approved("Alice", login())),
        row(network(), json.Null),
      ]),
    )
  assert decoded.seq == Some(7)
  let assert [first, second] = decoded.grants
  assert first.kind == remembered.Readable("/repo")
  assert remembered.who(first.provenance)
    == "Alice from a browser sign-in 9c1e0f2ab3d4e5f6"
  assert remembered.when(first.provenance) == Some(1_790_000_000_000)
  assert remembered.login(first.provenance)
    == Some(#("alice", "9c1e0f2ab3d4e5f6"))
  assert second.kind == remembered.FullNetwork
  assert second.provenance == remembered.Unknown
  assert remembered.who(second.provenance)
    == "Approved before approvals were recorded"
}

pub fn a_damaged_provenance_never_hides_its_permission_test() {
  let assert Ok(decoded) =
    remembered.decode(
      board([
        row(path("writable_root", "/repo"), json.String("junk")),
        row(
          path("readable_root", "/etc"),
          json.Object([#("by", json.Null), #("at_ms", json.Int(-4))]),
        ),
      ]),
    )
  assert decoded.grants
    |> list_kinds
    == [remembered.Writable("/repo"), remembered.Readable("/etc")]
  assert list_provenances(decoded.grants)
    == [remembered.Unknown, remembered.Unknown]
}

fn list_kinds(rows: List(remembered.Permission)) -> List(remembered.Kind) {
  case rows {
    [] -> []
    [first, ..rest] -> [first.kind, ..list_kinds(rest)]
  }
}

fn list_provenances(
  rows: List(remembered.Permission),
) -> List(remembered.Provenance) {
  case rows {
    [] -> []
    [first, ..rest] -> [first.provenance, ..list_provenances(rest)]
  }
}

// A daemon that remembers a kind this client has not learned is still
// listed, and its row can still be forgotten by echoing it, so a newer daemon
// does not close an older page.
pub fn a_row_of_an_unfamiliar_kind_is_kept_not_refused_test() {
  let strange = json.Object([#("type", json.String("quantum"))])
  let assert Ok(decoded) = remembered.decode(board([row(strange, json.Null)]))
  let assert [only] = decoded.grants
  assert only.kind == remembered.Unrecognized("quantum")
  assert only.wire == strange
}

pub fn a_malformed_board_is_an_error_not_a_crash_test() {
  assert result.is_error(remembered.decode(json.String("board")))
  assert result.is_error(remembered.decode(json.Object([])))
  assert result.is_error(
    remembered.decode(
      json.Object([
        #("seq", json.String("seven")),
        #("grants", json.Array([])),
        #("actions", json.Array([])),
      ]),
    ),
  )
  assert result.is_error(remembered.decode(board([json.String("row")])))
}

pub fn the_words_for_a_row_are_the_same_in_both_hosts_test() {
  assert remembered.describe(remembered.Readable("/repo")) == "Read /repo"
  assert remembered.describe(remembered.Writable("/repo/out"))
    == "Write /repo/out"
  assert remembered.describe(remembered.FullNetwork) == "Network access"
  let consent =
    remembered.Consent(
      id: "ab12",
      seq: 3,
      tool: Some("bash"),
      strand: Some("main"),
      preview: Some("make check"),
      provenance: remembered.Unknown,
    )
  assert remembered.describe_consent(consent) == "bash on main: make check"
  assert remembered.summary(remembered.Board(None, [], []))
    == "Nothing is remembered"
}

// Paths and names are session text. The words strip what would move a
// terminal's cursor or break a line, so a hostile path is one inert line.
pub fn hostile_text_is_one_inert_line_test() {
  let words = remembered.describe(remembered.Readable("/repo\n\u{1b}[31mred"))
  assert !string.contains(words, "\n")
  assert !string.contains(words, "\u{1b}")
}

pub fn a_forget_frame_names_its_target_and_echoes_the_sequence_test() {
  let everything =
    protocol.permission_forget(5, remembered.ForgetEverything(Some(7)))
  assert string.contains(everything, "\"cmd\":\"permission_forget\"")
  assert string.contains(everything, "\"kind\":\"all\"")
  assert string.contains(everything, "\"expected_seq\":7")
  let one =
    protocol.permission_forget(
      6,
      remembered.ForgetPermission(wire: network(), seq: None),
    )
  assert string.contains(one, "\"kind\":\"grant\"")
  assert !string.contains(one, "expected_seq")
  let consent =
    protocol.permission_forget(7, remembered.ForgetConsent("ab12", 4))
  assert string.contains(consent, "\"kind\":\"action\"")
  assert string.contains(consent, "\"id\":\"ab12\"")
  assert string.contains(consent, "\"expected_seq\":4")
}

pub fn the_read_is_an_empty_bodied_command_test() {
  assert string.contains(protocol.permissions(9), "\"cmd\":\"permissions\"")
}

pub fn a_permissions_snapshot_decodes_as_an_event_test() {
  let frame =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(9)),
        #("event", json.String("snapshot")),
        #(
          "body",
          json.Object([
            #("mode", json.String("permissions")),
            #("board", board([row(network(), json.Null)])),
          ]),
        ),
      ]),
    )
  let assert Ok(protocol.PermissionsSnapshot(decoded)) =
    protocol.decode_v2_presentation(frame)
  assert remembered.count(decoded) == 1
}
