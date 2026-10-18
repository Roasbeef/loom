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
//// pinned peer and asks through `ask_spawn` and `ask_join` below, and fills the
//// record the parent's Agency asks through (`client/remote_reach`).
////
//// In phase 1 nothing on the parent's side sends `RunEnded`, because a child
//// started from another orchestrator is always detached and outlives the run
//// that asked for it. The message, its handler and the fence that makes a late
//// `Spawn` for an ended run refuse stay as built, and `ask_run_ended` is the
//// call a phase that stops children by run would make.
////
//// Phase 2 adds `Release`, which says the parent session itself was deleted. It
//// is not a `RunEnded` for every run: the receiver stops every child of the
//// pair, whoever owns it, deletes the pair's session, and answers how many
//// children it stopped. A pair the receiver has no session for answers zero and
//// creates nothing, so the message is safe to send to an orchestrator that never
//// held a child, and safe to send twice. `ask_release` is the call.
////
//// Phase 2 of protocol-change/086 adds `Holds`, a read of how many sessions the
//// catalogue owns and how many sit on each executor. An operator's `revoke`
//// asks it before it signs, so that removing a member does not strand sessions
//// unannounced. It runs apart from the port, as a spawn does, because it walks
//// the catalogue.
////
//// Protocol-change/085 adds `Report`, which answers what the daemon says about
//// itself: its build, its uptime, and the executor, orchestrator and directory
//// facts it has (`client/node_report`). The facts come from the daemon through
//// `Reads`, as `Holds` comes through its `Holder`, and the port starts with
//// `unreported` where a daemon has none to give. A report is built where the
//// facts are, so it runs apart from the port, as `Holds` does. `Holds` is the
//// subset of a report that `revoke` needed before the report existed.
////
//// Phase 2 of protocol-change/084 adds `ChildSend`, a message from the parent
//// into a child on this orchestrator, served through the same `SpawnHost`, and
//// the first messages that run in the other direction. A child on this
//// orchestrator can mail its parent (`ChildMail`) and report what it is doing
//// (`ChildProgress`) to the parent's orchestrator, and the receiving port serves
//// them through a `ChildHost`, which a daemon with no `[orchestrators]` starts as
//// `refusing_children`. The three run apart from the port, and each is judged
//// by the node it came from: the host refuses a message whose node is not the
//// configured node of the orchestrator the parent's stub names. They are
//// idempotent by the keys their constructors document, so the box can resend
//// them until it is answered. `client/remote_mail` is their vocabulary, and the
//// sending ends are `ask_mail` and `ask_progress` below.
////
//// Protocol-change/089 adds the two messages by which the operator of a
//// spawning orchestrator answers a child's request for more authority. A child
//// on this orchestrator that its sandbox refuses can ask its parent's operator
//// (`ChildEscalation`, served by the `ChildHost` like mail and progress), and the
//// operator's decision comes back as `Resolve`, served by the `SpawnHost` like a
//// send into a child. Both are judged by the node they came from, and neither
//// changes what the other messages do. The sending ends are `ask_escalation` and
//// `ask_resolve`.
////
//// The port reveals whether an identity is in this daemon's catalogue, and for
//// `Holds` two counts of sessions, to a peer the operator pinned as a trusted
//// Erlang node. It carries no credential, and a client is never redirected by
//// it: the asking daemon decides what its own client is told.
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
////
//// ## Flow
////
//// `start_with` → `answer` → `detached` → `ask_release` → `ask_send` →
//// `ask_mail` → `ask_escalation` → `ask_resolve` → `exchange` → `exchange_why`
////
//// 1. `start_with` starts the port with the hosts a daemon supplies.
//// 2. `answer` handles one message. A read it can answer from a function it
////    holds is answered in place.
//// 3. `detached` runs the slow ones (a spawn, a join, a run end, a release, a
////    send, a child's mail or progress) in a task linked to the port, so a
////    question about ownership never waits behind them.
//// 4. The `ask_*` functions are the sending ends, `ask_release`, `ask_send` and
////    `ask_resolve` among those the laptop calls and `ask_mail` and
////    `ask_escalation` among those the box calls, and
////    each makes its one request through `exchange`, which wraps
////    `exchange_why`. That function takes a monitor before it sends, and
////    `ask_report` uses it directly to learn why there was no answer.

