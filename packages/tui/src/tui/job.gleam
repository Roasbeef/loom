//// The terminal's background jobs, described as data.
////
//// A daemon control request, the relaunch after an unexpected daemon death,
//// the session picker's activity poll and the provisional attachment's
//// startup each run in a weft task, because each one blocks on a socket and
//// the terminal must not. Resolving a new session's configuration runs in
//// one too, because it reads the file system and the step reads no file.
//// The step used to
//// start those tasks itself: it created the reply `Subject` and the
//// `weft.Cancel`, spawned the relay, and kept both in the model so a later
//// step could read the reply and tell a current reply from a stale one by
//// comparing subjects. That made the step create processes and mailboxes,
//// and left nothing a test could inspect short of running the job.
////
//// Now a reducer describes the job and names it with a `Key`. It queues
//// `effect.StartJob(key, spec)`, and the runtime (`tui/job_runner`) starts
//// the task after the step, keeps the key's subject and cancel signal in a
//// table of its own, and hands every reply back tagged with the key it
//// belongs to, as an `Arrival`. The reducer's slot for the job holds the
//// key together with the replies received for it (`Awaiting`), and a reply
//// is admitted into a slot only when its key is the slot's key. A reply for
//// a job the reducer has stopped waiting for finds no slot naming its key
//// and is dropped, so no reducer compares anything to decide whether a
//// reply is current.
////
//// Everything in this module is data and pure functions. Keys are
//// allocated from a counter on the model (`tui_model.start_job`), never
//// reused while the terminal runs, so a key names exactly one job.
////
//// A daemon control connection is named the same way. The runtime keeps
//// each one in its table beside the jobs and gives the step a `Daemon`: a
//// `ControlKey` and what the daemon's `hello` said about its build. A job
//// that asks through the daemon's control route names the key, and the
//// runtime resolves it when it starts the job, so the step holds no
//// connection. A relaunch's worker returns a connection, so its replies
//// arrive as `Arrival(daemon_selection.Host)`, and the runtime turns them
//// into `Arrival(Daemon)` as it files them, adding the new connection to
//// its table.

import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import session_view/connection_event
import session_view/snapshot
import tui/bootstrap
import tui/connection
import tui/daemon/protocol as control_protocol
import tui/session_selector
import tui/workspace
import weft

/// The name a reducer gives one job when it starts it.
///
/// Keys are allocated in order from `Model.next_job` and never reused while
/// the terminal runs, so a reply tagged with a key belongs to exactly the
/// job that key was given to.
pub opaque type Key {
  Key(Int)
}

/// The name the runtime keeps one daemon control connection under.
///
/// The runtime allocates it when a connection enters its table, at launch
/// or when a relaunch hands one back, and never reuses it, so a job or a
/// close that names it reaches the connection it named when it was decided.
pub opaque type ControlKey {
  ControlKey(Int)
}

/// The control key the runtime allocates for its `n`th connection.
///
/// ## Examples
///
/// ```gleam
/// let key = job.control_key(0)
/// ```
@internal
pub fn control_key(n: Int) -> ControlKey {
  ControlKey(n)
}

/// A daemon control connection as the step sees it: the key the runtime
/// holds it under, and the build its `hello` named, which the build notice
/// compares with the client's own.
pub type Daemon {
  Daemon(
    /// The runtime's key for the connection.
    control: ControlKey,
    /// The daemon's build, when its `hello` named one.
    build: Option(control_protocol.Build),
  )
}

/// The first key a fresh model allocates.
///
/// ## Examples
///
/// ```gleam
/// let next_job = job.first()
/// ```
pub fn first() -> Key {
  Key(0)
}

/// Allocates `next` and returns it together with the key that follows it.
///
/// ## Examples
///
/// ```gleam
/// let #(key, next_job) = job.allocate(model.next_job)
/// ```
pub fn allocate(next: Key) -> #(Key, Key) {
  let Key(value) = next
  #(next, Key(value + 1))
}

/// One reducer slot's view of a running job: its key, and the replies the
/// runtime received for it that the reducer has not taken yet, oldest
/// first.
///
/// The replies live inside the slot, as a buffered inbox's messages live
/// inside the inbox (`tui/buffered`). A reducer that stops waiting for the
/// job replaces or clears the slot, and the replies it held leave the model
/// with it, so nothing received for that job can reach a reducer later.
/// Every job is a one-task weft run, whose relay sends at most two
/// messages, so the list is at most two long.
pub opaque type Awaiting(reply) {
  Awaiting(key: Key, held: List(reply))
}

