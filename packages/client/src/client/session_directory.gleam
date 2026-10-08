//// The session directory: which orchestrator owns a session
//// (protocol-change/078, phase 3).
////
//// A deployment with two orchestrators keeps one catalogue per orchestrator.
//// A session is created on, and owned by, the orchestrator the client was
//// connected to, and the catalogue stays the source of truth for the sessions
//// that orchestrator owns. A client that asks the other orchestrator about it
//// needs to be told who owns it, and this module is the question and its three
//// answers.
////
//// ## The interface
////
//// `Directory.lookup` takes a session identity and answers `Here` (this
//// orchestrator owns it), `Elsewhere` (a configured orchestrator does), or a
//// `Miss`: `Unknown` (nobody answered that they hold it, and everybody
//// answered) or `Unreachable` (somebody could not be asked, and nobody else
//// holds it). A caller consults `lookup` before it acts on a session and never
//// reasons "I found it in my own catalogue, so it is mine". That rule is what
//// lets the backing change underneath callers. Phase 5 replaces the backing with
//// an authoritative store whose answer is not a function of this catalogue, and
//// adds a write half (`activate`) as a second field; callers of `lookup` do not
//// change.
////
//// ## The phase 3 backing
////
//// `peers` answers from the local catalogue first. When the local catalogue does
//// not hold the session, it asks every configured orchestrator at once, in one
//// deadline-bounded fan-out, the way `sessions.activity` asks its residents. The
//// question is `client/remote/orchestrator_port.Owns`, sent to the peer over the
//// pinned distribution connection. Nothing is cached, nothing is retried and no
//// reconnect loop runs: a peer that is down costs one connection attempt per
//// lookup, and a lookup happens only when a client names a session this daemon
//// does not hold.
////
//// `decide` is the whole policy and is pure. A peer that holds the session
//// wins over every silence, because a positive answer is proof and a missing one
//// is not. With no positive answer, any silence makes the miss `Unreachable`,
//// naming the silent orchestrators, because the session may live on exactly the
//// machine that did not answer. Only when every peer answered that it does not
//// hold the session is it `Unknown`.
////
//// ## What this does not do
////
//// No daemon registers a session anywhere: identities are UUIDv7, creation is
//// local, and a lookup that reaches the owner needs no earlier write. No peer
//// advertises an address; the asking side's `[orchestrators.<name>]` row holds
//// the address a client is told. And nothing follows the redirect for the
//// client, which would need that client to hold a credential for a second
//// daemon (`docs/client-protocol.md`, `not_owner`).

import client/distribution.{type Membership}
import client/orchestrators.{type Orchestrator}
import client/peer_mail
import client/remote/address
import client/remote/orchestrator_port.{type Ownership, NotOwned, Owned}
import gleam/list
import gleam/result
import weft

/// How long a lookup waits for the slowest peer. A peer that has not answered
/// by then is silent, and the lookup does not wait for it.
pub const deadline_ms = 2000

// The bounds on the two steps of one peer's question. Each is shorter than the
// deadline so that a peer which connects slowly can still answer, and the
// deadline is what ends a peer that is slow at both.
const connect_ms = 1500

const reply_ms = 1500

/// Who owns a session.
pub type Owner {
  /// This orchestrator does.
  Here

  /// A configured orchestrator does.
  Elsewhere(
    /// The configured row of the owner, which carries the node and, when the
    /// operator gave one, the address a client connects to.
    orchestrator: Orchestrator,
  )
}

/// Why no owner was found.
pub type Miss {
  /// Every orchestrator that was asked answered, and none holds the session.
  Unknown

  /// No orchestrator said it holds the session, and some could not be asked or
  /// did not answer.
  Unreachable(
    /// The names of the orchestrators that did not answer, in configuration
    /// order.
    orchestrators: List(String),
  )
}

/// The session directory.
pub type Directory {
  Directory(
    /// Which orchestrator owns the session with this canonical identity.
    lookup: fn(String) -> Result(Owner, Miss),
    /// How to speak to an owner that is not this orchestrator: the peer-mail
    /// endpoint for a session the orchestrator owns (phase 4). A directory
    /// that cannot reach anyone gives an endpoint whose every call is
    /// `Unreachable`.
    reach: fn(Orchestrator, String) -> peer_mail.Endpoint,
  )
}

/// One peer's question: the orchestrator asked, and its answer, with
/// `Error(Nil)` for no answer.
pub type Reply =
  #(Orchestrator, Result(Ownership, Nil))

/// The directory of a daemon that asks nobody. Every lookup is `Unknown`, so
/// a miss in the local catalogue is `not_found`, exactly as it was before
/// there was a directory.
///
/// ## Examples
///
/// ```gleam
/// assert session_directory.none().lookup("0198c0de-0000-7000-8000-000000000001")
///   == Error(session_directory.Unknown)
/// ```
pub fn none() -> Directory {
  Directory(lookup: fn(_session) { Error(Unknown) }, reach: cannot_reach)
}

