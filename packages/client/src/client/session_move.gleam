//// The vocabulary of one session move between two orchestrators
//// (protocol-change/078, phase 5).
////
//// A session is created on, and owned by, one orchestrator, and the owner can
//// hand it to another. Both ends and the messages between them need the same
//// few words, so this module holds them and nothing else: the six steps the
//// source takes, the manifest that rides beside the copied file, the chunks the
//// file travels in, the questions the receiver answers, and the names of the
//// files each side keeps. It performs no I/O and starts no process, which is why
//// the source's driver (`client/session_mover`), the receiver
//// (`client/session_importer`) and the orchestrator port that carries the
//// messages (`client/remote/orchestrator_port`) can all import it without
//// importing one another.
////
//// ## The six steps
////
//// The source drives a move through six steps, and each is durable before the
//// next begins, so a restart resumes from what is on disk and never from a
//// memory of where it was.
////
//// | Step | Durable afterward |
//// | --- | --- |
//// | `Intent` | the source's row is `moving`, and its slot is stopped |
//// | `Close` | the file's scope cell reads a clean close |
//// | `Cut` | a copy of the closed file, with its digest, beside the original |
//// | `Send` | the whole copy waits on the receiver |
//// | `Activate` | the receiver's row is `imported` and its file is in place |
//// | `Retire` | the source's row is `moved` and its file is set aside |
////
//// ## What crosses the wire
////
//// The copy is sent in `Chunk`s, each acknowledged before the next, and checked
//// as a whole by the digest the source took when it cut the file. There is no
//// resume inside a file: any failure sends the whole file again. The receiver
//// answers `Stage` to say how far it has got, and `Verdict` to say whether it
//// took a chunk or activated the session. A `Refused` verdict is definitive,
//// because the receiver looked and said no, while `Failed` and silence are not:
//// the source tries again, and an unreachable receiver never lets a move
//// abort.

import gleam/option.{type Option}
import gleam/string
import storage/catalogue

/// The largest piece of the copy sent in one message, in bytes. A message is
/// acknowledged before the next is sent, so this bounds what one lost message
/// costs and keeps the distribution link's other traffic moving between pieces.
pub const chunk_bytes = 262_144

/// The largest session file a move will carry, in bytes. The source reads the
/// whole copy into memory to hash it and to cut it into chunks, and the
/// receiver refuses to start a file that declares more, so a conversation larger
/// than this is refused before anything is sent.
pub const size_limit = 268_435_456

/// The six steps of a move, in the order the source takes them.
pub type Step {
  /// The source recorded `moving(op, to)` and stopped the session's slot.
  Intent

  /// The session's scope on the executor ended in a clean close, and the file
  /// says so.
  Close

  /// A copy of the closed file was cut and hashed.
  Cut

  /// The receiver holds the whole copy.
  Send

  /// The receiver recorded `imported(op, from)` and put the file in place.
  Activate

  /// The source recorded `moved(to)`, released its lease and set the file aside.
  Retire
}

/// The word a step is called in logs and in `LOOM_MOVE_CRASH_AFTER`.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.step_name(session_move.Cut) == "cut"
/// ```
pub fn step_name(step: Step) -> String {
  case step {
    Intent -> "intent"
    Close -> "close"
    Cut -> "cut"
    Send -> "send"
    Activate -> "activate"
    Retire -> "retire"
  }
}

/// The step a word names, for the test-only crash knob.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.parse_step("send") == Ok(session_move.Send)
/// assert session_move.parse_step("seven") == Error(Nil)
/// ```
pub fn parse_step(text: String) -> Result(Step, Nil) {
  case text {
    "intent" -> Ok(Intent)
    "close" -> Ok(Close)
    "cut" -> Ok(Cut)
    "send" -> Ok(Send)
    "activate" -> Ok(Activate)
    "retire" -> Ok(Retire)
    _ -> Error(Nil)
  }
}

