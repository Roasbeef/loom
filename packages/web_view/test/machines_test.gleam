//// What the Admin page reads of the daemon's `deployment.status` document
//// (`web_view/machines`): the machines it lists, the ledger members it merges in,
//// the words it draws, and the bounds its decoder holds the document to.

import core/json.{type JsonValue}
import fleet_fixture as fleet
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import web_view/machines

fn names(snapshot: machines.Snapshot) -> List(String) {
  list.map(snapshot.machines, fn(machine) { machine.name })
}

fn member(snapshot: machines.Snapshot, name: String) -> machines.Machine {
  let assert Ok(found) =
    list.find(snapshot.machines, fn(machine) { machine.name == name })
    as "the machine is listed"
  found
}

// The machines are the nodes the daemon dials, the asking daemon first, and then
// the ledger's members it does not.
pub fn the_list_is_the_dialled_nodes_then_the_unlinked_members_test() {
  let snapshot = fleet.overview("box")
  assert names(snapshot) == ["alpha", "box", "exec2", "bravo", "laptop"]
  assert snapshot.state == machines.Degraded
  assert snapshot.as_of_ms == Some(1_760_190_131_000)
}

// A ledger member that the daemon's configuration does not hold is never dialled:
// it has no findings, no link, and the page says so.
pub fn a_member_this_daemon_is_not_linked_to_is_marked_test() {
  let laptop = member(fleet.overview("box"), "laptop")
  assert laptop.here == machines.NotLinkedFromHere
  assert laptop.link == machines.Unobserved
  assert laptop.node == "laptop@10.0.0.7"
  assert laptop.roles == [machines.Executor]
  assert machines.state_of(laptop) == None
  let assert machines.Enrolled(standing) = laptop.ledgered
  assert standing.links == ["bravo"]

  // A pin that is not sixty-four lower-case hex digits is not kept.
  assert standing.pin == None
}

pub fn a_dialled_node_carries_what_it_reported_and_its_standing_test() {
  let snapshot = fleet.overview("box")
  let box = member(snapshot, "box")
  assert box.whose == machines.Other
  assert box.link == machines.Linked
  let assert machines.Dialled(findings) = box.here
  assert findings.state == machines.Degraded
  assert findings.reasons == ["unclean_scope"]
  assert findings.protocol == Some(3)
  let assert Some(executor) = findings.executor
  assert executor.scopes.open == 3
  assert executor.scopes.closed_unknown == 1
  assert executor.scope_limit == 16
  assert executor.platform == Some("linux/x86_64")
  assert executor.toolchains == ["go", "gleam"]
  assert executor.contradiction == None
  let assert machines.Enrolled(standing) = box.ledgered
  assert standing.pin == Some(fleet.box_pin)
  assert standing.links == ["alpha"]
  assert standing.reported_seq == Some(8)
  assert standing.age_ms == Some(412_000)
  assert standing.seat == machines.NoSeat
}

pub fn the_asking_daemon_is_itself_and_has_no_link_to_itself_test() {
  let alpha = member(fleet.overview("box"), "alpha")
  assert alpha.whose == machines.This
  assert alpha.link == machines.Unobserved
  assert alpha.roles == [machines.Orchestrator, machines.Member]
  let assert machines.Enrolled(standing) = alpha.ledgered
  assert standing.seat == machines.Voter
}

// A node the daemon is configured with that the ledger does not list is said to
// be unlisted, and a daemon without a ledger has no standing to state at all.
pub fn a_node_the_ledger_does_not_list_is_not_listed_test() {
  let snapshot = fleet.overview("box")
  assert member(snapshot, "exec2").ledgered == machines.NotListed
  assert member(snapshot, "bravo").ledgered == machines.NotListed
  let assert json.Object(fields) = fleet.document("box")
  let without =
    json.Object(list.filter(fields, fn(field) { field.0 != "ledger" }))
  let assert Ok(unledgered) = machines.decode_overview(without)
  assert unledgered.ledger == None
  assert names(unledgered) == ["alpha", "box", "exec2", "bravo"]
  assert member(unledgered, "box").ledgered == machines.Unledgered
}

