//// The orchestrator port: how one orchestrator answers another's question
//// "do you hold this session?" (protocol-change/078, phase 3).
////
//// Two orchestrators each keep their own catalogue, and a session is created
//// on, and owned by, the orchestrator the client was connected to. When a
//// client asks the other orchestrator about that session, the other one has no
//// record, and it asks its configured peers (`client/session_directory`). This
//// module is the answering end. It is a node-level service in the sense
//// `client/remote/host` is: one process per daemon, registered under a fixed
//// name, reached as `{name, node}` (`client/remote/address`).
////
//// It has its own closed message type and its own name, and it does not extend
//// the executor host's `HostMessage`. Every executor answers `HostMessage`, and
//// an executor's ledger actor would then carry a read it has nothing to do with.
//// Phase 4 adds peer-mail delivery as a second constructor of `Message` here,
//// beside `Owns`.
////
//// Phase 5 adds the receiving half of a session move to the same port: `Import`
//// carries the pieces of a copied session file, `ImportStatus` asks how far a
//// move has got, and `Activate` asks the receiver to make the copy into the
//// session. A pure daemon that never receives sessions starts the port without
//// an `Importer`, and every one of those messages is then refused (`start`), so
//// the question the port has always answered is the only one it can be asked.
//// The pieces and the status are handled in the port's own turn, so the pieces
//// of one copy are written in the order they were sent; an activation hashes and
//// opens a whole file, so it runs in a task of its own, linked to the port and
//// cancelled with the requester, and a question about ownership is never kept
//// waiting behind it.
////
//// The answer to `Owns` comes from the daemon's catalogue and from nowhere else. A
//// `reserved` registration counts as held, because a creation retried under its
//// original key must still reach the orchestrator that reserved it, and an
//// archived session counts as held, because it is still that orchestrator's to
//// restore. A catalogue that cannot answer produces no reply at all: the asker's
//// deadline turns silence into "could not tell", which is what it is. Replying
//// `NotOwned` for a failed read would let a transient fault read as proof that
//// the session exists nowhere.
////
//// The port reveals only whether an identity is in this daemon's catalogue, to a
//// peer the operator pinned as a trusted Erlang node. It carries no credential,
//// and a client is never redirected by it: the asking daemon decides what its
//// own client is told.

import client/internal/ffi_remote
import client/remote/address.{type Address}
import client/session_move.{
  type Activation, type Chunk, type Stage, type Verdict,
}
import gleam/erlang/process.{type Name, type Subject}
import runtime/residency
import weft
import weft/actor

/// The registered name every production daemon uses for its port.
pub const default_name = "loom_orchestrator"

/// What the port is asked.
pub type Message {
  /// Whether this daemon's catalogue holds the session. The answer goes to
  /// `reply`, which the asker owns.
  Owns(
    /// The canonical session identity.
    session: String,
    /// Where the answer goes.
    reply: Subject(Ownership),
  )

  /// One piece of a session file that another orchestrator is moving here
  /// (protocol-change/078, phase 5). The answer is `Accepted` once the piece is
  /// written, and the last piece completes the copy.
  Import(
    /// The piece, with the whole file's declared size.
    chunk: Chunk,
    /// Where the verdict goes.
    reply: Subject(Verdict),
  )

  /// How far the move `op` of this session has got on this orchestrator.
  ImportStatus(
    /// The canonical session identity.
    session: String,
    /// The move's identity.
    op: String,
    /// Where the stage goes.
    reply: Subject(Stage),
  )

  /// Asks this orchestrator to make the copy it holds into the session. The
  /// answer is `Accepted` once the session is recorded as imported and its file
  /// is in place, and a repeat of the same activation answers it again.
  Activate(
    /// What to check and what to register.
    activation: Activation,
    /// Where the verdict goes.
    reply: Subject(Verdict),
  )
}

/// What the port answers.
pub type Ownership {
  /// The session is in this daemon's catalogue, in any state.
  Owned

  /// It is not.
  NotOwned

  /// This daemon's catalogue holds a tombstone for the session: it handed the
  /// session to the orchestrator `to`, which serves it now
  /// (protocol-change/078, phase 5). The tombstone is the daemon's own record of
  /// whom it gave the session to, so this answer needs no peer.
  Moved(
    /// The name of the `[orchestrators.<name>]` that received the session, as
    /// this daemon calls it.
    to: String,
  )
}

/// What a daemon does when another orchestrator moves a session to it: take the
/// pieces of a copy, say how far a move has got, and activate the session. The
/// daemon supplies the functions, so the port neither knows the catalogue nor
/// opens a file.
pub type Importer {
  Importer(
    /// Writes one piece of a copy.
    chunk: fn(Chunk) -> Verdict,
    /// How far the move `op` of the session has got, given the session and `op`.
    stage: fn(String, String) -> Stage,
    /// Makes the copy into the session.
    activate: fn(Activation) -> Verdict,
  )
}

/// The importer of a daemon that does not accept sessions from other
/// orchestrators: nothing is ever received, and every piece and activation is
/// refused with `NotImporting`.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrator_port.declining().stage("s", "op") == session_move.Absent
/// ```
pub fn declining() -> Importer {
  Importer(
    chunk: fn(_chunk) { session_move.Refused(session_move.NotImporting) },
    stage: fn(_session, _op) { session_move.Absent },
    activate: fn(_activation) {
      session_move.Refused(session_move.NotImporting)
    },
  )
}

/// The production port name, for a daemon to register and for its peers to
/// address.
///
/// ## Examples
///
/// ```gleam
/// // address.Address(node: peer_node, name: orchestrator_port.default())
/// ```
pub fn default() -> Name(Message) {
  ffi_remote.fixed_name(default_name)
}

