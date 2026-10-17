//// `loom directory status` (protocol-change/083). The launcher parses and refuses
//// what it can before any daemon is started, the control protocol carries the
//// command and keeps the daemon's document whole, and the view reads the document
//// with a decoder of its own and prints it. These tests prove the parts that do
//// not need a daemon.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/directory_view

fn member(name, value) {
  #(name, value)
}

fn voter(node, votes) {
  json.Object([
    member("node", json.String(node)),
    member("voter", json.Bool(votes)),
  ])
}

// What a member answers: three configured nodes, all of which Ra lists, one of
// them leading, and one that is not a voter.
fn reply() -> json.JsonValue {
  json.Object([
    member(
      "members",
      json.Array([
        json.String("alpha@10.0.0.1"),
        json.String("bravo@10.0.0.4"),
        json.String("box@10.0.0.2"),
      ]),
    ),
    member("joined", json.Bool(True)),
    member(
      "ra_members",
      json.Array([
        voter("alpha@10.0.0.1", True),
        voter("bravo@10.0.0.4", True),
        voter("box@10.0.0.2", False),
      ]),
    ),
    member("applied_index", json.Int(412)),
    member("leader", json.String("bravo@10.0.0.4")),
  ])
}

fn is_error(result) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// --- the launcher ------------------------------------------------------------

pub fn the_verb_and_the_json_switch_are_read_before_any_daemon_is_asked_test() {
  assert tui.launch_directory(["status"]) == Ok(tui.AsText)
  assert tui.launch_directory(["status", "--json"]) == Ok(tui.AsJson)
  assert tui.launch_directory(["--json", "status"]) == Ok(tui.AsJson)
  assert tui.launch_directory(["status", "--state-dir", "/tmp/x"])
    == Ok(tui.AsText)
}

pub fn a_missing_or_unknown_verb_or_flag_is_refused_with_the_usage_test() {
  let assert Error(none) = tui.launch_directory([])
  assert string.contains(none, "usage: loom directory status")
  let assert Error(unknown) = tui.launch_directory(["join"])
  assert string.contains(unknown, "usage: loom directory status")
  let assert Error(flag) = tui.launch_directory(["status", "--nope", "x"])
  assert string.contains(flag, "--nope")
  assert string.contains(flag, "usage: loom directory status")
}

// --- the control protocol ----------------------------------------------------

pub fn the_command_is_a_read_with_no_body_test() {
  assert protocol.name(protocol.DirectoryStatus) == "directory.status"
  assert !protocol.mutates(protocol.DirectoryStatus)
  assert protocol.encode(3, protocol.DirectoryStatus, protocol.Epoch("current"))
    == Ok("{\"v\":2,\"id\":3,\"cmd\":\"directory.status\",\"body\":{}}")
}

pub fn the_answer_keeps_the_daemons_document_whole_test() {
  let frame =
    "{\"v\":2,\"reply_to\":3,\"event\":\"directory.status\",\"body\":{\"members\":[],\"joined\":false,\"applied_index\":0,\"future\":1}}"
  let assert Ok(protocol.Answer(
    3,
    "directory.status",
    protocol.DirectoryReply(document),
  )) = protocol.decode(frame)
  assert document
    == json.Object([
      member("members", json.Array([])),
      member("joined", json.Bool(False)),
      member("applied_index", json.Int(0)),
      member("future", json.Int(1)),
    ])
}

pub fn the_refusals_are_worded_as_what_they_mean_test() {
  assert selection.directory_failure(daemon.Refused(
      "bad_request",
      "unsupported control command",
    ))
    == "this daemon does not have directory views"
  assert selection.directory_failure(daemon.Refused("not_found", "not found"))
    == "this daemon is not a member of the session directory"
  assert selection.directory_failure(daemon.Refused(
      "forbidden",
      "request refused",
    ))
    == "forbidden: request refused"
}

// --- the reading and the text ------------------------------------------------

pub fn a_reply_is_read_into_members_votes_and_leader_test() {
  let assert Ok(status) = directory_view.decode(reply())
  assert status.members == ["alpha@10.0.0.1", "bravo@10.0.0.4", "box@10.0.0.2"]
  assert status.joining == directory_view.Joined
  assert status.leader == Some("bravo@10.0.0.4")
  assert status.applied_index == 412
  assert list.map(status.ra_members, fn(found) { found.vote })
    == [directory_view.Voter, directory_view.Voter, directory_view.NonVoter]
  assert status.unavailable == None
}