/// A slot for the job named `key`, with nothing received yet.
///
/// ## Examples
///
/// ```gleam
/// let slot = job.awaiting(key)
/// ```
pub fn awaiting(key: Key) -> Awaiting(reply) {
  Awaiting(key:, held: [])
}

/// The key of the job a slot waits for.
///
/// ## Examples
///
/// ```gleam
/// effect.CancelJob(job.key(run.job))
/// ```
pub fn key(awaiting: Awaiting(reply)) -> Key {
  awaiting.key
}

/// Appends a reply behind the ones the slot already holds, if it is a reply
/// to this slot's job.
///
/// The error is the fence: a reply whose key is not the slot's belongs to a
/// job this slot no longer waits for, and the caller drops it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(slot) = job.admit(job.awaiting(key), key, weft.AllDelivered)
/// ```
pub fn admit(
  awaiting: Awaiting(reply),
  key: Key,
  reply: reply,
) -> Result(Awaiting(reply), Nil) {
  case awaiting.key == key {
    True -> Ok(Awaiting(..awaiting, held: list.append(awaiting.held, [reply])))
    False -> Error(Nil)
  }
}

/// The replies the slot holds and no reducer has taken, oldest first.
///
/// A reducer that clears a slot passes these to `tui_model.release`, so a
/// reply that holds a resource is released rather than dropped with the
/// slot.
///
/// ## Examples
///
/// ```gleam
/// job.held(job.awaiting(key))
/// // -> []
/// ```
pub fn held(awaiting: Awaiting(reply)) -> List(reply) {
  awaiting.held
}

/// Takes the oldest reply the slot holds.
///
/// ## Examples
///
/// ```gleam
/// let #(slot, next) = job.take(slot)
/// ```
pub fn take(
  awaiting: Awaiting(reply),
) -> #(Awaiting(reply), Result(reply, Nil)) {
  case awaiting.held {
    [] -> #(awaiting, Error(Nil))
    [reply, ..rest] -> #(Awaiting(..awaiting, held: rest), Ok(reply))
  }
}

/// What a finished daemon control job produced.
///
/// Catalogue and peer requests share one job slot. The outcome identifies
/// which requested operation completed without adding overlapping pending
/// fields to the model.
pub type ControlOutcome {
  /// One authorized page and the identity to highlight in it.
  PageLoaded(
    page: control_protocol.Page,
    selected: String,
    collection: session_selector.Collection,
  )

  /// The daemon removed this registration and its database.
  SessionDeleted(session_id: String)

  /// Acknowledged archive preserves files while removing the active row.
  SessionArchived(session_id: String)

  /// Acknowledged restoration removes the row from the archive page.
  SessionRestored(session_id: String)

  /// The daemon acknowledged a rename with its canonical catalogue row.
  SessionRenamed(row: control_protocol.Session)

  /// One session catalogue and exact peer inspection for the modal.
  PeerWorkspaceLoaded(page: control_protocol.Page, document: json.JsonValue)

  /// One more revision-fenced target-session catalogue page.
  PeerSessionsLoaded(page: control_protocol.Page)

  /// One refreshed grant document after a request or mutation.
  PeerInspectionLoaded(document: json.JsonValue, after: Option(String))

  /// A link or unlink acknowledgement whose body preserves partial results.
  PeerOperationCompleted(document: json.JsonValue)

  /// One page of principals for the access overlay, and the cursor it was
  /// read after, absent for the first page.
  AccessListed(document: json.JsonValue, after: Option(String))

  /// One page of a principal's memberships for the access overlay.
  MembershipsListed(
    document: json.JsonValue,
    principal: String,
    after: Option(String),
  )

  /// The daemon acknowledged one access change.
  AccessChanged(document: json.JsonValue)
}

/// The ADT keeps a confirmed permanent deletion distinct from reversible
/// archive and restore requests while they share one bounded job slot.
pub type Removal {
  /// Stop the session and move it to the archive.
  Archive

  /// Move an archived session back to the active catalogue.
  Restore

  /// Stop the session and delete its registration and database.
  PermanentlyDelete
}

