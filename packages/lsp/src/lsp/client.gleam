//// The language-server client actor: one process owning one language
//// server over an `lsp/transport.Transport`, from the `initialize`
//// handshake to the witnessed close of its transport (ADR-015 §§1–3).
////
//// # Why this is an actor, and what it refuses to do
////
//// A language server is not a command. It keeps a model of every open
//// document, sends requests of its own that must be answered, and
//// publishes diagnostics whenever it likes, so something has to be
//// listening to it all the time. That something is this actor, and it
//// is the only place in the harness where LSP JSON-RPC ids, document
//// versions and publications are correlated.
////
//// Handlers read no disk. Ordinary `ChannelTransport` keeps the existing cast
//// writes and uncredited relay. `ConsumedChannelTransport` admits each logical
//// write to its bounded original writer; the managed pump waits for native input
//// independently of this actor. Output consumption waits only for that output's
//// local managed credit task to drain, after framing, parsing and state checks.
//// Request, settlement, handshake and shutdown waits remain actor state and timers.
//// Document texts come from the caller, which is why `sync` takes texts.
////
//// **Every request is gated on what the server advertised.** A measured
//// server left an unadvertised request unanswered for as long as it was
//// watched, so `protocol.supports` is checked before an id is minted, and
//// an unadvertised request answers `Unsupported` without a byte reaching
//// the server.
////
//// Both transports are trusted local channel seams. Rule Zero keeps the actual
//// server in the jail; neither variant can open an unjailed process. The ordinary
//// channel preserves existing local behavior. The consumed variant selects the
//// Registered JSON and retained-state profile specified by protocol 078.
////
//// # The phases
////
//// `Initializing` sends `initialize`, decodes the capabilities and sends
//// `initialized`; callers cannot hold a handle yet, and anything that
//// arrives early is postponed into `Serving`. `Serving` is the working
//// life. `ShuttingDown` has sent `shutdown` and waits a caller-chosen
//// grace for its answer; then `exit` is sent and the transport closed.
//// `Retiring` has closed the transport and waits, bounded by `retire_ms`,
//// for the original attachment close event. Registered native retirement requires
//// separate executor/helper evidence; no local close or deadline supplies it. The
//// actor exits only from `Retiring`, or at once when the transport
//// reports the close itself.
////
//// ## Transition table
////
//// `Phase` is the state type. Each cell is the phase the actor is in after
//// the message, or what the message does when it leaves the phase alone.
//// "Faulted" and "Forced" name the `Ending` a `Retiring` phase carries.
//// The per-id timers are `Expire`, `SettleExpired`, `ReadyQuiet` and
//// `ReadyExpired`; a caller request is `Ask`, `Sync`, `Settle` or `Ready`.
////
//// <!-- transitions: client.Phase -->
////
//// | Phase | `Handshake` | Caller request | `Read` | `Stop` | `Abandoned` |
//// |---|---|---|---|---|---|
//// | `Initializing` | stays; sends `initialize` and arms the handshake timeout (a failed write goes to `Retiring`, Faulted) | postponed until the phase changes | postponed | `Retiring`, Forced | `Retiring`, Forced |
//// | `Serving` | refused to the starter; stays | handled; stays (a failed write goes to `Retiring`, Faulted) | answered; stays | `ShuttingDown` (a failed write goes to `Retiring`, Forced) | `ShuttingDown` with `abandon_grace_ms` |
//// | `ShuttingDown` | refused; stays | refused `Unavailable`; stays | refused; stays | stays; the caller joins the stoppers | ignored |
//// | `Retiring` | refused; stays | refused `Unavailable`; stays | refused; stays | stays; the caller joins the stoppers | ignored |
////
//// <!-- transitions: client.Phase -->
////
//// | Phase | Transport bytes | Transport closed | Per-id timers | Phase timers |
//// |---|---|---|---|---|
//// | `Initializing` | stays; the `initialize` answer goes to `Serving`, a refusal or a framing fault to `Retiring` (Faulted) | actor exits, abnormally | ignored | `HandshakeExpired` goes to `Retiring` (Faulted); the others are ignored |
//// | `Serving` | stays; a framing fault or a bad body goes to `Retiring` (Faulted) | actor exits, abnormally | handled; stays | all ignored |
//// | `ShuttingDown` | stays; the `shutdown` answer goes to `Retiring` (Graceful), a fault to `Retiring` (Faulted) | actor exits normally, report Forced | `Expire` is handled; the rest are ignored | `GraceExpired` goes to `Retiring` (Forced); the others are ignored |
//// | `Retiring` | drained; Registered trailing complete bodies remain validated | actor exits: normally after a requested stop, abnormally after a fault | ignored | `RetireExpired` exits abnormally and reports `Unconfirmed`; the others are ignored |
////
//// A message that reaches a phase with nothing to do in it is dropped
//// rather than refused, because every such message is either a timer whose
//// work already finished or a notice that has no caller waiting on it.
////
//// ## Flow
////
//// The caller side and the actor side meet only through `Msg`:
////
//// ```text
//// start    -> spawn -> (actor) initializing -> begin_handshake
////          -> feed -> body -> message -> response -> answered
////          -> handshake_answered -> accept_initialize        phase becomes Serving
//// query    definition / hover / ... -> uri_of -> ask -> exchange -> call.try_call
////          -> (actor) serving -> ask_server -> mint -> send   reply is held in `pending`
////          -> feed -> response -> answered                    caller is answered
////          -> expire                                          or the deadline answers TimedOut
//// sync     sync -> resolve -> exchange -> (actor) sync_documents -> apply_op
//// settle   settle -> exchange -> begin_settle -> open_barrier -> release_settled
////          fed by notification -> record, and by answered -> barrier_answered
//// ready    ready -> exchange -> begin_ready -> progressed / moved -> quiet_lapsed
//// stop     stop -> (actor) begin_shutdown -> acknowledged / force_close
////          -> witnessed                                       actor exits
//// death    peer_closed or fail -> settle_all -> close
//// ```
////
//// `from_consumed`, `feed_flow`, `checked_notification`, `progress_candidate`,
//// `state_bounds`, `ready_admitted`, `settle_admitted`, `join_stopper` and
//// `flush_close` and `registered_diagnostic_numbers` own Registered consumption.
//// `handle` dispatches on the phase to `initializing`, `serving`,
//// `shutting_down` or `retiring`. Handlers that may change the phase in
//// the middle of their work return a `Flow` (a phase and its data), and
//// `conclude` turns it into the step the state machine expects.
////
//// ## Reading the handlers
////
//// The actor is a `weft/state_machine`, imported as `sm`. A handler returns
//// `sm.keep(data)` to stay in the phase, `sm.transition(to:, data:)` to
//// move to another, `sm.postpone` to hold the message until the phase
//// changes, and `sm.stop` or `sm.stop_abnormal` to exit. A state timeout
//// (`sm.with_state_timeout`) is a message the machine sends itself after a
//// delay and cancels when the phase changes, which is why `entered` is
//// the one place a phase's deadline is armed. The per-id timers use
//// `process.send_after` instead, because many are live at once; each is
//// checked for staleness against the table its id lives in.
////
//// # Death is reported, never survived
////
//// A transport close, a framing fault, a body that is not JSON-RPC or a
//// failed write settles every pending caller and every settlement waiter
//// with `Unavailable(reason)`, closes the transport, and ends the actor
//// with an abnormal exit carrying the reason. Restarting is not this
//// module's job: the manager that monitors `pid` restarts the server and
//// re-sends its documents (ADR-015 §1).
////
//// # Settled diagnostics are two rules
////
//// ADR-015 §3, measured on two servers: `gleam lsp` never versions a
//// publication but publishes before it answers a request sent after the
//// change; `gopls` versions every publication but may publish after that
//// answer. So `settle` sends a `documentSymbol` barrier and settles once
//// (a) the barrier has answered and (b) for a server that has ever
//// published a version, every changed document has a publication at
//// least as new as the version last synced. A deadline that lapses first
//// answers `DeadlineExpired` with whatever arrived — never a claim that
//// the code is clean.
////
//// # Readiness is the server's own progress
////
//// A server may answer while it is still loading its project, and
//// `rust-analyzer` does: an empty `definition`, references holding only
//// the declaration, no hover — answers indistinguishable from true ones.
//// The initialize request declares `window.workDoneProgress`, so a server
//// reports that loading as `$/progress` tokens running `begin` → `report`
//// … → `end`, and the actor keeps the set of tokens still active. `ready`
//// answers `Quiet` once no token has been active for a caller-chosen quiet
//// window, and `StillBusy` with the active titles if its deadline lapses
//// first. It is built the way settlement is: a waiter plus timers in actor
//// state, answered when the token set changes, never a blocked handler.
//// A server that reports no progress is quiet from the start, and waits
//// only the window.
////
//// Callers reach the actor only through `lsp/call.try_call`, the
//// monitored call that answers a dead or wedged callee as a value rather
//// than crashing the asker as `process.call` would.

import core/corruption
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import lsp/call
import lsp/framing
import lsp/internal/consumed_channel as consumed
import lsp/jsonrpc.{type Id}
import lsp/protocol.{
  type CallHierarchyItem, type DocumentSymbols, type Feature, type HoverResult,
  type IncomingCall, type InitializeResult, type Location, type OutgoingCall,
  type PrepareRename, type PublishDiagnostics, type ServerCapabilities,
  type ServerDiagnostic, type WorkspaceEdit, type WorkspaceFolder,
}
import lsp/range.{type Position}
import lsp/transport.{type Transport}
import weft/state_machine as sm

// --- bounds -----------------------------------------------------------------

/// The most documents the client holds open on the server. Opening one
/// more sends `didClose` for the least recently synced and forgets it
/// (ADR-015 §3). A server re-reads a closed document from disk, so the
/// bound costs a read, never a wrong answer.
pub const max_open_documents = 64

/// The most URIs whose latest publication the diagnostics store keeps.
/// Past it, the URI whose publication is oldest is forgotten. A server
/// that publishes about more files than this is reporting on a project
/// larger than any one settled block could show.
pub const max_published_uris = 512

/// The most diagnostics kept from one publication, in the server's order.
/// A file with more is broken past the point where the two-hundred-and-
/// first says anything new, and the bound caps what one hostile
/// publication can make the actor hold.
pub const max_diagnostics_per_uri = 200

/// The default budget for the `initialize` round trip. `gopls` answered
/// its first query in 1.8 s cold (ADR-015); a handshake that includes a
/// project load is given far longer than that.
pub const default_initialize_ms = 30_000

/// The default per-request deadline a caller can read back with
/// `request_deadline`.
pub const default_request_ms = 10_000

/// The most work-done progress tokens the client tracks at once. Past it,
/// the token that began earliest is forgotten. A server runs a handful of
/// concurrent tasks; a server that begins tokens and never ends them, or
/// mints a fresh one per file, would otherwise grow the actor's state
/// without end. The oldest is the one to drop because a genuinely long
/// load keeps reporting under its token, and a report for an unknown
/// token puts it back.
pub const max_progress_tokens = 64

/// How long a client that has closed its transport waits for the
/// transport to report the close before it exits without that witness.
pub const retire_ms = 5000

/// Slack added to the actor's own deadline before a caller gives up on the
/// actor itself. The actor answers `TimedOut` at the real deadline; this
/// only guards against a wholly wedged actor.
const reply_margin_ms = 1000

/// How long the actor's initialiser — which opens the transport — may run.
const init_timeout_ms = 5000

/// The shutdown grace a client gets when its owner dies without stopping
/// it: short, because nobody is waiting for the answer.
const abandon_grace_ms = 1000

/// How long a document sync or a read of the actor's state may wait for
/// the actor. Neither waits on the server, so this bounds only a wedged
/// actor.
const local_wait_ms = 5000

// --- public types -----------------------------------------------------------

/// An opaque handle to a started client. Sendable across processes; every
/// public function takes one.
pub opaque type Client {
  Client(subject: Subject(Msg), owner: process.Pid, request_ms: Int)
}

/// What `start` needs to know about the server it is starting.
///
/// Constructor invariants: `root` is an absolute path (a relative one is
/// refused as `BadRoot`); `initialize_ms` and `request_ms` are positive
/// millisecond budgets.
pub type Options {
  Options(
    /// The configured server name (`[lsp.<name>]`), for messages.
    server: String,
    /// The project root, absolute. It is the server's `rootUri` and its
    /// one workspace folder.
    root: String,
    /// The workspace folder's display name; servers use it only in
    /// messages.
    folder_name: String,
    /// The `languageId` a document is opened with when a `Change` reaches
    /// a document the server does not hold open.
    language_id: String,
    /// The budget for the whole `initialize` round trip.
    initialize_ms: Int,
    /// The deadline callers are advised to use per request; see
    /// `request_deadline`.
    request_ms: Int,
  )
}

/// Why `start` produced no serving client.
pub type StartError {
  /// The root is not an absolute path, so it has no `file://` URI.
  BadRoot(root: String)

  /// The transport could not be used: the actor that would own it could
  /// not start, or the transport failed before the handshake began.
  /// `reason` says which.
  TransportRefused(reason: String)

  /// The `initialize` exchange failed: the server refused it, answered
  /// with something that is not an `InitializeResult`, died, or missed
  /// the handshake budget.
  HandshakeFailed(error: RequestError)

  /// The server chose a `positionEncoding` other than UTF-16, the only
  /// encoding `lsp/text` converts from.
  EncodingUnsupported(encoding: String)
}

