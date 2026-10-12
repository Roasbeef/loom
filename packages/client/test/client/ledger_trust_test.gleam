//// What the ledger does to distribution (protocol-change/086, sections 6.4 and
//// 6.5), as decisions: which connected nodes an entry stops permitting, and
//// which executors an orchestrator keeps reaching for. The effects themselves,
//// the table a real handshake reads and the disconnects, are run across
//// emulators by `ledger_live_test`.

import client/distribution_plan.{Orchestrator}
import client/ledger_trust
import client/membership_entry.{Member, Upsert}
import gleam/int
import gleam/list
import support/membership_fixture as fixture
import support/membership_log as history

const hub = "loom@hub.example.net"

const laptop = "loom@laptop.example.net"

const box = "loom@box.example.net"

// A hub that is an orchestrator, a laptop linked to it, and an executor the
// hub lists. The laptop's own links make it a peer of the hub, and the hub's
// make the box one.
fn base() -> history.Log {
  history.genesis()
  |> history.must_push(Upsert(
    Member(..fixture.member("hub", []), role: Orchestrator),
  ))
  |> history.enroll("laptop", ["hub"])
  |> history.enroll("box", ["hub"])
}

pub fn a_revoked_member_that_is_connected_is_named_test() {
  let before = base()
  let after = history.revoke(before, "laptop")
  assert ledger_trust.stale(before.ledger, after.ledger, hub, [laptop, box])
    == [laptop]
}

pub fn a_member_whose_pin_changed_is_named_and_one_whose_pin_did_not_is_not_test() {
  let before = base()
  let renewed =
    history.must_push(
      before,
      Upsert(
        Member(
          ..fixture.member("laptop", ["hub"]),
          pin: fixture.pin_for("laptop", 1),
        ),
      ),
    )
  assert ledger_trust.stale(before.ledger, renewed.ledger, hub, [laptop, box])
    == [laptop]

  // An amendment that keeps the pin leaves the connection alone.
  let amended =
    history.must_push(
      before,
      Upsert(
        Member(..fixture.member("laptop", ["hub"]), host: "other.example.net"),
      ),
    )
  assert ledger_trust.stale(before.ledger, amended.ledger, hub, [laptop, box])
    == []
}

pub fn a_connected_node_the_table_never_listed_is_named_test() {
  let log = base()
  assert ledger_trust.stale(log.ledger, log.ledger, hub, [
      "loom@stranger.example.net",
    ])
    == ["loom@stranger.example.net"]
}

pub fn a_node_that_is_revoked_itself_names_every_connection_test() {
  let before = base()
  let after = history.revoke(before, "hub")
  assert ledger_trust.stale(before.ledger, after.ledger, hub, [laptop, box])
    == [laptop, box]
}

pub fn an_orchestrator_dials_the_executors_it_is_linked_to_test() {
  let log = base()

  // The box is an executor linked to the hub. The laptop is also linked to the
  // hub, and as an executor it is dialed as well.
  assert ledger_trust.executors_to_dial(log.ledger, hub) == [box, laptop]
}

pub fn an_executor_and_a_stranger_dial_nobody_test() {
  let log = base()
  assert ledger_trust.executors_to_dial(log.ledger, box) == []
  assert ledger_trust.executors_to_dial(log.ledger, "loom@x.example.net") == []

  // A linked orchestrator is not dialed: only orchestrators dial, and only
  // executors are dialed this way.
  let peers =
    history.must_push(
      log,
      Upsert(Member(..fixture.member("desk", ["hub"]), role: Orchestrator)),
    )
  assert ledger_trust.executors_to_dial(peers.ledger, hub) == [box, laptop]
}

pub fn the_table_is_bounded_by_the_ledgers_members_and_not_the_static_peer_cap_test() {
  // A hub linked to 63 executors is a full ledger of 64 active members. The
  // static bound of 32 peers does not apply, and the table holds all 63 pins.
  let hub_log =
    history.must_push(
      history.genesis(),
      Upsert(Member(..fixture.member("hub", []), role: Orchestrator)),
    )
  let full =
    int.range(from: 1, to: 64, with: hub_log, run: fn(log, index) {
      history.enroll(log, "n" <> int.to_string(index), ["hub"])
    })
  assert ledger_trust.max_peers() == 63
  assert list.length(ledger_trust.pairs(full.ledger, hub)) == 63

  // Each row pairs a pin with the node name that pin must present.
  assert list.contains(ledger_trust.pairs(full.ledger, hub), #(
    fixture.pin_for("n1", 0),
    "loom@n1.example.net",
  ))

  // A node that is not a member has no rows.
  assert ledger_trust.pairs(full.ledger, "loom@x.example.net") == []
}