/// One daemon control request the picker or the peer manager asked for.
///
/// Each variant carries only the values its worker needs. The worker used
/// to be a closure built in the reducer, and a closure over a model field
/// copies the whole model into the task; a variant cannot capture the
/// model at all.
pub type ControlJob {
  /// Lists one catalogue page. `session` and `workspace` choose the row to
  /// highlight: the attached session, or the workspace's default when none
  /// is attached.
  LoadPage(
    command: control_protocol.Command,
    collection: session_selector.Collection,
    session: String,
    workspace: String,
  )

  /// Renames a catalogue session.
  Rename(session: String, name: String)

  /// Archives, restores or permanently deletes a catalogue session.
  Remove(session: String, removal: Removal)

  /// Lists the catalogue and inspects the source strand's peer grants, for
  /// the peer manager's first page.
  LoadPeerWorkspace(source_session: String, source_strand: String)

  /// Inspects one strand's peer grants, from the page after `after`.
  InspectPeers(session: String, strand: String, after: Option(String))

  /// Lists one more target-session page under a fixed catalogue revision.
  LoadPeerSessions(after: String, revision: Int)

  /// Sends one link or unlink.
  MutatePeers(command: control_protocol.Command)

  /// Reads one page of the owner's access listing: `ListPrincipals` or
  /// `PrincipalMemberships`.
  ReadAccess(command: control_protocol.Command)

  /// Sends one access change: `SetMemberRole`, `RevokeMembership` or
  /// `RevokeCredentials`.
  ChangeAccess(command: control_protocol.Command)
}

/// Which job to start. The runtime turns each variant into a weft task.
pub type Spec {
  /// A daemon control request over the terminal's control route.
  Control(control: ControlKey, request: ControlJob)

  /// The one bounded relaunch an unexpected daemon death earns, from the
  /// local launch options.
  Reconnect(options: bootstrap.Options)

  /// The picker's activity poll for these resident identities, on a
  /// control connection the worker opens and closes itself.
  Activity(control: ControlKey, ids: List(String))

  /// A provisional attachment: resolve the route through daemon control,
  /// connect a conversation socket, publish it as `Prepared`, and wait for
  /// the terminal's acknowledgement, all within `within_ms`.
  Attach(route: AttachRoute, within_ms: Int)

  /// Resolves the configuration a new session is created with, from the
  /// local launch options: the state root from `HOME` or `--state-dir`,
  /// and the canonical path of `--config` or of the trusted
  /// `<state-root>/loom.toml` when it exists (`bootstrap.session_configuration`).
  Configure(options: bootstrap.Options)

  /// Writes an image's bytes to a private file and hands the file to the
  /// platform's opener (`tui/image_open`).
  OpenImage(mime_type: String, data: String)
}

/// How an attachment job resolves the session it connects to.
pub type AttachRoute {
  /// Opens an existing catalogue session.
  OpenSession(control: ControlKey, session: String)

  /// Creates a session under a retained creation key, then opens it.
  CreateSession(
    control: ControlKey,
    key: String,
    workspace: String,
    name: String,
    config: String,
    profile: String,
    /// The executor `workspace` is registered on, or empty when it is a path
    /// on the daemon's host (protocol-change/078).
    executor: String,
  )
}

/// What an attachment worker publishes once its socket is open.
///
/// The runtime creates the frames subject when it starts the job and hands
/// it to the worker, which connects the socket to it and names it here. This
/// is how the candidate learns its frames inbox: from the `Prepared` that
/// carries the socket feeding it, never from the step that asked for the
/// job, which creates no subject. A `Prepared` the terminal will not use
/// still holds an open socket, so whoever drops one closes the socket and
/// discards the frames subject.
pub type Prepared {
  Prepared(
    /// The open conversation socket, not yet adopted.
    socket: connection.Connection,
    /// The session, epoch and incarnation the initial cut must match.
    expected: snapshot.Expected,
    /// Canonical workspace returned by the authorized catalogue record.
    workspace: workspace.Context,
    /// Display name from the authorized catalogue.
    session_name: String,
    /// The creation key only a successful adoption may clear.
    creation_key: Option(String),
    /// The subject the worker waits on for the terminal's acknowledgement.
    acknowledgement: Subject(Nil),
    /// The terminal-owned subject the socket delivers frames to.
    frames: Subject(connection_event.Message),
  )
}

