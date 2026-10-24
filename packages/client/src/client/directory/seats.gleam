//// Who the membership ledger seats in the session directory, and the one
//// change that brings Ra's membership closer to it (protocol-change/086,
//// phase 3; design note section 11.3).
////
//// A deployment with a ledger has two member lists. The ledger lists every
//// trusted node, and a node's `directory` standing says whether it also holds
//// a seat in the Khepri cluster, as a voter or as a learner. Ra keeps its own
//// list of servers. The ledger owns the first and Ra follows it, never the
//// reverse, because a trust change must not wait for a quorum.
////
//// This module is the pure part of the following. `places` reads the seats out
//// of a ledger, and `plan` compares them with what Ra holds and names the next
//// change, or says why there is none. It performs nothing: the member actor
//// asks it on the Ra leader and applies the answer through `store`, so every
//// rule here is a test over values.
////
//// ## Who adds and who removes
////
//// A member adds itself. Ra needs the new server running, with the UId it will
//// be recorded under, before the cluster can reach it, and only the new node can
//// start that server. So a node whose ledger entry seats it joins on its own
//// (`directory/member`), as a voter or a learner according to the entry. The
//// Ra leader never adds. It removes, because nobody else can say that a member
//// should go: a revoked node cannot be asked to leave, and the nodes that
//// remain cannot tell a member that was revoked from one that is slow.
////
//// ## What the leader removes
////
//// A Ra member goes when the ledger names its node and gives it no seat (it was
//// revoked, or its standing is `none`) or a different one (a voter that is now
//// a learner, or the reverse). Ra never stops the server it removed, so the
//// removed node does not learn of it from the cluster. It finds out by asking
//// (`rejoin`): a node the ledger seats whose store cannot say what the cluster
//// holds asks the leader through a peer, and when the leader's membership does
//// not list it, the node resets its store and joins again in the seat the
//// ledger gives it. A node the ledger does not seat never does, and neither
//// does one whose question went unanswered. A
//// Ra member the ledger has never named is left alone and reported. It is
//// either a node of another deployment or a node whose enrollment this
//// leader's ledger has not received yet, and removing it on a stale ledger
//// would take a member out of a cluster it had every right to be in.
////
//// ## What the leader will not do
////
//// Removing a voter changes the configuration at once, and the change commits
//// only when a majority of the voters that remain have it. The leader therefore
//// removes a voter only while a majority of the remaining voters are replicating
//// its log, which is what Ra's own status for the member says (`Membership.up`):
//// a node that is connected may run no Ra server, and one Ra has marked
//// disconnected or suspended will not acknowledge the change. Otherwise it holds, says so, and asks again at the next tick, so a
//// removal that cannot commit never sits in the log blocking the changes that
//// could. The floor of three voters is the operator's command and not this
//// module's: the ledger is the authority, and `revoke --force` is the way to
//// shrink the cluster on purpose.

import client/directory/store.{type Membership, type Seat, Learner, Voter}
import client/internal/ffi_khepri
import client/membership_entry
import client/membership_ledger.{type Ledger}
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/result
import gleam/string

/// A node the ledger seats in the directory.
pub type Place {
  Place(
    /// The Erlang node name.
    node: String,
    /// What the ledger asks of it.
    seat: Seat,
  )
}

/// What the ledger says about the directory: the nodes it seats, and a way to
/// ask whether it has ever named a node at all.
pub type Seats {
  Seats(
    /// The active members whose standing is `voter` or `learner`, ordered by
    /// node name.
    places: List(Place),
    /// Whether any entry of the ledger has named this node, active or revoked.
    named: fn(String) -> Bool,
  )
}

/// Why a Ra member should go.
pub type Why {
  /// The ledger named the node and seats it nowhere: it was revoked, or its
  /// standing is `none`.
  Unseated

  /// The ledger seats the node in the other seat.
  OtherSeat
}

/// What the leader does next.
pub type Verdict {
  /// This member is not the Ra leader, or Ra has no leader to ask. The leader
  /// owns the reconciliation.
  NotLeader

  /// This member leads Ra and the ledger it reads gives it no seat: it was
  /// revoked, or its ledger could not be read. A leader that is not a member any
  /// longer has no standing to remove anyone, so it does nothing.
  NotSeated

  /// Ra holds every member the ledger names no seat for and the ledger names no
  /// one that Ra holds in the wrong seat. `missing` lists the seated nodes Ra
  /// does not hold yet, which join by themselves, and `foreign` the Ra members
  /// the ledger has never named, which stay.
  Settled(missing: List(String), foreign: List(String))

  /// Remove this member from Ra.
  Remove(node: String, why: Why)

  /// A removal is due and cannot commit yet, because a majority of the voters
  /// that would remain are not connected. Nothing is changed.
  Held(node: String, why: Why)
}

