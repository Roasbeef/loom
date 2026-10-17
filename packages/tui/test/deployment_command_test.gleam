//// `loom deployment status` and `loom deployment executors`
//// (protocol-change/085). The launcher parses and refuses what it can before
//// any daemon is started, the control protocol carries the command and its
//// answer, and the view reads the answer with a decoder of its own and prints
//// it. These tests prove the parts that do not need a daemon: the words the
//// launcher accepts, the frame it sends, what it makes of each shape of reply,
//// and the text it prints.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/deployment_view

fn member(name, value) {
  #(name, value)
}

fn node(node, name, role, state, reason) {
  json.Object(
    list.flatten([
      [
        member("node", json.String(node)),
        member("name", json.String(name)),
        member("roles", json.Array([json.String(role)])),
        member("state", json.String(state)),
      ],
      case reason {
        Some(word) -> [member("reason", json.String(word))]
        None -> []
      },
    ]),
  )
}

fn edge(to, kind, link) {
  json.Object([
    member("from", json.String("alpha@10.0.0.1")),
    member("to", json.String(to)),
    member("kind", json.String(kind)),
    member("link", json.String(link)),
  ])
}

fn executor(name, node, state, declared) {
  json.Object([
    member("name", json.String(name)),
    member("node", json.String(node)),
    member("state", json.String(state)),
    member("declared", json.Object(declared)),
  ])
}

// What a daemon answers with three nodes up and an executor down: the example
// of the design, as this slice's daemon writes it.
fn reply() -> json.JsonValue {
  json.Object([
    member("as_of_ms", json.Int(1_760_190_131_000)),
    member("self", json.String("alpha@10.0.0.1")),
    member("state", json.String("degraded")),
    member(
      "reasons",
      json.Array([
        json.Object([
          member("node", json.String("exec2@10.0.0.9")),
          member("reason", json.String("timeout")),
        ]),
      ]),
    ),
    member(
      "nodes",
      json.Array([
        node("alpha@10.0.0.1", "alpha@10.0.0.1", "orchestrator", "ok", None),
        node("bravo@10.0.0.4", "bravo", "orchestrator", "ok", None),
        node("box@10.0.0.2", "box", "executor", "ok", None),
        node("exec2@10.0.0.9", "exec2", "executor", "down", Some("timeout")),
      ]),
    ),
    member(
      "edges",
      json.Array([
        edge("bravo@10.0.0.4", "peer", "connected"),
        edge("box@10.0.0.2", "serves", "connected"),
        edge("exec2@10.0.0.9", "serves", "none"),
      ]),
    ),
    member(
      "placements",
      json.Object([
        member(
          "executors",
          json.Array([
            executor("box", "box@10.0.0.2", "ready", [
              member("toolchains", json.Array([])),
            ]),
            executor("exec2", "exec2@10.0.0.9", "down", [
              member("platform", json.String("linux/x86_64")),
              member("enforcement", json.String("enforced")),
              member("toolchains", json.Array([json.String("codemode")])),
            ]),
          ]),
        ),
        member(
          "pools",
          json.Array([
            json.Object([
              member("name", json.String("builders")),
              member(
                "executors",
                json.Array([json.String("exec2"), json.String("box")]),
              ),
              member("eligible", json.Array([json.String("box")])),
            ]),
          ]),
        ),
      ]),
    ),
  ])
}

// --- the launcher ------------------------------------------------------------

pub fn the_verbs_and_the_json_switch_are_read_before_any_daemon_is_asked_test() {
  assert tui.launch_deployment(["status"])
    == Ok(tui.ShowDeployment(None, tui.AsText))
  assert tui.launch_deployment(["executors"])
    == Ok(tui.ShowExecutors(tui.AsText))
  assert tui.launch_deployment(["status", "--json"])
    == Ok(tui.ShowDeployment(None, tui.AsJson))
  assert tui.launch_deployment(["--json", "executors"])
    == Ok(tui.ShowExecutors(tui.AsJson))

  // The shared local options compose with them in either order.
  assert tui.launch_deployment(["status", "--state-dir", "/tmp/x", "--json"])
    == Ok(tui.ShowDeployment(None, tui.AsJson))
  assert tui.launch_deployment(["executors", "--server", "/tmp/s"])
    == Ok(tui.ShowExecutors(tui.AsText))
}

pub fn a_node_key_narrows_status_to_one_node_test() {
  assert tui.launch_deployment(["status", "--node", "build-box"])
    == Ok(tui.ShowDeployment(Some("build-box"), tui.AsText))
  assert tui.launch_deployment(["status", "--json", "--node", "desk"])
    == Ok(tui.ShowDeployment(Some("desk"), tui.AsJson))
  assert tui.launch_deployment([
      "--node",
      "box",
      "status",
      "--state-dir",
      "/tmp/x",
    ])
    == Ok(tui.ShowDeployment(Some("box"), tui.AsText))
}