import client/internal/ffi_remote
import client/node_report.{type NodeReport}
import client/peer_mail
import client/protocol.{type EscalationRecord}
import client/remote/address.{type Address}
import client/remote_escalation.{type Answer, type Decider, type Decision}
import client/remote_mail.{type ChildRefusal, type Receipt}
import client/remote_spawn.{
  type CallSite, type Joined, type Origin, type Parent, type Request,
  type SpawnRefusal, type Spawned,
}
import client/session_move.{
  type Activation, type Chunk, type Stage, type Verdict,
}
import core/glance.{type Glance}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Name, type Subject}
import gleam/result
import host/build_identity
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

  /// Tells the receiver that the parent session was deleted, so it stops every
  /// child it holds for that parent and deletes the session that held them. The
  /// answer is how many children it stopped. A parent the receiver holds nothing
  /// for answers zero and creates nothing, and a repeat stops nothing more.
  ///
  /// It may reach the receiver before the `Spawn` it concerns, because the two
  /// come from different processes. The receiver then has no session to delete,
  /// and the `Spawn` that follows makes one, which the parent's own deletion
  /// bounds by the child's deadline and the receiver's retention sweep.
  Release(
    /// The parent session and strand. Only the session names what is released.
    parent: Parent,
    /// Where the count goes.
    reply: Subject(Result(Int, SpawnRefusal)),
  )

  /// Delivers a message from the parent into a child that runs on this
  /// orchestrator (protocol-change/084, phase 2). The answer is how the message
  /// landed (`remote_mail.encode_landing`), or the reason the host refused it.
  /// The message id is the sending call site's digest, and the host stores a
  /// receipt under it, so a repeat is answered from the receipt and delivers
  /// nothing twice. A child with no run open starts a detached run, bounded by
  /// the deadline the child already has.
  ///
  /// Like every message of the parent it may arrive before the `Spawn` it
  /// concerns, because the two come from different processes. A child that does
  /// not exist yet is a refusal, never a message the host holds.
  ChildSend(
    /// The parent session and strand, on the sending orchestrator.
    parent: Parent,
    /// The child, as `Spawned` returned it.
    child: Handle,
    /// The message's identity, which keys the receipt.
    message_id: String,
    /// What the parent says.
    text: String,
    /// Where the landing goes.
    reply: Subject(Result(JsonValue, SpawnRefusal)),
  )

  /// Mail from a child that runs on the sending orchestrator to its parent on
  /// this one (protocol-change/084, phase 2). The answer is a final `Receipt`,
  /// or a `ChildRefusal` of which only `ParentSessionNotOpen` is worth asking
  /// again. The message id is the child's call-site digest on the sender, and the
  /// receiver stores a receipt under it, so a resend is answered from the
  /// receipt and steers the parent once.
  ///
  /// The child is named by the strand name the sender gave it, and the receiver
  /// finds the parent's stub by that name, never by the handle: the mail may
  /// arrive before the answer to the `Spawn` that made the child, when the stub
  /// is still `Requested` and has no handle.
  ChildMail(
    /// The parent session and strand, on this orchestrator.
    parent: Parent,
    /// The child that sent it. Only its strand is read.
    child: Handle,
    /// The message's identity, which keys the receipt.
    message_id: String,
    /// What the child says.
    text: String,
    /// Where the receipt goes.
    reply: Subject(Result(Receipt, ChildRefusal)),
  )

  /// A glance at what a child that runs on the sending orchestrator is doing
  /// (protocol-change/084, phase 2). The receiver keeps the newest on the
  /// parent's stub for that child and ignores one that is not newer, so a resend
  /// is harmless and the order messages arrive in does not matter. It is
  /// answered like mail, with `Ok(Nil)` once the stub holds the glance or a newer
  /// one.
  ChildProgress(
    /// The parent session and strand, on this orchestrator.
    parent: Parent,
    /// The child the glance describes. Only its strand is read.
    child: Handle,
    /// What it is doing.
    glance: Glance,
    /// Where the answer goes.
    reply: Subject(Result(Nil, ChildRefusal)),
  )

  /// A request for more authority from a child that runs on the sending
  /// orchestrator, for its parent on this one (protocol-change/089). The record
  /// is the sender's, at the `seq` it carries. The receiver keeps the newest it
  /// has heard of for each `(escalation_id, seq)` and draws it for the parent's
  /// operator, and a record that is no longer pending clears the card. The
  /// answer is `Ok(Nil)` once the receiver holds that record or a newer one.
  ///
  /// The child is named by its strand, and the receiver finds the parent's stub
  /// by that name as it does for `ChildMail`, so the message may arrive before
  /// the answer to the `Spawn` that made the child.
  ChildEscalation(
    /// The parent session and strand, on this orchestrator.
    parent: Parent,
    /// The child that asked. Only its strand is read.
    child: Handle,
    /// The question, in the protocol's own vocabulary, with the grants the
    /// sender's approval ceiling admits.
    record: EscalationRecord,
    /// Where the answer goes.
    reply: Subject(Result(Nil, ChildRefusal)),
  )

  /// The parent's operator answering a child's request that runs on this
  /// orchestrator (protocol-change/089). The answer says whether the decision
  /// committed, or why not, with the record as it now is when the question has
  /// moved. It may arrive before the sender's `ChildEscalation` is acknowledged,
  /// and the receiver judges it against its own record alone.
  Resolve(
    /// The parent session and strand, on the sending orchestrator.
    parent: Parent,
    /// The child that asked.
    child: Handle,
    /// The record's identity on this orchestrator.
    escalation_id: String,
    /// What the operator decided.
    decision: Decision,
    /// The `seq` of the question the operator was shown.
    expected_seq: Int,
    /// Who decided, as text, for provenance.
    decided_by: Decider,
    /// Where the answer goes.
    reply: Subject(Result(Answer, SpawnRefusal)),
  )

  /// What this daemon holds that a revoke of it, or of an executor it places
  /// sessions on, would strand (protocol-change/086, phase 2): how many
  /// sessions its catalogue owns, and how many of them are placed on each
  /// executor. The operator's tool asks it before it signs a `revoke`. The
  /// answer is `Error(Nil)` when the catalogue could not be read, which the
  /// asker must not mistake for "none".
  ///
  /// This is the subset of protocol-change/085's `Report` that the check
  /// needs (`OrchestratorFacts.occupied` and `placements`), built before the
  /// rest of the report so that the check does not wait for it. A port built
  /// before this constructor existed has no clause for it and stops, as for
  /// `Describe`, so this port assumes peers of the same build.
  Holds(
    /// Where the answer goes.
    reply: Subject(Result(Held, Nil)),
  )

  /// What this daemon says about itself (protocol-change/085): its build and
  /// uptime, and the executor, orchestrator and directory facts it has. The
  /// answer is always a report; a daemon with none of those facts says only who
  /// it is. A port built before this constructor existed has no clause for it
  /// and stops, as for `Holds`, so this port assumes peers of the same build.
  Report(
    /// Where the report goes.
    reply: Subject(NodeReport),
  )
}

