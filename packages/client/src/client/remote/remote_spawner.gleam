//// The sending end of a subagent that runs on another orchestrator
//// (protocol-change/084, slice S3).
////
//// The receiving end is the orchestrator port's `Spawn`, `Join` and `RunEnded`
//// (`client/remote/orchestrator_port`); this module is how a parent's Agency
//// sends the first two. It does not send `RunEnded`, because a remote child is
//// always detached in phase 1. It is modelled on `client/remote/remote_peer`, which does the same
//// for peer mail, and it fills the record the Agency asks through
//// (`client/remote_reach`), which also says how a call ends: answered, refused
//// or unreachable.
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
////    membership and its configured orchestrators.
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
import client/remote_spawn.{type SpawnRefusal}
import gleam/list
import gleam/result

// How much longer than the window it asks the receiver to wait a join's own
// deadline is, so the receiver's answer for a window that ran out is not itself
// cut off by the round trip.
const join_slack_ms = 2000

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
/// ## Examples
///
/// ```gleam
/// // remote_spawner.over_distribution(membership, orchestrators, session_id, fn() { True })
/// ```
pub fn over_distribution(
  membership: Membership,
  configured: List(Orchestrator),
  session: String,
  offered: fn() -> Bool,
) -> Reach {
  remote_reach.Reach(
    session:,
    orchestrators: list.map(configured, fn(orchestrator) { orchestrator.name }),
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
  )
}

// Connects to the pinned peer of a configured orchestrator, so that the port is
// reached on a connection that exists. Every way of not reaching the node is
// silence, and a name that is not configured is the one definitive refusal.
fn reached(
  membership: Membership,
  configured: List(Orchestrator),
  name: String,
) -> Result(address.Address(orchestrator_port.Message), Failure) {
  use orchestrator <- result.try(
    orchestrators.find(configured, name)
    |> result.replace_error(remote_reach.not_configured(name)),
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