// The reach of a daemon with no way to connect: an endpoint nobody answers.
fn cannot_reach(
  _orchestrator: Orchestrator,
  session: String,
) -> peer_mail.Endpoint {
  peer_mail.Endpoint(session:, call: fn(_command) {
    Error(peer_mail.Unreachable)
  })
}

/// The same directory with `reach` as the way to speak to an owner. The
/// lookup is unchanged; only the daemon that has a distribution membership
/// knows how to build a connected endpoint.
///
/// ## Examples
///
/// ```gleam
/// // session_directory.with_reach(directory, remote_peer.over_distribution(membership))
/// ```
pub fn with_reach(
  directory: Directory,
  reach: fn(Orchestrator, String) -> peer_mail.Endpoint,
) -> Directory {
  Directory(..directory, reach:)
}

/// The phase 3 directory over the configured orchestrators.
///
/// `held` reads this daemon's own catalogue; an error is treated as not held,
/// since the caller only asks after its own read missed. `ask` puts one
/// question to one orchestrator (`over_distribution` is the production one). A
/// daemon that lists no orchestrator is `none()`.
///
/// ## Examples
///
/// ```gleam
/// // session_directory.peers(configured, held, session_directory.over_distribution(membership))
/// ```
pub fn peers(
  asked: List(Orchestrator),
  held: fn(String) -> Result(Ownership, Nil),
  ask: fn(Orchestrator, String) -> Result(Ownership, Nil),
) -> Directory {
  case asked {
    [] -> none()
    _ ->
      Directory(
        lookup: fn(session) {
          case held(session) {
            Ok(Owned) -> Ok(Here)
            Ok(NotOwned) | Error(Nil) -> fan_out(asked, session, ask) |> decide
          }
        },
        reach: cannot_reach,
      )
  }
}

/// The production question: connect to the pinned peer if it is not already
/// connected, then ask its port. A peer the membership does not know, a refused
/// handshake, an unreachable host, a missing port and a late answer are all
/// `Error(Nil)`, which is silence.
///
/// ## Examples
///
/// ```gleam
/// // let ask = session_directory.over_distribution(membership)
/// // ask(orchestrator, session_id)
/// ```
pub fn over_distribution(
  membership: Membership,
) -> fn(Orchestrator, String) -> Result(Ownership, Nil) {
  fn(orchestrator: Orchestrator, session: String) {
    use peer <- result.try(
      distribution.peer(membership, orchestrator.node)
      |> result.replace_error(Nil),
    )
    use Nil <- result.try(
      distribution.connect(peer, connect_ms) |> result.replace_error(Nil),
    )
    orchestrator_port.ask(
      address.Address(
        node: distribution.node(peer),
        name: orchestrator_port.default(),
      ),
      session,
      reply_ms,
    )
  }
}

// Every orchestrator is asked at once from the calling process, in one weft
// run under `deadline_ms`, and the run's deadline kills and joins any task
// still waiting. A task that answers completes and a task that gets no answer
// fails, so `Failed` is silence already; outcomes come back in input order, so
// zipping them with the list restores configuration order. Anything other than
// an answer is silence: a task that crashed or was cut off told the lookup
// nothing, and treating it as "not held" would let a fault read as proof.
fn fan_out(
  asked: List(Orchestrator),
  session: String,
  ask: fn(Orchestrator, String) -> Result(Ownership, Nil),
) -> List(Reply) {
  let outcomes =
    asked
    |> list.map(fn(orchestrator) { fn() { ask(orchestrator, session) } })
    |> weft.new
    |> weft.deadline(deadline_ms)
    |> weft.start
  list.map2(asked, outcomes, fn(orchestrator, outcome) {
    case outcome {
      weft.Completed(value:, ..) -> #(orchestrator, Ok(value))
      weft.Failed(..)
      | weft.Crashed(..)
      | weft.Abandoned(..)
      | weft.NeverStarted(..)
      | weft.DrainProofLost(..)
      | weft.CancellationUnconfirmed(..) -> #(orchestrator, Error(Nil))
    }
  })
}

/// The directory's policy, as a function of the replies. The first
/// orchestrator that holds the session, in configuration order, owns it.
/// Otherwise any silence makes the miss `Unreachable`, naming each silent
/// orchestrator, and only a full set of "not held" answers is `Unknown`.
///
/// ## Examples
///
/// ```gleam
/// assert session_directory.decide([]) == Error(session_directory.Unknown)
/// ```
pub fn decide(replies: List(Reply)) -> Result(Owner, Miss) {
  case list.find(replies, fn(reply) { reply.1 == Ok(Owned) }) {
    Ok(#(orchestrator, _)) -> Ok(Elsewhere(orchestrator))
    Error(Nil) ->
      case silent(replies) {
        [] -> Error(Unknown)
        names -> Error(Unreachable(names))
      }
  }
}

// The names of the orchestrators that gave no answer, in the order asked.
fn silent(replies: List(Reply)) -> List(String) {
  list.filter_map(replies, fn(reply) {
    case reply {
      #(orchestrator, Error(Nil)) -> Ok(orchestrator.name)
      #(_, Ok(_)) -> Error(Nil)
    }
  })
}