/// What the daemon supplies for the questions the port cannot answer from its
/// own state. The port neither reads a ledger nor walks a catalogue; the daemon
/// does, and hands the port the function.
pub type Reads {
  Reads(
    /// Builds this daemon's report. It runs in a task of its own, linked to the
    /// port and cancelled with the requester (`detached`), so it may ask the
    /// executor host, the movers and the catalogue, each of which has its own
    /// deadline.
    report: fn() -> NodeReport,
  )
}

/// The reads of a daemon with nothing to report beyond who it is: its node, its
/// build, and no orchestrator, executor or directory facts. The clocks are
/// zero, since a daemon that reports nothing has no start to measure from.
///
/// ## Examples
///
/// ```gleam
/// let report = orchestrator_port.unreported().report()
/// assert report.executor == option.None
/// ```
pub fn unreported() -> Reads {
  Reads(report: fn() {
    let identity = build_identity.current()
    node_report.bare(
      node: atom.to_string(node.name(node.self())),
      build_version: identity.version,
      build_commit: identity.commit,
      epoch: "",
      started_ms: 0,
      now_ms: 0,
    )
  })
}

/// What a daemon's catalogue holds, as `Holds` answers it.
pub type Held {
  Held(
    /// The sessions this daemon owns: every active registration whose custody
    /// is not `Moved`. A session handed to another orchestrator is that
    /// orchestrator's now, and archived sessions are not counted.
    sessions: Int,
    /// How many of them are placed on each executor, by the executor's node,
    /// for the executors this daemon lists. At most `max_placed` entries,
    /// ordered by node.
    placed: List(Placed),
  )
}

/// The sessions placed on one executor.
pub type Placed {
  Placed(
    /// The executor's full node name.
    executor_node: String,
    /// The sessions placed on it.
    sessions: Int,
  )
}

/// The most executors a `Held` lists.
pub const max_placed = 64

/// Reads what the daemon's catalogue holds. The daemon supplies it, so the port
/// does not know the catalogue.
pub type Holder =
  fn() -> Result(Held, Nil)

