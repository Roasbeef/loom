//// What the gateway counts as someone being there, once a session's page can be
//// carried to another orchestrator (protocol-change/108, "Whether a refused call
//// waits").
////
//// An escalation seam asks `gateway.attached` before it parks a refused call for
//// a decision. A feed whose spawner has no `approval_ceiling` can watch and
//// cannot decide, so it must not make a call wait, while a feed that can decide
//// is a page like any other. The doors are attached to one real gateway, and the
//// count is read from it, so the claim is about the gateway's own state.
////
//// The gateway fixture holds one host sink of its own, which is counted, so each
//// test reads that baseline first and measures against it.

import client/gateway
import client/gateway_test
import core/ids
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import runtime/api
import storage/access
import support/peer_rig
import weft/poll

const seed = 1080

fn owner() -> access.Principal {
  access.Principal(
    id: "owner-1",
    display_name: "Owner",
    kind: access.OwnerPrincipal,
  )
}

// Attaches the box owner at the Operator authority through `door`, as the feed
// host and a page both do, and answers the handle that detaches it.
fn attach(
  harness: gateway_test.Harness,
  door: gateway.Door,
  name: String,
) -> gateway.ConnectionHandle {
  let assert Ok(digest) = access.credential_digest(string.repeat("b", 64))
    as "the fixture digest is valid"
  let authority = access.Participant(access.Operator)
  let assert Ok(handle) =
    gateway.attach_authenticated(
      harness.hub,
      gateway.Binding(
        session_id: ids.session_id_to_string(api.session_id(harness.runtime)),
        epoch: "epoch",
        incarnation: "incarnation",
        connection_id: name,
        principal: owner(),
        authority:,
        digest:,
        signin: None,
        door:,
      ),
      fn() { Ok(#(owner(), authority)) },
      fn(_frame) { Nil },
      fn() { Nil },
      fn() { Nil },
      process.self(),
    )
    as "the attachment is admitted"
  handle
}

// Waits until the hub has dropped a detached connection, so the count is read
// after the hub processed the detach and not before it.
fn settled(harness: gateway_test.Harness, expected: Int) -> Nil {
  let outcome =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case gateway.attached(harness.hub) == expected {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  assert outcome == poll.Answered(Nil)
}

pub fn a_feed_that_cannot_decide_is_not_someone_attached_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed))
  let before = gateway.attached(harness.hub)

  let watching =
    attach(harness, gateway.PeerDoor("laptop", gateway.Watches), "w")
  assert gateway.attached(harness.hub) == before

  gateway.connection_detach(watching)
  settled(harness, before)
}

pub fn a_feed_that_can_decide_is_a_page_like_any_other_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed + 1))
  let before = gateway.attached(harness.hub)
  let deciding =
    attach(harness, gateway.PeerDoor("laptop", gateway.Decides), "d")
  assert gateway.attached(harness.hub) == before + 1

  gateway.connection_detach(deciding)
  settled(harness, before)
}

pub fn only_the_feeds_that_cannot_decide_are_left_out_of_the_count_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed + 2))
  let before = gateway.attached(harness.hub)
  let page = attach(harness, gateway.PageDoor, "p")
  let terminal = attach(harness, gateway.SocketDoor, "t")
  let watching =
    attach(harness, gateway.PeerDoor("laptop", gateway.Watches), "w")
  let deciding =
    attach(harness, gateway.PeerDoor("tablet", gateway.Decides), "d")

  // Four are attached and three of them count.
  assert gateway.attached(harness.hub) == before + 3

  gateway.connection_detach(page)
  settled(harness, before + 2)
  gateway.connection_detach(deciding)
  settled(harness, before + 1)
  gateway.connection_detach(terminal)
  settled(harness, before)

  // The feed that watches was never counted, and leaving changes nothing.
  gateway.connection_detach(watching)
  settled(harness, before)
}