/// What the receiver needs to register a session beside its file. It is the
/// source's registration without what is the source's own: the identity travels
/// separately, the database path is the receiver's to choose, and a
/// configuration path names a file on the source's machine, so it is dropped and
/// the receiver uses its own default.
pub type Manifest {
  Manifest(
    /// The workspace's registered name on the executor.
    workspace: String,
    /// The session's display name as the source showed it.
    name: String,
    /// The model profile the session was created under, or `None`.
    profile: Option(String),
    /// The `[models.<key>]` the session's main role was pinned to at creation,
    /// or `None`. It is part of the creation request like the profile, so a
    /// session that moves keeps the choice its owner made
    /// (protocol-change/080).
    model: Option(String),
    /// The `[executors.<name>]` that holds the session's scope.
    executor: String,
    /// The `[pools.<name>]` the session was created in, or the empty string.
    pool: String,
    /// The first-prompt subtitle the source showed, or `None`.
    subtitle: Option(String),
    /// When the session was created, in Unix milliseconds.
    created_at: Int,
  )
}

/// The manifest of a registration.
///
/// ## Examples
///
/// ```gleam
/// // session_move.manifest_of(registration).executor == registration.executor
/// ```
pub fn manifest_of(registration: catalogue.Registration) -> Manifest {
  Manifest(
    workspace: registration.workspace,
    name: registration.name,
    profile: registration.profile,
    model: registration.model,
    executor: registration.executor,
    pool: registration.pool,
    subtitle: registration.subtitle,
    created_at: registration.created_at,
  )
}

/// One piece of the copy, with enough to place it without any other state.
pub type Chunk {
  Chunk(
    /// The session's canonical identity.
    session: String,
    /// The move's identity.
    op: String,
    /// Where in the file the piece starts. The first piece is at zero, which
    /// begins the file afresh whatever was received before.
    offset: Int,
    /// The size of the whole file, declared with every piece.
    total: Int,
    /// The piece itself.
    bytes: BitArray,
  )
}

/// The request to make the copy the receiver holds into the session.
pub type Activation {
  Activation(
    /// The session's canonical identity.
    session: String,
    /// The move's identity.
    op: String,
    /// The name of the node the session comes from, which the receiver matches
    /// to one of its own `[orchestrators.<name>]` rows.
    from_node: String,
    /// The SHA-256 of the whole copy, in lowercase hexadecimal.
    digest: String,
    /// The incarnation of the session's scope that the copy's cell says closed
    /// cleanly. The receiver checks the cell says so too.
    incarnation: Int,
    /// What to register the session as.
    manifest: Manifest,
  )
}

/// How far the receiver has got with one move.
pub type Stage {
  /// It holds no complete copy for this move.
  Absent

  /// It holds the whole copy and has not activated the session.
  Received

  /// It recorded the import and put the file in place.
  Activated
}

/// Why the receiver said no. Every one is about what the receiver found, so the
/// source can treat the answer as final.
pub type Refusal {
  /// The declared size is more than a move carries, or the file is empty.
  BadSize(limit: Int)

  /// A piece did not start where the file stood, so the source starts again
  /// from the beginning.
  OutOfOrder(expected: Int)

  /// The copy's SHA-256 is not the one the source took.
  DigestMismatch

  /// No complete copy waits for this move.
  NothingReceived

  /// The copy's scope cell does not read a clean close at the claimed
  /// incarnation, or cannot be read.
  NotClosed(reason: String)

  /// This orchestrator has no `[executors.<name>]` for the session's executor,
  /// so it could not attach to the scope.
  NoExecutor(name: String)

  /// The node that sent this is not one of this orchestrator's
  /// `[orchestrators.<name>]`.
  UnknownSource(node: String)

  /// This catalogue already holds the session in a state that forbids the
  /// import, such as moving it elsewhere or holding it under another move.
  Conflict

  /// The request is malformed: an identity or an operation outside its grammar.
  Malformed(reason: String)

  /// This daemon does not accept sessions from other orchestrators.
  NotImporting

  /// On a directory member (protocol-change/080): the owner record no longer
  /// says the sender is moving the session to this receiver, and does not name
  /// the receiver as owner, so the move ended without it. The source reads the
  /// record before it does anything else.
  MoveEnded
}

