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

fn box_owner() -> access.Principal {
  access.Principal(
    id: "owner-1",
    display_name: "Owner",
    kind: access.OwnerPrincipal,
  )
}

/// A running feed over a real gateway, which attaches at once, owned by the
/// calling process.
fn feed(harness: gateway_test.Harness, name: String) -> feed_host.Feed {
  feed_owned(harness, name, process.self())
}

/// A running feed that watches `owner` until it is registered.
fn feed_owned(
  harness: gateway_test.Harness,
  name: String,
  owner: process.Pid,
) -> feed_host.Feed {
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
        principal: box_owner(),
        authority:,
        digest:,
        signin: None,
        door: gateway.PeerDoor("laptop", gateway.Decides),
      ),
      check: fn() { Ok(#(box_owner(), authority)) },
      failed_reader: fn() { Nil },
      spawner: "laptop",
      ceiling: None,
      decider: remote_escalation.Decider(principal: "page", name: "Page"),
      admit: fn() { Ok(Nil) },
      owner:,
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
  assert feed_directory.find(directory, "tablet", token)
    == Error(feed_directory.Gone)
  assert feed_directory.find(
      directory,
      "laptop",
      "0123456789abcdef0123456789abcdef",
    )
    == Error(feed_directory.Gone)
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
    == Error(feed_directory.AtCap)
  let assert Ok(_) =
    feed_directory.reserve(directory, "tablet", process.self(), 3)
  let assert [first, ..] = tokens
  feed_directory.release(directory, first)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case feed_directory.reserve(directory, "laptop", process.self(), 3) {
        Ok(_) -> poll.Done(Nil)
        Error(_) -> poll.Retry
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
    == Error(feed_directory.AtCap)
  process.kill(owner)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case feed_directory.reserve(directory, "laptop", process.self(), 1) {
        Ok(_) -> poll.Done(Nil)
        Error(_) -> poll.Retry
      }
    })
    as "the dead owner's place is freed"
}

pub fn a_feed_holds_its_place_until_it_exits_and_is_then_forgotten_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed + 1))
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  let assert Ok(token) =
    feed_directory.reserve(directory, "laptop", process.self(), 1)
  let running = feed(harness, "b")
  feed_directory.register(directory, token, running)

  // While it runs, ended or not, it holds the only place, because an ended feed
  // keeps its process and its permit until it is forgotten.
  assert feed_directory.reserve(directory, "laptop", process.self(), 1)
    == Error(feed_directory.AtCap)
  assert feed_directory.find(directory, "laptop", token) == Ok(running)

  // When it exits it is not found, and its place is free.
  feed_host.detach(running)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case feed_directory.find(directory, "laptop", token) {
        Error(feed_directory.Gone) -> poll.Done(Nil)
        Ok(_) | Error(feed_directory.Unanswered) -> poll.Retry
      }
    })
    as "an exited feed is forgotten"
  let assert Ok(_) =
    feed_directory.reserve(directory, "laptop", process.self(), 1)
}

pub fn a_feed_started_by_an_owner_that_dies_before_it_registers_exits_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed + 2))
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.send(started, feed_owned(harness, "c", process.self()))
      process.sleep(60_000)
    })
  let assert Ok(unregistered) = process.receive(started, 2000)
    as "the feed starts under its owner"
  // The owner is cancelled between the feed's start and its registration, so
  // the feed, which nobody counts, goes with it.
  process.kill(owner)
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 10, attempt: fn() {
      case process.is_alive(feed_host.pid(unregistered)) {
        False -> poll.Done(Nil)
        True -> poll.Retry
      }
    })
    as "an unregistered feed does not outlive its owner"
  Nil
}

pub fn a_registered_feed_outlives_its_owner_test() {
  let harness = gateway_test.reserved_fixture(peer_rig.session_id(seed + 3))
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(token) =
        feed_directory.reserve(directory, "laptop", process.self(), 1)
      let running = feed_owned(harness, "d", process.self())
      feed_directory.register(directory, token, running)
      feed_host.registered(running)
      process.send(started, #(token, running))
      process.sleep(60_000)
    })
  let assert Ok(#(token, running)) = process.receive(started, 2000)
    as "the feed registers"
  process.kill(owner)

  // The directory dropped nothing, and the feed is still the one it holds.
  let assert Ok(Nil) = {
    process.sleep(100)
    case process.is_alive(feed_host.pid(running)) {
      True -> Ok(Nil)
      False -> Error(Nil)
    }
  }
  assert feed_directory.find(directory, "laptop", token) == Ok(running)
  feed_host.detach(running)
}

pub fn a_directory_that_does_not_answer_reserves_nothing_and_finds_nothing_test() {
  let assert Ok(directory) = feed_directory.start() as "the directory starts"
  feed_directory.stop(directory)

  // A silent directory is not a missing feed, and it is not a full spawner.
  assert feed_directory.reserve(directory, "laptop", process.self(), 8)
    == Error(feed_directory.Unavailable)
  assert feed_directory.find(
      directory,
      "laptop",
      "0123456789abcdef0123456789abcdef",
    )
    == Error(feed_directory.Unanswered)
}
