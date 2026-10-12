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
//// a learner, or the reverse; the member then joins again in its new seat). A
//// Ra member the ledger has never named is left alone and reported. It is
//// either a node of another deployment or a node whose enrollment this
//// leader's ledger has not received yet, and removing it on a stale ledger
//// would take a member out of a cluster it had every right to be in.
////
//// ## What the leader will not do
////
//// Removing a voter changes the configuration at once, and the change commits
//// only when a majority of the voters that remain have it. The leader therefore
//// removes a voter only while a majority of the remaining voters are connected
//// to it. Otherwise it holds, says so, and asks again at the next tick, so a
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
pub type Roster {
  Roster(
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

/// The seats of a ledger, read from its active members, and a way to tell
/// whether it has ever named a node.
///
/// ## Examples
///
/// ```gleam
/// roster.roster(ledger).places
/// // -> [Place("loom@a.example", Voter), Place("loom@b.example", Learner)]
/// ```
pub fn roster(ledger: Ledger) -> Roster {
  Roster(places: places(ledger), named: membership_ledger.ever_named(ledger, _))
}

/// The seats of a ledger: its active members with a `directory` standing other
/// than `none`, ordered by node name.
///
/// ## Examples
///
/// ```gleam
/// roster.places(ledger) // -> [Place("loom@a.example", Voter)]
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
/// assert roster.seat_of(places, "loom@a.example") == Ok(Voter)
/// ```
pub fn seat_of(places: List(Place), node: String) -> Result(Seat, Nil) {
  list.find(places, fn(place) { place.node == node })
  |> result.map(fn(place) { place.seat })
}

/// The next change, or the reason there is none.
///
/// `local` is this member's node name, `up` the nodes connected to it, which
/// need not list `local`. The reconciliation is the leader's alone, and the
/// leader never removes itself: a leader the ledger no longer seats stands down
/// when its own entry reaches it, as the revoke that unseated it disconnects it
/// from everyone.
///
/// A learner is removed before a voter, and members in name order, so the same
/// state gives the same answer on every call. The first removal that is safe is
/// the one returned. When every due removal is held, the first is reported.
///
/// ## Examples
///
/// ```gleam
/// roster.plan(roster, ra, "loom@a.example", ["loom@b.example"])
/// // -> Settled(missing: [], foreign: [])
/// ```
pub fn plan(
  roster: Roster,
  ra: Membership,
  local: String,
  up: List(String),
) -> Verdict {
  case ra.leader == Some(local), seat_of(roster.places, local) {
    False, _ -> NotLeader
    True, Error(Nil) -> NotSeated
    True, Ok(_) -> {
      let due = removals(roster, ra, local)
      let voters = voting(ra)
      let reachable = fn(node: String) {
        node == local || list.contains(up, node)
      }
      case list.find(due, fn(one) { safe(one, voters, reachable) }) {
        Ok(#(node, why, _)) -> Remove(node, why)
        Error(Nil) ->
          case due {
            [#(node, why, _), ..] -> Held(node, why)
            [] ->
              Settled(
                missing: missing(roster, ra),
                foreign: foreign(roster, ra, local),
              )
          }
      }
    }
  }
}

// The Ra members the ledger wants gone, learners before voters. The third
// element is whether Ra counts the member toward the majority.
fn removals(
  roster: Roster,
  ra: Membership,
  local: String,
) -> List(#(String, Why, ffi_khepri.Voting)) {
  ra.members
  |> list.filter_map(fn(held) {
    let #(node, voting) = held
    case node == local {
      True -> Error(Nil)
      False ->
        case seat_of(roster.places, node), roster.named(node) {
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

// Whether the seat is the one the member holds. A member Ra is promoting is on
// its way to a voter's seat, and counts as one.
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

fn voting(ra: Membership) -> List(String) {
  list.filter_map(ra.members, fn(held) {
    case held.1 {
      ffi_khepri.Voter -> Ok(held.0)
      ffi_khepri.Promoting | ffi_khepri.NonVoter -> Error(Nil)
    }
  })
}

// A removal is safe when it takes no vote away, or when a majority of the
// voters that remain are reachable and there is at least one. Ra applies the
// new configuration as soon as the change is appended, so the majority it needs
// to commit is the majority of the voters left.
fn safe(
  one: #(String, Why, ffi_khepri.Voting),
  voters: List(String),
  reachable: fn(String) -> Bool,
) -> Bool {
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

fn missing(roster: Roster, ra: Membership) -> List(String) {
  roster.places
  |> list.filter(fn(place) {
    !result.is_ok(list.key_find(ra.members, place.node))
  })
  |> list.map(fn(place) { place.node })
}

fn foreign(roster: Roster, ra: Membership, local: String) -> List(String) {
  ra.members
  |> list.filter_map(fn(held) {
    let #(node, _) = held
    case
      node != local
      && !roster.named(node)
      && seat_of(roster.places, node) == Error(Nil)
    {
      True -> Ok(node)
      False -> Error(Nil)
    }
  })
}
