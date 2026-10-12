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
//// beside `Owns`: `PeerCommand` carries one of the five commands a session's
//// peer mail sends to a recipient on another orchestrator
//// (`client/remote/remote_peer` is the sending end). The fifth, `Roster`, is a
//// read of the strands the recipient granted the sender, and `Describe` is a
//// read of what this daemon's catalogue says about a session it owns, without
//// opening it. Both let a listing on the sender's orchestrator show a
//// recipient here as it shows a local one.
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
//// Phase 6 (protocol-change/084) adds the receiving half of a subagent that runs
//// on this orchestrator for a parent on another: `Spawn` starts a child, `Join`
//// reports on children, and `RunEnded` stops the children a finished run owns.
//// The vocabulary is `client/remote_spawn`. A daemon supplies a `SpawnHost`, the
//// functions that judge and serve those three messages, and a daemon that
//// accepts no spawns starts the port with `refusing_spawns`, which answers every
//// one with `UnknownSpawner`, as a daemon that receives no sessions refuses
//// `Import`. All three run apart from the port, as `Activate` does, because a
//// spawn may open a session and a join may wait for most of half a minute, and
//// a question about ownership is never kept waiting behind either. A host that
//// cannot answer sends nothing, and the asker's deadline turns that into
//// silence, which for a spawn means "the child may exist" and is resolved by
//// resending, since the receiver adopts the child its call site already made.
//// The sending end is `client/remote/remote_spawner`, which connects to the
//// pinned peer and asks through `ask_spawn`, `ask_join` and `ask_run_ended`
//// below, and fills the record the parent's Agency asks through
//// (`client/remote_reach`).
////
//// The port reveals only whether an identity is in this daemon's catalogue, to a
//// peer the operator pinned as a trusted Erlang node. It carries no credential,
//// and a client is never redirected by it: the asking daemon decides what its
//// own client is told.
////
//// A `PeerCommand` is served on the same trust. A peer orchestrator is pinned
//// by the operator and can already do anything the distribution connection
//// allows, so the port limits what it forwards for the sake of correctness
//// rather than as an access boundary: the sending orchestrator authenticates
//// its own session and puts that session's identity in the command, and the
//// recipient's grant is still the authority that admits it. A `Describe`
//// reveals what a local listing of the session would, to a peer that already
//// has every session's identity from `Owns`; the sender asks only about a
//// session its own link or grant names, and the recipient's `Roster` answer is
//// bounded by the grants the recipient made to the asking session.

