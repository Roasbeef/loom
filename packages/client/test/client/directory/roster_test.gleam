//// The directory's roster and the plan that makes Ra follow it
//// (protocol-change/086, phase 3): the seats a ledger gives, the one change the
//// Ra leader makes next, and the cases in which it makes none.
////
//// Everything here is a value. A Ra membership is a list of nodes with whether
//// each votes, so a test describes a cluster in a line and asks `plan` what the
//// leader would do. The reconciliation as the member actor runs it, against a
//// real Ra, is `ledger_directory_test`.

import client/directory/roster.{
  type Roster, Held, NotLeader, OtherSeat, Place, Remove, Roster, Settled,
  Unseated,
}
import client/directory/store.{type Membership, Learner, Membership, Voter}
import client/internal/ffi_khepri.{NonVoter, Promoting}
import client/membership_entry.{Upsert}
import gleam/list
import gleam/option.{None, Some}
import support/membership_fixture as fixture
import support/membership_log as log

const a = "loom@a.example.net"

const b = "loom@b.example.net"

const c = "loom@c.example.net"

const d = "loom@d.example.net"

const e = "loom@e.example.net"

// A roster that seats these nodes and has named these nodes, seated or not.
fn roster(seated: List(#(String, store.Seat)), named: List(String)) -> Roster {
  Roster(
    places: list.map(seated, fn(seat) { Place(seat.0, seat.1) }),
    named: fn(node) {
      list.contains(named, node)
      || list.any(seated, fn(seat) { seat.0 == node })
    },
  )
}

// Ra's view from the leader `a`.
fn ra(members: List(#(String, ffi_khepri.Voting))) -> Membership {
  Membership(members:, leader: Some(a))
}

pub fn the_places_of_a_ledger_are_its_seated_members_in_node_order_test() {
  let history =
    log.genesis()
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("c", []),
        directory: membership_entry.Voter,
      ),
    ))
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("a", []),
        directory: membership_entry.Voter,
      ),
    ))
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("b", []),
        directory: membership_entry.Learner,
      ),
    ))
    |> log.enroll("laptop", [])
  assert roster.places(history.ledger)
    == [Place(a, Voter), Place(b, Learner), Place(c, Voter)]
}

pub fn a_revoked_member_has_no_place_but_the_ledger_has_named_it_test() {
  let history =
    log.genesis()
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("a", []),
        directory: membership_entry.Voter,
      ),
    ))
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("b", []),
        directory: membership_entry.Voter,
      ),
    ))
    |> log.revoke("b")
  let seats = roster.roster(history.ledger)
  assert seats.places == [Place(a, Voter)]
  assert seats.named(b)
  assert !seats.named("loom@never.example.net")
}