pub fn the_ledger_and_the_directory_and_the_moves_are_read_test() {
  let snapshot = fleet.overview("box")
  assert snapshot.ledger
    == Some(machines.Ledger(head_seq: 9, self_name: "alpha"))
  assert snapshot.directory
    == Some(machines.Directory(Some(machines.Unconfirmed)))
  let assert [move] = snapshot.moves
  assert move.phase == machines.Waiting
  assert move.stalled_ms == Some(120_000)
  assert move.reason == Some("the destination is busy")
}

// The line under the heading counts the machines by group and what needs a
// look, and says the first reason one is not ok.
pub fn the_summary_line_counts_what_needs_a_look_test() {
  assert machines.summary_words([]) == "No machines"
  assert machines.summary_words(fleet.overview("box").machines)
    == "5 machines · 2 orchestrators · 3 executors · 1 degraded · 1 down · 1 not linked from here: box: a scope is stuck closing or closed with unknown cleanup; only an operator's release frees it"
  let assert json.Object(fields) = fleet.document("box")
  let healthy =
    json.Object(
      list.map(fields, fn(field) {
        case field.0 {
          "nodes" -> #("nodes", json.Array([only_alpha(fields)]))
          "ledger" -> #("ledger", json.Null)
          _ -> field
        }
      }),
    )
  let assert Ok(single) = machines.decode_overview(healthy)
  assert machines.summary_words(single.machines)
    == "1 machine · 1 orchestrator · all ok"
}

// The pools come from the reply's placements, and a reply that says the daemon
// runs with distribution is read as distributed.
pub fn the_pools_and_the_footing_are_read_test() {
  let snapshot = fleet.overview("box")
  assert snapshot.distribution == machines.Distributed
  assert snapshot.pools == [machines.Pool("linux", ["box", "exec2"], ["box"])]
  let assert json.Object(fields) = fleet.document("box")
  let unstated =
    json.Object(
      list.filter(fields, fn(field) {
        field.0 != "distribution" && field.0 != "placements"
      }),
    )
  let assert Ok(older) = machines.decode_overview(unstated)
  assert older.distribution == machines.Distributed
  assert older.pools == []
}

// A daemon with no distribution is "This machine": the node name the BEAM gave
// it is never the name it is drawn under. Every other machine keeps its name,
// with its node under it when the two differ.
pub fn a_standalone_daemon_is_this_machine_test() {
  let snapshot = fleet.standalone()
  assert snapshot.distribution == machines.Standalone
  let assert [own] = snapshot.machines
  assert machines.title(snapshot, own)
    == machines.Title(name: "This machine", node: None)
  let fleet_snapshot = fleet.overview("box")
  assert machines.title(fleet_snapshot, member(fleet_snapshot, "box"))
    == machines.Title(name: "box", node: Some(fleet.box_node))
  assert machines.group_of(member(fleet_snapshot, "alpha"))
    == machines.OrchestratorGroup
  assert machines.group_of(member(fleet_snapshot, "box"))
    == machines.ExecutorGroup
}