import client/internal/ffi_remote
import client/peer_mail
import client/remote/address.{type Address}
import client/remote_spawn.{
  type CallSite, type Joined, type Origin, type Parent, type Request,
  type SpawnRefusal, type Spawned,
}
import client/session_move.{
  type Activation, type Chunk, type Stage, type Verdict,
}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Name, type Subject}
import runtime/residency
import tools/agent.{type Handle}
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

  /// One peer-mail command for a session this daemon holds, from the
  /// orchestrator whose session is sending to it (protocol-change/078, phase
  /// 4). Only `Allow`, `Revoke`, `Deliver`, `SentReceipt` and `Roster` are
  /// served; the port refuses every other command, because the sending
  /// orchestrator never needs another and each one reads or writes state a
  /// remote peer has no business with. The answer is the local Agency's own, so
  /// a repeated `Deliver` is answered from the stored receipt exactly as it is
  /// in one VM, and a `Roster` lists what the session granted the sender.
  PeerCommand(
    /// The canonical identity of the recipient session.
    session: String,
    /// The command, which is plain data and carries no process or closure.
    command: peer_mail.Command,
    /// Where the answer goes. A command that was refused is answered with
    /// `Error`; nothing is sent when the port itself could not run.
    reply: Subject(Result(JsonValue, String)),
  )

  /// What this daemon's catalogue says about a session it owns, for a listing
  /// on the orchestrator that links to it. It reads the catalogue and never
  /// opens the session, as the local description does, so a saved session
  /// answers. The answer is the description or the text of the reason there is
  /// none; nothing is sent when the port itself could not run.
  ///
  /// A port built before this constructor existed has no clause for it and
  /// stops. A new `peer_mail.Command` would do the same, because `served` has no
  /// catch-all, so this port assumes peers of the same build
  /// (protocol-change/078, "Mixed builds").
  Describe(
    /// The canonical session identity.
    session: String,
    /// Where the answer goes.
    reply: Subject(Result(JsonValue, String)),
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

  /// How far the move `op` of this session has got on this orchestrator. No
  /// reply is sent when the importer cannot tell.
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

  /// Starts a child for a parent on the sending orchestrator
  /// (protocol-change/084). The answer is the child's handle, or the reason the
  /// spawn was refused. A repeat from the same call site answers the same
  /// handle, which is what lets the sender resend until it is answered.
  Spawn(
    /// The parent session and strand, on the sending orchestrator.
    parent: Parent,
    /// The parent's planned call, from which the child's name is derived.
    call_site: CallSite,
    /// The parent's depth, which the spawner's `max_depth` is checked against.
    depth: Int,
    /// The tools the parent holds, which the child's tools may not exceed.
    parent_tools: List(String),
    /// What the parent asked for.
    request: Request,
    /// Where the answer goes.
    reply: Subject(Result(Spawned, SpawnRefusal)),
  )

  /// Waits, for at most `within_ms`, until the named children of the parent have
  /// settled, and answers one entry per handle in the order given. A wait is a
  /// read: asking twice about a settled child answers the same entry twice.
  Join(
    /// The parent session and strand whose children are meant.
    parent: Parent,
    /// The children, as `Spawned` returned them.
    handles: List(Handle),
    /// The longest the receiver waits, in milliseconds.
    within_ms: Int,
    /// Where the entries go.
    reply: Subject(Result(List(Joined), SpawnRefusal)),
  )

  /// Tells the receiver that the parent's run `operation` ended, so it stops the
  /// children that run owns. The answer is how many it stopped, and a repeat
  /// stops nothing more.
  RunEnded(
    /// The parent session and strand.
    parent: Parent,
    /// The parent's operation that ended.
    operation: OpId,
    /// Where the count goes.
    reply: Subject(Result(Int, SpawnRefusal)),
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

/// What a daemon does when another orchestrator asks it to run subagents
/// (protocol-change/084): judge the sender against its spawn policy, and serve
/// the three messages. The daemon supplies the functions, so the port neither
/// reads the policy nor opens a session.
///
/// Each function runs in a task of its own, linked to the port and cancelled
/// with the requester (`detached`), so one may take as long as it needs. Each
/// answers `Error` with the refusal when it declines, and a function that
/// crashes sends nothing.
pub type SpawnHost {
  SpawnHost(
    /// Starts a child, or adopts the one the call site already made.
    spawn: fn(Origin, CallSite, Int, List(String), Request) ->
      Result(Spawned, SpawnRefusal),
    /// Reports on children, given the handles and the longest wait in
    /// milliseconds.
    join: fn(Origin, List(Handle), Int) -> Result(List(Joined), SpawnRefusal),
    /// Stops the children a finished run owns, given the run's operation, and
    /// counts them.
    run_ended: fn(Origin, OpId) -> Result(Int, SpawnRefusal),
  )
}

/// The host of a daemon that accepts no spawns: every message is refused with
/// `UnknownSpawner`, naming the node it came from, because no spawner names that
/// node.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.refusing_spawns().run_ended(origin, operation)
/// // -> Error(remote_spawn.UnknownSpawner(origin.node))
/// ```
pub fn refusing_spawns() -> SpawnHost {
  SpawnHost(
    spawn: fn(origin, _call_site, _depth, _parent_tools, _request) {
      Error(remote_spawn.UnknownSpawner(node: origin.node))
    },
    join: fn(origin, _handles, _within_ms) {
      Error(remote_spawn.UnknownSpawner(node: origin.node))
    },
    run_ended: fn(origin, _operation) {
      Error(remote_spawn.UnknownSpawner(node: origin.node))
    },
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
    /// An importer that cannot tell, because its catalogue did not answer,
    /// returns `Error(Nil)` and the port sends nothing, as it does for `Owns`.
    stage: fn(String, String) -> Result(Stage, Nil),
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
/// assert orchestrator_port.declining().stage("s", "op") == Ok(session_move.Absent)
/// ```
pub fn declining() -> Importer {
  Importer(
    chunk: fn(_chunk) { session_move.Refused(session_move.NotImporting) },
    stage: fn(_session, _op) { Ok(session_move.Absent) },
    activate: fn(_activation) {
      session_move.Refused(session_move.NotImporting)
    },
  )
}

/// What the port does with a peer command once it has accepted the kind: find
/// the session's Agency here and ask it. A session this daemon's catalogue
/// holds that is not resident is `Error(peer_mail.not_open_reason)`, so the
/// sender can wait for the owner to open it, and one it does not hold is
/// `Error(peers.not_running)`, the text a local send to a session nobody holds
/// gets.
pub type PeerHandler =
  fn(String, peer_mail.Command) -> Result(JsonValue, String)

/// What the port answers to `Describe`: the catalogue's description of the
/// session, or the reason there is none. The daemon supplies it, so the port
/// does not know the catalogue.
pub type Describer =
  fn(String) -> Result(JsonValue, String)

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
/// A port started this way refuses every peer command, which is what a daemon
/// with nothing to deliver to answers. `start_serving` takes the handler that
/// forwards them.
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
  start_with(
    name,
    held,
    fn(_session, _command) { Error(peer_unserved) },
    unserved_description,
    declining(),
    refusing_spawns(),
  )
}

// The description of a port started without a catalogue to describe from.
fn unserved_description(_session: String) -> Result(JsonValue, String) {
  Error(peer_unserved)
}

/// Starts the port as `start` does, and serves peer commands with `peer`.
/// The port decides which kinds of command are served; `peer` is only called
/// for those. A `Describe` is refused.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start_serving(orchestrator_port.default(), held, forward)
/// ```
pub fn start_serving(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
  peer: PeerHandler,
) -> actor.StartResult(Subject(Message)) {
  start_with(
    name,
    held,
    peer,
    unserved_description,
    declining(),
    refusing_spawns(),
  )
}

/// Starts the port as `start` does, for a daemon that also receives sessions
/// another orchestrator moves to it. `importer` answers the pieces, the status
/// and the activation. Peer commands are refused.
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
  start_with(
    name,
    held,
    fn(_session, _command) { Error(peer_unserved) },
    unserved_description,
    importer,
    refusing_spawns(),
  )
}

/// Starts the port serving peer commands (phase 4), descriptions of the
/// sessions it holds, session moves (phase 5) and subagent spawns (phase 6),
/// which is what the production daemon runs. `start`, `start_serving` and
/// `start_importing` are this with the other parts refused.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start_with(orchestrator_port.default(), held, forward, describe, importer, spawns)
/// ```
pub fn start_with(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
  peer: PeerHandler,
  describe: Describer,
  importer: Importer,
  spawns: SpawnHost,
) -> actor.StartResult(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) {
    answer(held, peer, describe, importer, spawns, state, message)
  })
  |> actor.named(name)
  |> actor.hibernate_after(residency.hibernate_after_ms)
  |> actor.start
}