/// The holder of a port started without a catalogue: it cannot tell.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrator_port.unheld() == Error(Nil)
/// ```
pub fn unheld() -> Result(Held, Nil) {
  Error(Nil)
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
    /// Stops every child of the parent and deletes the session that held them,
    /// and counts the children it stopped. A parent with no session answers
    /// zero.
    release: fn(Origin) -> Result(Int, SpawnRefusal),
    /// Delivers a message into a child, given the child, the message's identity
    /// and its text, and answers how it landed. A repeat of an identity answers
    /// from the receipt.
    send: fn(Origin, Handle, String, String) -> Result(JsonValue, SpawnRefusal),
    /// Applies the parent's operator's decision to a child's request, given the
    /// child, the record's identity here, the decision, the `seq` the operator
    /// was shown and who decided (protocol-change/089).
    resolve: fn(Origin, Handle, String, Decision, Int, Decider) ->
      Result(Answer, SpawnRefusal),
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
    release: fn(origin) {
      Error(remote_spawn.UnknownSpawner(node: origin.node))
    },
    send: fn(origin, _child, _message_id, _text) {
      Error(remote_spawn.UnknownSpawner(node: origin.node))
    },
    resolve: fn(origin, _child, _id, _decision, _seq, _decider) {
      Error(remote_spawn.UnknownSpawner(node: origin.node))
    },
  )
}

/// What a daemon does with what a child on another orchestrator sends its
/// parent here (protocol-change/084, phase 2): find the parent session, check
/// that the message came from the orchestrator that runs the child, and admit it.
/// The daemon supplies the functions, so the port neither reads the roster nor
/// opens a session.
///
/// Each function runs in a task of its own, linked to the port and cancelled
/// with the requester (`detached`). Each answers `Error` with the refusal when it
/// declines, and a function that crashes sends nothing.
pub type ChildHost {
  ChildHost(
    /// Admits a child's mail into the parent, given the child and the message's
    /// identity and text, and answers the receipt.
    mail: fn(Origin, Handle, String, String) -> Result(Receipt, ChildRefusal),
    /// Keeps a child's glance on the parent's stub for it.
    progress: fn(Origin, Handle, Glance) -> Result(Nil, ChildRefusal),
    /// Keeps a child's request for more authority for the parent's operator to
    /// answer, given the child and the record (protocol-change/089).
    escalation: fn(Origin, Handle, EscalationRecord) ->
      Result(Nil, ChildRefusal),
  )
}