/// The receiver's answer to a chunk or an activation.
pub type Verdict {
  /// The chunk was written, or the session is activated.
  Accepted

  /// The receiver looked and said no.
  Refused(refusal: Refusal)

  /// The receiver could not decide, for a reason that may pass. The source
  /// tries again.
  Failed(reason: String)
}

/// A refusal in words, for a log line and for the reason an aborted move
/// reports.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.describe(session_move.DigestMismatch)
///   == "the received copy does not match the digest"
/// ```
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    BadSize(limit:) ->
      "the file is empty or larger than the "
      <> string.inspect(limit)
      <> " bytes a move carries"
    OutOfOrder(expected:) ->
      "a piece did not start at offset " <> string.inspect(expected)
    DigestMismatch -> "the received copy does not match the digest"
    NothingReceived -> "no complete copy was received for this move"
    NotClosed(reason:) -> "the copy is not cleanly closed: " <> reason
    NoExecutor(name:) -> "this orchestrator has no executor named " <> name
    UnknownSource(node:) ->
      "this orchestrator does not list the node "
      <> node
      <> " as an orchestrator"
    Conflict -> "this orchestrator already holds the session in another state"
    Malformed(reason:) -> "the request is malformed: " <> reason
    NotImporting -> "this orchestrator does not accept moved sessions"
    MoveEnded ->
      "the directory record shows the move ended without this orchestrator"
  }
}

// --- the files each side keeps -----------------------------------------------

/// The writer-lease owner a move holds on the source file while it cuts and
/// sends. It names the move, so only the move's own earlier run can reclaim it.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.lease_owner("op1") == "move:op1"
/// ```
pub fn lease_owner(op: String) -> String {
  "move:" <> op
}

/// The writer-lease owner of a short read of a closed file's scope cell.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.reader_owner("op1") == "move-read:op1"
/// ```
pub fn reader_owner(op: String) -> String {
  "move-read:" <> op
}

/// Where the source puts its cut of the session file: beside the original, so
/// both are on one filesystem and one directory listing explains them.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.copy_path("/s/a.db", "op1") == "/s/a.db.move.op1"
/// ```
pub fn copy_path(path: String, op: String) -> String {
  path <> ".move." <> op
}

/// Where the source sets its original aside once the move finished.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.moved_path("/s/a.db") == "/s/a.db.moved"
/// ```
pub fn moved_path(path: String) -> String {
  path <> ".moved"
}

/// The directory a receiver keeps pieces and finished copies in, below its state
/// root.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.incoming_directory("/state") == "/state/incoming"
/// ```
pub fn incoming_directory(state_root: String) -> String {
  state_root <> "/incoming"
}

/// Where a complete copy of the session waits for activation.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.incoming_path("/state", "s1", "op1")
///   == "/state/incoming/s1.op1"
/// ```
pub fn incoming_path(
  state_root: String,
  session: String,
  op: String,
) -> String {
  incoming_directory(state_root) <> "/" <> session <> "." <> op
}

/// Where the pieces of a copy are written until the last one arrives, so that a
/// name that exists as a complete copy is always whole.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.part_path("/state", "s1", "op1")
///   == "/state/incoming/s1.op1.part"
/// ```
pub fn part_path(state_root: String, session: String, op: String) -> String {
  incoming_path(state_root, session, op) <> ".part"
}

/// The scratch copy of a received copy that the receiver opens to read its scope
/// cell, so the bytes whose digest it checked are never the bytes it opened.
///
/// ## Examples
///
/// ```gleam
/// assert session_move.check_path("/state", "s1", "op1")
///   == "/state/incoming/s1.op1.check"
/// ```
pub fn check_path(state_root: String, session: String, op: String) -> String {
  incoming_path(state_root, session, op) <> ".check"
}