/// What a member seated by the ledger does about the store it believes it has
/// joined, once it knows what the leader's membership holds.
pub type Rejoin {
  /// The leader's membership lists this node, or the leader did not say, or the
  /// ledger does not seat this node. The store is left as it is.
  Stay

  /// The leader answered, and its membership does not list this node. The leader
  /// removed it, and Ra never stops the server it removes, so the store queues
  /// every call until its deadline and reports no quorum while the cluster is
  /// well. The node resets the store and joins again.
  Rejoin
}

/// The seats of a ledger, read from its active members, and a way to tell
/// whether it has ever named a node.
///
/// ## Examples
///
/// ```gleam
/// seats.read(ledger).places
/// // -> [Place("loom@a.example", Voter), Place("loom@b.example", Learner)]
/// ```
pub fn read(ledger: Ledger) -> Seats {
  Seats(places: places(ledger), named: membership_ledger.ever_named(ledger, _))
}

/// The seats of a ledger: its active members with a `directory` standing other
/// than `none`, ordered by node name.
///
/// ## Examples
///
/// ```gleam
/// seats.places(ledger) // -> [Place("loom@a.example", Voter)]
/// ```
pub fn places(ledger: Ledger) -> List(Place) {
  membership_ledger.members(ledger)
  |> list.filter_map(fn(member) {
    case member.directory {
      membership_entry.Voter -> Ok(Place(member.node, Voter))
      membership_entry.Learner -> Ok(Place(member.node, Learner))
      membership_entry.NotInDirectory -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.node, b.node) })
}

/// The seat the ledger gives a node.
///
/// ## Examples
///
/// ```gleam
/// assert seats.seat_of(places, "loom@a.example") == Ok(Voter)
/// ```
pub fn seat_of(places: List(Place), node: String) -> Result(Seat, Nil) {
  list.find(places, fn(place) { place.node == node })
  |> result.map(fn(place) { place.seat })
}