/// Why a request produced no answer. Plain data: nothing here is ever a
/// caller's crash.
pub type RequestError {
  /// The server did not advertise this request, so it was never sent.
  Unsupported(feature: Feature)

  /// The server answered with a JSON-RPC error, in its own words. A
  /// refused rename's message is the useful part (ADR-015 §4).
  ServerError(code: Int, message: String)

  /// No answer arrived within the request's deadline. The id was
  /// forgotten and `$/cancelRequest` sent for it; a late answer is
  /// dropped.
  TimedOut(after_ms: Int)

  /// The client cannot answer: the server died, the transport faulted,
  /// the client is shutting down, or the actor is gone. `reason` says
  /// which.
  Unavailable(reason: String)

  /// The server answered with something that is not the shape the method
  /// promises; `reason` names the field that broke it.
  Malformed(reason: String)

  /// A path handed in has no `file://` URI: it is not absolute.
  InvalidPath(path: String)

  /// A rename answer asked to create, rename or delete a file, which the
  /// hashline path cannot land; the whole edit is refused (ADR-015 §4).
  EditRefused(kind: String, uri: String)
}

/// One change to the server's view of the documents, computed by the
/// caller (ADR-015 §3's push and pull). The actor never reads disk, so
/// every text here is the text the caller read.
pub type DocOp {
  /// Hold `path` open with `text`. Opening a document already open
  /// changes it instead.
  Open(path: String, language_id: String, text: String)

  /// Replace `path`'s text, full-text sync. A document not open is opened
  /// with the options' `language_id`.
  Change(path: String, text: String)

  /// Stop holding `path` open. Closing a document not open does nothing.
  Close(path: String)
}

/// Whether a settlement met ADR-015 §3's two rules before its deadline.
pub type SettleOutcome {
  /// Both rules held: the diagnostics are current as of the change.
  Settled

  /// The deadline lapsed first. What arrived is reported, and it may be
  /// stale or partial; it is never a claim that the code is clean.
  DeadlineExpired
}