/// The refusal for a peer command of a kind the port does not serve.
pub const peer_unserved = "that command is not served to a peer orchestrator"

// One question, answered from the catalogue before the next is read. The
// catalogue read is a call into the registry, so a slow registry delays later
// questions; each asker bounds its own wait and treats a late answer as
// silence, so nothing here needs a queue of its own.
//
// A peer command is answered in the same loop. It waits on the session's
// Agency for at most that Agency's holder timeout, so a wedged session delays
// the questions behind it by that long and no longer; a sender whose deadline
// passes first treats the late answer as silence and asks again, and an asked
// `Deliver` that did commit answers its repeat with the stored receipt.
fn answer(
  held: fn(String) -> Result(Ownership, Nil),
  peer: PeerHandler,
  describe: Describer,
  importer: Importer,
  spawns: SpawnHost,
  state: Nil,
  message: Message,
) -> actor.Next(Nil, Message) {
  case message {
    Owns(session:, reply:) ->
      case held(session) {
        Ok(ownership) -> process.send(reply, ownership)
        Error(Nil) -> Nil
      }

    PeerCommand(session:, command:, reply:) ->
      case served(command) {
        True -> process.send(reply, peer(session, command))
        False -> process.send(reply, Error(peer_unserved))
      }

    // A description is one catalogue read, answered in this turn like `Owns`.
    Describe(session:, reply:) -> process.send(reply, describe(session))

    // A piece is written in this turn, so the pieces of one copy land in the
    // order they were sent.
    Import(chunk:, reply:) -> process.send(reply, importer.chunk(chunk))
    ImportStatus(session:, op:, reply:) ->
      case importer.stage(session, op) {
        Ok(stage) -> process.send(reply, stage)
        Error(Nil) -> Nil
      }

    // An activation hashes and opens a whole file. It runs apart from the
    // port, so a lookup is not kept waiting behind it.
    Activate(activation:, reply:) ->
      detached(reply, fn(_node) { importer.activate(activation) })

    // The three subagent messages each run apart from the port. A spawn may
    // open a session, a join waits for up to 25 s, and a run end reaches into
    // the session's Agency, which answers when its holder does. The requester's
    // node is the receiver's account of who is asking (`remote_spawn.Origin`),
    // and the host judges it against the spawn policy.
    Spawn(parent:, call_site:, depth:, parent_tools:, request:, reply:) ->
      detached(reply, fn(node) {
        spawns.spawn(
          remote_spawn.Origin(node:, parent:),
          call_site,
          depth,
          parent_tools,
          request,
        )
      })
    Join(parent:, handles:, within_ms:, reply:) ->
      detached(reply, fn(node) {
        spawns.join(remote_spawn.Origin(node:, parent:), handles, within_ms)
      })
    RunEnded(parent:, operation:, reply:) ->
      detached(reply, fn(node) {
        spawns.run_ended(remote_spawn.Origin(node:, parent:), operation)
      })
  }
  actor.continue(state)
}