fn only_alpha(fields: List(#(String, JsonValue))) -> JsonValue {
  let assert Ok(json.Array([alpha, ..])) = list.key_find(fields, "nodes")
  alpha
}

pub fn a_reply_for_one_node_carries_its_long_lists_test() {
  let assert Ok(detail) = machines.decode_detail(fleet.detail_document())
  assert detail.node == fleet.box_node
  assert detail.workspaces == ["app", "docs"]
  let assert [closing, unknown] = detail.unclean
  assert closing.stuck == machines.Closing
  assert unknown.stuck == machines.UnknownCleanup(Some(2))
  assert detail.more == []
}

// --- bounds ---------------------------------------------------------------------

fn with_field(document: JsonValue, key: String, value: JsonValue) -> JsonValue {
  let assert json.Object(fields) = document
  json.Object([#(key, value), ..list.filter(fields, fn(f) { f.0 != key })])
}

pub fn a_document_without_its_required_members_is_refused_test() {
  let assert Error(_) = machines.decode_overview(json.Object([]))
  let assert Error(_) = machines.decode_overview(json.Array([]))
  let assert Error(_) =
    machines.decode_overview(with_field(
      fleet.document("box"),
      "nodes",
      json.Null,
    ))
  let assert Error(_) =
    machines.decode_overview(with_field(
      fleet.document("box"),
      "state",
      json.String("fine"),
    ))
  let assert Error(_) = machines.decode_detail(json.Object([]))
  let assert Error(_) =
    machines.decode_detail(with_field(
      fleet.detail_document(),
      "nodes",
      json.Array([]),
    ))
}

// A text over the limit, or empty, is no text, so a node whose name is one is a
// reply the page refuses; a bound on a list refuses the whole list the page
// needs and cuts one it can do without.
pub fn a_text_is_bounded_and_a_required_list_is_refused_when_long_test() {
  let long = string.repeat("a", machines.text_limit + 1)
  let assert Error(_) = machines.decode_overview(fleet.document(long))
  let assert Error(_) = machines.decode_overview(fleet.document(""))
  let assert Ok(_) =
    machines.decode_overview(
      fleet.document(string.repeat("a", machines.text_limit)),
    )
  let crowd =
    list.repeat(only_alpha_of(fleet.document("box")), machines.list_limit + 1)
  let assert Error(_) =
    machines.decode_overview(with_field(
      fleet.document("box"),
      "nodes",
      json.Array(crowd),
    ))
}

fn only_alpha_of(document: JsonValue) -> JsonValue {
  let assert json.Object(fields) = document
  only_alpha(fields)
}

// An optional member that is malformed is left out and the rest is drawn.
pub fn a_malformed_optional_member_is_left_out_test() {
  let document =
    fleet.document("box")
    |> with_field("ledger", json.String("not an object"))
    |> with_field("directory", json.Array([]))
    |> with_field("moves", json.Int(3))
    |> with_field("edges", json.String("x"))
  let assert Ok(snapshot) = machines.decode_overview(document)
  assert snapshot.ledger == None
  assert snapshot.directory == None
  assert snapshot.moves == []
  assert snapshot.edges == []
  assert names(snapshot) == ["alpha", "box", "exec2", "bravo"]
}

// A relation, phase or scope state the page does not know is skipped and not
// guessed at.
pub fn a_word_the_page_does_not_know_is_skipped_test() {
  let assert Ok(detail) =
    machines.decode_detail(
      json.Object([
        #("nodes", json.Array([unknown_scope_node()])),
      ]),
    )
  assert detail.unclean == []
}

fn unknown_scope_node() -> JsonValue {
  json.Object([
    #("node", json.String("box@10.0.0.2")),
    #(
      "executor",
      json.Object([
        #(
          "unclean",
          json.Array([
            json.Object([
              #("session", json.String("s")),
              #("state", json.String("exploding")),
            ]),
          ]),
        ),
      ]),
    ),
  ])
}

// --- words ----------------------------------------------------------------------

pub fn the_words_are_fixed_test() {
  assert machines.pill_class(machines.Healthy) == "online"
  assert machines.pill_class(machines.Degraded) == "pending"
  assert machines.pill_class(machines.Down) == "ended"
  assert machines.age_words(0) == "just now"
  assert machines.age_words(12_000) == "12 s ago"
  assert machines.age_words(412_000) == "6 min ago"
  assert machines.age_words(7_300_000) == "2 h ago"
  assert machines.age_words(200_000_000) == "2 d ago"
  assert machines.uptime_words(90_000_000) == "1 d 1 h"
  assert machines.reason_words("timeout") == "did not answer in time"

  // A reason this page does not know is drawn as the daemon wrote it.
  assert machines.reason_words("new_word") == "new_word"
  assert list.map(machines.tabs, machines.tab_words)
    == ["Overview", "Sessions", "Access", "Activity"]
}