pub fn only_the_leader_reconciles_test() {
  let seats = roster([#(a, Voter), #(b, Voter)], [])
  let held = [#(a, ffi_khepri.Voter), #(b, ffi_khepri.Voter), #(c, NonVoter)]
  assert roster.plan(seats, Membership(members: held, leader: Some(b)), a, [b])
    == NotLeader
  assert roster.plan(seats, Membership(members: held, leader: None), a, [b])
    == NotLeader
}

pub fn a_cluster_that_matches_the_roster_is_settled_test() {
  let seats = roster([#(a, Voter), #(b, Voter), #(c, Learner)], [])
  assert roster.plan(
      seats,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, NonVoter),
      ]),
      a,
      [b, c],
    )
    == Settled(missing: [], foreign: [])
}

// A voter Ra is still promoting is on its way to the seat the ledger gave it.
pub fn a_voter_being_promoted_holds_a_voters_seat_test() {
  let seats = roster([#(a, Voter), #(b, Voter), #(c, Voter)], [])
  assert roster.plan(
      seats,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, Promoting),
      ]),
      a,
      [b, c],
    )
    == Settled(missing: [], foreign: [])
}

// A seated node that is not in Ra has not joined yet. It joins by itself, and
// the leader only says so.
pub fn a_seat_nobody_has_taken_is_reported_as_missing_test() {
  let seats = roster([#(a, Voter), #(b, Voter), #(c, Learner)], [])
  assert roster.plan(
      seats,
      ra([#(a, ffi_khepri.Voter), #(b, ffi_khepri.Voter)]),
      a,
      [b],
    )
    == Settled(missing: [c], foreign: [])
}

pub fn a_revoked_member_is_removed_from_ra_test() {
  let seats = roster([#(a, Voter), #(b, Voter), #(c, Voter)], [d])
  assert roster.plan(
      seats,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, ffi_khepri.Voter),
        #(d, ffi_khepri.Voter),
      ]),
      a,
      [b, c, d],
    )
    == Remove(d, Unseated)
}

// The ledger has never named a node in Ra when it is another deployment's, or
// when this leader has not received the entry that enrolled it. Removing it on
// that evidence could take a member out of a cluster it belongs in.
pub fn a_node_the_ledger_never_named_is_left_alone_and_reported_test() {
  let seats = roster([#(a, Voter), #(b, Voter), #(c, Voter)], [])
  assert roster.plan(
      seats,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, ffi_khepri.Voter),
        #(e, NonVoter),
      ]),
      a,
      [b, c],
    )
    == Settled(missing: [], foreign: [e])
}

pub fn a_member_in_the_other_seat_is_removed_to_rejoin_test() {
  let wants_learner = roster([#(a, Voter), #(b, Voter), #(c, Learner)], [])
  let wants_voter = roster([#(a, Voter), #(b, Voter), #(c, Voter)], [])
  assert roster.plan(
      wants_learner,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, ffi_khepri.Voter),
      ]),
      a,
      [b, c],
    )
    == Remove(c, OtherSeat)
  assert roster.plan(
      wants_voter,
      ra([#(a, ffi_khepri.Voter), #(b, ffi_khepri.Voter), #(c, NonVoter)]),
      a,
      [b, c],
    )
    == Remove(c, OtherSeat)

  // A member Ra is promoting is not a learner either.
  assert roster.plan(
      wants_learner,
      ra([#(a, ffi_khepri.Voter), #(b, ffi_khepri.Voter), #(c, Promoting)]),
      a,
      [b, c],
    )
    == Remove(c, OtherSeat)
}

// A learner takes no vote away, so it goes first and whatever the state of the
// others.
pub fn learners_are_removed_before_voters_and_whatever_is_reachable_test() {
  let seats = roster([#(a, Voter)], [b, c, d])
  assert roster.plan(
      seats,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, ffi_khepri.Voter),
        #(d, NonVoter),
      ]),
      a,
      [],
    )
    == Remove(d, Unseated)
}

// With three voters, removing one leaves two, and the change commits only when
// both have it. A leader that can reach only itself would append a change that
// could not commit.
pub fn a_voter_is_removed_only_while_a_majority_of_the_rest_is_reachable_test() {
  let seats = roster([#(a, Voter), #(b, Voter)], [c])
  let members = [
    #(a, ffi_khepri.Voter),
    #(b, ffi_khepri.Voter),
    #(c, ffi_khepri.Voter),
  ]
  assert roster.plan(seats, ra(members), a, [b, c]) == Remove(c, Unseated)
  assert roster.plan(seats, ra(members), a, [c]) == Held(c, Unseated)
  assert roster.plan(seats, ra(members), a, []) == Held(c, Unseated)
}

// Of five voters, removing one leaves four, which need three: the leader and two
// more.
pub fn the_majority_is_counted_over_the_voters_that_remain_test() {
  let seats = roster([#(a, Voter), #(b, Voter), #(c, Voter), #(d, Voter)], [e])
  let members = [
    #(a, ffi_khepri.Voter),
    #(b, ffi_khepri.Voter),
    #(c, ffi_khepri.Voter),
    #(d, ffi_khepri.Voter),
    #(e, ffi_khepri.Voter),
  ]
  assert roster.plan(seats, ra(members), a, [b, c]) == Remove(e, Unseated)
  assert roster.plan(seats, ra(members), a, [b]) == Held(e, Unseated)
}

// A voter that cannot be removed does not stop a learner that can: the learner
// is first in line anyway, and a held voter is reported only when nothing is
// safe to do.
pub fn a_held_removal_does_not_block_a_safe_one_test() {
  let seats = roster([#(a, Voter), #(b, Voter)], [c, d])
  let members = [
    #(a, ffi_khepri.Voter),
    #(b, ffi_khepri.Voter),
    #(c, ffi_khepri.Voter),
    #(d, ffi_khepri.Voter),
  ]

  // Neither voter can go (two of the three that would remain are not here), and
  // the leader says so for the first.
  assert roster.plan(seats, ra(members), a, []) == Held(c, Unseated)
}

// A leader the ledger no longer seats has been revoked, or reads a ledger it
// cannot use. It is cut off from the others by the revoke, and the others elect
// another. It has no standing to remove anyone, and removes no one, itself
// included.
pub fn a_leader_the_ledger_does_not_seat_does_nothing_test() {
  let seats = roster([#(b, Voter), #(c, Voter)], [a, d])
  assert roster.plan(
      seats,
      ra([
        #(a, ffi_khepri.Voter),
        #(b, ffi_khepri.Voter),
        #(c, ffi_khepri.Voter),
        #(d, ffi_khepri.NonVoter),
      ]),
      a,
      [b, c],
    )
    == roster.NotSeated
}

pub fn removals_come_in_a_fixed_order_test() {
  let seats = roster([#(a, Voter)], [b, c, d, e])
  let members = [
    #(a, ffi_khepri.Voter),
    #(b, ffi_khepri.Voter),
    #(c, NonVoter),
    #(d, NonVoter),
    #(e, ffi_khepri.Voter),
  ]
  assert roster.plan(seats, ra(members), a, [b, c, d, e]) == Remove(c, Unseated)
}
