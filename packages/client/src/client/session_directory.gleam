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
//// lets the backing change underneath callers.
////
//// Phase 5 adds the write half as a second field, `Directory.activate`, which
//// asks the orchestrator a session is moving to to make its copy into the
//// session. The authority for a move is not a third store: it is the pair of
//// catalogue rows, the source's `moving` and `moved` and the receiver's
//// `imported`, ordered by the write-ahead intent, and `activate` is the one
//// message that takes the receiver's row. A session that moved away leaves a
//// tombstone, and the catalogue that holds it answers `lookup` from the
//// tombstone alone, with no question to any peer: `Elsewhere` the orchestrator
//// the session went to.
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
import client/remote/address
import client/remote/orchestrator_port.{type Ownership, Moved, NotOwned, Owned}
import client/session_move.{
  type Activation, type Chunk, type Stage, type Verdict,
}
import gleam/list
import gleam/option.{type Option, None, Some}
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
    /// Asks an orchestrator to activate a session from the copy it holds, and
    /// answers its verdict, or `Error(Nil)` when it could not be asked or did not
    /// answer in time. The answer `Accepted` is the compare-and-set on the
    /// receiver's catalogue: after it, the receiver owns the session.
    activate: fn(Orchestrator, Activation) -> Result(Verdict, Nil),
  )
}

/// The rest of what a source says to a receiver, beside `Directory.activate`:
/// the pieces of a copy and the question of how far a move has got. They are
/// apart from the directory because only the mover sends them, and the
/// directory is read by every command that names a session.
pub type Courier {
  Courier(
    /// Sends one piece to an orchestrator and answers its verdict, or
    /// `Error(Nil)` for silence.
    send: fn(Orchestrator, Chunk) -> Result(Verdict, Nil),
    /// Asks an orchestrator how far the move `op` of a session has got, given
    /// the session and the `op`, or `Error(Nil)` for silence.
    stage: fn(Orchestrator, String, String) -> Result(Stage, Nil),
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
  Directory(lookup: fn(_session) { Error(Unknown) }, activate: fn(_, _) {
    Error(Nil)
  })
}

/// The directory with its `activate` replaced. A directory built by `peers`
/// activates nothing until it is given the question to ask.
///
/// ## Examples
///
/// ```gleam
/// // session_directory.peers(configured, held, ask) |> session_directory.activating(activate)
/// ```
pub fn activating(
  directory: Directory,
  activate: fn(Orchestrator, Activation) -> Result(Verdict, Nil),
) -> Directory {
  Directory(..directory, activate:)
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

            // This catalogue gave the session away and says to whom. It is the
            // daemon's own record, so no peer is asked.
            Ok(Moved(to:)) -> Ok(Elsewhere(configured_or_named(asked, to)))
            Ok(NotOwned) | Error(Nil) -> fan_out(asked, session, ask) |> decide
          }
        },
        activate: fn(_orchestrator, _activation) { Error(Nil) },
      )
  }
}

// The configured orchestrator a tombstone names. A tombstone outlives the
// configuration that was current when it was written, so one naming an
// orchestrator that is no longer listed still redirects, by name alone: the
// refusal carries a name and no address, and the client is told to ask there.
fn configured_or_named(
  asked: List(Orchestrator),
  name: String,
) -> Orchestrator {
  case orchestrators.find(asked, name) {
    Ok(found) -> found
    Error(Nil) -> orchestrators.Orchestrator(name:, node: "", address: None)
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
    use at <- result.try(reached(membership, orchestrator))
    orchestrator_port.ask(at, session, reply_ms)
  }
}

/// How long the source waits for the receiver to take one piece of a copy.
pub const chunk_reply_ms = 15_000

/// How long the source waits for the receiver to say how far a move has got.
pub const stage_reply_ms = 5000

/// How long the source waits for the receiver to activate a session. It hashes
/// the whole copy and opens it, so this is the longest of the three.
pub const activation_reply_ms = 120_000

// Connects to the pinned peer of an orchestrator, or says nothing: every way
// of not reaching it is the silence the callers already treat as "try again".
fn reached(
  membership: Membership,
  orchestrator: Orchestrator,
) -> Result(address.Address(orchestrator_port.Message), Nil) {
  use peer <- result.try(
    distribution.peer(membership, orchestrator.node)
    |> result.replace_error(Nil),
  )
  use Nil <- result.try(
    distribution.connect(peer, connect_ms) |> result.replace_error(Nil),
  )
  Ok(address.Address(
    node: distribution.node(peer),
    name: orchestrator_port.default(),
  ))
}

/// The production `Directory.activate`: connect to the pinned peer and ask its
/// port to activate the session. A peer the membership does not know, a refused
/// handshake, an unreachable host, a missing port and a late answer are all
/// `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // session_directory.peers(configured, held, ask) |> session_directory.activating(session_directory.activation_over(membership))
/// ```
pub fn activation_over(
  membership: Membership,
) -> fn(Orchestrator, Activation) -> Result(Verdict, Nil) {
  fn(orchestrator, activation) {
    use at <- result.try(reached(membership, orchestrator))
    orchestrator_port.ask_activation(at, activation, activation_reply_ms)
  }
}

/// The production courier: each call connects to the pinned peer if it is not
/// already connected and asks its port.
///
/// ## Examples
///
/// ```gleam
/// // let courier = session_directory.courier_over(membership)
/// ```
pub fn courier_over(membership: Membership) -> Courier {
  Courier(
    send: fn(orchestrator, chunk) {
      use at <- result.try(reached(membership, orchestrator))
      orchestrator_port.send_chunk(at, chunk, chunk_reply_ms)
    },
    stage: fn(orchestrator, session, op) {
      use at <- result.try(reached(membership, orchestrator))
      orchestrator_port.ask_stage(at, session, op, stage_reply_ms)
    },
  )
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
/// Failing that, a peer's tombstone points at where the session went: the first
/// one, in configuration order, redirects to the orchestrator it names, even if
/// that orchestrator was silent, since a record of a hand-over is proof and
/// silence is not. Otherwise any silence makes the miss `Unreachable`, naming
/// each silent orchestrator, and only a full set of "not held" answers is
/// `Unknown`.
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
      case first_tombstone(replies) {
        Some(name) ->
          Ok(
            Elsewhere(configured_or_named(
              list.map(replies, fn(reply) { reply.0 }),
              name,
            )),
          )
        None ->
          case silent(replies) {
            [] -> Error(Unknown)
            names -> Error(Unreachable(names))
          }
      }
  }
}

// The orchestrator the first tombstone in the replies names.
fn first_tombstone(replies: List(Reply)) -> Option(String) {
  list.find_map(replies, fn(reply) {
    case reply.1 {
      Ok(Moved(to:)) -> Ok(to)
      Ok(Owned) | Ok(NotOwned) | Error(Nil) -> Error(Nil)
    }
  })
  |> option.from_result
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