// A node is named by its configuration key. A node name, a path or an empty
// word is refused here, before any daemon is asked, and the flag belongs to
// `status` alone.
pub fn a_node_that_is_not_a_configuration_key_is_refused_test() {
  list.each(["box@10.0.0.2", "Box", "../x", "a b", ""], fn(word) {
    let assert Error(refusal) =
      tui.launch_deployment(["status", "--node", word])
    assert string.contains(refusal, "usage: loom deployment status")
  })
  let assert Error(missing) = tui.launch_deployment(["status", "--node"])
  assert string.contains(missing, "--node")
  let assert Error(misplaced) =
    tui.launch_deployment(["executors", "--node", "box"])
  assert string.contains(misplaced, "--node applies to status only")
}

pub fn an_unknown_verb_a_missing_verb_or_an_unknown_flag_is_refused_with_the_usage_test() {
  let assert Error(none) = tui.launch_deployment([])
  assert string.contains(none, "loom deployment status")
  assert string.contains(none, "loom deployment executors")
  let assert Error(unknown) = tui.launch_deployment(["bogus"])
  assert string.contains(unknown, "usage: loom deployment status")
  let assert Error(flag) = tui.launch_deployment(["status", "--nope", "x"])
  assert string.contains(flag, "--nope")
  assert string.contains(flag, "usage: loom deployment")
}

pub fn the_usage_says_that_a_down_executor_is_still_a_choice_test() {
  let assert Error(usage) = tui.launch_deployment([])
  assert string.contains(
    usage,
    "does not stop you from choosing one that is down",
  )
  assert string.contains(
    usage,
    "--json prints the daemon's reply as it was sent",
  )
}

// --- the control protocol ----------------------------------------------------

pub fn the_command_is_a_read_with_no_body_unless_it_names_a_node_test() {
  assert protocol.name(protocol.DeploymentStatus(None)) == "deployment.status"
  assert !protocol.mutates(protocol.DeploymentStatus(None))
  assert protocol.encode(
      3,
      protocol.DeploymentStatus(None),
      protocol.Epoch("current"),
    )
    == Ok("{\"v\":2,\"id\":3,\"cmd\":\"deployment.status\",\"body\":{}}")
  assert protocol.encode(
      4,
      protocol.DeploymentStatus(Some("build-box")),
      protocol.Epoch("current"),
    )
    == Ok(
      "{\"v\":2,\"id\":4,\"cmd\":\"deployment.status\",\"body\":{\"node\":\"build-box\"}}",
    )

  // A key outside the grammar never reaches the wire.
  assert protocol.encode(
      5,
      protocol.DeploymentStatus(Some("box@10.0.0.2")),
      protocol.Epoch("current"),
    )
    == Error("node must be a configuration key")
}

pub fn a_missing_node_is_worded_as_one_test() {
  assert selection.deployment_failure(daemon.Refused("not_found", "not found"))
    == "the daemon's configuration has no executor or orchestrator under that name"
}

pub fn the_answer_keeps_the_daemons_document_whole_test() {
  let frame =
    "{\"v\":2,\"reply_to\":3,\"event\":\"deployment.status\",\"body\":{\"self\":\"alpha@10.0.0.1\",\"state\":\"ok\",\"nodes\":[],\"future\":1}}"
  let assert Ok(protocol.Answer(
    3,
    "deployment.status",
    protocol.DeploymentReply(document),
  )) = protocol.decode(frame)
  assert document
    == json.Object([
      member("self", json.String("alpha@10.0.0.1")),
      member("state", json.String("ok")),
      member("nodes", json.Array([])),
      member("future", json.Int(1)),
    ])
}

pub fn a_daemon_that_does_not_know_the_command_is_said_not_to_have_the_view_test() {
  let refusal =
    protocol.decode(
      "{\"v\":2,\"reply_to\":3,\"event\":\"error\",\"body\":{\"code\":\"bad_request\",\"message\":\"unsupported control command\"}}",
    )
  assert refusal
    == Ok(protocol.Refused(
      Some(3),
      "bad_request",
      "unsupported control command",
    ))
  assert selection.deployment_failure(daemon.Refused(
      "bad_request",
      "unsupported control command",
    ))
    == "this daemon does not have deployment views"
}

pub fn the_other_refusals_keep_their_code_and_words_test() {
  assert selection.deployment_failure(daemon.Refused(
      "forbidden",
      "request refused",
    ))
    == "forbidden: request refused"
  assert selection.deployment_failure(daemon.Refused(
      "bad_request",
      "node must be a name",
    ))
    == "bad_request: node must be a name"
  assert selection.deployment_failure(daemon.TimedOut)
    == "daemon control timed out; reconnect explicitly"
}

// --- the reading of a reply --------------------------------------------------

