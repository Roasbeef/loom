//// The link keeper, stepped by hand on a fake timer wheel.
////
//// The keeper arms its beat through an injected `after`, so a test records each
//// arming, decides when it rings, and can see that none was armed. The
//// connection is two closures that count: how often the keeper asked whether the
//// node was connected, and how often it connected.

import client/remote/link_keeper
import gleam/erlang/process.{type Subject}
import support/addresses
import weft/poll
import weft/registry as address

type Arming {
  Arming(delay_ms: Int, wake: fn() -> Nil)
}

type Keeping {
  Keeping(
    armings: Subject(Arming),
    connects: Subject(Nil),
    name: address.Address(link_keeper.Message),
  )
}

// Starts a keeper whose node is connected or not, as `up` says, and whose beat
// arms into the returned subject rather than into the clock.
fn keeper(up up: Bool) -> Keeping {
  let armings = process.new_subject()
  let connects = process.new_subject()
  let name = addresses.new()
  let options =
    link_keeper.Options(
      link: link_keeper.Link(connected: fn() { up }, connect: fn() {
        process.send(connects, Nil)
      }),
      after: fn(delay_ms, wake) {
        process.send(armings, Arming(delay_ms:, wake:))
      },
    )
  let assert Ok(_) = link_keeper.start(options, name) as "the keeper starts"
  Keeping(armings:, connects:, name:)
}

fn arming(keeping: Keeping) -> Arming {
  let assert Ok(found) = process.receive(keeping.armings, 2000)
    as "the keeper armed its beat"
  found
}

// A beat that was not armed is shown by waiting out a window in which one
// would have been.
fn assert_no_arming(keeping: Keeping) -> Nil {
  let assert Error(Nil) = process.receive(keeping.armings, 200)
    as "the keeper holds no timer"
  Nil
}

fn connected_once(keeping: Keeping) -> Nil {
  let assert Ok(Nil) = process.receive(keeping.connects, 2000)
    as "the keeper connected"
  Nil
}

fn assert_no_connect(keeping: Keeping) -> Nil {
  let assert Error(Nil) = process.receive(keeping.connects, 200)
    as "the keeper did not connect"
  Nil
}

pub fn an_idle_keeper_arms_nothing_and_never_connects_test() {
  let keeping = keeper(up: False)
  assert_no_arming(keeping)
  assert_no_connect(keeping)
}

pub fn a_vote_arms_the_two_second_beat_and_a_beat_connects_a_dropped_node_test() {
  let keeping = keeper(up: False)
  link_keeper.hold(keeping.name, "s1")

  // The vote arms the beat at the keeper's cadence and connects nothing yet:
  // the sessions that voted already dial on demand.
  let beat = arming(keeping)
  assert beat.delay_ms == link_keeper.beat_ms
  assert_no_connect(keeping)

  // Each beat that finds the node down connects, and arms the next.
  beat.wake()
  connected_once(keeping)
  let next = arming(keeping)
  assert next.delay_ms == link_keeper.beat_ms
  next.wake()
  connected_once(keeping)
}

pub fn a_beat_that_finds_the_node_connected_connects_nothing_test() {
  let keeping = keeper(up: True)
  link_keeper.hold(keeping.name, "s1")
  let beat = arming(keeping)
  beat.wake()

  // The beat is still armed for the next look, and nothing was dialed.
  let next = arming(keeping)
  assert next.delay_ms == link_keeper.beat_ms
  assert_no_connect(keeping)
}

pub fn the_last_dropped_vote_stops_the_keeper_and_a_late_beat_is_ignored_test() {
  let keeping = keeper(up: False)
  link_keeper.hold(keeping.name, "s1")
  link_keeper.hold(keeping.name, "s2")
  let beat = arming(keeping)

  // One session still holds, so the keeper keeps beating.
  link_keeper.drop(keeping.name, "s1")
  beat.wake()
  connected_once(keeping)
  let next = arming(keeping)

  // The last vote leaves, the beat is cancelled, and a beat that was already
  // in flight is dropped rather than handled.
  link_keeper.drop(keeping.name, "s2")
  next.wake()
  assert_no_connect(keeping)
  assert_no_arming(keeping)
}

pub fn a_voter_that_dies_loses_its_vote_test() {
  let keeping = keeper(up: False)
  let done = process.new_subject()
  let _voter =
    process.spawn_unlinked(fn() {
      link_keeper.hold(keeping.name, "gone")
      process.send(done, Nil)
    })
  let assert Ok(Nil) = process.receive(done, 2000) as "the voter voted"
  let beat = arming(keeping)

  // The voter exited, so its monitor fires and the keeper goes idle. The beat
  // the keeper armed is now a stale one.
  wait_idle(keeping, beat)
}

// A keeper that went idle ignores a ring of the beat it armed while holding.
// The ring is repeated until the monitor has been handled, because the death of
// the voter and the first ring race.
fn wait_idle(keeping: Keeping, beat: Arming) -> Nil {
  let settled =
    poll.until(within: 3000, every: 25, attempt: fn() {
      beat.wake()
      case process.receive(keeping.connects, 50) {
        Ok(Nil) -> poll.Retry
        Error(Nil) -> poll.Done(Nil)
      }
    })
  let assert poll.Answered(Nil) = settled as "the dead voter's vote was dropped"
  assert_no_connect(keeping)
}

pub fn a_second_vote_from_a_session_replaces_the_first_test() {
  let keeping = keeper(up: False)
  link_keeper.hold(keeping.name, "s1")
  link_keeper.hold(keeping.name, "s1")
  let beat = arming(keeping)

  // One vote per session: a single drop empties the keeper.
  link_keeper.drop(keeping.name, "s1")
  beat.wake()
  assert_no_connect(keeping)
}
