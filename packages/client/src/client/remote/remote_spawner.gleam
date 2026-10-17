//// The sending end of a subagent that runs on another orchestrator
//// (protocol-change/084, slice S3).
////
//// The receiving end is the orchestrator port's `Spawn`, `Join`, `RunEnded` and
//// `Release` (`client/remote/orchestrator_port`); this module is how a parent's
//// Agency sends the first two. It does not send `RunEnded`, because a remote
//// child is always detached. `Release` is sent for a parent session that was
//// deleted, so its caller is the daemon's release drainer and not an Agency:
//// `release_over` is the same connect-and-ask for that one question. It is
//// modelled on `client/remote/remote_peer`, which does the same for peer mail,
//// and it fills the record the Agency asks through (`client/remote_reach`),
//// which also says how a call ends: answered, refused or unreachable.
////
//// Each call connects to the orchestrator's pinned peer if it is not connected
//// and asks that peer's port, so nothing keeps a connection between calls and a
//// laptop that sleeps costs the next call one reconnect. The connection is made
//// before the message is sent because a message to a node that is not connected
//// yet is lost silently. The node is resolved through the membership and the
//// configured orchestrators, so nothing a peer sends is turned into an atom, and
//// a name that is not configured is a definitive refusal.
////
//// ## Flow
////
//// `over_distribution` → `reached` → `answer`
////
//// 1. `over_distribution` builds the `Reach` of one session over the daemon's
////    membership and its configured orchestrators, and `release_over` builds
////    the one call of it that a deleted session's drainer makes.
//// 2. `reached` resolves an orchestrator's name to its pinned peer and connects,
////    or says why not.
//// 3. `answer` turns the port's reply, a refusal or silence, into the two
////    failures.

import client/distribution.{type Membership}
import client/orchestrators.{type Orchestrator}
import client/peer_mail.{type Failure}
import client/remote/address
import client/remote/orchestrator_port
import client/remote_reach.{type Reach}
import client/remote_spawn.{type Parent, type SpawnRefusal}
import client/roster.{type Roster}
import gleam/list
import gleam/result

// How much longer than the window it asks the receiver to wait a join's own
// deadline is, so the receiver's answer for a window that ran out is not itself
// cut off by the round trip.
const join_slack_ms = 2000

// How long a release waits for its answer, in milliseconds. The receiver stops
// the children and hands the session to its registry, which answers without
// waiting for the session to drain, so the bound is short.
const release_ms = 15_000

// The bound on connecting to a peer that is not connected yet. It is shorter
// than a call so that an unreachable host costs the sender little.
const connect_ms = 1500

/// The production reach of one session: for each configured orchestrator, connect
/// to its pinned peer if it is not connected and ask its port. A name the daemon
/// does not list, a peer the membership does not know, a refused handshake, an
/// unreachable host, a missing port and a late answer each end as the outcome
/// they are in `client/remote_reach`.
///
/// `offered` is asked at each spawn. The daemon passes the test that the session
/// is one its owner holds alone (`manager.unshared_sessions`).
///
/// The names the session's model is told are the orchestrators the roster holds
/// when the session opens. A spawn reads the roster again to resolve the name it
/// is given, so an orchestrator revoked since then is refused as not
/// configured, and one enrolled since then is told to the sessions that open
/// after it.
///
/// ## Examples
///
/// ```gleam
/// // remote_spawner.over_distribution(membership, orchestrators, session_id, fn() { True })
/// ```
pub fn over_distribution(
  membership: Membership,
  configured: Roster(Orchestrator),
  session: String,
  offered: fn() -> Bool,
) -> Reach {
  remote_reach.Reach(
    session:,
    orchestrators: list.map(roster.rows(configured), fn(orchestrator) {
      orchestrator.name
    }),
    offered:,
    spawn: fn(name, parent, site, depth, tools, request, within_ms) {
      use at <- result.try(reached(membership, configured, name))
      orchestrator_port.ask_spawn(
        at,
        parent,
        site,
        depth,
        tools,
        request,
        within_ms,
      )
      |> answer
    },
    join: fn(name, parent, handles, window_ms) {
      use at <- result.try(reached(membership, configured, name))
      orchestrator_port.ask_join(
        at,
        parent,
        handles,
        window_ms,
        window_ms + join_slack_ms,
      )
      |> answer
    },
    release: release_over(membership, configured),
  )
}

/// The one question of `over_distribution` that outlives the session asking it:
/// tells an orchestrator that a parent session was deleted, so it stops the
/// children it holds for it and deletes the session that held them. The answer
/// is how many children it stopped.
///
/// The daemon's release drainer calls it for a session that no longer exists, so
/// it takes the membership and the configured orchestrators and nothing of a
/// session. A name the daemon does not list is a definitive refusal, and every
/// way of not reaching the node is silence, as for the other calls.
///
/// ## Examples
///
/// ```gleam
/// // remote_spawner.release_over(membership, orchestrators)("box", parent) == Ok(2)
/// ```
pub fn release_over(
  membership: Membership,
  configured: Roster(Orchestrator),
) -> fn(String, Parent) -> Result(Int, Failure) {
  fn(name, parent) {
    use at <- result.try(reached(membership, configured, name))
    orchestrator_port.ask_release(at, parent, release_ms) |> release_answer
  }
}

/// The port's reply to a `Release` as the two failures.
///
/// It differs from the other calls in one rule: a `StoreFailure` is
/// `Unreachable`, not `Refused`. A release row is settled by an answer, and a
/// store failure on the box (a registry that timed out, a session that is
/// opening, a deletion that failed) says the box could not do it now, not that
/// it never will. Settling the row would leave the child running to its
/// deadline, so the drainer must send again. Every other refusal is definitive.
///
/// ## Examples
///
/// ```gleam
/// assert remote_spawner.release_answer(Ok(Error(remote_spawn.StoreFailure("busy"))))
///   == Error(peer_mail.Unreachable)
/// ```
pub fn release_answer(
  heard: Result(Result(Int, SpawnRefusal), Nil),
) -> Result(Int, Failure) {
  case heard {
    Ok(Error(remote_spawn.StoreFailure(..))) -> Error(peer_mail.Unreachable)
    other -> answer(other)
  }
}

// Connects to the pinned peer of a configured orchestrator, so that the port is
// reached on a connection that exists. Every way of not reaching the node is
// silence, and a name that is not configured is the one definitive refusal.
fn reached(
  membership: Membership,
  configured: Roster(Orchestrator),
  name: String,
) -> Result(address.Address(orchestrator_port.Message), Failure) {
  use orchestrator <- result.try(
    orchestrators.find(roster.rows(configured), name)
    |> result.map_error(fn(_) { remote_reach.not_configured(name) }),
  )
  use peer <- result.try(
    distribution.peer(membership, orchestrator.node)
    |> result.replace_error(peer_mail.Unreachable),
  )
  use Nil <- result.try(
    distribution.connect(peer, connect_ms)
    |> result.replace_error(peer_mail.Unreachable),
  )
  Ok(address.Address(
    node: distribution.node(peer),
    name: orchestrator_port.default(),
  ))
}

// The port's reply as the two failures. Silence from the asking functions is
// `Error(Nil)`, a refusal rides inside an answer, and only the second is
// definitive.
fn answer(heard: Result(Result(a, SpawnRefusal), Nil)) -> Result(a, Failure) {
  case heard {
    Ok(Ok(value)) -> Ok(value)
    Ok(Error(refusal)) ->
      Error(peer_mail.Refused(remote_spawn.describe_refusal(refusal)))
    Error(Nil) -> Error(peer_mail.Unreachable)
  }
}