/// Starts the port under `name`, linked to the caller. `held` reads this
/// daemon's catalogue: `Ok(Owned)` or `Ok(NotOwned)` when it could tell, and
/// `Error(Nil)` when it could not, in which case nothing is sent.
///
/// The start fails, and registers nothing, if the name is taken.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start(orchestrator_port.default(), held)
/// ```
pub fn start(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
) -> actor.StartResult(Subject(Message)) {
  start_importing(name, held, declining())
}

/// Starts the port as `start` does, for a daemon that also receives sessions
/// another orchestrator moves to it. `importer` answers the pieces, the status
/// and the activation.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start_importing(orchestrator_port.default(), held, importer)
/// ```
pub fn start_importing(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
  importer: Importer,
) -> actor.StartResult(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) {
    answer(held, importer, state, message)
  })
  |> actor.named(name)
  |> actor.hibernate_after(residency.hibernate_after_ms)
  |> actor.start
}

// One question, answered from the catalogue before the next is read. The
// catalogue read is a call into the registry, so a slow registry delays later
// questions; each asker bounds its own wait and treats a late answer as
// silence, so nothing here needs a queue of its own.
fn answer(
  held: fn(String) -> Result(Ownership, Nil),
  importer: Importer,
  state: Nil,
  message: Message,
) -> actor.Next(Nil, Message) {
  case message {
    Owns(session:, reply:) ->
      case held(session) {
        Ok(ownership) -> process.send(reply, ownership)
        Error(Nil) -> Nil
      }

    // A piece is written in this turn, so the pieces of one copy land in the
    // order they were sent.
    Import(chunk:, reply:) -> process.send(reply, importer.chunk(chunk))
    ImportStatus(session:, op:, reply:) ->
      process.send(reply, importer.stage(session, op))

    // An activation hashes and opens a whole file. It runs apart from the
    // port, so a lookup is not kept waiting behind it.
    Activate(activation:, reply:) ->
      detached(reply, fn() { importer.activate(activation) })
  }
  actor.continue(state)
}

// Computes one reply in a run that dies with the requester and with the port.
// The requester is on another node, so its death or disconnection arrives as a
// monitor `DOWN` and cancels the run, as it does for the executor's owner port.
// A run that crashes sends nothing, and the asker's deadline turns that into
// silence.
fn detached(reply: Subject(reply), compute: fn() -> reply) -> Nil {
  case process.subject_owner(reply) {
    Ok(requester) -> {
      let _witness =
        weft.new([
          fn() {
            process.send(reply, compute())
            Ok(Nil)
          },
        ])
        |> weft.cancel_when_exits(requester)
        |> weft.start_witnessed
      Nil
    }
    Error(Nil) -> Nil
  }
}

/// Asks the port at `at` whether it holds the session, and waits at most
/// `within_ms` for the answer.
///
/// `Error(Nil)` means no answer: the node is unreachable, no port is registered
/// there, the port did not answer in time, or it could not read its catalogue.
/// The monitor is taken before the request is sent, so a node that is already
/// gone ends the wait at once with its `DOWN` instead of with the deadline.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask(Address(node: peer, name: orchestrator_port.default()), id, 1500)
/// ```
pub fn ask(
  at: Address(Message),
  session: String,
  within_ms: Int,
) -> Result(Ownership, Nil) {
  exchange(at, fn(reply) { Owns(session:, reply:) }, within_ms)
}

/// Sends one piece of a copy to the port at `at` and waits at most `within_ms`
/// for the verdict. `Error(Nil)` is silence, as `ask` defines it, and is not a
/// refusal.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.send_chunk(Address(node: peer, name: orchestrator_port.default()), chunk, 5000)
/// ```
pub fn send_chunk(
  at: Address(Message),
  chunk: Chunk,
  within_ms: Int,
) -> Result(Verdict, Nil) {
  exchange(at, fn(reply) { Import(chunk:, reply:) }, within_ms)
}

/// Asks the port at `at` how far the move `op` of the session has got. Silence
/// is `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_stage(Address(node: peer, name: orchestrator_port.default()), session, op, 2000)
/// ```
pub fn ask_stage(
  at: Address(Message),
  session: String,
  op: String,
  within_ms: Int,
) -> Result(Stage, Nil) {
  exchange(at, fn(reply) { ImportStatus(session:, op:, reply:) }, within_ms)
}

/// Asks the port at `at` to activate the session from the copy it holds, and
/// waits at most `within_ms`. Silence is `Error(Nil)`; the activation may or may
/// not have happened, and the same question can be asked again.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_activation(Address(node: peer, name: orchestrator_port.default()), activation, 60_000)
/// ```
pub fn ask_activation(
  at: Address(Message),
  activation: Activation,
  within_ms: Int,
) -> Result(Verdict, Nil) {
  exchange(at, fn(reply) { Activate(activation:, reply:) }, within_ms)
}

// One request and its reply. The monitor is taken before the request is sent,
// so a node that is already gone ends the wait at once with its `DOWN` and not
// with the deadline.
fn exchange(
  at: Address(Message),
  request: fn(Subject(answer)) -> Message,
  within_ms: Int,
) -> Result(answer, Nil) {
  let reply = process.new_subject()
  let watch = address.watch(at)
  address.deliver(at, request(reply))
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
    |> process.selector_receive(within_ms)

  // Demonitoring flushes a `DOWN` that arrived beside the reply.
  process.demonitor_process(watch)
  case heard {
    Ok(answered) -> answered
    Error(Nil) -> Error(Nil)
  }
}
