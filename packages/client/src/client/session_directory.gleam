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
//// ## The directory backing (protocol-change/081)
////
//// A daemon that is a member of the session directory's Khepri cluster asks
//// no peer at all. `khepri` reads this member's own copy of the session's
//// owner record: no record is `Unknown`, a record naming this node is `Here`,
//// one naming another node is `Elsewhere` with this daemon's row for that
//// node, or a row carrying only the node name when it lists none, and a store
//// that is not running or has not joined is `Unavailable`. The copy can lag
//// the leader, which is acceptable for a redirect: a client sent to the
//// previous owner is redirected again there. Such a directory also carries
//// the `Ownership` writes on an orchestrator, and its `standing` reports the
//// member's view of the cluster for `directory.status`.
////
//// ## What this does not do
////
//// No daemon registers a session anywhere: identities are UUIDv7, creation is
//// local, and a lookup that reaches the owner needs no earlier write. No peer
//// advertises an address; the asking side's `[orchestrators.<name>]` row holds
//// the address a client is told. And nothing follows the redirect for the
//// client, which would need that client to hold a credential for a second
//// daemon (`docs/client-protocol.md`, `not_owner`).

import client/directory/member
import client/directory/ownership
import client/directory/record.{type Record}
import client/directory/store
import client/distribution.{type Membership}
import client/orchestrators.{type Orchestrator}
import client/peer_mail
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

/// How long `settle_over` waits for a first connection's handshake. A lookup
/// gives one connection `connect_ms`, which a first TLS handshake to a loaded
/// machine can outlast; the handshake goes on in the background after the
/// lookup gives up on it. This is the second, longer wait a command with no
/// way to retry takes for it, and it stays under OTP's own handshake bound
/// (`net_setuptime`, seven seconds by default).
pub const settle_ms = 5000

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

  /// The directory store on this member is not running or has not joined, so
  /// its copy of the record cannot be read (protocol-change/081).
  Unavailable(
    /// What went wrong, for the refusal's message.
    reason: String,
  )
}

/// Whether this daemon is a member of the session directory's Khepri cluster
/// (protocol-change/081).
pub type Standing {
  /// The daemon is not a member; `directory.status` is refused.
  NotMember

  /// The daemon is a member, and this is how it reports what it knows.
  Member(
    /// The member's view of the cluster, asked when `directory.status` is.
    status: fn() -> member.Status,
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
    /// Asks an orchestrator to activate a session from the copy it holds, and
    /// answers its verdict, or `Error(Nil)` when it could not be asked or did not
    /// answer in time. The answer `Accepted` is the compare-and-set on the
    /// receiver's catalogue: after it, the receiver owns the session.
    activate: fn(Orchestrator, Activation) -> Result(Verdict, Nil),
    /// Waits, bounded by `settle_ms`, for the connection to every listed
    /// orchestrator to finish its handshake. A command with nothing to retry
    /// from calls it after a lookup found an owner silent, because the silence
    /// may be only a first handshake still under way. A directory that
    /// connects to nobody does nothing.
    settle: fn() -> Nil,
    /// The writes to the directory's owner records, on an orchestrator that is
    /// a directory member; `None` everywhere else (protocol-change/081).
    ownership: Option(ownership.Ownership),
    /// Whether this daemon is a directory member.
    standing: Standing,
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
  Directory(
    lookup: fn(_session) { Error(Unknown) },
    reach: cannot_reach,
    activate: fn(_, _) { Error(Nil) },
    settle: fn() { Nil },
    ownership: None,
    standing: NotMember,
  )
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

/// The directory with its `settle` replaced. A directory built by `peers` or
/// `khepri` settles nothing until it is given the connections to wait for.
///
/// ## Examples
///
/// ```gleam
/// // directory |> session_directory.settling(session_directory.settle_over(membership, listed))
/// ```
pub fn settling(directory: Directory, settle: fn() -> Nil) -> Directory {
  Directory(..directory, settle:)
}

/// The production `Directory.settle`: connects to the pinned peer of every
/// listed orchestrator at once, each under `settle_ms`, and returns when every
/// handshake has finished or failed, or the bound has passed. A connection
/// already made answers at once, so a settle among connected peers costs
/// nothing. The outcomes are not reported: the caller asks its question again
/// and reads the answer there.
///
/// ## Examples
///
/// ```gleam
/// // let settle = session_directory.settle_over(membership, config.orchestrators)
/// ```
pub fn settle_over(
  membership: Membership,
  listed: List(Orchestrator),
) -> fn() -> Nil {
  fn() {
    let _outcomes =
      listed
      |> list.map(fn(orchestrator: Orchestrator) {
        fn() {
          use peer <- result.try(
            distribution.peer(membership, orchestrator.node)
            |> result.replace_error(Nil),
          )
          distribution.connect(peer, settle_ms) |> result.replace_error(Nil)
        }
      })
      |> weft.new
      |> weft.deadline(settle_ms + 500)
      |> weft.start
    Nil
  }
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
        reach: cannot_reach,
        activate: fn(_orchestrator, _activation) { Error(Nil) },
        settle: fn() { Nil },
        ownership: None,
        standing: NotMember,
      )
  }
}

/// The directory of a member daemon (protocol-change/081): lookups read this
/// member's copy of the owner record. `local` is this daemon's node name, and
/// `listed` its configured orchestrators, through which an owner's node is
/// named to a client.
///
/// ## Examples
///
/// ```gleam
/// // session_directory.khepri(config.orchestrators, local, store.read)
/// ```
pub fn khepri(
  listed: List(Orchestrator),
  local: String,
  read: fn(String) -> Result(Option(Record), store.Unavailable),
) -> Directory {
  Directory(
    lookup: fn(session) {
      case read(session) {
        Ok(None) -> Error(Unknown)
        Ok(Some(found)) if found.owner == local -> Ok(Here)
        Ok(Some(found)) -> Ok(Elsewhere(by_node_or_named(listed, found.owner)))
        Error(store.Unavailable(reason:)) -> Error(Unavailable(reason))
      }
    },
    reach: cannot_reach,
    activate: fn(_orchestrator, _activation) { Error(Nil) },
    settle: fn() { Nil },
    ownership: None,
    standing: NotMember,
  )
}

/// The directory with its writes and its standing set, for a member daemon.
///
/// ## Examples
///
/// ```gleam
/// // session_directory.as_member(directory, Some(ownership), fn() { member.status(handle) })
/// ```
pub fn as_member(
  directory: Directory,
  ownership: Option(ownership.Ownership),
  status: fn() -> member.Status,
) -> Directory {
  Directory(..directory, ownership:, standing: Member(status:))
}

// The configured orchestrator a node answers to, or a row carrying the node as
// its name when this daemon lists none: the refusal still says where the
// session is, without an address.
fn by_node_or_named(listed: List(Orchestrator), node: String) -> Orchestrator {
  case orchestrators.by_node(listed, node) {
    Ok(found) -> found
    Error(Nil) -> orchestrators.Orchestrator(name: node, node:, address: None)
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