pub fn a_reply_is_read_into_nodes_edges_executors_and_pools_test() {
  let assert Ok(status) = deployment_view.decode(reply())
  assert status.self == "alpha@10.0.0.1"
  assert status.state == deployment_view.NodeDegraded
  assert status.reasons == [#("exec2@10.0.0.9", "timeout")]
  assert list.map(status.nodes, fn(each) { each.name })
    == ["alpha@10.0.0.1", "bravo", "box", "exec2"]
  assert list.map(status.edges, fn(each) { each.link })
    == [
      deployment_view.Connected,
      deployment_view.Connected,
      deployment_view.NotConnected,
    ]
  assert list.map(status.executors, fn(each) { each.state })
    == [deployment_view.PlacementReady, deployment_view.PlacementDown]
  assert list.map(status.pools, fn(each) { each.eligible }) == [["box"]]
}

// --- the ledger of a daemon that runs from one --------------------------------

fn ledger_member(name, reported, age) {
  json.Object(
    list.flatten([
      [member("name", json.String(name))],
      case reported {
        Some(seq) -> [member("reported_seq", json.Int(seq))]
        None -> []
      },
      case age {
        Some(ms) -> [member("ms_since_report", json.Int(ms))]
        None -> []
      },
    ]),
  )
}

// The body of `ledger.status`, which `deployment.status` carries under `ledger`.
fn ledger(refusal) -> json.JsonValue {
  json.Object([
    member("deployment", json.String(string.repeat("a", 32))),
    member("state", json.String("ok")),
    member(
      "head",
      json.Object([
        member("seq", json.Int(9)),
        member("id", json.String("4c1e9a0b" <> string.repeat("0", 56))),
      ]),
    ),
    member(
      "members",
      json.Array([
        ledger_member("alpha", Some(9), Some(0)),
        ledger_member("box", Some(7), Some(125_000)),
        ledger_member("laptop", None, None),
        ledger_member("desk", Some(9), Some(4000)),
      ]),
    ),
    member("last_refusal", refusal),
  ])
}

fn with_ledger(value: json.JsonValue) -> json.JsonValue {
  let assert json.Object(members) = reply()
  json.Object(list.append(members, [member("ledger", value)]))
}

pub fn the_ledger_head_and_each_members_report_are_read_and_drawn_test() {
  let assert Ok(status) = deployment_view.decode(with_ledger(ledger(json.Null)))
  let assert Some(found) = status.ledger
  assert found.head_seq == 9
  assert found.head_id == "4c1e9a0b"
  assert list.map(found.members, fn(each) { each.reported })
    == [Some(9), Some(7), None, Some(9)]
  assert found.last_refusal == None

  let drawn = deployment_view.status_text(status)
  assert string.contains(
    drawn,
    "LEDGER entry 9 (4c1e9a0b), 2 of 4 members hold it",
  )
  assert string.contains(drawn, "alpha   entry 9  current, 0s ago")
  assert string.contains(drawn, "box     entry 7  behind by 2, 2m ago")
  assert string.contains(drawn, "laptop  -        not reported")
  assert !string.contains(drawn, "last refusal")
}

pub fn the_last_refusal_is_drawn_with_its_step_test() {
  let refusal =
    json.Object([
      member("seq", json.Int(7)),
      member("step", json.String("fork")),
    ])
  let assert Ok(status) = deployment_view.decode(with_ledger(ledger(refusal)))
  let assert Some(found) = status.ledger
  assert found.last_refusal
    == Some(deployment_view.LedgerRefusal(seq: Some(7), step: "fork"))
  assert string.contains(
    deployment_view.status_text(status),
    "last refusal: entry 7, step fork",
  )
}

pub fn a_daemon_without_a_ledger_draws_no_ledger_section_test() {
  let assert Ok(status) = deployment_view.decode(reply())
  assert status.ledger == None
  assert !string.contains(deployment_view.status_text(status), "LEDGER")
}

pub fn a_ledger_that_does_not_decode_is_left_out_and_the_rest_is_drawn_test() {
  let broken = json.Object([member("state", json.String("ok"))])
  let assert Ok(status) = deployment_view.decode(with_ledger(broken))
  assert status.ledger == None
  assert list.length(status.nodes) == 4

  // A member entry that is malformed is skipped like any optional entry.
  let assert json.Object(fields) = ledger(json.Null)
  let skipped =
    json.Object(
      list.map(fields, fn(each) {
        case each.0 {
          "members" ->
            member(
              "members",
              json.Array([
                json.String("nonsense"),
                ledger_member("alpha", Some(9), Some(0)),
              ]),
            )
          _ -> each
        }
      }),
    )
  let assert Ok(status) = deployment_view.decode(with_ledger(skipped))
  let assert Some(found) = status.ledger
  assert list.map(found.members, fn(each) { each.name }) == ["alpha"]
}

pub fn a_standing_other_than_ok_is_stated_test() {
  let assert json.Object(fields) = ledger(json.Null)
  let revoked =
    json.Object(
      list.map(fields, fn(each) {
        case each.0 {
          "state" -> member("state", json.String("revoked"))
          _ -> each
        }
      }),
    )
  let assert Ok(status) = deployment_view.decode(with_ledger(revoked))
  assert string.contains(
    deployment_view.status_text(status),
    "this daemon is revoked in the ledger",
  )
}

pub fn members_the_reader_does_not_know_and_optional_ones_that_are_absent_are_fine_test() {
  let assert json.Object(members) = reply()

  // A later daemon adds members to a node and to the reply, and a node that has
  // none of them is still read.
  let widened =
    json.Object([
      member("future", json.String("anything")),
      ..list.map(members, fn(each) {
        case each.0 {
          "nodes" ->
            member(
              "nodes",
              json.Array([
                json.Object([
                  member("node", json.String("alpha@10.0.0.1")),
                  member("name", json.String("alpha@10.0.0.1")),
                  member("roles", json.Array([json.String("orchestrator")])),
                  member("state", json.String("degraded")),
                  member("build_version", json.String("0.2.0")),
                  member(
                    "executor",
                    json.Object([member("scopes", json.Int(3))]),
                  ),
                ]),
              ]),
            )
          _ -> each
        }
      })
    ])
  let assert Ok(status) = deployment_view.decode(widened)
  let assert [only] = status.nodes
  assert only.state == deployment_view.NodeDegraded
  assert only.reason == None
}

pub fn a_reply_without_its_required_members_is_an_error_not_a_crash_test() {
  assert deployment_view.decode(json.Object([])) |> is_error
  assert deployment_view.decode(json.Null) |> is_error
  assert deployment_view.decode(json.String("down")) |> is_error
  assert deployment_view.decode(json.Array([])) |> is_error

  // `self`, `state` and `nodes` are each required.
  let assert json.Object(members) = reply()
  list.each(["self", "state", "nodes"], fn(key) {
    let without = json.Object(list.filter(members, fn(each) { each.0 != key }))
    assert deployment_view.decode(without) |> is_error
  })
}

pub fn a_state_word_outside_the_protocol_is_refused_rather_than_guessed_test() {
  let assert json.Object(members) = reply()
  let with_state = fn(word) {
    json.Object([member("state", json.String(word)), ..members])
  }
  assert deployment_view.decode(with_state("on fire")) |> is_error

  // A node needs its four required members too.
  let bare =
    json.Object([
      member("self", json.String("alpha@10.0.0.1")),
      member("state", json.String("ok")),
      member(
        "nodes",
        json.Array([
          json.Object([member("node", json.String("alpha@10.0.0.1"))]),
        ]),
      ),
    ])
  assert deployment_view.decode(bare) |> is_error
}

pub fn a_node_name_longer_than_the_bound_is_refused_test() {
  let long = string.repeat("a", 300)
  let document =
    json.Object([
      member("self", json.String(long)),
      member("state", json.String("ok")),
      member("nodes", json.Array([])),
    ])
  assert deployment_view.decode(document) |> is_error
}

fn is_error(result) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// --- the printed text --------------------------------------------------------

pub fn status_prints_the_verdict_the_nodes_and_the_links_of_a_reply_without_reports_test() {
  let assert Ok(text) =
    tui.format_deployment(reply(), tui.ShowDeployment(None, tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from alpha, 3 of 4 nodes answered, 13:42:11 UTC",
        "state: degraded (exec2 down)",
        "",
        "NODE   ROLE          STATE  BUILD  SCOPES  NOTE",
        "alpha  orchestrator  ok     -      -",
        "bravo  orchestrator  ok     -      -",
        "box    executor      ok     -      -",
        "exec2  executor      down   -      -       timeout",
        "",
        "LINKS  == connected from alpha   .. not connected from alpha   -- relation, not observable from alpha",
        "alpha == bravo   peer",
        "alpha == box     serves",
        "alpha .. exec2   serves",
      ],
      "\n",
    )
}

// What a daemon that only knows itself prints: the self row, its slots, and no
// links, directory or moves.
pub fn a_daemon_with_no_peers_prints_its_own_row_only_test() {
  let alone =
    json.Object([
      member("as_of_ms", json.Int(1_760_191_331_000)),
      member("self", json.String("alpha@10.0.0.1")),
      member("state", json.String("ok")),
      member("reasons", json.Array([])),
      member(
        "nodes",
        json.Array([
          json.Object([
            member("node", json.String("alpha@10.0.0.1")),
            member("name", json.String("alpha@10.0.0.1")),
            member("roles", json.Array([json.String("orchestrator")])),
            member("state", json.String("ok")),
            member("self", json.Bool(True)),
            member("build_version", json.String("0.3.0")),
            member("build_commit", json.String("b4eeb50c9d1e")),
            member("uptime_ms", json.Int(86_400_000)),
            member(
              "orchestrator",
              json.Object([
                member("capacity", json.Int(8)),
                member("occupied", json.Int(0)),
                member("resident", json.Int(0)),
                member("imports", json.String("receiving")),
                member("moves_in_flight", json.Int(0)),
              ]),
            ),
          ]),
        ]),
      ),
      member("edges", json.Array([])),
      member(
        "placements",
        json.Object([
          member("executors", json.Array([])),
          member("pools", json.Array([])),
        ]),
      ),
      member("orchestrators", json.Array([])),
      member("moves", json.Array([])),
    ])
  let assert Ok(text) =
    tui.format_deployment(alone, tui.ShowDeployment(None, tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from alpha, 1 of 1 nodes answered, 14:02:11 UTC",
        "state: ok",
        "",
        "NODE   ROLE          STATE  BUILD     SCOPES  NOTE",
        "alpha  orchestrator  ok     b4eeb50c  -       8 slots, 0 resident",
      ],
      "\n",
    )
}

// A daemon that is not asked for reports, an older one, still prints.
pub fn a_reply_with_the_four_required_members_only_prints_test() {
  let bare =
    json.Object([
      member("self", json.String("nonode@nohost")),
      member("state", json.String("ok")),
      member("reasons", json.Array([])),
      member(
        "nodes",
        json.Array([
          node("nonode@nohost", "nonode@nohost", "orchestrator", "ok", None),
        ]),
      ),
    ])
  let assert Ok(text) =
    tui.format_deployment(bare, tui.ShowDeployment(None, tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from nonode, 1 of 1 nodes answered",
        "state: ok",
        "",
        "NODE    ROLE          STATE  BUILD  SCOPES  NOTE",
        "nonode  orchestrator  ok     -      -",
      ],
      "\n",
    )
}

pub fn executors_names_the_unreachable_one_with_its_reason_test() {
  let assert Ok(text) =
    tui.format_deployment(reply(), tui.ShowExecutors(tui.AsText))
  assert text
    == string.join(
      [
        "EXECUTOR  NODE            STATE  PLATFORM      ENFORCEMENT  TOOLCHAINS  POOLS     NOTE",
        "box       box@10.0.0.2    ready  -             -            -           builders",
        "exec2     exec2@10.0.0.9  down   linux/x86_64  enforced     codemode    builders  timeout",
        "",
        "POOL      EXECUTORS (trial order)  ELIGIBLE",
        "builders  exec2, box               box",
      ],
      "\n",
    )
}

pub fn a_daemon_with_no_executor_says_so_test() {
  let none =
    json.Object([
      member("self", json.String("alpha@10.0.0.1")),
      member("state", json.String("ok")),
      member("nodes", json.Array([])),
    ])
  assert tui.format_deployment(none, tui.ShowExecutors(tui.AsText))
    == Ok("no executors are configured")
}

pub fn json_prints_the_daemons_document_unread_test() {
  // Even a document the view could not read is printed, since the reply is the
  // daemon's and `--json` does not interpret it.
  let odd = json.Object([member("anything", json.Array([json.Int(1)]))])
  assert tui.format_deployment(odd, tui.ShowDeployment(None, tui.AsJson))
    == Ok(json.to_string(odd))
  assert tui.format_deployment(reply(), tui.ShowExecutors(tui.AsJson))
    == Ok(json.to_string(reply()))
}

pub fn text_that_cannot_be_read_is_an_error_naming_what_was_wrong_test() {
  let assert Error(words) =
    tui.format_deployment(json.Object([]), tui.ShowDeployment(None, tui.AsText))
  assert string.contains(
    words,
    "the daemon's deployment reply was not understood",
  )
}

pub fn a_hostile_name_cannot_move_the_cursor_or_start_a_row_test() {
  let hostile =
    json.Object([
      member("self", json.String("alpha@10.0.0.1")),
      member("state", json.String("down")),
      member(
        "reasons",
        json.Array([
          json.Object([
            member("node", json.String("x@10.0.0.9")),
            member("reason", json.String("t\u{1b}[31mimeout")),
          ]),
        ]),
      ),
      member(
        "nodes",
        json.Array([
          node(
            "x@10.0.0.9",
            "evil\nFAKE ROW  ok",
            "executor\u{1b}[2J",
            "down",
            Some("t\rrick"),
          ),
        ]),
      ),
    ])
  let assert Ok(text) =
    tui.format_deployment(hostile, tui.ShowDeployment(None, tui.AsText))
  assert !string.contains(text, "\u{1b}")
  assert !string.contains(text, "\r")
  assert list.length(string.split(text, "\n")) == 5
}

// --- the reports --------------------------------------------------------------

fn text(word) {
  json.String(word)
}

fn count(number) {
  json.Int(number)
}

fn reported(
  node_name,
  name,
  roles,
  state,
  reasons,
  facts: List(#(String, json.JsonValue)),
) {
  json.Object(
    list.flatten([
      [
        member("node", text(node_name)),
        member("name", text(name)),
        member("roles", json.Array(list.map(roles, text))),
        member("state", text(state)),
      ],
      case reasons {
        [] -> []
        words -> [member("reasons", json.Array(list.map(words, text)))]
      },
      [
        member("build_version", text("0.3.0")),
        member("build_commit", text("b4eeb50c9d1e")),
        member("uptime_ms", count(3_600_000)),
      ],
      facts,
    ]),
  )
}

fn scope_counts(open, closing, closed_clean, closed_unknown) {
  json.Object([
    member("open", count(open)),
    member("closing", count(closing)),
    member("closed_clean", count(closed_clean)),
    member("closed_unknown", count(closed_unknown)),
  ])
}

fn executor_facts(extra: List(#(String, json.JsonValue))) {
  member(
    "executor",
    json.Object(list.append(
      [
        member("scopes", scope_counts(3, 0, 9, 1)),
        member("scope_limit", count(16)),
        member("ledger_bytes", count(2_097_152)),
        member("ledger_limit", count(536_870_912)),
        member("unacknowledged", count(0)),
        member("platform", text("linux/x86_64")),
        member("contradiction", json.Null),
      ],
      extra,
    )),
  )
}

fn relation(from, to, kind, extra: List(#(String, json.JsonValue))) {
  json.Object(list.append(
    [
      member("from", text(from)),
      member("to", text(to)),
      member("kind", text(kind)),
    ],
    extra,
  ))
}

const alpha = "alpha@10.0.0.1"

const bravo = "bravo@10.0.0.4"

const box = "box@10.0.0.2"

const exec2 = "exec2@10.0.0.9"

// The example of the design (section 8 of the admin surface note), as the daemon
// writes it: four nodes, one executor with a scope that needs a release and one
// that does not answer, a move that has stalled, and a directory of three.
fn example() -> json.JsonValue {
  let linked = member("link", text("connected"))
  json.Object([
    member("as_of_ms", count(1_760_191_331_000)),
    member("self", text(alpha)),
    member("state", text("degraded")),
    member(
      "reasons",
      json.Array([
        json.Object([
          member("node", text(exec2)),
          member("reason", text("timeout")),
        ]),
        json.Object([
          member("node", text(box)),
          member("reason", text("unclean_scope")),
        ]),
      ]),
    ),
    member(
      "nodes",
      json.Array([
        reported(alpha, alpha, ["orchestrator", "member"], "ok", [], [
          member("self", json.Bool(True)),
          member(
            "orchestrator",
            json.Object([
              member("capacity", count(8)),
              member("occupied", count(2)),
              member("resident", count(2)),
              member("imports", text("receiving")),
              member("moves_in_flight", count(1)),
            ]),
          ),
        ]),
        reported(bravo, "bravo", ["orchestrator", "member"], "ok", [], []),
        reported(
          box,
          "box",
          ["executor", "member"],
          "degraded",
          ["unclean_scope"],
          [
            executor_facts([
              member(
                "unclean",
                json.Array([
                  json.Object([
                    member(
                      "session",
                      text("0198c0de-0000-7000-8000-000000000002"),
                    ),
                    member("state", text("unknown_cleanup")),
                    member("count", count(1)),
                  ]),
                ]),
              ),
            ]),
          ],
        ),
        json.Object([
          member("node", text(exec2)),
          member("name", text("exec2")),
          member("roles", json.Array([text("executor")])),
          member("state", text("down")),
          member("reason", text("timeout")),
        ]),
      ]),
    ),
    member(
      "edges",
      json.Array([
        relation(alpha, bravo, "peer", [linked]),
        relation(alpha, box, "serves", [member("sessions", count(3)), linked]),
        relation(bravo, box, "serves", [member("sessions", count(1))]),
        relation(alpha, exec2, "serves", [
          member("sessions", count(0)),
          member("link", text("none")),
        ]),
        relation(alpha, bravo, "member", [
          member("voter", json.Bool(True)),
          member("leader", json.Bool(True)),
          linked,
        ]),
        relation(alpha, box, "member", [
          member("voter", json.Bool(True)),
          member("leader", json.Bool(False)),
          linked,
        ]),
        relation(bravo, box, "member", [
          member("voter", json.Bool(True)),
          member("leader", json.Bool(False)),
        ]),
      ]),
    ),
    member(
      "directory",
      json.Object([
        member("members", json.Array([text(alpha), text(bravo), text(box)])),
        member("joined", json.Bool(True)),
        member(
          "ra_members",
          json.Array(
            list.map([alpha, bravo, box], fn(node) {
              json.Object([
                member("node", text(node)),
                member("voter", json.Bool(True)),
              ])
            }),
          ),
        ),
        member("applied_index", count(412)),
        member("leader", text(bravo)),
        member("copy", text("current")),
      ]),
    ),
    member(
      "moves",
      json.Array([
        json.Object([
          member("session_id", text("0198c0de-0000-7000-8000-000000000001")),
          member("op", text("0198c0de-0000-7000-8000-000000000a01")),
          member("to", text("bravo")),
          member("phase", text("waiting")),
          member("stalled_ms", count(240_000)),
          member("reason", text("receiver did not answer")),
        ]),
      ]),
    ),
  ])
}

pub fn the_design_example_prints_as_designed_test() {
  let assert Ok(text) =
    tui.format_deployment(example(), tui.ShowDeployment(None, tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from alpha, 3 of 4 nodes answered, 14:02:11 UTC",
        "state: degraded (exec2 down; box has 1 scope that needs a release)",
        "",
        "NODE   ROLE                  STATE     BUILD     SCOPES  NOTE",
        "alpha  orchestrator, member  ok        b4eeb50c  -       8 slots, 2 resident, 1 move in flight",
        "bravo  orchestrator, member  ok        b4eeb50c  -       directory leader",
        "box    executor, member      degraded  b4eeb50c  4/16    1 scope needs release: 0198c0de",
        "exec2  executor              down      -         -       timeout",
        "",
        "LINKS  == connected from alpha   .. not connected from alpha   -- relation, not observable from alpha",
        "alpha == bravo   peer, member",
        "alpha == box     serves 3, member",
        "bravo -- box     serves 1, member",
        "alpha .. exec2   serves 0",
        "",
        "DIRECTORY  3 members, 3 voters, leader bravo, this copy current",
        "MOVES      1 in flight: 0198c0de alpha -> bravo, waiting 4m, receiver did not answer",
      ],
      "\n",
    )
}

// An overview carries the numbers and not the sessions that need a release, so
// the row says how many and not which.
pub fn an_overview_without_the_long_lists_counts_the_scopes_that_need_release_test() {
  let assert Ok(status) = deployment_view.decode(example())
  let assert Ok(box_node) =
    list.find(status.nodes, fn(each) { each.name == "box" })
  assert box_node.reasons == ["unclean_scope"]
  let assert Some(facts) = box_node.executor
  assert facts.closed_unknown == 1
  assert facts.scope_limit == 16
  assert status.extent == deployment_view.Everything
  assert list.length(status.moves) == 1
  let assert Some(directory) = status.directory
  assert directory.voters == 3
  assert directory.leader == Some(bravo)
  assert directory.copy == Some("current")
}

fn without_unclean(document: json.JsonValue) -> json.JsonValue {
  let assert json.Object(members) = document
  json.Object(
    list.map(members, fn(each) {
      case each.0 {
        "nodes" -> {
          let assert json.Array(nodes) = each.1
          member(
            "nodes",
            json.Array(
              list.map(nodes, fn(found) {
                let assert json.Object(fields) = found
                json.Object(
                  list.map(fields, fn(field) {
                    case field.0 {
                      "executor" ->
                        member("executor", {
                          let assert json.Object(facts) = field.1
                          json.Object(
                            list.filter(facts, fn(fact) { fact.0 != "unclean" }),
                          )
                        })
                      _ -> field
                    }
                  }),
                )
              }),
            ),
          )
        }
        _ -> each
      }
    }),
  )
}

pub fn a_node_that_needs_a_release_is_counted_when_the_sessions_are_not_listed_test() {
  let assert Ok(text) =
    tui.format_deployment(
      without_unclean(example()),
      tui.ShowDeployment(None, tui.AsText),
    )
  assert string.contains(text, "1 scope needs release\n")
  assert !string.contains(text, "0198c0de\n")
}

// A reply about one node draws the node and then its long lists: the scopes held
// against the limit, the ledger, the workspaces, and each scope that needs a
// release with the command that frees it.
pub fn a_reply_for_one_node_prints_its_long_lists_test() {
  let one =
    json.Object([
      member("as_of_ms", count(1_760_191_331_000)),
      member("self", text(alpha)),
      member("state", text("degraded")),
      member(
        "reasons",
        json.Array([
          json.Object([
            member("node", text(box)),
            member("reason", text("unclean_scope")),
          ]),
        ]),
      ),
      member(
        "nodes",
        json.Array([
          reported(box, "box", ["executor"], "degraded", ["unclean_scope"], [
            executor_facts([
              member("workspaces", json.Array([text("proj"), text("docs")])),
              member(
                "unclean",
                json.Array([
                  json.Object([
                    member(
                      "session",
                      text("0198c0de-0000-7000-8000-000000000002"),
                    ),
                    member("state", text("unknown_cleanup")),
                    member("count", count(2)),
                  ]),
                ]),
              ),
            ]),
          ]),
        ]),
      ),
    ])
  let assert Ok(status) = deployment_view.decode(one)
  assert status.extent == deployment_view.OneNode
  let assert Ok(text) =
    tui.format_deployment(one, tui.ShowDeployment(Some("box"), tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from alpha, 1 of 1 nodes answered, 14:02:11 UTC",
        "state: degraded (box has 1 scope that needs a release)",
        "",
        "NODE  ROLE      STATE     BUILD     SCOPES  NOTE",
        "box   executor  degraded  b4eeb50c  4/16    1 scope needs release: 0198c0de",
        "",
        "box (box@10.0.0.2)",
        "  build 0.3.0 b4eeb50c9d1e, up 1h",
        "  scopes: 3 open, 0 closing, 9 closed clean, 1 closed unknown; 4 of 16 held, 12 free",
        "  ledger: 2 MiB of 512 MiB, 0 unacknowledged",
        "  platform: linux/x86_64",
        "  workspaces: proj, docs",
        "  needs release: 0198c0de-0000-7000-8000-000000000002, 2 children not proven gone",
        "    run on that executor: loomd executor release 0198c0de-0000-7000-8000-000000000002",
      ],
      "\n",
    )
}

pub fn every_reason_word_reads_as_a_sentence_test() {
  let sentence = fn(word) {
    let document =
      json.Object([
        member("self", text(alpha)),
        member("state", text("degraded")),
        member(
          "reasons",
          json.Array([
            json.Object([
              member("node", text(box)),
              member("reason", text(word)),
            ]),
          ]),
        ),
        member(
          "nodes",
          json.Array([
            reported(box, "box", ["executor"], "degraded", [word], []),
          ]),
        ),
      ])
    let assert Ok(drawn) =
      tui.format_deployment(document, tui.ShowDeployment(None, tui.AsText))
    let assert [_, verdict, ..] = string.split(drawn, "\n")
    verdict
  }
  assert sentence("full") == "state: degraded (box has no free scope)"
  assert sentence("declaration_contradicted")
    == "state: degraded (box's census contradicts its declaration)"
  assert sentence("build_differs") == "state: degraded (box runs another build)"
  assert sentence("protocol_differs")
    == "state: degraded (box speaks another protocol)"
  assert sentence("directory_no_leader")
    == "state: degraded (box's directory has no leader)"
  assert sentence("directory_copy_unconfirmed")
    == "state: degraded (box's directory copy is unconfirmed)"
  assert sentence("directory_quorum_lost")
    == "state: degraded (box cannot reach a quorum of directory voters)"

  // A word this reader does not know is still said, as the daemon wrote it.
  assert sentence("something_new") == "state: degraded (box: something_new)"
}

pub fn a_hostile_session_or_reason_cannot_move_the_cursor_in_the_new_members_test() {
  let hostile =
    json.Object([
      member("as_of_ms", count(1_760_191_331_000)),
      member("self", text(alpha)),
      member("state", text("degraded")),
      member(
        "nodes",
        json.Array([
          reported(box, "box", ["executor"], "degraded", ["unclean_scope"], [
            executor_facts([
              member(
                "unclean",
                json.Array([
                  json.Object([
                    member("session", text("s\u{1b}[2Jevil\nROW")),
                    member("state", text("closing")),
                  ]),
                ]),
              ),
            ]),
          ]),
        ]),
      ),
      member(
        "moves",
        json.Array([
          json.Object([
            member("session_id", text("m\u{1b}[31m1")),
            member("to", text("b\rravo")),
            member("phase", text("wait\ning")),
            member("reason", text("r\u{1b}]0;title\u{7}")),
          ]),
        ]),
      ),
    ])
  let assert Ok(drawn) =
    tui.format_deployment(hostile, tui.ShowDeployment(None, tui.AsText))
  assert !string.contains(drawn, "\u{1b}")
  assert !string.contains(drawn, "\r")
  assert !string.contains(drawn, "\u{7}")
}

pub fn text_and_lists_beyond_their_bounds_are_refused_or_dropped_test() {
  // A node list longer than the bound is refused whole, because a client holds a
  // reply to the bound the daemon keeps.
  let many =
    json.Object([
      member("self", text(alpha)),
      member("state", text("ok")),
      member(
        "nodes",
        json.Array(list.repeat(
          node(box, "box", "executor", "ok", None),
          times: 129,
        )),
      ),
    ])
  assert deployment_view.decode(many) |> is_error

  // An optional list that is too long reads as absent, and text that is too
  // long reads as absent.
  let long = string.repeat("a", 300)
  let widened =
    json.Object([
      member("self", text(alpha)),
      member("state", text("ok")),
      member("nodes", json.Array([])),
      member(
        "moves",
        json.Array(list.repeat(
          json.Object([
            member("session_id", text("s")),
            member("to", text("b")),
            member("phase", text("running")),
          ]),
          times: 200,
        )),
      ),
    ])
  let assert Ok(status) = deployment_view.decode(widened)
  assert list.length(status.moves) == 128
  let assert Ok(status) =
    deployment_view.decode(
      json.Object([
        member("self", text(alpha)),
        member("state", text("ok")),
        member("nodes", json.Array([])),
        member("directory", json.Object([member("leader", text(long))])),
      ]),
    )
  assert status.directory == None
}

// --- a reply cut to fit one frame --------------------------------------------

fn with_members(
  document: json.JsonValue,
  extra: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  let assert json.Object(members) = document
  json.Object(list.append(members, extra))
}

// An overview that left things out says so and points at the one-node read, and
// it is still an overview when it left out the edges.
pub fn an_overview_that_was_cut_says_what_is_left_out_test() {
  let cut =
    with_members(without_unclean(example()), [
      member("orchestrators", json.Array([])),
      member("omitted", json.Array([text("moves"), text("edges")])),
    ])
  let assert Ok(status) = deployment_view.decode(cut)
  assert status.extent == deployment_view.Everything
  assert status.omitted == ["moves", "edges"]
  let assert Ok(drawn) =
    tui.format_deployment(cut, tui.ShowDeployment(None, tui.AsText))
  assert string.contains(
    drawn,
    "left out to fit one frame: moves, edges\nrun with --node <key> for the rest",
  )
}

pub fn a_node_reply_that_was_cut_names_the_lists_test() {
  let one =
    json.Object([
      member("self", text(alpha)),
      member("state", text("ok")),
      member("nodes", json.Array([])),
      member("more", json.Array([text("moves"), text("workspaces")])),
    ])
  let assert Ok(drawn) =
    tui.format_deployment(one, tui.ShowDeployment(Some("box"), tui.AsText))
  assert string.contains(drawn, "lists cut to fit one frame: moves, workspaces")
}

pub fn a_node_that_connected_and_gave_no_report_says_so_test() {
  let silent =
    json.Object([
      member("self", text(alpha)),
      member("state", text("down")),
      member(
        "nodes",
        json.Array([
          node(box, "box", "executor", "down", Some("silent")),
        ]),
      ),
    ])
  let assert Ok(drawn) =
    tui.format_deployment(silent, tui.ShowDeployment(None, tui.AsText))
  assert string.contains(drawn, "connected, no report")
}
