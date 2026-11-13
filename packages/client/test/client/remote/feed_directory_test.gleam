//// The directory that finds a live feed by its token (protocol-change/108,
//// "The fences").
////
//// A token is looked up only among the feeds of the spawner the sender's node
//// resolved to, so another spawner's token is not found, and the cap is the one
//// place a place for a feed is counted, so two attaches racing for the last place
//// cannot both have it. The feeds in these tests are real `feed_host` processes
//// over a real gateway, because the directory monitors them.

import client/gateway
import client/gateway_test
import client/remote/feed_directory
import client/remote/feed_host
import client/remote_escalation
import core/ids
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import runtime/api
import storage/access
import support/peer_rig
import weft/poll

const seed = 1084

fn owner() -> access.Principal {
  access.Principal(
    id: "owner-1",
    display_name: "Owner",
    kind: access.OwnerPrincipal,
  )
}

/// A running feed over a real gateway, which attaches at once.
fn feed(harness: gateway_test.Harness, name: String) -> feed_host.Feed {
  let assert Ok(digest) = access.credential_digest(string.repeat("c", 64))
    as "the fixture digest is valid"
  let authority = access.Participant(access.Operator)
  let assert Ok(feed) =
    feed_host.start(feed_host.Settings(
      hub: harness.hub,
      binding: gateway.Binding(
        session_id: ids.session_id_to_string(api.session_id(harness.runtime)),
        epoch: "epoch",
        incarnation: "incarnation",
        connection_id: name,
        principal: owner(),
        authority:,
        digest:,
        signin: None,
        door: gateway.PeerDoor("laptop", gateway.Decides),
      ),
      check: fn() { Ok(#(owner(), authority)) },
      failed_reader: fn() { Nil },
      spawner: "laptop",
      ceiling: None,
      decider: remote_escalation.Decider(principal: "page", name: "Page"),
      admit: fn() { Ok(Nil) },
      ended: fn() { Nil },
      lease_ms: 60_000,
    ))
    as "the feed starts"
  feed
}

pub fn a_token_is_found_only_among_its_own_spawners_feeds_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed))
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  let assert Ok(token) =
    feed_directory.reserve(directory, "laptop", process.self(), 8)
  let running = feed(harness, "a")
  feed_directory.register(directory, token, running)

  assert feed_directory.find(directory, "laptop", token) == Ok(running)
  assert feed_directory.find(directory, "tablet", token) == Error(Nil)
  assert feed_directory.find(
      directory,
      "laptop",
      "0123456789abcdef0123456789abcdef",
    )
    == Error(Nil)
  feed_host.detach(running)
}

pub fn the_cap_counts_reservations_and_a_release_gives_the_place_back_test() {
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  let tokens =
    list.map([1, 2, 3], fn(_) {
      let assert Ok(token) =
        feed_directory.reserve(directory, "laptop", process.self(), 3)
      token
    })

  // The fourth is refused, and another spawner's places are its own.
  assert feed_directory.reserve(directory, "laptop", process.self(), 3)
    == Error(Nil)
  let assert Ok(_) =
    feed_directory.reserve(directory, "tablet", process.self(), 3)
  let assert [first, ..] = tokens
  feed_directory.release(directory, first)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case feed_directory.reserve(directory, "laptop", process.self(), 3) {
        Ok(_) -> poll.Done(Nil)
        Error(Nil) -> poll.Retry
      }
    })
    as "a released place is available again"
}

pub fn a_reservation_whose_owner_exits_gives_its_place_back_test() {
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  let reserved = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(token) =
        feed_directory.reserve(directory, "laptop", process.self(), 1)
      process.send(reserved, token)
      process.sleep(60_000)
    })
  let assert Ok(_) = process.receive(reserved, 2000)
  assert feed_directory.reserve(directory, "laptop", process.self(), 1)
    == Error(Nil)
  process.kill(owner)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case feed_directory.reserve(directory, "laptop", process.self(), 1) {
        Ok(_) -> poll.Done(Nil)
        Error(Nil) -> poll.Retry
      }
    })
    as "the dead owner's place is freed"
}

pub fn a_feed_that_exits_is_forgotten_and_an_ended_one_stops_counting_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed + 1))
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  let assert Ok(token) =
    feed_directory.reserve(directory, "laptop", process.self(), 1)
  let running = feed(harness, "b")
  feed_directory.register(directory, token, running)

  // While it runs it holds the only place.
  assert feed_directory.reserve(directory, "laptop", process.self(), 1)
    == Error(Nil)

  // Once it says it ended it is still found, for a late poll, and holds none.
  feed_directory.ended(directory, token)
  let assert Ok(_) =
    feed_directory.reserve(directory, "laptop", process.self(), 1)
  assert feed_directory.find(directory, "laptop", token) == Ok(running)

  // When it exits it is not found.
  feed_host.detach(running)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case feed_directory.find(directory, "laptop", token) {
        Error(Nil) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
      }
    })
    as "an exited feed is forgotten"
}