/// The next change, or the reason there is none.
///
/// `local` is this member's node name, and `ra` the membership as the leader
/// gives it, whose `up` lists the members it is replicating to. The
/// reconciliation is the leader's alone, and the leader never removes itself: a
/// leader the ledger no longer seats stands down when its own entry reaches it,
/// as the revoke that unseated it disconnects it from everyone.
///
/// A learner is removed before a voter, and members in name order, so the same
/// state gives the same answer on every call. The first removal that is safe is
/// the one returned. When every due removal is held, the first is reported.
///
/// ## Examples
///
/// ```gleam
/// seats.plan(wanted, ra, "loom@a.example")
/// // -> Settled(missing: [], foreign: [])
/// ```
pub fn plan(wanted: Seats, ra: Membership, local: String) -> Verdict {
  // Check leadership status and local seating before planning cluster changes.
  case ra.leader == Some(local), seat_of(wanted.places, local) {
    False, _ -> NotLeader
    True, Error(Nil) -> NotSeated
    True, Ok(_) -> {
      let due = removals(wanted, ra, local)
      let voters = voting(ra)
      let replicating = ra.up
      let reachable = fn(node: String) {
        node == local || list.contains(replicating, node)
      }

      // Find the first membership removal that preserves quorum among remaining voters.
      case list.find(due, fn(one) { safe(one, voters, reachable) }) {
        Ok(#(node, why, _)) -> Remove(node, why)
        Error(Nil) ->
          case due {
            [#(node, why, _), ..] -> Held(node, why)
            [] ->
              Settled(
                missing: missing(wanted, ra),
                foreign: foreign(wanted, ra, local),
              )
          }
      }
    }
  }
}

/// Whether a node resets its store and joins again, given what the leader said.
///
/// `answer` is the cluster's membership as a leader gave it to a question this
/// node asked, or `Error(Nil)` when no leader answered. Only an explicit answer
/// that leaves this node out is a reason to reset: a timeout, an unreachable
/// peer and a missing leader say nothing about this node, and a node that did
/// not ask cannot tell a removed member from a slow cluster. A node the ledger
/// does not seat never joins, so it never resets either. The decision depends on
/// no clock and no count, so a healthy member cannot be talked into churning by
/// a slow network.
///
/// ## Examples
///
/// ```gleam
/// seats.rejoin(wanted, "loom@a.example", Error(Nil)) // -> Stay
/// ```
pub fn rejoin(
  wanted: Seats,
  local: String,
  answer: Result(Membership, Nil),
) -> Rejoin {
  case seat_of(wanted.places, local), answer {
    Ok(_), Ok(ra) ->
      case list.key_find(ra.members, local) {
        Ok(_) -> Stay
        Error(Nil) -> Rejoin
      }
    Error(Nil), _ | Ok(_), Error(Nil) -> Stay
  }
}

/// Computes the list of Ra cluster members that must be removed according to the desired
/// seat configuration, prioritizing learners before voting members.
fn removals(
  wanted: Seats,
  ra: Membership,
  local: String,
) -> List(#(String, Why, ffi_khepri.Voting)) {
  ra.members
  |> list.filter_map(fn(held) {
    let #(node, voting) = held

    // Filter out the local node from removal candidates.
    case node == local {
      True -> Error(Nil)
      False ->
        case seat_of(wanted.places, node), wanted.named(node) {
          Ok(seat), _ ->
            case seat_matches(seat, voting) {
              True -> Error(Nil)
              False -> Ok(#(node, OtherSeat, voting))
            }
          Error(Nil), True -> Ok(#(node, Unseated, voting))
          Error(Nil), False -> Error(Nil)
        }
    }
  })
  |> list.sort(fn(a, b) {
    case counts(a.2), counts(b.2) {
      False, True -> order.Lt
      True, False -> order.Gt
      _, _ -> string.compare(a.0, b.0)
    }
  })
}

/// Checks whether a member's current Ra voting standing matches the desired seat type.
fn seat_matches(seat: Seat, voting: ffi_khepri.Voting) -> Bool {
  case seat, voting {
    Voter, ffi_khepri.Voter | Voter, ffi_khepri.Promoting -> True
    Learner, ffi_khepri.NonVoter -> True
    Voter, ffi_khepri.NonVoter
    | Learner, ffi_khepri.Voter
    | Learner, ffi_khepri.Promoting
    -> False
  }
}

// Whether Ra counts the member toward the majority.
fn counts(voting: ffi_khepri.Voting) -> Bool {
  voting == ffi_khepri.Voter
}

/// Extracts all member node names that currently hold full voting rights in the Ra cluster.
fn voting(ra: Membership) -> List(String) {
  list.filter_map(ra.members, fn(held) {
    case held.1 {
      ffi_khepri.Voter -> Ok(held.0)
      ffi_khepri.Promoting | ffi_khepri.NonVoter -> Error(Nil)
    }
  })
}

/// Verifies that removing a given member preserves a quorum of reachable voters.
fn safe(
  one: #(String, Why, ffi_khepri.Voting),
  voters: List(String),
  reachable: fn(String) -> Bool,
) -> Bool {
  // Non-voters can always be removed safely without impacting voting majority.
  case counts(one.2) {
    False -> True
    True -> {
      let left = list.filter(voters, fn(node) { node != one.0 })
      let up = list.count(left, reachable)
      let down = list.count(left, fn(node) { !reachable(node) })
      up >= 1 && up > down
    }
  }
}

/// Finds desired member places that have not yet been enrolled in the Ra cluster.
fn missing(wanted: Seats, ra: Membership) -> List(String) {
  wanted.places
  |> list.filter(fn(place) {
    !result.is_ok(list.key_find(ra.members, place.node))
  })
  |> list.map(fn(place) { place.node })
}

/// Finds members currently enrolled in Ra that are neither local nor known to the ledger.
fn foreign(wanted: Seats, ra: Membership, local: String) -> List(String) {
  ra.members
  |> list.filter_map(fn(held) {
    let #(node, _) = held

    // Detect unrecognized nodes present in Ra membership.
    case
      node != local
      && !wanted.named(node)
      && seat_of(wanted.places, node) == Error(Nil)
    {
      True -> Ok(node)
      False -> Error(Nil)
    }
  })
}