/// The host of a daemon that lists no `[orchestrators]`: no orchestrator runs
/// children for it, so every message is refused as coming from the wrong place,
/// `OriginMismatch`, which is definitive.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.refusing_children().mail(origin, child, "id", "hello")
/// // -> Error(remote_mail.OriginMismatch)
/// ```
pub fn refusing_children() -> ChildHost {
  ChildHost(
    mail: fn(_origin, _child, _message_id, _text) {
      Error(remote_mail.OriginMismatch)
    },
    progress: fn(_origin, _child, _glance) { Error(remote_mail.OriginMismatch) },
    escalation: fn(_origin, _child, _record) {
      Error(remote_mail.OriginMismatch)
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
    refusing_children(),
    unheld,
    unreported(),
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
    refusing_children(),
    unheld,
    unreported(),
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
    refusing_children(),
    unheld,
    unreported(),
  )
}

/// Starts the port serving peer commands (phase 4), descriptions of the
/// sessions it holds, session moves (phase 5), subagent spawns (phase 6) and
/// the mail and progress of children that run elsewhere, which is what the
/// production daemon runs. `start`, `start_serving` and
/// `start_importing` are this with the other parts refused.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_) = orchestrator_port.start_with(orchestrator_port.default(), held, forward, describe, importer, spawns, children, holds, reads)
/// ```
pub fn start_with(
  name: Name(Message),
  held: fn(String) -> Result(Ownership, Nil),
  peer: PeerHandler,
  describe: Describer,
  importer: Importer,
  spawns: SpawnHost,
  children: ChildHost,
  holds: Holder,
  reads: Reads,
) -> actor.StartResult(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) {
    answer(
      held,
      peer,
      describe,
      importer,
      spawns,
      children,
      holds,
      reads,
      state,
      message,
    )
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
  children: ChildHost,
  holds: Holder,
  reads: Reads,
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

    // The holdings walk the catalogue a page at a time, which takes as long as
    // the catalogue is large. It runs apart from the port, as an activation
    // does, so a question about ownership is not kept waiting behind it.
    Holds(reply:) -> detached(reply, fn(_node) { holds() })

    // A report asks the executor host, the movers and the catalogue, each of
    // which may be busy, so it runs apart from the port for the same reason.
    Report(reply:) -> detached(reply, fn(_node) { reads.report() })

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
    Release(parent:, reply:) ->
      detached(reply, fn(node) {
        spawns.release(remote_spawn.Origin(node:, parent:))
      })

    // A send into a child reaches into the delegate session's Agency, which
    // answers when its holder does, so it runs apart from the port like the
    // other subagent messages. The sender's node is judged against the spawn
    // policy by the host.
    ChildSend(parent:, child:, message_id:, text:, reply:) ->
      detached(reply, fn(node) {
        spawns.send(
          remote_spawn.Origin(node:, parent:),
          child,
          message_id,
          text,
        )
      })

    // A child's mail and progress reach into a parent session's Agency, which
    // may be opening or busy, so they run apart from the port as well. The host
    // checks that the sender's node is the node of the orchestrator the parent's
    // stub names, and answers `OriginMismatch` if it is not.
    ChildMail(parent:, child:, message_id:, text:, reply:) ->
      detached(reply, fn(node) {
        children.mail(
          remote_spawn.Origin(node:, parent:),
          child,
          message_id,
          text,
        )
      })
    ChildProgress(parent:, child:, glance:, reply:) ->
      detached(reply, fn(node) {
        children.progress(remote_spawn.Origin(node:, parent:), child, glance)
      })
    ChildEscalation(parent:, child:, record:, reply:) ->
      detached(reply, fn(node) {
        children.escalation(remote_spawn.Origin(node:, parent:), child, record)
      })

    // A decision reaches into the delegate session's gateway, which commits on
    // the session's one writer, so it runs apart from the port like the other
    // messages that reach into a session.
    Resolve(
      parent:,
      child:,
      escalation_id:,
      decision:,
      expected_seq:,
      decided_by:,
      reply:,
    ) ->
      detached(reply, fn(node) {
        spawns.resolve(
          remote_spawn.Origin(node:, parent:),
          child,
          escalation_id,
          decision,
          expected_seq,
          decided_by,
        )
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

/// Asks the port at `at` what its catalogue holds, and waits at most
/// `within_ms`. `Error(Nil)` means the daemon did not say: the node is
/// unreachable, no port is registered there, the answer was late, or the
/// catalogue could not be read. It is never "nothing held".
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_holds(Address(node: peer, name: orchestrator_port.default()), 5000)
/// ```
pub fn ask_holds(at: Address(Message), within_ms: Int) -> Result(Held, Nil) {
  case exchange(at, fn(reply) { Holds(reply:) }, within_ms) {
    Ok(Ok(held)) -> Ok(held)
    Ok(Error(Nil)) | Error(Nil) -> Error(Nil)
  }
}

/// Why a port did not answer.
pub type Silence {
  /// The monitor fired at once: no port is registered there, the node is gone,
  /// or the port ended.
  PortGone

  /// The wait ran out with the port still there.
  AskTimedOut
}

/// Asks the port at `at` what the daemon says about itself, and waits at most
/// `within_ms`. `Error` means the daemon did not say, and why: the port is gone
/// or the report was late. A report that arrives is the daemon's own account, and
/// its absence is never read as "nothing to report".
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_report(Address(node: peer, name: orchestrator_port.default()), 2500)
/// ```
pub fn ask_report(
  at: Address(Message),
  within_ms: Int,
) -> Result(NodeReport, Silence) {
  exchange_why(at, fn(reply) { Report(reply:) }, within_ms)
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

/// Tells the port at `at` that a parent session was deleted, and waits at most
/// `within_ms` for the count of children it stopped. Silence is `Error(Nil)`,
/// and the same message can be sent again.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_release(Address(node: peer, name: orchestrator_port.default()), parent, 7000)
/// ```
pub fn ask_release(
  at: Address(Message),
  parent: Parent,
  within_ms: Int,
) -> Result(Result(Int, SpawnRefusal), Nil) {
  exchange(at, fn(reply) { Release(parent:, reply:) }, within_ms)
}

/// Delivers a message into a child on the port at `at`, and waits at most
/// `within_ms` for how it landed. Silence is `Error(Nil)`, and the same message
/// can be sent again: the receiver stores a receipt under the message id.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_send(Address(node: peer, name: orchestrator_port.default()), parent, child, id, "hello", 15_000)
/// ```
pub fn ask_send(
  at: Address(Message),
  parent: Parent,
  child: Handle,
  message_id: String,
  text: String,
  within_ms: Int,
) -> Result(Result(JsonValue, SpawnRefusal), Nil) {
  exchange(
    at,
    fn(reply) { ChildSend(parent:, child:, message_id:, text:, reply:) },
    within_ms,
  )
}

/// Mails a parent on the port at `at` from a child on this orchestrator, and
/// waits at most `within_ms` for the receipt. Silence is `Error(Nil)`, and the
/// same mail can be sent again: the receiver stores a receipt under the message
/// id.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_mail(Address(node: laptop, name: orchestrator_port.default()), parent, child, id, "done", 15_000)
/// ```
pub fn ask_mail(
  at: Address(Message),
  parent: Parent,
  child: Handle,
  message_id: String,
  text: String,
  within_ms: Int,
) -> Result(Result(Receipt, ChildRefusal), Nil) {
  exchange(
    at,
    fn(reply) { ChildMail(parent:, child:, message_id:, text:, reply:) },
    within_ms,
  )
}

/// Pushes a child's glance to the port at `at`, and waits at most `within_ms`
/// for the answer. Silence is `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_progress(Address(node: laptop, name: orchestrator_port.default()), parent, child, glance, 15_000)
/// ```
pub fn ask_progress(
  at: Address(Message),
  parent: Parent,
  child: Handle,
  glance: Glance,
  within_ms: Int,
) -> Result(Result(Nil, ChildRefusal), Nil) {
  exchange(
    at,
    fn(reply) { ChildProgress(parent:, child:, glance:, reply:) },
    within_ms,
  )
}

/// Pushes a child's request for more authority to the port at `at`, and waits
/// at most `within_ms` for the answer. Silence is `Error(Nil)`, and the same
/// record can be sent again: the receiver keeps the newest `seq` it has heard of.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_escalation(Address(node: laptop, name: orchestrator_port.default()), parent, child, record, 15_000)
/// ```
pub fn ask_escalation(
  at: Address(Message),
  parent: Parent,
  child: Handle,
  record: EscalationRecord,
  within_ms: Int,
) -> Result(Result(Nil, ChildRefusal), Nil) {
  exchange(
    at,
    fn(reply) { ChildEscalation(parent:, child:, record:, reply:) },
    within_ms,
  )
}

/// Sends the parent's operator's decision to the port at `at`, and waits at most
/// `within_ms` for the answer. Silence is `Error(Nil)`; the decision may or may
/// not have committed, and asking again is safe because the receiver judges
/// the `seq` the operator was shown.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.ask_resolve(Address(node: box, name: orchestrator_port.default()), parent, child, id, decision, 3, decider, 5000)
/// ```
pub fn ask_resolve(
  at: Address(Message),
  parent: Parent,
  child: Handle,
  escalation_id: String,
  decision: Decision,
  expected_seq: Int,
  decided_by: Decider,
  within_ms: Int,
) -> Result(Result(Answer, SpawnRefusal), Nil) {
  exchange(
    at,
    fn(reply) {
      Resolve(
        parent:,
        child:,
        escalation_id:,
        decision:,
        expected_seq:,
        decided_by:,
        reply:,
      )
    },
    within_ms,
  )
}

// One request and its reply. Silence is `Error(Nil)`.
fn exchange(
  at: Address(Message),
  request: fn(Subject(answer)) -> Message,
  within_ms: Int,
) -> Result(answer, Nil) {
  exchange_why(at, request, within_ms) |> result.replace_error(Nil)
}

// One request and its reply, with the reason when there is none. The monitor is
// taken before the request is sent, so a node that is already gone ends the wait
// at once with its `DOWN` (`PortGone`: nothing is registered there, or the port
// ended) and not with the deadline (`AskTimedOut`).
fn exchange_why(
  at: Address(Message),
  request: fn(Subject(answer)) -> Message,
  within_ms: Int,
) -> Result(answer, Silence) {
  let reply = process.new_subject()
  let watch = address.watch(at)
  address.deliver(at, request(reply))
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(PortGone) })
    |> process.selector_receive(within_ms)

  // Demonitoring flushes a `DOWN` that arrived beside the reply.
  process.demonitor_process(watch)
  case heard {
    Ok(answered) -> answered
    Error(Nil) -> Error(AskTimedOut)
  }
}