pub fn the_text_names_the_members_their_votes_and_the_leader_test() {
  let assert Ok(text) = tui.format_directory(reply(), tui.AsText)
  assert text
    == string.join(
      [
        "directory: 3 members, 2 voters, leader bravo@10.0.0.4, applied index 412",
        "this node has joined the cluster",
        "",
        "NODE            VOTE       ROLE    NOTE",
        "alpha@10.0.0.1  voter",
        "bravo@10.0.0.4  voter      leader",
        "box@10.0.0.2    non-voter",
      ],
      "\n",
    )
}

// A member that cannot reach a quorum says why Ra cannot name voters or a
// leader, and the text says that instead of inventing them. A Ra member the
// configured list lacks is drawn with that note.
pub fn a_cluster_that_cannot_say_or_that_differs_from_the_list_is_drawn_so_test() {
  let blind =
    json.Object([
      member("members", json.Array([json.String("alpha@10.0.0.1")])),
      member("joined", json.Bool(False)),
      member("ra_members", json.Array([])),
      member("applied_index", json.Int(0)),
      member("unavailable", json.String("no quorum")),
    ])
  let assert Ok(text) = tui.format_directory(blind, tui.AsText)
  assert text
    == string.join(
      [
        "directory: 1 member, no cluster view (no quorum), applied index 0",
        "this node has not joined the cluster",
        "",
        "NODE            VOTE  ROLE  NOTE",
        "alpha@10.0.0.1  -",
      ],
      "\n",
    )

  let extra =
    json.Object([
      member("members", json.Array([json.String("alpha@10.0.0.1")])),
      member("joined", json.Bool(True)),
      member(
        "ra_members",
        json.Array([voter("alpha@10.0.0.1", True), voter("zed@10.0.0.9", True)]),
      ),
      member("applied_index", json.Int(7)),
    ])
  let assert Ok(text) = tui.format_directory(extra, tui.AsText)
  assert string.contains(text, "no leader")
  assert string.contains(text, "zed@10.0.0.9    voter")
  assert string.contains(text, "not in the configured list")
}

pub fn json_prints_the_daemons_document_unread_test() {
  let odd = json.Object([member("anything", json.Array([json.Int(1)]))])
  assert tui.format_directory(odd, tui.AsJson) == Ok(json.to_string(odd))
}

pub fn a_reply_without_its_required_members_is_an_error_not_a_crash_test() {
  assert directory_view.decode(json.Object([])) |> is_error
  assert directory_view.decode(json.Null) |> is_error
  assert directory_view.decode(json.Array([])) |> is_error
  let assert json.Object(members) = reply()
  list.each(["members", "joined", "applied_index"], fn(key) {
    let without = json.Object(list.filter(members, fn(each) { each.0 != key }))
    assert directory_view.decode(without) |> is_error
  })
  let assert Error(words) = tui.format_directory(json.Object([]), tui.AsText)
  assert string.contains(
    words,
    "the daemon's directory reply was not understood",
  )
}

pub fn text_and_lists_beyond_their_bounds_are_refused_or_dropped_test() {
  let long = string.repeat("a", 300)
  let with_members = fn(names) {
    json.Object([
      member("members", json.Array(names)),
      member("joined", json.Bool(True)),
      member("applied_index", json.Int(1)),
    ])
  }
  assert directory_view.decode(with_members([json.String(long)])) |> is_error
  assert directory_view.decode(
      with_members(list.repeat(json.String("alpha@10.0.0.1"), times: 129)),
    )
    |> is_error

  // A bad entry in an optional list is skipped, and too long a leader is absent.
  let assert json.Object(members) = reply()
  let widened =
    json.Object(
      list.map(members, fn(each) {
        case each.0 {
          "ra_members" ->
            member(
              "ra_members",
              json.Array([
                json.String("nonsense"),
                voter("alpha@10.0.0.1", True),
              ]),
            )
          "leader" -> member("leader", json.String(long))
          _ -> each
        }
      }),
    )
  let assert Ok(status) = directory_view.decode(widened)
  assert list.length(status.ra_members) == 1
  assert status.leader == None
}

pub fn a_hostile_node_name_cannot_move_the_cursor_or_start_a_row_test() {
  let hostile =
    json.Object([
      member("members", json.Array([json.String("evil\u{1b}[2J\nFAKE ROW")])),
      member("joined", json.Bool(True)),
      member("applied_index", json.Int(1)),
      member("leader", json.String("l\rrr")),
    ])
  let assert Ok(text) = tui.format_directory(hostile, tui.AsText)
  assert !string.contains(text, "\u{1b}")
  assert !string.contains(text, "\r")
  assert list.length(string.split(text, "\n")) == 5
}
