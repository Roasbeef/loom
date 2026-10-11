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
    member("state", json.String("down")),
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
  assert tui.launch_deployment(["status"]) == Ok(tui.ShowDeployment(tui.AsText))
  assert tui.launch_deployment(["executors"])
    == Ok(tui.ShowExecutors(tui.AsText))
  assert tui.launch_deployment(["status", "--json"])
    == Ok(tui.ShowDeployment(tui.AsJson))
  assert tui.launch_deployment(["--json", "executors"])
    == Ok(tui.ShowExecutors(tui.AsJson))

  // The shared local options compose with them in either order.
  assert tui.launch_deployment(["status", "--state-dir", "/tmp/x", "--json"])
    == Ok(tui.ShowDeployment(tui.AsJson))
  assert tui.launch_deployment(["executors", "--server", "/tmp/s"])
    == Ok(tui.ShowExecutors(tui.AsText))
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

pub fn the_command_is_a_read_with_no_body_test() {
  assert protocol.name(protocol.DeploymentStatus) == "deployment.status"
  assert !protocol.mutates(protocol.DeploymentStatus)
  assert protocol.encode(
      3,
      protocol.DeploymentStatus,
      protocol.Epoch("current"),
    )
    == Ok("{\"v\":2,\"id\":3,\"cmd\":\"deployment.status\",\"body\":{}}")
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
  assert status.state == deployment_view.NodeDown
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

pub fn status_prints_the_verdict_the_nodes_and_the_links_test() {
  let assert Ok(text) =
    tui.format_deployment(reply(), tui.ShowDeployment(tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from alpha@10.0.0.1, 3 of 4 nodes answered",
        "state: down (exec2: timeout)",
        "",
        "NODE   ROLE          STATE  NOTE",
        "alpha  orchestrator  ok",
        "bravo  orchestrator  ok",
        "box    executor      ok",
        "exec2  executor      down   timeout",
        "",
        "LINKS (== connected, .. not connected, -- not observable from alpha)",
        "alpha  ==  bravo  peer",
        "alpha  ==  box    serves",
        "alpha  ..  exec2  serves",
      ],
      "\n",
    )
}

pub fn a_daemon_with_no_peers_prints_its_own_row_only_test() {
  let alone =
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
    tui.format_deployment(alone, tui.ShowDeployment(tui.AsText))
  assert text
    == string.join(
      [
        "deployment as seen from nonode@nohost, 1 of 1 nodes answered",
        "state: ok",
        "",
        "NODE    ROLE          STATE  NOTE",
        "nonode  orchestrator  ok",
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
  assert tui.format_deployment(odd, tui.ShowDeployment(tui.AsJson))
    == Ok(json.to_string(odd))
  assert tui.format_deployment(reply(), tui.ShowExecutors(tui.AsJson))
    == Ok(json.to_string(reply()))
}

pub fn text_that_cannot_be_read_is_an_error_naming_what_was_wrong_test() {
  let assert Error(words) =
    tui.format_deployment(json.Object([]), tui.ShowDeployment(tui.AsText))
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
    tui.format_deployment(hostile, tui.ShowDeployment(tui.AsText))
  assert !string.contains(text, "\u{1b}")
  assert !string.contains(text, "\r")
  assert list.length(string.split(text, "\n")) == 5
}