/// The answer to `settle`.
pub type Settlement {
  Settlement(
    outcome: SettleOutcome,
    /// Every path published about since the earliest change being
    /// settled, plus the latest stored publication for each changed
    /// path, sorted by path. Breaking one file breaks its dependents, so
    /// other files' publications are part of the answer (ADR-015 §3).
    published: List(#(String, List(ServerDiagnostic))),
  )
}

/// The answer to `ready`: whether the server has finished the work it
/// reported through `$/progress`.
pub type Readiness {
  /// No work-done progress was active for the whole quiet window.
  Quiet

  /// The deadline lapsed while work was active, or before the quiet
  /// window closed. `titles` are the active tokens' titles, oldest first,
  /// for a message; empty when the window, not an active token, was the
  /// wait.
  StillBusy(titles: List(String))
}

/// How a `stop` ended.
pub type StopReport {
  /// The server answered `shutdown`, was sent `exit`, and its transport
  /// reported the close.
  Graceful

  /// The server did not answer `shutdown` within the grace (or the
  /// client was faulting already); `exit` was sent and the transport
  /// closed without it, and the transport reported the close.
  Forced

  /// The client had already exited before `stop` reached it: its server
  /// died or faulted, and the exit was the report.
  AlreadyGone

  /// The transport never reported the close within `retire_ms`, or the
  /// client did not answer at all. The server may still be running; the
  /// broker's step abort is the backstop (ADR-015 §1).
  Unconfirmed
}

// --- the actor's vocabulary -------------------------------------------------

/// The client actor's message set. Opaque: only this module builds these,
/// so nothing outside can forge a response, an expiry or a witness.
pub opaque type Msg {
  /// The starter asks for the handshake. Sent once, by `start`.
  Handshake(reply: Subject(Result(Nil, StartError)))

  /// The handshake's state timeout lapsed.
  HandshakeExpired

  /// One gated request: `build` receives the minted id and returns the
  /// whole message.
  Ask(
    feature: Feature,
    build: fn(Id) -> JsonValue,
    deadline_ms: Int,
    reply: Subject(Result(JsonValue, RequestError)),
  )

  /// A request's deadline lapsed. Stale when the id already settled.
  Expire(id: Int)

  /// A requesting process died; only its pending protocol requests are cancelled.
  CallerDown(monitor: process.Monitor)

  /// Document operations, already resolved to URIs by the caller.
  Sync(ops: List(Resolved), reply: Subject(Result(Nil, RequestError)))

  /// Wait for settled diagnostics after a change to `uris`.
  Settle(
    uris: List(String),
    deadline_ms: Int,
    reply: Subject(Result(Settlement, RequestError)),
  )

  /// A settlement's deadline lapsed. Stale when it already settled.
  SettleExpired(token: Int)

  /// Wait until no work-done progress has been active for `quiet_ms`.
  Ready(
    quiet_ms: Int,
    deadline_ms: Int,
    reply: Subject(Result(Readiness, RequestError)),
  )

  /// A readiness waiter's quiet window lapsed. Armed when the token set
  /// was empty at `epoch`; stale when the set has changed since, or when
  /// the waiter was already answered.
  ReadyQuiet(token: Int, epoch: Int)

  /// A readiness waiter's deadline lapsed. Stale when it was answered.
  ReadyExpired(token: Int)

  /// A read of the actor's own state; never reaches the server.
  Read(reading: Reading)

  /// Stop the server: `shutdown`, `exit`, close, within the grace.
  Stop(grace_ms: Int, reply: Subject(StopReport))

  /// The shutdown grace lapsed without an answer.
  GraceExpired

  /// The transport did not report the close within `retire_ms`.
  RetireExpired

  /// Inbound bytes or the close, from the transport.
  FromTransport(event: transport.TransportEvent)

  /// Original local output remains credited until the actor finishes consumption.
  FromConsumed(event: consumed.Event)

  /// Nobody will stop this client: its owner died, or `start` gave up on
  /// the handshake reply.
  Abandoned
}

// The reads of the actor's state, grouped so a phase that refuses them
// refuses all four in one place.
type Reading {
  TextOf(uri: String, reply: Subject(Result(Option(String), RequestError)))
  OpenPaths(reply: Subject(Result(List(String), RequestError)))
  PublishedFor(
    uri: Option(String),
    reply: Subject(
      Result(List(#(String, List(ServerDiagnostic))), RequestError),
    ),
  )
  CapabilitiesOf(reply: Subject(Result(ServerCapabilities, RequestError)))
  Observed(reply: Subject(Result(ObservationState, RequestError)))
}

// A `DocOp` with its path resolved to a URI in the caller, so the actor
// never meets a path it cannot name.
type Resolved {
  Opening(uri: String, path: String, language_id: String, text: String)
  Changing(uri: String, path: String, text: String)
  Closing(uri: String)
}

// What an in-flight id is waiting for. The variant decides what its
// answer does: reach a caller, pass a settlement barrier, complete the
// handshake, or acknowledge shutdown.
type Pending {
  CallerWaits(
    reply: Subject(Result(JsonValue, RequestError)),
    deadline_ms: Int,
    feature: Feature,
    monitor: Option(process.Monitor),
  )
  BarrierFor(token: Int)
  HandshakeWaits(reply: Subject(Result(Nil, StartError)))
  ShutdownWaits
}

// One document the server holds open. `text` is exactly the last text
// sent, which is the rename base of ADR-015 §4. `version` is drawn from
// one counter shared by every document, so it also orders documents by
// last sync for the LRU bound, and a document closed and reopened never
// reuses a version an old publication already carries. `mark` is the
// publication sequence at its last sync: a settlement collects what was
// published after it.
type Document {
  Document(path: String, version: Int, text: String, mark: Int)
}

// The latest publication for one URI. `sequence` is the store's own
// arrival count, so "published since" is a comparison.
type Publication {
  Publication(
    path: String,
    version: Option(Int),
    diagnostics: List(ServerDiagnostic),
    sequence: Int,
  )
}

// Whether this server has ever put a version on a publication. It never
// goes back: rule (b) of settlement applies from the first versioned
// publication on.
type Versioning {
  Unversioned
  Versioned
}

// Rule (a) of one settlement.
type Barrier {
  // The `documentSymbol` barrier is in flight under this id.
  BarrierAwaiting(id: Int)

  // The barrier answered, or nothing changed so nothing needed ordering.
  BarrierPassed

  // The server has no `documentSymbol`, so no request can order its
  // publications; only rule (b) can settle, and an unversioned server
  // never does (protocol.ServerCapabilities.document_symbol).
  BarrierUnavailable
}

// A changed document and the version its diagnostics must reach. `None`
// when the document is not open: there is no version to wait for.
type Target {
  Target(uri: String, version: Option(Int))
}

// One work-done progress token the server has begun and not ended.
// `title` is what a caller still waiting at its deadline is told; `order`
// is its arrival count, which the `max_progress_tokens` bound evicts by.
type Activity {
  Activity(title: String, order: Int)
}

// A caller waiting for `ready`. Its deadline timer is armed when it
// arrives; its quiet timer whenever the token set is, or becomes, empty.
type Readier {
  Readier(reply: Subject(Result(Readiness, RequestError)), quiet_ms: Int)
}

// A caller waiting in `settle`: where to answer, the publication sequence
// to collect from, the changed documents whose versions it waits on, and
// the state of its `documentSymbol` barrier.
type Waiter {
  Waiter(
    reply: Subject(Result(Settlement, RequestError)),
    mark: Int,
    targets: List(Target),
    barrier: Barrier,
  )
}

// The actor's state in the state-machine sense. A phase decides which
// messages are acted on, refused or dropped; the module doc's transition
// table lists every pair.
type Phase {
  // `initialize` is in flight, or about to be sent. Callers cannot hold a
  // handle yet.
  Initializing

  // The handshake succeeded; requests, syncs and settlements are served.
  Serving

  // `shutdown` has been sent, and the client waits at most `grace_ms` for
  // its answer before closing anyway.
  ShuttingDown(grace_ms: Int)

  // The transport has been closed and every waiter answered. `ending` says
  // how the client got here and `reason` is what callers were told. The
  // actor leaves only on the transport's close or after `retire_ms`.
  Retiring(ending: Ending, reason: String)
}

// Why the client is retiring, which decides the stop report and whether
// the exit is normal.
type Ending {
  // A caller or the owner's death asked for the stop. `report` is what
  // `stop` returns once the transport confirms the close.
  Requested(report: StopReport)

  // The server or the transport failed. The exit is abnormal so the
  // manager's monitor sees it, and any `stop` caller is told `Forced`.
  Faulted
}

// Everything the actor owns, beyond the phase. Grouped by purpose below:
// identity, the transport, request correlation, documents, diagnostics,
// settlement waiters, readiness, and stop callers.
type Data {
  Data(
    /// The configured server name, for messages.
    server: String,
    /// Actor-local incarnation token; never sent to the server or cap caller.
    generation: reference.Reference,
    /// Moves on every server-reported failure, including one later recovered.
    failure_epoch: Int,
    /// The `languageId` for a `Change` to a document not yet open.
    language_id: String,
    /// The root as a `file://` URI, sent in `initialize`.
    root_uri: String,
    /// The one workspace folder, also the answer to
    /// `workspace/workspaceFolders`.
    folders: List(WorkspaceFolder),
    /// The handshake budget, in milliseconds.
    initialize_ms: Int,
    /// The actor's own mailbox, which its timers send to.
    commands: Subject(Msg),
    /// The write and close ends of the transport. Replaced by an inert
    /// connection once closed.
    connection: transport.Connection,
    /// Selected by the closed transport, preserving ordinary local behavior.
    profile: json.ParseProfile,
    /// Close is deferred through current output consumption before cancellation.
    deferred_close: Option(fn() -> Nil),
    /// Registered stderr retains its latest bytes without an output archive.
    stderr_ring: BitArray,
    /// Bytes read from the server that have not yet made a whole frame.
    buffer: framing.Buffer,
    /// What the server advertised; empty until `initialize` answers.
    capabilities: ServerCapabilities,
    /// The next JSON-RPC id to mint. Ids are integers, counted from 1.
    next_id: Int,
    /// Requests in flight, by minted id.
    pending: Dict(Int, Pending),
    /// The next document version, shared by every document.
    next_version: Int,
    /// The documents the server holds open, by URI.
    documents: Dict(String, Document),
    /// The count of publications received, so "published since" is a
    /// comparison.
    sequence: Int,
    /// Whether the server has ever versioned a publication.
    versioning: Versioning,
    /// The latest publication for each URI.
    publications: Dict(String, Publication),
    /// One bounded server load error, retained until a semantic answer
    /// proves recovery. It is data, never an instruction to the harness.
    server_failure: Option(String),
    /// The next key for a settlement or readiness waiter.
    next_token: Int,
    /// Settlements in progress, by token.
    waiters: Dict(Int, Waiter),
    /// Work-done progress tokens begun and not ended.
    progress: Dict(protocol.ProgressToken, Activity),
    /// The next arrival count for a progress token.
    next_activity: Int,
    // Moves on every change to the set of active tokens, so a quiet
    // timer armed while the set was empty knows, when it fires, whether
    // it has stayed empty since.
    quiet_epoch: Int,
    /// Readiness waiters, by token.
    readiers: Dict(Int, Readier),
    /// Callers of `stop` to be told how it ended.
    stoppers: List(Subject(StopReport)),
  )
}

// The phase and data a sequence of events has reached. Handlers that
// may change phase partway — a chunk carrying a shutdown answer and then
// more bytes — return one of these, and `conclude` turns it into a step.
type Flow {
  Flow(phase: Phase, data: Data)
}

// --- lifecycle ----------------------------------------------------------------

/// Options with the default budgets and the root's last segment as the
/// folder name.
///
/// ## Examples
///
/// ```gleam
/// let options = client.options(server: "gleam", root: "/work/app", language_id: "gleam")
/// assert options.folder_name == "app"
/// assert options.initialize_ms == client.default_initialize_ms
/// ```
///
pub fn options(
  server server: String,
  root root: String,
  language_id language_id: String,
) -> Options {
  let folder_name = case list.last(string.split(root, "/")) {
    Ok("") | Error(Nil) -> root
    Ok(name) -> name
  }
  Options(
    server:,
    root:,
    folder_name:,
    language_id:,
    initialize_ms: default_initialize_ms,
    request_ms: default_request_ms,
  )
}

/// Starts a client over `transport`: opens it, sends `initialize` with the
/// root as `rootUri` and only workspace folder, decodes the capabilities,
/// refuses a non-UTF-16 position encoding, and sends `initialized`. The
/// whole handshake is bounded by `options.initialize_ms`.
///
/// The calling process is the client's owner: if it dies, the client
/// shuts its server down. The client is not linked to it; monitor `pid`
/// to learn of the client's death.
///
/// On a refusal the client has already closed its transport, and `start`
/// waits (bounded by `retire_ms`) for it to exit before returning.
///
/// ## Examples
///
/// ```gleam
/// // client.start(transport, client.options(server: "gleam", root: "/work", language_id: "gleam"))
/// // -> Ok(client)
/// ```
///
pub fn start(
  transport_spec: Transport,
  options: Options,
) -> Result(Client, StartError) {
  use root_uri <- result.try(
    protocol.path_to_uri(options.root)
    |> result.replace_error(BadRoot(root: options.root)),
  )
  let profile = case transport_spec {
    transport.ChannelTransport(_) -> json.StandardJson
    transport.ConsumedChannelTransport(_) -> json.RegisteredLspJson
  }
  let folders = [
    protocol.WorkspaceFolder(uri: root_uri, name: options.folder_name),
  ]
  use client <- result.try(spawn(
    transport_spec,
    profile,
    options,
    root_uri,
    folders,
  ))

  // The actor answers at the handshake deadline itself; the margin only
  // covers an actor that cannot answer at all, which is abandoned so its
  // transport still closes.
  let waiting = int.max(options.initialize_ms, 1) + reply_margin_ms
  case call.try_call(client.subject, waiting:, sending: Handshake) {
    Ok(Ok(Nil)) -> Ok(client)
    Ok(Error(error)) -> {
      await_exit(client, retire_ms + reply_margin_ms)
      Error(error)
    }
    Error(fault) -> {
      process.send(client.subject, Abandoned)
      Error(HandshakeFailed(error: unreachable(fault)))
    }
  }
}

/// Stops the server: `shutdown`, then `exit` once it answers (or once
/// `grace_ms` passes without an answer), then the transport is closed and
/// its close awaited. Pending callers and settlements answer
/// `Unavailable` at once. Returns when the actor has exited or the bound
/// lapsed.
///
/// ## Examples
///
/// ```gleam
/// // client.stop(client, 2000) -> client.Graceful
/// ```
///
pub fn stop(client: Client, grace_ms: Int) -> StopReport {
  let grace_ms = int.max(grace_ms, 1)
  let waiting = grace_ms + retire_ms + reply_margin_ms
  case call.try_call(client.subject, waiting:, sending: Stop(grace_ms, _)) {
    Error(call.CalleeGone) -> AlreadyGone
    Error(call.NoReply) -> Unconfirmed
    Ok(report) -> {
      // The report is the actor's last act before it stops, so the exit
      // follows at once; waiting for it means a caller that restarts the
      // server never overlaps two clients for one root.
      await_exit(client, reply_margin_ms)
      report
    }
  }
}

/// The client actor's pid, for the manager's monitor. The client exits
/// normally after a requested stop, and abnormally — carrying the reason
/// as a string — when its server died or its transport faulted.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(client.pid(client))
/// ```
///
pub fn pid(client: Client) -> process.Pid {
  client.owner
}

/// The per-request deadline the client was started with, for callers
/// that have no deadline of their own.
///
/// ## Examples
///
/// ```gleam
/// // client.request_deadline(client) -> 10_000
/// ```
///
pub fn request_deadline(client: Client) -> Int {
  client.request_ms
}

/// What the server advertised in its `initialize` result.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(capabilities) = client.capabilities(client)
/// // protocol.supports(capabilities, protocol.HoverFeature) -> protocol.Provided
/// ```
///
pub fn capabilities(
  client: Client,
) -> Result(ServerCapabilities, RequestError) {
  read(client, CapabilitiesOf)
}

/// The LSP method a feature's request is sent as, for an `Unsupported`
/// answer worded the way the protocol names it.
///
/// ## Examples
///
/// ```gleam
/// assert client.feature_method(protocol.HoverFeature) == "textDocument/hover"
/// ```
///
pub fn feature_method(feature: Feature) -> String {
  case feature {
    protocol.DefinitionFeature -> "textDocument/definition"
    protocol.ReferencesFeature -> "textDocument/references"
    protocol.HoverFeature -> "textDocument/hover"
    protocol.DocumentSymbolFeature -> "textDocument/documentSymbol"
    protocol.RenameFeature -> "textDocument/rename"
    protocol.PrepareRenameFeature -> "textDocument/prepareRename"
    protocol.CallHierarchyFeature -> "textDocument/prepareCallHierarchy"
  }
}

// --- requests -----------------------------------------------------------------

/// Sends one request gated on `feature`, answering the raw `result`. The
/// typed helpers below are this plus a decoder; use this for a method
/// they do not cover, naming the feature that advertises it.
///
/// ## Examples
///
/// ```gleam
/// // client.request(client, protocol.HoverFeature, "textDocument/hover", Some(params), 5000)
/// // -> Ok(json.Null)
/// ```
///
pub fn request(
  client: Client,
  feature: Feature,
  method: String,
  params: Option(JsonValue),
  deadline_ms: Int,
) -> Result(JsonValue, RequestError) {
  ask(client, feature, jsonrpc.request(_, method, params), deadline_ms)
}

/// `textDocument/definition` at a position in `path`.
///
/// ## Examples
///
/// ```gleam
/// // client.definition(client, "/work/src/app.gleam", range.Position(3, 8), 5000)
/// // -> Ok([protocol.Location("file:///work/src/util.gleam", ..)])
/// ```
///
pub fn definition(
  client: Client,
  path: String,
  at: Position,
  deadline_ms: Int,
) -> Result(List(Location), RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.definition_request(_, uri, at)
  use value <- result.try(ask(
    client,
    protocol.DefinitionFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_locations(value) |> result.map_error(malformed)
}

/// `textDocument/references` at a position in `path`, the declaration
/// included.
///
/// ## Examples
///
/// ```gleam
/// // client.references(client, "/work/src/app.gleam", range.Position(3, 8), 5000)
/// ```
///
pub fn references(
  client: Client,
  path: String,
  at: Position,
  deadline_ms: Int,
) -> Result(List(Location), RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.references_request(_, uri, at)
  use value <- result.try(ask(
    client,
    protocol.ReferencesFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_locations(value) |> result.map_error(malformed)
}

/// `textDocument/hover` at a position in `path`; `None` when the server
/// has nothing to say there.
///
/// ## Examples
///
/// ```gleam
/// // client.hover(client, "/work/src/app.gleam", range.Position(3, 8), 5000)
/// ```
///
pub fn hover(
  client: Client,
  path: String,
  at: Position,
  deadline_ms: Int,
) -> Result(Option(HoverResult), RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.hover_request(_, uri, at)
  use value <- result.try(ask(client, protocol.HoverFeature, build, deadline_ms))
  protocol.decode_hover(value) |> result.map_error(malformed)
}

/// `textDocument/documentSymbol` for `path`: its outline.
///
/// ## Examples
///
/// ```gleam
/// // client.document_symbol(client, "/work/src/app.gleam", 5000)
/// ```
///
pub fn document_symbol(
  client: Client,
  path: String,
  deadline_ms: Int,
) -> Result(DocumentSymbols, RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.document_symbol_request(_, uri)
  use value <- result.try(ask(
    client,
    protocol.DocumentSymbolFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_document_symbols(value) |> result.map_error(malformed)
}

/// `textDocument/prepareRename` at a position in `path`.
///
/// ## Examples
///
/// ```gleam
/// // client.prepare_rename(client, "/work/src/app.gleam", range.Position(3, 8), 5000)
/// ```
///
pub fn prepare_rename(
  client: Client,
  path: String,
  at: Position,
  deadline_ms: Int,
) -> Result(PrepareRename, RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.prepare_rename_request(_, uri, at)
  use value <- result.try(ask(
    client,
    protocol.PrepareRenameFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_prepare_rename(value) |> result.map_error(malformed)
}

/// `textDocument/rename` at a position in `path`. The server computes the
/// edit and writes nothing; an edit carrying a file operation is refused
/// whole as `EditRefused`.
///
/// ## Examples
///
/// ```gleam
/// // client.rename(client, "/work/src/app.gleam", range.Position(3, 8), "salute", 5000)
/// ```
///
pub fn rename(
  client: Client,
  path: String,
  at: Position,
  new_name: String,
  deadline_ms: Int,
) -> Result(WorkspaceEdit, RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.rename_request(_, uri, at, new_name)
  use value <- result.try(ask(
    client,
    protocol.RenameFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_workspace_edit(value)
  |> result.map_error(fn(fault) {
    case fault {
      protocol.EditMalformed(fault:) -> malformed(fault)
      protocol.ResourceOperationRefused(kind:, uri:) -> EditRefused(kind:, uri:)
    }
  })
}

/// `textDocument/prepareCallHierarchy` at a position in `path`: the items
/// the call walks start from.
///
/// ## Examples
///
/// ```gleam
/// // client.prepare_call_hierarchy(client, "/work/main.go", range.Position(3, 5), 5000)
/// ```
///
pub fn prepare_call_hierarchy(
  client: Client,
  path: String,
  at: Position,
  deadline_ms: Int,
) -> Result(List(CallHierarchyItem), RequestError) {
  use uri <- result.try(uri_of(path))
  let build = protocol.prepare_call_hierarchy_request(_, uri, at)
  use value <- result.try(ask(
    client,
    protocol.CallHierarchyFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_call_hierarchy_items(value) |> result.map_error(malformed)
}

/// `callHierarchy/incomingCalls` for an item the server returned.
///
/// ## Examples
///
/// ```gleam
/// // client.incoming_calls(client, item, 5000)
/// ```
///
pub fn incoming_calls(
  client: Client,
  item: CallHierarchyItem,
  deadline_ms: Int,
) -> Result(List(IncomingCall), RequestError) {
  let build = protocol.incoming_calls_request(_, item)
  use value <- result.try(ask(
    client,
    protocol.CallHierarchyFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_incoming_calls(value) |> result.map_error(malformed)
}

/// `callHierarchy/outgoingCalls` for an item the server returned.
///
/// ## Examples
///
/// ```gleam
/// // client.outgoing_calls(client, item, 5000)
/// ```
///
pub fn outgoing_calls(
  client: Client,
  item: CallHierarchyItem,
  deadline_ms: Int,
) -> Result(List(OutgoingCall), RequestError) {
  let build = protocol.outgoing_calls_request(_, item)
  use value <- result.try(ask(
    client,
    protocol.CallHierarchyFeature,
    build,
    deadline_ms,
  ))
  protocol.decode_outgoing_calls(value) |> result.map_error(malformed)
}

// --- documents and diagnostics --------------------------------------------------

/// Applies document operations in order: `didOpen`, full-text
/// `didChange`, `didClose`. Every path is resolved before anything is
/// sent, so a bad path sends nothing. Answers once every notification has
/// been written.
///
/// ## Examples
///
/// ```gleam
/// // client.sync(client, [client.Change("/work/src/app.gleam", text)])
/// // -> Ok(Nil)
/// ```
///
pub fn sync(client: Client, ops: List(DocOp)) -> Result(Nil, RequestError) {
  use ops <- result.try(list.try_map(ops, resolve))
  exchange(client, local_wait_ms, Sync(ops, _)) |> result.flatten
}

/// Waits for settled diagnostics after a change to `paths` (ADR-015 §3),
/// at most `deadline_ms`. Call it after the `sync` that carried the
/// change.
///
/// ## Examples
///
/// ```gleam
/// // client.settle(client, ["/work/src/app.gleam"], 1500)
/// // -> Ok(client.Settlement(client.Settled, [#("/work/src/app.gleam", [])]))
/// ```
///
pub fn settle(
  client: Client,
  paths: List(String),
  deadline_ms: Int,
) -> Result(Settlement, RequestError) {
  use uris <- result.try(list.try_map(paths, uri_of))
  let deadline_ms = int.max(deadline_ms, 1)
  exchange(client, deadline_ms + reply_margin_ms, Settle(uris, deadline_ms, _))
  |> result.flatten
}

/// Waits until the server has reported no active work-done progress for a
/// continuous `quiet_ms`, measured from the later of this call and the
/// end of the last active token, and answers `Quiet`; or answers
/// `StillBusy` with the active titles once `deadline_ms` lapses first.
/// With `quiet_ms` 0 it answers at once when nothing is active. Ask it
/// before a query whose answer a loading server would get wrong: a server
/// may answer while loading with empty results rather than errors.
///
/// ## Examples
///
/// ```gleam
/// // client.ready(client, quiet_ms: 300, deadline_ms: 60_000)
/// // -> Ok(client.Quiet)
/// // client.ready(client, quiet_ms: 0, deadline_ms: 50)
/// // -> Ok(client.StillBusy(titles: ["Indexing"]))
/// ```
///
pub fn ready(
  client: Client,
  quiet_ms quiet_ms: Int,
  deadline_ms deadline_ms: Int,
) -> Result(Readiness, RequestError) {
  let deadline_ms = int.max(deadline_ms, 1)
  let quiet_ms = int.max(quiet_ms, 0)
  exchange(client, deadline_ms + reply_margin_ms, Ready(
    quiet_ms,
    deadline_ms,
    _,
  ))
  |> result.flatten
}

/// The latest stored publication for `path`, or for every path the
/// server has published about when `None`, sorted by path.
///
/// ## Examples
///
/// ```gleam
/// // client.diagnostics(client, None) -> Ok([#("/work/src/app.gleam", [])])
/// ```
///
pub fn diagnostics(
  client: Client,
  path: Option(String),
) -> Result(List(#(String, List(ServerDiagnostic))), RequestError) {
  use uri <- result.try(case path {
    None -> Ok(None)
    Some(path) -> result.map(uri_of(path), Some)
  })
  read(client, PublishedFor(uri, _))
}

/// The exact text last sent to the server for `path` — the rename base of
/// ADR-015 §4 — or `None` when the document is not open.
///
/// ## Examples
///
/// ```gleam
/// // client.synced_text(client, "/work/src/app.gleam") -> Ok(Some("pub fn main() { 1 }\n"))
/// ```
///
pub fn synced_text(
  client: Client,
  path: String,
) -> Result(Option(String), RequestError) {
  use uri <- result.try(uri_of(path))
  read(client, TextOf(uri, _))
}

/// Every path the server holds open, sorted. This is what the pull of
/// ADR-015 §3 re-reads before a query.
///
/// ## Examples
///
/// ```gleam
/// // client.open_paths(client) -> Ok(["/work/src/app.gleam"])
/// ```
///
pub fn open_paths(client: Client) -> Result(List(String), RequestError) {
  read(client, OpenPaths)
}

// --- the caller side ------------------------------------------------------------

// The one path every typed request takes: gate and send in the actor,
// answer back through `exchange`. The nested `Result` that `exchange`
// returns is the call's own outcome on the outside and the actor's answer
// on the inside; `result.flatten` joins them.
fn ask(
  client: Client,
  feature: Feature,
  build: fn(Id) -> JsonValue,
  deadline_ms: Int,
) -> Result(JsonValue, RequestError) {
  // Clamped: a non-positive delay would reach process.send_after, which
  // raises on negatives.
  let deadline_ms = int.max(deadline_ms, 1)
  exchange(client, deadline_ms + reply_margin_ms, Ask(
    feature,
    build,
    deadline_ms,
    _,
  ))
  |> result.flatten
}

// A read of the actor's own state. `reading` builds the `Reading` variant
// from the reply subject, so each public reader names only what it asks.
fn read(
  client: Client,
  reading: fn(Subject(Result(a, RequestError))) -> Reading,
) -> Result(a, RequestError) {
  exchange(client, local_wait_ms, fn(reply) { Read(reading(reply)) })
  |> result.flatten
}

// Every exchange goes through `lsp/call.try_call`: the caller of a query
// or a settlement holds an edit's verdict, and a dead or wedged client
// must answer `Unavailable` rather than exit the asker, which is what
// `process.call` would do.
fn exchange(
  client: Client,
  waiting: Int,
  make: fn(Subject(reply)) -> Msg,
) -> Result(reply, RequestError) {
  call.try_call(client.subject, waiting:, sending: make)
  |> result.map_error(unreachable)
}

// A failed call, not a failed request: the actor could not be reached at
// all, which the caller sees as `Unavailable`.
fn unreachable(fault: call.CallFault) -> RequestError {
  case fault {
    call.CalleeGone -> Unavailable(reason: "the lsp client is not running")
    call.NoReply -> Unavailable(reason: "the lsp client did not answer")
  }
}

// Every public function that takes a path resolves it here first, so a
// relative path is refused in the caller and never reaches the actor.
fn uri_of(path: String) -> Result(String, RequestError) {
  protocol.path_to_uri(path) |> result.replace_error(InvalidPath(path:))
}

// Resolves a document operation's path in the caller, so a bad path in a
// batch sends nothing at all.
fn resolve(op: DocOp) -> Result(Resolved, RequestError) {
  case op {
    Open(path:, language_id:, text:) -> {
      use uri <- result.map(uri_of(path))
      Opening(uri:, path:, language_id:, text:)
    }
    Change(path:, text:) -> {
      use uri <- result.map(uri_of(path))
      Changing(uri:, path:, text:)
    }
    Close(path:) -> result.map(uri_of(path), Closing)
  }
}

// A decoder's fault, as the error a caller sees. `BadResult` is the only
// `ProtocolFault`, so the plain `let` pattern below always matches.
fn malformed(fault: protocol.ProtocolFault) -> RequestError {
  let protocol.BadResult(reason:) = fault
  Malformed(reason:)
}

// Waits, bounded, for the actor to exit. A refused start and a stop both
// return only once the pid is gone, so a caller that starts a replacement
// never has two clients speaking for one root.
fn await_exit(client: Client, within: Int) -> Nil {
  let watch = process.monitor(client.owner)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_) { Nil })
    |> process.selector_receive(within)
  process.demonitor_process(watch)
  Nil
}

// --- the actor ------------------------------------------------------------------

// Starts the actor and returns its handle. The initialiser below runs in
// the new process: it builds the selector, calls `connect` there so the
// transport's events are addressed to this process, and returns the first
// phase and the empty `Data`. A selector chooses which of several message
// sources the actor listens to and maps each into `Msg`: its own command
// mailbox, the transport's events, and the owner's death.
fn spawn(
  transport_spec: Transport,
  profile: json.ParseProfile,
  options: Options,
  root_uri: String,
  folders: List(WorkspaceFolder),
) -> Result(Client, StartError) {
  let owner = process.self()
  sm.new_with_initialiser(init_timeout_ms, fn(commands) {
    // The owner's death is the one stop nobody sends, so it is watched
    // from the first instruction the actor runs.
    let inbound = process.new_subject()
    let credited = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(inbound, FromTransport)
      |> process.select_map(credited, FromConsumed)
      |> process.select_monitors(fn(down) { CallerDown(down.monitor) })
      |> process.select_specific_monitor(process.monitor(owner), fn(_) {
        Abandoned
      })

    // `connect` runs here, in the actor, so the transport's events are
    // addressed to the process that will select them.
    use connection <- result.try(case transport_spec {
      transport.ChannelTransport(connect) -> Ok(connect(inbound))
      transport.ConsumedChannelTransport(connect) -> {
        use connection <- result.map(consumed.open(connect, credited))
        transport.Connection(connection.send, connection.close)
      }
    })
    let data =
      Data(
        server: options.server,
        generation: reference.new(),
        failure_epoch: 0,
        language_id: options.language_id,
        root_uri:,
        folders:,
        initialize_ms: int.max(options.initialize_ms, 1),
        commands:,
        connection:,
        profile:,
        deferred_close: None,
        stderr_ring: <<>>,
        buffer: framing.new(),
        capabilities: nothing_advertised(),
        next_id: 1,
        pending: dict.new(),
        next_version: 1,
        documents: dict.new(),
        sequence: 0,
        versioning: Unversioned,
        publications: dict.new(),
        server_failure: None,
        next_token: 1,
        waiters: dict.new(),
        progress: dict.new(),
        next_activity: 0,
        quiet_epoch: 0,
        readiers: dict.new(),
        stoppers: [],
      )
    sm.initialised(Initializing, data)
    |> sm.selecting(selector)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.on_enter(entered)
  |> sm.unlinked
  |> sm.start
  |> result.map(fn(started) {
    Client(
      subject: started.data,
      owner: started.pid,
      request_ms: int.max(options.request_ms, 1),
    )
  })
  |> result.map_error(fn(error) {
    TransportRefused(reason: describe_start_error(error))
  })
}

// Until `initialize` answers, the server has advertised nothing, so a
// gate consulted early refuses everything rather than guessing.
fn nothing_advertised() -> ServerCapabilities {
  protocol.ServerCapabilities(
    definition: protocol.NotProvided,
    references: protocol.NotProvided,
    hover: protocol.NotProvided,
    document_symbol: protocol.NotProvided,
    rename: protocol.NoRename,
    call_hierarchy: protocol.NotProvided,
    sync: protocol.SyncNone,
    open_close: protocol.OpenCloseSilent,
    position_encoding: None,
  )
}

// Renders a failure to start the actor itself, as opposed to a failed
// handshake, which `describe_refusal` renders.
fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "the lsp client's transport did not open in time"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "the lsp client exited while opening its transport"
  }
}

// Every path into a phase arms that phase's deadline, so a phase added or
// entered from a new place later cannot forget it. A state timeout dies
// with the phase, so a grace or retirement deadline can never fire in a
// phase that did not ask for it.
fn entered(_from: Phase, to: Phase, data: Data) -> sm.Enter(Phase, Data, Msg) {
  case to {
    Initializing | Serving -> sm.keep(data)
    ShuttingDown(grace_ms:) ->
      sm.keep(data)
      |> sm.with_state_timeout(after: grace_ms, sending: GraceExpired)
    Retiring(..) ->
      sm.keep(data)
      |> sm.with_state_timeout(after: retire_ms, sending: RetireExpired)
  }
}

// The state machine's one event handler. It does nothing but choose the
// handler for the current phase, so each phase's rules read in one place.
fn handle(phase: Phase, data: Data, msg: Msg) -> sm.Next(Phase, Data, Msg) {
  case phase {
    Initializing -> initializing(data, msg)
    Serving -> serving(data, msg)
    ShuttingDown(..) -> shutting_down(phase, data, msg)
    Retiring(ending:, reason:) -> retiring(data, ending, reason, msg)
  }
}

// Before the handshake answers nobody holds a handle, so a query can only
// arrive by a race with `start` returning; it waits, postponed, for
// `Serving` (or is refused in-band by `Retiring`).
fn initializing(data: Data, msg: Msg) -> sm.Next(Phase, Data, Msg) {
  case msg {
    Handshake(reply:) -> begin_handshake(data, reply)
    HandshakeExpired -> conclude(Initializing, handshake_expired(data))
    FromConsumed(event) -> from_consumed(Initializing, data, event)
    FromTransport(transport.TransportData(bytes:)) ->
      feed(Initializing, data, bytes)
    FromTransport(transport.TransportClosed(reason:)) ->
      peer_closed(data, reason)
    Stop(reply:, ..) -> {
      let data = Data(..data, stoppers: [reply, ..data.stoppers])
      conclude(Initializing, abandon(data, "the lsp client was stopped"))
    }
    Abandoned ->
      conclude(Initializing, abandon(data, "the lsp client was abandoned"))
    Ask(..) | Sync(..) | Settle(..) | Ready(..) | Read(..) ->
      sm.keep(data) |> sm.postpone
    CallerDown(..)
    | Expire(..)
    | SettleExpired(..)
    | ReadyQuiet(..)
    | ReadyExpired(..)
    | GraceExpired
    | RetireExpired -> sm.keep(data)
  }
}

// The working phase. A request becomes a pending entry and a timer; a
// transport chunk is fed to the framer; the stop messages move the phase.
fn serving(data: Data, msg: Msg) -> sm.Next(Phase, Data, Msg) {
  case msg {
    Ask(feature:, build:, deadline_ms:, reply:) ->
      conclude(Serving, ask_server(data, feature, build, deadline_ms, reply))
    Expire(id:) -> conclude(Serving, expire(Flow(Serving, data), id))
    CallerDown(monitor:) ->
      conclude(Serving, caller_gone(Flow(Serving, data), monitor))
    Sync(ops:, reply:) -> conclude(Serving, sync_documents(data, ops, reply))
    Settle(uris:, deadline_ms:, reply:) ->
      conclude(Serving, begin_settle(data, uris, deadline_ms, reply))
    SettleExpired(token:) ->
      conclude(Serving, settle_expired(Flow(Serving, data), token))
    Ready(quiet_ms:, deadline_ms:, reply:) ->
      conclude(Serving, ready_admitted(data, quiet_ms, deadline_ms, reply))
    ReadyQuiet(token:, epoch:) -> sm.keep(quiet_lapsed(data, token, epoch))
    ReadyExpired(token:) -> sm.keep(ready_expired(data, token))
    Read(reading) -> {
      answer_read(data, reading)
      sm.keep(data)
    }
    FromConsumed(event) -> from_consumed(Serving, data, event)
    FromTransport(transport.TransportData(bytes:)) -> feed(Serving, data, bytes)
    FromTransport(transport.TransportClosed(reason:)) ->
      peer_closed(data, reason)
    Stop(grace_ms:, reply:) ->
      conclude(Serving, begin_shutdown(data, grace_ms, Some(reply)))
    Abandoned -> conclude(Serving, begin_shutdown(data, abandon_grace_ms, None))
    Handshake(reply:) -> {
      process.send(
        reply,
        Error(TransportRefused("the lsp client is already serving")),
      )
      sm.keep(data)
    }
    HandshakeExpired | GraceExpired | RetireExpired -> sm.keep(data)
  }
}

// `shutdown` is in flight. Everything a caller could want is refused:
// the server is leaving and every earlier waiter was already answered.
// Bytes are still read, because the shutdown answer is among them.
fn shutting_down(
  phase: Phase,
  data: Data,
  msg: Msg,
) -> sm.Next(Phase, Data, Msg) {
  let reason = "the lsp client is shutting down"
  case msg {
    FromConsumed(event) -> from_consumed(phase, data, event)
    FromTransport(transport.TransportData(bytes:)) -> feed(phase, data, bytes)

    // The server left before answering; the close is the witness.
    FromTransport(transport.TransportClosed(..)) ->
      witnessed(data, Requested(Forced), reason)

    GraceExpired -> conclude(phase, force_close(data))
    Stop(reply:, ..) -> join_stopper(phase, data, reply)
    Expire(id:) -> conclude(phase, expire(Flow(phase, data), id))
    Ask(..) | Sync(..) | Settle(..) | Ready(..) ->
      refuse(data, reply_of(msg), reason)
    Read(reading) -> {
      refuse_read(reading, reason)
      sm.keep(data)
    }
    Handshake(reply:) -> {
      process.send(reply, Error(TransportRefused(reason)))
      sm.keep(data)
    }
    CallerDown(..)
    | SettleExpired(..)
    | ReadyQuiet(..)
    | ReadyExpired(..)
    | Abandoned
    | HandshakeExpired
    | RetireExpired -> sm.keep(data)
  }
}

// The transport has been closed and every waiter answered. Only the
// close's witness, or the bound on waiting for it, moves the actor on.
fn retiring(
  data: Data,
  ending: Ending,
  reason: String,
  msg: Msg,
) -> sm.Next(Phase, Data, Msg) {
  case msg {
    FromConsumed(consumed.Closed(_)) -> witnessed(data, ending, reason)
    FromConsumed(consumed.Failed(_)) | FromConsumed(consumed.Output(..)) ->
      sm.keep(data)
    FromTransport(transport.TransportClosed(..)) ->
      witnessed(data, ending, reason)
    RetireExpired -> {
      list.each(data.stoppers, process.send(_, Unconfirmed))
      sm.stop_abnormal(
        "the language server's transport never confirmed its close: " <> reason,
      )
    }
    Stop(reply:, ..) -> join_stopper(Retiring(ending, reason), data, reply)
    Ask(..) | Sync(..) | Settle(..) | Ready(..) ->
      refuse(data, reply_of(msg), reason)
    Read(reading) -> {
      refuse_read(reading, reason)
      sm.keep(data)
    }
    Handshake(reply:) -> {
      process.send(reply, Error(HandshakeFailed(Unavailable(reason))))
      sm.keep(data)
    }
    FromTransport(transport.TransportData(..))
    | CallerDown(..)
    | Expire(..)
    | SettleExpired(..)
    | ReadyQuiet(..)
    | ReadyExpired(..)
    | GraceExpired
    | HandshakeExpired
    | Abandoned -> sm.keep(data)
  }
}

// The four caller messages share one refusal. Returned as a closure so
// the refusing phase does not repeat the four shapes.
fn join_stopper(
  phase: Phase,
  data: Data,
  reply: Subject(StopReport),
) -> sm.Next(Phase, Data, Msg) {
  let candidate = Data(..data, stoppers: [reply, ..data.stoppers])
  case state_bounds(candidate) {
    Ok(Nil) -> sm.keep(candidate)
    Error(reason) -> {
      process.send(reply, Unconfirmed)
      conclude(phase, fail(data, reason))
    }
  }
}

fn reply_of(msg: Msg) -> fn(RequestError) -> Nil {
  case msg {
    Ask(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Sync(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Settle(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Ready(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Handshake(..)
    | HandshakeExpired
    | CallerDown(..)
    | Expire(..)
    | SettleExpired(..)
    | ReadyQuiet(..)
    | ReadyExpired(..)
    | Read(..)
    | Stop(..)
    | GraceExpired
    | RetireExpired
    | FromTransport(..)
    | FromConsumed(..)
    | Abandoned -> fn(_) { Nil }
  }
}

fn refuse(
  data: Data,
  reply: fn(RequestError) -> Nil,
  reason: String,
) -> sm.Next(Phase, Data, Msg) {
  reply(Unavailable(reason:))
  sm.keep(data)
}

// Turns a handler's result into a step. If the phase did not change the
// actor stays put, which keeps the phase's state timeout armed; if it did,
// `sm.transition` runs `entered` for the new phase.
fn conclude(before: Phase, flow: Flow) -> sm.Next(Phase, Data, Msg) {
  let flow = case state_bounds(flow.data) {
    Ok(Nil) -> flow
    Error(reason) -> fail(flow.data, reason)
  }
  let flow = Flow(..flow, data: flush_close(flow.data))
  case flow.phase == before {
    True -> sm.keep(flow.data)
    False -> sm.transition(to: flow.phase, data: flow.data)
  }
}

// --- handshake ------------------------------------------------------------------

fn begin_handshake(
  data: Data,
  reply: Subject(Result(Nil, StartError)),
) -> sm.Next(Phase, Data, Msg) {
  let #(data, id) = mint(data, HandshakeWaits(reply:))
  let message =
    protocol.initialize_request(jsonrpc.IdInt(id), data.root_uri, data.folders)

  // The handshake deadline is a state timeout: reaching `Serving` or
  // `Retiring` cancels it, so it can never fire against a live server.
  case send(data, message) {
    Ok(Nil) ->
      sm.keep(data)
      |> sm.with_state_timeout(
        after: data.initialize_ms,
        sending: HandshakeExpired,
      )
    Error(reason) -> conclude(Initializing, fail(data, reason))
  }
}

// The handshake budget lapsed with no `initialize` answer. The starter is
// told `TimedOut`, and the client faults.
fn handshake_expired(data: Data) -> Flow {
  let data =
    dict.fold(data.pending, data, fn(data, id, pending) {
      case pending {
        HandshakeWaits(reply:) -> {
          let error = HandshakeFailed(TimedOut(after_ms: data.initialize_ms))
          process.send(reply, Error(error))
          Data(..data, pending: dict.delete(data.pending, id))
        }
        CallerWaits(..) | BarrierFor(..) | ShutdownWaits -> data
      }
    })
  fail(
    data,
    "the language server did not answer initialize within "
      <> int.to_string(data.initialize_ms)
      <> " ms",
  )
}

// The `initialize` answer arrived. On success, `initialized` is sent and
// the phase becomes `Serving`; on any failure the starter is told why and
// the client faults. The block below runs the same two fallible steps with
// `use`, so the first failure becomes `accepted`.
fn handshake_answered(
  data: Data,
  reply: Subject(Result(Nil, StartError)),
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Flow {
  let accepted = {
    use init <- result.try(accept_initialize(outcome))
    send(data, protocol.initialized())
    |> result.map(fn(_) { init })
    |> result.map_error(fn(reason) { HandshakeFailed(Unavailable(reason:)) })
  }

  // The starter learns the verdict before the phase moves, so `start`
  // returns a client that is already `Serving` or already retiring.
  process.send(reply, result.replace(accepted, Nil))
  case accepted {
    Ok(init) -> Flow(Serving, Data(..data, capabilities: init.capabilities))
    Error(error) -> fail(data, "initialize failed: " <> describe_refusal(error))
  }
}

// Decodes the `initialize` outcome, and refuses a server that chose a
// position encoding the harness cannot convert.
fn accept_initialize(
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Result(InitializeResult, StartError) {
  use value <- result.try(
    outcome
    |> result.map_error(fn(error) {
      HandshakeFailed(ServerError(code: error.code, message: error.message))
    }),
  )
  use init <- result.try(
    protocol.decode_initialize_result(value)
    |> result.map_error(fn(fault) { HandshakeFailed(malformed(fault)) }),
  )

  // UTF-16 is what the protocol means by an absent encoding, and the only
  // one `lsp/text` converts; any other choice would shift every column.
  case init.capabilities.position_encoding {
    None | Some("utf-16") -> Ok(init)
    Some(encoding) -> Error(EncodingUnsupported(encoding:))
  }
}

// The reason string a failed handshake faults the client with, which every
// other waiter is then told.
fn describe_refusal(error: StartError) -> String {
  case error {
    BadRoot(root:) -> "bad root " <> root
    TransportRefused(reason:) -> reason
    EncodingUnsupported(encoding:) ->
      "unsupported position encoding " <> encoding
    HandshakeFailed(error: ServerError(message:, ..)) -> message
    HandshakeFailed(error: Malformed(reason:)) -> reason
    HandshakeFailed(error: Unavailable(reason:)) -> reason
    HandshakeFailed(error: TimedOut(..)) -> "timed out"
    HandshakeFailed(error: Unsupported(..))
    | HandshakeFailed(error: InvalidPath(..))
    | HandshakeFailed(error: EditRefused(..)) -> "refused"
  }
}

// --- requests, in the actor -----------------------------------------------------

// The gate comes before the id: an unadvertised request is answered here
// and no byte of it reaches the server, which might never answer it.
fn ask_server(
  data: Data,
  feature: Feature,
  build: fn(Id) -> JsonValue,
  deadline_ms: Int,
  reply: Subject(Result(JsonValue, RequestError)),
) -> Flow {
  case protocol.supports(data.capabilities, feature) {
    protocol.NotProvided -> {
      process.send(reply, Error(Unsupported(feature:)))
      Flow(Serving, data)
    }
    protocol.Provided -> {
      let monitor =
        process.subject_owner(reply)
        |> result.map(process.monitor)
        |> option.from_result
      let #(data, id) =
        mint(data, CallerWaits(reply:, deadline_ms:, feature:, monitor:))

      // The id is tracked before the write, so a failed write's `fail`
      // answers this caller with every other one.
      case send(data, build(jsonrpc.IdInt(id))) {
        Ok(Nil) -> {
          process.send_after(data.commands, deadline_ms, Expire(id:))
          Flow(Serving, data)
        }
        Error(reason) -> fail(data, reason)
      }
    }
  }
}

// A request's own deadline. Per-id timers are the sanctioned per-key
// deadline table of docs/weft.md: a stale fire finds its id gone and does
// nothing. A live one answers the caller, forgets the id so a late answer
// is dropped, and tells the server to stop computing it.
fn expire(flow: Flow, id: Int) -> Flow {
  case dict.get(flow.data.pending, id) {
    Ok(CallerWaits(reply:, deadline_ms:, monitor:, ..)) -> {
      demonitor(monitor)
      process.send(reply, Error(TimedOut(after_ms: deadline_ms)))
      let data = Data(..flow.data, pending: dict.delete(flow.data.pending, id))
      cancel(Flow(..flow, data:), id)
    }
    Ok(BarrierFor(..))
    | Ok(HandshakeWaits(..))
    | Ok(ShutdownWaits)
    | Error(Nil) -> flow
  }
}

// Tells the server to stop computing a request the client has forgotten.
// A failed write is the server gone, which faults the client.
fn cancel(flow: Flow, id: Int) -> Flow {
  case send(flow.data, protocol.cancel_request(jsonrpc.IdInt(id))) {
    Ok(Nil) -> flow
    Error(reason) -> fail(flow.data, reason)
  }
}

// Takes the next id and records what its answer will do. The id is
// pending from this point, before anything is sent.
fn mint(data: Data, pending: Pending) -> #(Data, Int) {
  let id = data.next_id
  let data =
    Data(
      ..data,
      next_id: id + 1,
      pending: dict.insert(data.pending, id, pending),
    )
  #(data, id)
}

// --- inbound ----------------------------------------------------------------------

// A chunk of the server's stdout. The framer holds partial frames; each
// whole body is handled in order, and a body can move the phase (the
// shutdown answer), so the rest of the chunk is handled in the new one.
fn feed(
  phase: Phase,
  data: Data,
  bytes: BitArray,
) -> sm.Next(Phase, Data, Msg) {
  conclude(phase, feed_flow(phase, data, bytes))
}

fn feed_flow(phase: Phase, data: Data, bytes: BitArray) -> Flow {
  case framing.push(data.buffer, bytes) {
    Error(fault) ->
      fail(
        data,
        "the language server's output is not lsp framing: "
          <> describe_fault(fault),
      )
    Ok(#(buffer, bodies)) ->
      list.fold(bodies, Flow(phase, Data(..data, buffer:)), body)
  }
}

// Consumption belongs to the original client after every completed body and state
// mutation. A failure withholds the grant and closes that original attachment.
fn from_consumed(
  phase: Phase,
  data: Data,
  event: consumed.Event,
) -> sm.Next(Phase, Data, Msg) {
  case event {
    consumed.Closed(reason) -> {
      case phase {
        ShuttingDown(_) -> witnessed(data, Requested(Forced), reason)
        Initializing | Serving -> peer_closed(data, reason)
        Retiring(ending, why) -> witnessed(data, ending, why)
      }
    }
    consumed.Failed(reason) -> conclude(phase, fail(data, reason))
    consumed.Output(stream, bytes, grant) -> {
      let flow = case stream {
        consumed.Stdout -> feed_flow(phase, data, bytes)
        consumed.Stderr -> {
          let combined = bit_array.append(data.stderr_ring, bytes)
          let size = bit_array.byte_size(combined)
          let kept = int.min(size, 8192)
          let ring =
            bit_array.slice(combined, size - kept, kept)
            |> result.lazy_unwrap(fn() { <<>> })
          Flow(phase, Data(..data, stderr_ring: ring))
        }
      }
      let checked = case flow.phase {
        Retiring(Faulted, reason) -> Error(reason)
        Initializing | Serving | ShuttingDown(_) | Retiring(Requested(_), _) ->
          state_bounds(flow.data)
      }
      let checked = checked |> result.try(fn(_) { consumed.consume(grant) })
      case checked {
        Ok(Nil) -> conclude(phase, flow)
        Error(reason) -> conclude(phase, fail(flow.data, reason))
      }
    }
  }
}

fn body(flow: Flow, text: String) -> Flow {
  case flow.phase {
    // A faulted client drains the rest of the chunk without acting on it.
    Retiring(Faulted, _) -> flow
    Retiring(Requested(_), _) -> {
      case flow.data.profile {
        json.StandardJson -> flow
        json.RegisteredLspJson -> {
          case jsonrpc.decode_profile(text, flow.data.profile) {
            Ok(_) -> flow
            Error(_) ->
              fail(flow.data, "trailing consumed output is not JSON-RPC")
          }
        }
      }
    }
    Initializing | Serving | ShuttingDown(..) -> message(flow, text)
  }
}

// One whole message. A body that is not JSON-RPC is transport-fatal: the
// stream can no longer be trusted to carry the answers callers wait on.
// A well-formed message the client does not act on is dropped.
fn message(flow: Flow, text: String) -> Flow {
  case jsonrpc.decode_profile(text, flow.data.profile) {
    Error(jsonrpc.MalformedMessage(report:)) ->
      fail(
        flow.data,
        "the language server sent a body that is not json: "
          <> corruption.describe(report),
      )
    Error(jsonrpc.BadMessage(reason:)) ->
      fail(
        flow.data,
        "the language server sent a body that is not json-rpc: wanted "
          <> reason,
      )
    Ok(jsonrpc.Response(id:, outcome:)) -> response(flow, id, outcome)
    Ok(jsonrpc.ServerRequest(id:, method:, params:)) ->
      answer_server(flow, id, method, params)
    Ok(jsonrpc.Notification(method:, params:)) ->
      case checked_notification(flow.data, method, params) {
        Ok(data) -> Flow(..flow, data:)
        Error(reason) -> fail(flow.data, reason)
      }
  }
}

// Correlation is by the exact minted integer. A string id was never
// minted here, and an id no longer pending — expired, cancelled, settled
// by a death — is a late answer nobody reads.
fn response(
  flow: Flow,
  id: Id,
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Flow {
  case id {
    jsonrpc.IdString(..) -> flow
    jsonrpc.IdInt(value:) ->
      case dict.get(flow.data.pending, value) {
        Error(Nil) -> flow
        Ok(pending) -> {
          let pending_now = dict.delete(flow.data.pending, value)
          let flow = Flow(..flow, data: Data(..flow.data, pending: pending_now))
          answered(flow, pending, outcome)
        }
      }
  }
}

fn answered(
  flow: Flow,
  pending: Pending,
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Flow {
  case pending {
    CallerWaits(reply:, feature:, monitor:, ..) -> {
      demonitor(monitor)
      let answered = result.map_error(outcome, server_error)
      let #(data, answered) = semantic_answer(flow.data, feature, answered)
      process.send(reply, answered)
      Flow(..flow, data:)
    }

    // Any answer, an error included, proves the server processed every
    // notification sent before the barrier: that is rule (a).
    BarrierFor(token:) -> Flow(..flow, data: barrier_answered(flow.data, token))

    HandshakeWaits(reply:) -> handshake_answered(flow.data, reply, outcome)
    ShutdownWaits -> acknowledged(flow.data)
  }
}

// An empty result is ambiguous after a server-reported load failure. A
// substantive result is evidence that analysis recovered; it retires the
// retained error so later legitimate misses remain ordinary empty answers.
fn semantic_answer(
  data: Data,
  feature: Feature,
  outcome: Result(JsonValue, RequestError),
) -> #(Data, Result(JsonValue, RequestError)) {
  case outcome, data.server_failure {
    Error(_), _ | Ok(_), None -> #(data, outcome)
    Ok(json.Array([_, ..])), Some(_)
      if feature == protocol.CallHierarchyFeature
    -> #(data, outcome)
    Ok(value), Some(reason) ->
      case substantive(feature, value) {
        True -> #(Data(..data, server_failure: None), outcome)
        False -> #(data, Error(Unavailable(reason:)))
      }
  }
}

// Recovery needs a decoded semantic result, not merely a non-null JSON
// object. Hover and rename both encode legitimate empty answers as objects.
// Call hierarchy shares one capability across three different decoders.
// Its nonempty replies reach the method-specific decoder without clearing
// the failure; another semantic query must establish recovery.
fn substantive(feature: Feature, value: JsonValue) -> Bool {
  case feature {
    protocol.DefinitionFeature | protocol.ReferencesFeature ->
      case protocol.decode_locations(value) {
        Ok(locations) -> !list.is_empty(locations)
        Error(_) -> False
      }
    protocol.HoverFeature ->
      case protocol.decode_hover(value) {
        Ok(Some(hover)) -> string.trim(hover.contents) != ""
        Ok(None) | Error(_) -> False
      }
    protocol.DocumentSymbolFeature ->
      case protocol.decode_document_symbols(value) {
        Ok(protocol.Hierarchical(symbols)) -> !list.is_empty(symbols)
        Ok(protocol.Flat(symbols)) -> !list.is_empty(symbols)
        Error(_) -> False
      }
    protocol.RenameFeature ->
      case protocol.decode_workspace_edit(value) {
        Ok(edit) ->
          list.any(edit.documents, fn(document) {
            !list.is_empty(document.edits)
          })
        Error(_) -> False
      }
    protocol.PrepareRenameFeature ->
      case protocol.decode_prepare_rename(value) {
        Ok(protocol.CanRename(..)) | Ok(protocol.CanRenameDefault) -> True
        Ok(protocol.CannotRename) | Error(_) -> False
      }
    protocol.CallHierarchyFeature -> False
  }
}

// A JSON-RPC error object as the `ServerError` a caller sees.
fn server_error(error: jsonrpc.RpcError) -> RequestError {
  ServerError(code: error.code, message: error.message)
}

// A request the server sent us is answered at once from the pure policy
// in `protocol.answer_server_request`: configuration nulls, folders,
// `applied: false`, method-not-found. The actor decides nothing.
fn answer_server(
  flow: Flow,
  id: Id,
  method: String,
  params: Option(JsonValue),
) -> Flow {
  let answer = case
    protocol.answer_server_request(method, params, flow.data.folders)
  {
    Ok(value) -> jsonrpc.response(id, value)
    Error(error) -> jsonrpc.error_response(Some(id), error)
  }
  case send(flow.data, answer) {
    Ok(Nil) -> flow
    Error(reason) -> fail(flow.data, reason)
  }
}

// Ordinary channels retain their prior malformed-notification behavior. The
// Registered path refuses malformed or oversized evidence before its state or
// settlement changes, so discarded diagnostics cannot become a clean result.
fn checked_notification(
  data: Data,
  method: String,
  params: Option(JsonValue),
) -> Result(Data, String) {
  case data.profile {
    json.StandardJson -> Ok(notification(data, method, params))
    json.RegisteredLspJson -> {
      use classified <- result.try(
        protocol.classify_notification(method, params)
        |> result.replace_error("malformed Registered LSP notification"),
      )
      case classified {
        protocol.Published(published) -> {
          use <- bool.guard(
            when: !list.is_empty(list.drop(
              published.diagnostics,
              max_diagnostics_per_uri,
            )),
            return: Error("Registered diagnostics exceed the per-URI count"),
          )
          use Nil <- result.try(registered_diagnostic_numbers(published))
          use <- bool.guard(
            when: !dict.has_key(data.publications, published.uri)
              && dict.size(data.publications) >= max_published_uris,
            return: Error("Registered diagnostics exceed the URI count"),
          )
          use _ <- result.try(
            protocol.uri_to_path(published.uri)
            |> result.replace_error(
              "Registered diagnostics have an invalid local URI",
            ),
          )
          let next = record(data, published)
          use Nil <- result.try(state_bounds(next))
          Ok(release_settled(next))
        }
        protocol.Progressed(progress) -> {
          let candidate = progress_candidate(data, progress)
          use <- bool.guard(
            when: dict.size(candidate.progress) > max_progress_tokens,
            return: Error("Registered progress exceeds the token count"),
          )
          use Nil <- result.try(state_bounds(candidate))
          Ok(progressed(data, progress))
        }
        protocol.ServerFailure(message) -> {
          let next =
            Data(
              ..data,
              server_failure: Some(server_failure(message)),
              failure_epoch: data.failure_epoch + 1,
            )
          use Nil <- result.try(state_bounds(next))
          Ok(next)
        }
        protocol.Ignored(_) | protocol.Unrecognised(_) -> Ok(data)
      }
    }
  }
}

// The fixed publication/site charges cover bounded LSP integers, not arbitrary
// precision values admitted by the shared ordinary decoder. Registered retention
// applies the protocol's uinteger positions and signed integer publication version
// before record or settlement can retain them or acknowledge the output.
fn registered_diagnostic_numbers(
  published: protocol.PublishDiagnostics,
) -> Result(Nil, String) {
  let version_valid = case published.version {
    None -> True
    Some(version) -> version >= -2_147_483_648 && version <= 2_147_483_647
  }
  let ranges_valid =
    list.all(published.diagnostics, fn(diagnostic) {
      let start = diagnostic.range.start
      let end = diagnostic.range.end
      start.line >= 0
      && start.line <= 2_147_483_647
      && start.character >= 0
      && start.character <= 2_147_483_647
      && end.line >= 0
      && end.line <= 2_147_483_647
      && end.character >= 0
      && end.character <= 2_147_483_647
    })
  use <- bool.guard(
    when: !version_valid || !ranges_valid,
    return: Error("Registered diagnostics exceed the LSP integer ranges"),
  )
  Ok(Nil)
}

// Candidate progress preserves the count and bytes before any readiness reply.
fn progress_candidate(data: Data, progress: protocol.WorkDoneProgress) -> Data {
  case progress {
    protocol.ProgressBegin(token, title) ->
      Data(
        ..data,
        progress: dict.insert(
          data.progress,
          token,
          Activity(title, data.next_activity),
        ),
      )
    protocol.ProgressReport(token) -> {
      case dict.has_key(data.progress, token) {
        True -> data
        False ->
          Data(
            ..data,
            progress: dict.insert(
              data.progress,
              token,
              Activity(token_text(token), data.next_activity),
            ),
          )
      }
    }
    protocol.ProgressEnd(token) ->
      Data(..data, progress: dict.delete(data.progress, token))
  }
}

fn notification(data: Data, method: String, params: Option(JsonValue)) -> Data {
  case protocol.classify_notification(method, params) {
    Ok(protocol.Published(diagnostics:)) ->
      release_settled(record(data, diagnostics))
    Ok(protocol.Progressed(progress:)) -> progressed(data, progress)
    Ok(protocol.ServerFailure(message:)) ->
      Data(
        ..data,
        server_failure: Some(server_failure(message)),
        failure_epoch: data.failure_epoch + 1,
      )
    Ok(protocol.Ignored(..)) | Ok(protocol.Unrecognised(..)) | Error(..) -> data
  }
}

// Retain bytes, not grapheme count: a single grapheme may contain an
// arbitrarily long sequence of combining marks. Invalid truncated UTF-8
// keeps a fixed explanation rather than retaining the oversized original.
fn server_failure(message: String) -> String {
  let bytes = bit_array.from_string(message)
  let length = int.min(bit_array.byte_size(bytes), 2048)
  let bounded =
    bit_array.slice(bytes, 0, length)
    |> result.try(bit_array.to_string)
    |> result.unwrap("server error message was truncated at 2048 bytes")
  "the language server reported an error: " <> bounded
}

// --- documents ------------------------------------------------------------------

// Applies a batch of resolved operations in order, stopping at the first
// failed write. Success answers the caller once every notification has
// been written; the server is not asked whether it accepted them.
fn sync_documents(
  data: Data,
  ops: List(Resolved),
  reply: Subject(Result(Nil, RequestError)),
) -> Flow {
  case list.try_fold(ops, data, apply_op) {
    Ok(synced) -> {
      process.send(reply, Ok(Nil))
      Flow(Serving, synced)
    }

    // Only a failed write stops a sync, and a failed write is the server
    // gone; the documents it half-sent die with the transport.
    Error(reason) -> {
      process.send(reply, Error(Unavailable(reason:)))
      fail(data, reason)
    }
  }
}

// One resolved operation. A `Change` to a document the server does not
// hold becomes an open, with the options' language id.
fn apply_op(data: Data, op: Resolved) -> Result(Data, String) {
  case op {
    Opening(uri:, path:, language_id:, text:) ->
      open_or_change(data, uri, path, language_id, text)
    Changing(uri:, path:, text:) ->
      open_or_change(data, uri, path, data.language_id, text)
    Closing(uri:) -> close_document(data, uri)
  }
}

// Full-text sync either way: a document the server holds gets a
// `didChange`, any other a `didOpen` (after making room under the
// bound). Both record the exact text sent, the rename base.
fn open_or_change(
  data: Data,
  uri: String,
  path: String,
  language_id: String,
  text: String,
) -> Result(Data, String) {
  let version = data.next_version
  let data = Data(..data, next_version: version + 1)
  let document = Document(path:, version:, text:, mark: data.sequence)
  let proposed =
    Data(..data, documents: dict.insert(data.documents, uri, document))
  use Nil <- result.try(state_bounds(proposed))
  use data <- result.try(case dict.has_key(data.documents, uri) {
    True -> {
      use Nil <- result.map(send(data, protocol.did_change(uri, version, text)))
      data
    }
    False -> {
      use data <- result.try(make_room(data))
      use Nil <- result.map(send(
        data,
        protocol.did_open(uri, language_id, version, text),
      ))
      data
    }
  })
  Ok(Data(..data, documents: dict.insert(data.documents, uri, document)))
}

// Closing a document that is not open does nothing, so a repeated close
// from the caller sends nothing.
fn close_document(data: Data, uri: String) -> Result(Data, String) {
  case dict.has_key(data.documents, uri) {
    False -> Ok(data)
    True -> {
      use Nil <- result.map(send(data, protocol.did_close(uri)))
      Data(..data, documents: dict.delete(data.documents, uri))
    }
  }
}

// The 64-document bound. The least recently synced document holds the
// smallest version, because versions come from one shared counter; it is
// closed on the server and forgotten here, and the server reads it from
// disk if it needs it again.
fn make_room(data: Data) -> Result(Data, String) {
  case dict.size(data.documents) < max_open_documents {
    True -> Ok(data)
    False ->
      case least_recent(data.documents) {
        None -> Ok(data)
        Some(uri) -> close_document(data, uri)
      }
  }
}

// The URI with the smallest version, which is the document synced longest
// ago. Folding keeps one candidate, the smallest seen so far.
fn least_recent(documents: Dict(String, Document)) -> Option(String) {
  dict.fold(documents, None, fn(oldest, uri, document) {
    case oldest {
      Some(#(_, version)) if version <= document.version -> oldest
      Some(_) | None -> Some(#(uri, document.version))
    }
  })
  |> option.map(fn(oldest) { oldest.0 })
}

// --- diagnostics and settlement -----------------------------------------------------

// Stores one publication as the latest for its URI, under both bounds. A
// URI that is not a local file names nothing a caller can ask about and
// is dropped.
fn record(data: Data, published: PublishDiagnostics) -> Data {
  case protocol.uri_to_path(published.uri) {
    Error(..) -> data
    Ok(path) -> {
      let sequence = data.sequence + 1
      let publication =
        Publication(
          path:,
          version: published.version,
          diagnostics: list.take(published.diagnostics, max_diagnostics_per_uri),
          sequence:,
        )
      let versioning = case published.version {
        Some(..) -> Versioned
        None -> data.versioning
      }
      let publications =
        room_for_publication(data.publications, published.uri)
        |> dict.insert(published.uri, publication)
      Data(..data, sequence:, versioning:, publications:)
    }
  }
}

// Makes room for one more URI under `max_published_uris` by dropping the
// oldest publication. A URI already stored is replaced in place, so it
// never evicts anything.
fn room_for_publication(
  publications: Dict(String, Publication),
  uri: String,
) -> Dict(String, Publication) {
  let full = dict.size(publications) >= max_published_uris
  case full && !dict.has_key(publications, uri) {
    False -> publications
    True -> {
      let oldest =
        dict.fold(publications, None, fn(oldest, uri, publication) {
          case oldest {
            Some(#(_, sequence)) if sequence <= publication.sequence -> oldest
            Some(_) | None -> Some(#(uri, publication.sequence))
          }
        })
      case oldest {
        None -> publications
        Some(#(uri, _)) -> dict.delete(publications, uri)
      }
    }
  }
}

// A settlement starts from the earliest sync of any changed document, so
// a publication that raced ahead of the `settle` call — `gleam lsp`
// publishes as soon as it has rechecked — is still "since the change".
fn begin_settle(
  data: Data,
  uris: List(String),
  deadline_ms: Int,
  reply: Subject(Result(Settlement, RequestError)),
) -> Flow {
  let token = data.next_token
  let data = Data(..data, next_token: token + 1)
  let targets =
    list.map(uris, fn(uri) {
      let version =
        dict.get(data.documents, uri)
        |> option.from_result
        |> option.map(fn(document) { document.version })
      Target(uri:, version:)
    })

  let candidate =
    Data(
      ..data,
      waiters: dict.insert(
        data.waiters,
        token,
        Waiter(reply, change_mark(data, uris), targets, BarrierUnavailable),
      ),
    )
  case state_bounds(candidate) {
    Error(reason) -> {
      process.send(reply, Error(Unavailable(reason)))
      fail(data, reason)
    }
    Ok(Nil) -> settle_admitted(data, uris, token, targets, deadline_ms, reply)
  }
}

fn settle_admitted(
  data: Data,
  uris: List(String),
  token: Int,
  targets: List(Target),
  deadline_ms: Int,
  reply: Subject(Result(Settlement, RequestError)),
) -> Flow {
  case open_barrier(data, uris, token) {
    Error(reason) -> {
      process.send(reply, Error(Unavailable(reason:)))
      fail(data, reason)
    }
    Ok(#(data, barrier)) -> {
      let waiter =
        Waiter(reply:, mark: change_mark(data, uris), targets:, barrier:)
      let data = Data(..data, waiters: dict.insert(data.waiters, token, waiter))

      // Armed before the check, so a settlement that holds already is
      // released now and its timer fires stale.
      process.send_after(data.commands, deadline_ms, SettleExpired(token:))
      Flow(Serving, release_settled(data))
    }
  }
}

// The earliest sync mark among the changed documents; a URI that is not
// open contributes nothing, so the mark never rises above the sequence.
fn change_mark(data: Data, uris: List(String)) -> Int {
  list.fold(uris, data.sequence, fn(mark, uri) {
    case dict.get(data.documents, uri) {
      Ok(document) -> int.min(mark, document.mark)
      Error(Nil) -> mark
    }
  })
}

// The barrier goes on the first changed URI: any request would order the
// server's queue, and `documentSymbol` is the one every measured server
// answers cheaply.
fn open_barrier(
  data: Data,
  uris: List(String),
  token: Int,
) -> Result(#(Data, Barrier), String) {
  let advertised =
    protocol.supports(data.capabilities, protocol.DocumentSymbolFeature)
  case uris, advertised {
    [], _ -> Ok(#(data, BarrierPassed))
    [_, ..], protocol.NotProvided -> Ok(#(data, BarrierUnavailable))
    [first, ..], protocol.Provided -> {
      let #(data, id) = mint(data, BarrierFor(token:))
      use Nil <- result.map(send(
        data,
        protocol.document_symbol_request(jsonrpc.IdInt(id), first),
      ))
      #(data, BarrierAwaiting(id:))
    }
  }
}

// The `documentSymbol` barrier answered for the waiter holding `token`.
// An unknown token is a waiter that already expired, and is ignored.
fn barrier_answered(data: Data, token: Int) -> Data {
  case dict.get(data.waiters, token) {
    Error(Nil) -> data
    Ok(waiter) -> {
      let waiter = Waiter(..waiter, barrier: BarrierPassed)
      release_settled(
        Data(..data, waiters: dict.insert(data.waiters, token, waiter)),
      )
    }
  }
}

// Every event that can complete a settlement — a barrier's answer, a
// publication, a new waiter — ends here, and every waiter whose two
// rules now hold is answered and forgotten. Its timer then fires stale.
fn release_settled(data: Data) -> Data {
  dict.fold(data.waiters, data, fn(data, token, waiter) {
    case settled(data, waiter) {
      False -> data
      True -> {
        let settlement = case data.server_failure {
          None -> Ok(Settlement(Settled, collect(data, waiter)))
          Some(reason) -> Error(Unavailable(reason:))
        }
        process.send(waiter.reply, settlement)
        Data(..data, waiters: dict.delete(data.waiters, token))
      }
    }
  })
}

// ADR-015 §3. Rule (a): the barrier answered. Rule (b): once this server
// has ever versioned a publication, every changed document has one at
// least as new as its synced version. A server with no barrier and no
// versions can never settle; it answers at the deadline instead.
fn settled(data: Data, waiter: Waiter) -> Bool {
  case waiter.barrier, data.versioning {
    BarrierAwaiting(..), _ -> False
    BarrierUnavailable, Unversioned -> False
    BarrierPassed, Unversioned -> True
    BarrierPassed, Versioned | BarrierUnavailable, Versioned ->
      list.all(waiter.targets, caught_up(data, _))
  }
}

// Whether a changed document's diagnostics have reached the version that
// was synced. A document that is not open has no version to reach.
fn caught_up(data: Data, target: Target) -> Bool {
  case target.version, dict.get(data.publications, target.uri) {
    None, _ -> True
    Some(wanted), Ok(Publication(version: Some(seen), ..)) -> seen >= wanted
    Some(_), Ok(Publication(version: None, ..)) | Some(_), Error(Nil) -> False
  }
}

// The deadline answers with what arrived and withdraws the barrier: the
// server is told to stop computing it, and its late answer finds no id.
fn settle_expired(flow: Flow, token: Int) -> Flow {
  case dict.get(flow.data.waiters, token) {
    Error(Nil) -> flow
    Ok(waiter) -> {
      let settlement = case flow.data.server_failure {
        Some(reason) -> Error(Unavailable(reason:))
        None -> Ok(Settlement(DeadlineExpired, collect(flow.data, waiter)))
      }
      process.send(waiter.reply, settlement)
      let data =
        Data(..flow.data, waiters: dict.delete(flow.data.waiters, token))
      case waiter.barrier {
        BarrierAwaiting(id:) -> {
          let data = Data(..data, pending: dict.delete(data.pending, id))
          cancel(Flow(..flow, data:), id)
        }
        BarrierPassed | BarrierUnavailable -> Flow(..flow, data:)
      }
    }
  }
}

// The answer to a settlement: every URI published after the waiter's mark,
// plus each changed URI's stored publication, as `#(path, diagnostics)`
// sorted by path.
fn collect(
  data: Data,
  waiter: Waiter,
) -> List(#(String, List(ServerDiagnostic))) {
  dict.to_list(data.publications)
  |> list.filter(fn(entry) {
    let #(uri, publication) = entry
    publication.sequence > waiter.mark
    || list.any(waiter.targets, fn(target) { target.uri == uri })
  })
  |> list.map(fn(entry) { #({ entry.1 }.path, { entry.1 }.diagnostics) })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

// --- readiness ----------------------------------------------------------------------

// A readiness waiter arrives. With nothing active and no window to wait,
// it is answered now and arms nothing. Otherwise its deadline is armed,
// and — when nothing is active — its quiet window too, from this call; if
// something is active the window is armed later, when the set empties.
fn ready_admitted(
  data: Data,
  quiet_ms: Int,
  deadline_ms: Int,
  reply: Subject(Result(Readiness, RequestError)),
) -> Flow {
  let candidate =
    Data(
      ..data,
      readiers: dict.insert(
        data.readiers,
        data.next_token,
        Readier(reply, quiet_ms),
      ),
    )
  case state_bounds(candidate) {
    Ok(Nil) -> Flow(Serving, begin_ready(data, quiet_ms, deadline_ms, reply))
    Error(reason) -> {
      process.send(reply, Error(Unavailable(reason)))
      fail(data, reason)
    }
  }
}

fn begin_ready(
  data: Data,
  quiet_ms: Int,
  deadline_ms: Int,
  reply: Subject(Result(Readiness, RequestError)),
) -> Data {
  let idle = dict.is_empty(data.progress)
  case idle && quiet_ms == 0 {
    True -> {
      process.send(reply, Ok(Quiet))
      data
    }
    False -> {
      let token = data.next_token
      let readiers =
        dict.insert(data.readiers, token, Readier(reply:, quiet_ms:))
      process.send_after(data.commands, deadline_ms, ReadyExpired(token:))
      case idle {
        True -> arm_quiet(token, quiet_ms, data)
        False -> Nil
      }
      Data(..data, next_token: token + 1, readiers:)
    }
  }
}

// Starts a quiet window under the current epoch. The epoch it carries is
// what lets `quiet_lapsed` tell a window that stayed empty from one that
// was interrupted.
fn arm_quiet(token: Int, quiet_ms: Int, data: Data) -> Nil {
  process.send_after(
    data.commands,
    quiet_ms,
    ReadyQuiet(token:, epoch: data.quiet_epoch),
  )
  Nil
}

// A quiet window lapsed. The epoch it was armed under is the proof: the
// window was armed only while the set was empty, and every change to the
// set moves the epoch, so an unmoved epoch means nothing was active for
// the whole window. A moved one means a later window, armed when the set
// last emptied, is the one that counts.
fn quiet_lapsed(data: Data, token: Int, epoch: Int) -> Data {
  case dict.get(data.readiers, token), epoch == data.quiet_epoch {
    Ok(readier), True -> {
      process.send(readier.reply, Ok(Quiet))
      Data(..data, readiers: dict.delete(data.readiers, token))
    }
    Ok(_), False | Error(Nil), _ -> data
  }
}

// The deadline lapsed first. The caller hears what is still running, so
// its refusal can name the work rather than guess at it.
fn ready_expired(data: Data, token: Int) -> Data {
  case dict.get(data.readiers, token) {
    Error(Nil) -> data
    Ok(readier) -> {
      process.send(readier.reply, Ok(StillBusy(titles: active_titles(data))))
      Data(..data, readiers: dict.delete(data.readiers, token))
    }
  }
}

// The titles of the tokens still active, oldest first, as a caller's
// message names the work that kept the server busy.
fn active_titles(data: Data) -> List(String) {
  dict.values(data.progress)
  |> list.sort(fn(left, right) { int.compare(left.order, right.order) })
  |> list.map(fn(activity) { activity.title })
}

// One work-done progress notification. A `begin` or an unknown token's
// `report` adds the token, since a server may report before the `begin`
// reaches us or never send one; an `end` removes it. Only a change to the
// set moves the epoch, and a set that has just emptied starts every
// waiter's quiet window from now.
fn progressed(data: Data, progress: protocol.WorkDoneProgress) -> Data {
  case progress {
    protocol.ProgressBegin(token:, title:) ->
      case dict.get(data.progress, token) {
        Ok(activity) -> {
          let activity = Activity(..activity, title:)
          Data(..data, progress: dict.insert(data.progress, token, activity))
        }
        Error(Nil) -> activate(data, token, title)
      }
    protocol.ProgressReport(token:) ->
      case dict.has_key(data.progress, token) {
        True -> data
        False -> activate(data, token, token_text(token))
      }
    protocol.ProgressEnd(token:) ->
      case dict.has_key(data.progress, token) {
        False -> data
        True -> moved(Data(..data, progress: dict.delete(data.progress, token)))
      }
  }
}

// Adds a token under the `max_progress_tokens` bound, evicting the one
// that began earliest when the set is full.
fn activate(data: Data, token: protocol.ProgressToken, title: String) -> Data {
  let order = data.next_activity
  let room = case dict.size(data.progress) >= max_progress_tokens {
    False -> data.progress
    True -> evict_oldest(data.progress)
  }
  let progress = dict.insert(room, token, Activity(title:, order:))
  moved(Data(..data, progress:, next_activity: order + 1))
}

// Drops the token that began earliest, by arrival count.
fn evict_oldest(
  progress: Dict(protocol.ProgressToken, Activity),
) -> Dict(protocol.ProgressToken, Activity) {
  let oldest =
    dict.fold(progress, None, fn(oldest, token, activity) {
      case oldest {
        Some(#(_, order)) if order <= activity.order -> oldest
        Some(_) | None -> Some(#(token, activity.order))
      }
    })
  case oldest {
    None -> progress
    Some(#(token, _)) -> dict.delete(progress, token)
  }
}

// The set of active tokens changed. The epoch moves, so every quiet
// window armed before now fires stale; and if the set is now empty, each
// waiter's window starts again from here — at once for one that asked
// for no window at all.
fn moved(data: Data) -> Data {
  let data = Data(..data, quiet_epoch: data.quiet_epoch + 1)
  case dict.is_empty(data.progress) {
    False -> data
    True ->
      dict.fold(data.readiers, data, fn(data, token, readier) {
        case readier.quiet_ms {
          0 -> {
            process.send(readier.reply, Ok(Quiet))
            Data(..data, readiers: dict.delete(data.readiers, token))
          }
          quiet_ms -> {
            arm_quiet(token, quiet_ms, data)
            data
          }
        }
      })
  }
}

// A token named for a caller's message when no `begin` gave it a title.
fn token_text(token: protocol.ProgressToken) -> String {
  case token {
    protocol.IntToken(value:) -> int.to_string(value)
    protocol.StringToken(value:) -> value
  }
}

// Answers a read from the actor's state. Nothing here reaches the server.
fn answer_read(data: Data, reading: Reading) -> Nil {
  case reading {
    TextOf(uri:, reply:) -> {
      let text =
        dict.get(data.documents, uri)
        |> option.from_result
        |> option.map(fn(document) { document.text })
      process.send(reply, Ok(text))
    }
    OpenPaths(reply:) -> {
      let paths = list.map(dict.values(data.documents), fn(doc) { doc.path })
      process.send(reply, Ok(list.sort(paths, string.compare)))
    }
    PublishedFor(uri:, reply:) -> {
      let wanted = fn(entry: #(String, Publication)) {
        option.unwrap(option.map(uri, fn(uri) { uri == entry.0 }), True)
      }
      let published =
        dict.to_list(data.publications)
        |> list.filter(wanted)
        |> list.map(fn(entry) { #({ entry.1 }.path, { entry.1 }.diagnostics) })
        |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
      let outcome = case data.server_failure {
        None -> Ok(published)
        Some(reason) -> Error(Unavailable(reason:))
      }
      process.send(reply, outcome)
    }
    CapabilitiesOf(reply:) -> process.send(reply, Ok(data.capabilities))
    Observed(reply:) -> {
      let documents =
        list.map(dict.values(data.documents), fn(doc) {
          ObservedDocument(path: doc.path, version: doc.version, text: doc.text)
        })
      let state =
        ObservationState(
          generation: data.generation,
          revision: data.next_version,
          activity_epoch: data.quiet_epoch,
          failure_epoch: data.failure_epoch,
          failure: data.server_failure,
          busy: list.map(dict.values(data.progress), fn(activity) {
            activity.title
          }),
          documents:,
        )
      process.send(reply, Ok(state))
    }
  }
}

// Answers a read the phase refuses, with the phase's reason.
fn refuse_read(reading: Reading, reason: String) -> Nil {
  let error = Unavailable(reason:)
  case reading {
    TextOf(reply:, ..) -> process.send(reply, Error(error))
    OpenPaths(reply:) -> process.send(reply, Error(error))
    PublishedFor(reply:, ..) -> process.send(reply, Error(error))
    CapabilitiesOf(reply:) -> process.send(reply, Error(error))
    Observed(reply:) -> process.send(reply, Error(error))
  }
}

// --- stopping and dying ---------------------------------------------------------

// A requested stop settles every waiter first: the server is leaving,
// and nobody should wait out a deadline for an answer it will not send.
// Then `shutdown` goes out and the grace starts, armed by `entered`.
fn begin_shutdown(
  data: Data,
  grace_ms: Int,
  stopper: Option(Subject(StopReport)),
) -> Flow {
  let data = settle_all(data, "the lsp client is shutting down")
  let stoppers = case stopper {
    Some(stopper) -> [stopper, ..data.stoppers]
    None -> data.stoppers
  }
  let #(data, id) = mint(Data(..data, stoppers:), ShutdownWaits)
  case send(data, protocol.shutdown_request(jsonrpc.IdInt(id))) {
    Ok(Nil) -> Flow(ShuttingDown(grace_ms: int.max(grace_ms, 1)), data)
    Error(reason) -> Flow(Retiring(Requested(Forced), reason), close(data))
  }
}

// The server answered `shutdown`, so `exit` is what it waits for. A
// failed `exit` write means it already left; the close follows either way.
fn acknowledged(data: Data) -> Flow {
  let _ = send(data, protocol.exit())
  Flow(Retiring(Requested(Graceful), "the lsp client was stopped"), close(data))
}

// The grace lapsed. `exit` is still sent — a server that merely missed
// the grace may honour it — and the transport is closed regardless.
fn force_close(data: Data) -> Flow {
  let _ = send(data, protocol.exit())
  Flow(
    Retiring(Requested(Forced), "the language server ignored shutdown"),
    close(data),
  )
}

// Stopped or abandoned before the handshake finished: there is no server
// state worth a graceful `shutdown`, so the transport closes at once.
fn abandon(data: Data, reason: String) -> Flow {
  let data = settle_all(data, reason)
  Flow(Retiring(Requested(Forced), reason), close(data))
}

// The transport itself reported the close while the client was working:
// the server died. The close is the witness, so the actor settles every
// waiter and exits at once, abnormally, for the manager's monitor.
// The server's end of the transport closed while the client was working.
// `inert_connection` is swapped in first so that answering the waiters
// writes nothing to a closed peer.
fn peer_closed(data: Data, reason: String) -> sm.Next(Phase, Data, Msg) {
  let reason = "the language server exited: " <> reason
  let _ = settle_all(Data(..data, connection: inert_connection()), reason)
  sm.stop_abnormal(reason)
}

// The transport confirmed its close. A requested stop reports what it
// recorded and exits normally; a fault reports `Forced` and exits
// abnormally with the original reason.
fn witnessed(
  data: Data,
  ending: Ending,
  reason: String,
) -> sm.Next(Phase, Data, Msg) {
  case ending {
    Requested(report:) -> {
      list.each(data.stoppers, process.send(_, report))
      sm.stop()
    }
    Faulted -> {
      list.each(data.stoppers, process.send(_, Forced))
      sm.stop_abnormal(reason)
    }
  }
}

// A fault: every waiter is answered with the reason, the transport is
// closed, and the client retires to await the close's witness.
fn fail(data: Data, reason: String) -> Flow {
  let data = settle_all(data, reason)
  Flow(Retiring(Faulted, reason), close(data))
}

// Answers every caller still waiting, with the same reason, and empties
// the three tables. Barrier and shutdown entries have no caller of their
// own: the settlement waiter owns the barrier's reply, and a stop caller is
// answered by `witnessed`.
fn settle_all(data: Data, reason: String) -> Data {
  let error = Unavailable(reason:)
  dict.each(data.pending, fn(_, pending) {
    case pending {
      CallerWaits(reply:, monitor:, ..) -> {
        demonitor(monitor)
        process.send(reply, Error(error))
      }
      HandshakeWaits(reply:) ->
        process.send(reply, Error(HandshakeFailed(error:)))
      BarrierFor(..) | ShutdownWaits -> Nil
    }
  })
  dict.each(data.waiters, fn(_, waiter) {
    process.send(waiter.reply, Error(error))
  })
  dict.each(data.readiers, fn(_, readier) {
    process.send(readier.reply, Error(error))
  })
  Data(..data, pending: dict.new(), waiters: dict.new(), readiers: dict.new())
}

// Closes the transport once: the connection is replaced by an inert one,
// so nothing later writes to, or closes again, a peer already told to go.
fn close(data: Data) -> Data {
  case data.profile {
    json.StandardJson -> {
      data.connection.close()
      Data(..data, connection: inert_connection())
    }
    json.RegisteredLspJson -> {
      case data.deferred_close {
        Some(_) -> data
        None ->
          Data(
            ..data,
            connection: inert_connection(),
            deferred_close: Some(data.connection.close),
          )
      }
    }
  }
}

// The output handler consumes its current grant before this original close runs.
fn flush_close(data: Data) -> Data {
  case data.deferred_close {
    None -> data
    Some(close) -> {
      close()
      Data(..data, deferred_close: None)
    }
  }
}

// A connection whose writes fail and whose close does nothing, used once
// the real one has been closed.
fn inert_connection() -> transport.Connection {
  transport.Connection(send: fn(_) { Error(Nil) }, close: fn() { Nil })
}

// Frames and writes one message. The only I/O a handler performs. A failed
// write means the server stopped reading, and the caller turns the reason
// into a fault.
fn send(data: Data, message: JsonValue) -> Result(Nil, String) {
  use Nil <- result.try(state_bounds(data))
  let frame = framing.frame(message)
  use Nil <- result.try(case data.profile {
    json.StandardJson -> Ok(Nil)
    json.RegisteredLspJson -> {
      case string.split_once(frame, "\r\n\r\n") {
        Ok(#(_, body)) -> {
          use <- bool.guard(
            when: string.byte_size(body) > framing.max_frame_bytes,
            return: Error(
              "Registered outbound LSP body exceeds its framed limit",
            ),
          )
          Ok(Nil)
        }
        Error(Nil) -> Error("Registered outbound framing is invalid")
      }
    }
  })
  data.connection.send(frame)
  |> result.map_error(fn(_) {
    "the language server " <> data.server <> " no longer accepts input"
  })
}

// These are retained logical budgets, separate from framed JSON and writer bytes.
// Whole-document folds stay within the fixed count ceilings and precede publication.
fn state_bounds(data: Data) -> Result(Nil, String) {
  case data.profile {
    json.StandardJson -> Ok(Nil)
    json.RegisteredLspJson -> {
      let documents =
        dict.fold(data.documents, 0, fn(bytes, _, document) {
          bytes + string.byte_size(document.text)
        })
      let diagnostics =
        dict.fold(data.publications, 0, fn(bytes, uri, publication) {
          bytes
          + string.byte_size(uri)
          + string.byte_size(publication.path)
          + 128
          + list.fold(publication.diagnostics, 0, fn(bytes, diagnostic) {
            bytes
            + string.byte_size(diagnostic.message)
            + option.unwrap(option.map(diagnostic.source, string.byte_size), 0)
            + 128
          })
        })
      let document_metadata =
        dict.fold(data.documents, 0, fn(bytes, uri, document) {
          bytes + string.byte_size(uri) + string.byte_size(document.path) + 128
        })
      let progress =
        dict.fold(data.progress, 0, fn(bytes, token, activity) {
          bytes
          + string.byte_size(token_text(token))
          + string.byte_size(activity.title)
          + 128
        })
      let waiters =
        dict.fold(data.waiters, 0, fn(bytes, _, waiter) {
          bytes
          + 128
          + list.fold(waiter.targets, 0, fn(bytes, target) {
            bytes + string.byte_size(target.uri) + 64
          })
        })
      let metadata =
        document_metadata
        + progress
        + waiters
        + string.byte_size(data.server)
        + string.byte_size(data.language_id)
        + string.byte_size(data.root_uri)
        + list.fold(data.folders, 0, fn(bytes, folder) {
          bytes
          + string.byte_size(folder.uri)
          + string.byte_size(folder.name)
          + 64
        })
        + option.unwrap(option.map(data.server_failure, string.byte_size), 0)
        + option.unwrap(
          option.map(data.capabilities.position_encoding, string.byte_size),
          0,
        )
        + dict.size(data.pending)
        * 128
        + dict.size(data.readiers)
        * 128
        + list.length(data.stoppers)
        * 64
      use <- bool.guard(
        when: documents > 4_194_304
          || diagnostics > 4_194_304
          || metadata > 4_194_304
          || dict.size(data.documents) > max_open_documents
          || dict.size(data.publications) > max_published_uris
          || dict.size(data.progress) > max_progress_tokens
          || dict.size(data.pending) > 128,
        return: Error(
          "Registered LSP retained state or outstanding requests exceed their bounds",
        ),
      )
      Ok(Nil)
    }
  }
}

// Renders a framing fault into the reason callers are given.
fn describe_fault(fault: framing.FramingFault) -> String {
  case fault {
    framing.HeaderTooLong(limit:) ->
      "a header ran past " <> int.to_string(limit) <> " bytes"
    framing.FrameTooLong(limit:, declared:) ->
      "a frame declared "
      <> int.to_string(declared)
      <> " bytes, over the "
      <> int.to_string(limit)
      <> " byte cap"
    framing.MissingContentLength -> "a header carried no Content-Length"
    framing.DuplicateContentLength -> "a header carried Content-Length twice"
    framing.BadContentLength(value:) -> "a Content-Length of " <> value
    framing.MalformedHeader(reason:) -> reason
    framing.BodyNotUtf8 -> "a body was not utf-8"
  }
}

// A request shares its caller's custody. Withdrawing its id before the cancel
// write means a late result cannot reach a later observation or caller.
fn caller_gone(flow: Flow, monitor: process.Monitor) -> Flow {
  dict.to_list(flow.data.pending)
  |> list.fold(flow, fn(flow, entry) {
    case entry.1 {
      CallerWaits(monitor: Some(held), ..) if held == monitor -> {
        let data =
          Data(..flow.data, pending: dict.delete(flow.data.pending, entry.0))
        cancel(Flow(..flow, data:), entry.0)
      }
      CallerWaits(..) | BarrierFor(..) | HandshakeWaits(..) | ShutdownWaits ->
        flow
    }
  })
}

fn demonitor(monitor: Option(process.Monitor)) -> Nil {
  case monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
}

/// One atomic read of the actor's synced document and analysis state.
///
/// The generation is an actor-local token, which the harness content-hashes
/// before exposing it. The revision and epochs detect intervening syncs,
/// progress and failures, even when the final document text is unchanged.
pub type ObservationState {
  ObservationState(
    /// This client incarnation's unique token.
    generation: reference.Reference,
    /// The next monotonically increasing internal document version.
    revision: Int,
    /// Changes in active work-done progress.
    activity_epoch: Int,
    /// Server failures reported since the client started.
    failure_epoch: Int,
    /// Any retained analysis failure.
    failure: Option(String),
    /// Active work-done progress titles.
    busy: List(String),
    /// The exact currently synced document texts and versions.
    documents: List(ObservedDocument),
  )
}

/// A document as the actor last sent it to the server.
pub type ObservedDocument {
  ObservedDocument(
    /// The canonical path given at document sync.
    path: String,
    /// The actor's globally increasing internal version.
    version: Int,
    /// The full text sent with that version.
    text: String,
  )
}

/// Reads one atomic observation state within the caller's remaining bound.
///
/// ## Examples
///
/// ```gleam
/// // client.observation_state(client, 1000) -> Ok(ObservationState(..))
/// ```
pub fn observation_state(
  client: Client,
  waiting: Int,
) -> Result(ObservationState, RequestError) {
  exchange(client, int.max(int.min(waiting, local_wait_ms), 1), fn(reply) {
    Read(Observed(reply))
  })
  |> result.flatten
}