// The five commands `client/peers` sends to a recipient. Everything else is
// the recipient's own business or a read of its conversation: `Inbox`,
// `History` and `Received` page what the session holds, `Link` and `Unlink`
// edit the sender's own index, `Describe` writes the recipient's own
// self-description, and the `Outbox*` commands belong to the sending session.
// The match names every constructor, so a new command is a compile error here
// until someone decides whether a peer may send it.
fn served(command: peer_mail.Command) -> Bool {
  case command {
    peer_mail.Allow(..)
    | peer_mail.Revoke(..)
    | peer_mail.Deliver(..)
    | peer_mail.SentReceipt(..)
    | peer_mail.Roster(..) -> True

    peer_mail.Link(..)
    | peer_mail.Unlink(..)
    | peer_mail.Links(..)
    | peer_mail.Grants(..)
    | peer_mail.Describe(..)
    | peer_mail.Activity(..)
    | peer_mail.Inbox(..)
    | peer_mail.InboxGet(..)
    | peer_mail.History(..)
    | peer_mail.Received(..)
    | peer_mail.ReceivedGet(..)
    | peer_mail.Overview
    | peer_mail.OutboxClaim(..)
    | peer_mail.OutboxSettle(..)
    | peer_mail.OutboxDue
    | peer_mail.OutboxReceipt(..) -> False
  }
}

// Computes one reply in a run that dies with the requester and with the port.
// The requester is on another node, so its death or disconnection arrives as a
// monitor `DOWN` and cancels the run, as it does for the executor's owner port.
// A run that crashes sends nothing, and the asker's deadline turns that into
// silence. `compute` is handed the requester's node name, which only the
// subagent messages read.
fn detached(reply: Subject(reply), compute: fn(String) -> reply) -> Nil {
  case process.subject_owner(reply) {
    Ok(requester) -> {
      let from = ffi_remote.node_of(requester)
      let _witness =
        weft.new([
          fn() {
            process.send(reply, compute(from))
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

/// Asks the port at `at` what its catalogue says about the session, and waits at
/// most `within_ms` for the answer. The outer `Error(Nil)` is silence, as `ask`
/// defines it; the inner result is the owner's own answer, a description or the
/// text of the reason there is none.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_description(Address(node: peer, name: orchestrator_port.default()), id, 2000)
/// ```
pub fn ask_description(
  at: Address(Message),
  session: String,
  within_ms: Int,
) -> Result(Result(JsonValue, String), Nil) {
  exchange(at, fn(reply) { Describe(session:, reply:) }, within_ms)
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

/// Asks the port at `at` to start a child, and waits at most `within_ms`.
/// `Error(Nil)` is silence, as `ask` defines it: the child may or may not
/// exist, and the same question can be asked again, because the receiver adopts
/// the child the call site already made.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_spawn(Address(node: peer, name: orchestrator_port.default()), parent, call_site, 0, tools, request, 30_000)
/// ```
pub fn ask_spawn(
  at: Address(Message),
  parent: Parent,
  call_site: CallSite,
  depth: Int,
  parent_tools: List(String),
  request: Request,
  within_ms: Int,
) -> Result(Result(Spawned, SpawnRefusal), Nil) {
  exchange(
    at,
    fn(reply) {
      Spawn(parent:, call_site:, depth:, parent_tools:, request:, reply:)
    },
    within_ms,
  )
}

/// Asks the port at `at` to report on children, and waits at most `within_ms`
/// for the answer, which the caller sets above the window it asks the receiver
/// to wait. Silence is `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_join(Address(node: peer, name: orchestrator_port.default()), parent, handles, 25_000, 27_000)
/// ```
pub fn ask_join(
  at: Address(Message),
  parent: Parent,
  handles: List(Handle),
  window_ms: Int,
  within_ms: Int,
) -> Result(Result(List(Joined), SpawnRefusal), Nil) {
  exchange(
    at,
    fn(reply) { Join(parent:, handles:, within_ms: window_ms, reply:) },
    within_ms,
  )
}

/// Tells the port at `at` that a run ended, and waits at most `within_ms` for
/// the count of children it stopped. Silence is `Error(Nil)`, and the same
/// message can be sent again.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_run_ended(Address(node: peer, name: orchestrator_port.default()), parent, operation, 7000)
/// ```
pub fn ask_run_ended(
  at: Address(Message),
  parent: Parent,
  operation: OpId,
  within_ms: Int,
) -> Result(Result(Int, SpawnRefusal), Nil) {
  exchange(at, fn(reply) { RunEnded(parent:, operation:, reply:) }, within_ms)
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