/// One message an attachment job sends: its `Prepared`, sent by the worker
/// itself, or one of the relay's messages about the worker's outcome.
pub type AttachReply {
  /// The worker's socket, open and waiting to be acknowledged.
  Published(prepared: Prepared)

  /// The weft relay's account of the worker. The relay's last message,
  /// `AllDelivered`, is what permits adoption, and the host does not pass
  /// it on as it is: it reads whether the published socket's process is
  /// still alive and hands the attempt `Finished` instead.
  Settled(reply: weft.Pulled(Nil, String))

  /// The relay's `AllDelivered`, with whether the socket the attempt would
  /// adopt was still alive when the host received it (`runtime.hold`).
  /// Reading that is a process read, so the host does it and the attempt,
  /// which only decides, adopts or fails on the answer.
  Finished(socket: SocketLiveness)
}

/// Whether the socket an attempt would adopt still has a live process
/// behind it, read by the host when the attachment job ended.
pub type SocketLiveness {
  /// The socket's actor was alive when the host looked.
  SocketAlive

  /// The socket cannot be adopted, and why: its actor had exited, or the
  /// attempt's lane has no socket at all.
  SocketGone(reason: String)
}

/// What a control job's relay sends.
pub type ControlReply =
  weft.Pulled(ControlOutcome, String)

/// What the relaunch's relay sends: the relaunched daemon's control
/// connection as the runtime receives it (`daemon_selection.Host`), or as
/// the step holds it (`Daemon`).
pub type ReconnectReply(control) =
  weft.Pulled(control, String)

/// What the activity poll's relay sends.
pub type ActivityReply =
  weft.Pulled(List(control_protocol.Activity), String)

/// What the configuration job's relay sends: the canonical configuration
/// path, empty when there is none, or why it could not be resolved.
pub type ConfigurationReply =
  weft.Pulled(String, String)

/// What the open-image job's relay sends: the path of the file the opener
/// was given, or why the image could not be opened.
pub type ImageReply =
  weft.Pulled(String, String)

/// One message a job's relay sent, tagged with the job's key.
///
/// The runtime produces these from the job's own subject, and
/// `runtime.hold` admits each into the slot of its kind when that slot
/// holds the same key. `control` is how a relaunch's connection is held:
/// the runtime receives `Arrival(daemon_selection.Host)` and files
/// `Arrival(Daemon)`.
pub type Arrival(control) {
  /// A reply from a daemon control job.
  ControlArrived(key: Key, reply: ControlReply)

  /// A reply from the relaunch.
  ReconnectArrived(key: Key, reply: ReconnectReply(control))

  /// A reply from the activity poll.
  ActivityArrived(key: Key, reply: ActivityReply)

  /// A message from an attachment job.
  AttachArrived(key: Key, reply: AttachReply)

  /// A reply from the configuration job.
  ConfigurationArrived(key: Key, reply: ConfigurationReply)

  /// A reply from the open-image job.
  ImageArrived(key: Key, reply: ImageReply)
}

/// The key an arrival is tagged with.
///
/// ## Examples
///
/// ```gleam
/// job.arrival_key(job.ControlArrived(key, weft.AllDelivered))
/// ```
pub fn arrival_key(arrival: Arrival(control)) -> Key {
  arrival.key
}

/// Reports whether an arrival is the last its job's relay will send.
///
/// A relay sends each outcome, then exactly one `AllDelivered` or
/// `RunLost`, and exits; nothing arrives for that key afterwards.
///
/// ## Examples
///
/// ```gleam
/// assert job.is_last(job.ControlArrived(key, weft.AllDelivered))
/// ```
pub fn is_last(arrival: Arrival(control)) -> Bool {
  case arrival {
    ControlArrived(reply:, ..) -> ends_run(reply)
    ReconnectArrived(reply:, ..) -> ends_run(reply)
    ActivityArrived(reply:, ..) -> ends_run(reply)
    ConfigurationArrived(reply:, ..) -> ends_run(reply)
    ImageArrived(reply:, ..) -> ends_run(reply)
    AttachArrived(reply: Settled(reply:), ..) -> ends_run(reply)
    AttachArrived(reply: Finished(_), ..) -> True
    AttachArrived(reply: Published(_), ..) -> False
  }
}

fn ends_run(reply: weft.Pulled(a, e)) -> Bool {
  case reply {
    weft.AllDelivered | weft.RunLost(_) -> True
    weft.PulledOutcome(_) | weft.NotYet -> False
  }
}
