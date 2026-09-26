//// The language-server client actor: one process owning one language
//// server over a `mcp/transport.Transport`, from the `initialize`
//// handshake to the witnessed close of its transport (ADR-013 §§1–3).
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
//// **No handler blocks and no handler reads disk.** The production
//// transport is the broker's jailed exec, and ADR-013 §1 records that the
//// path has no backpressure: the relay forwards every stdout chunk as a
//// message and stdin is a cast. So every wait — a request's deadline, a
//// settlement, the handshake, the shutdown grace — lives in actor state as
//// a pending entry plus a timer, and the only I/O a handler performs is
//// `Connection.send`. The texts a document sync carries were read by the
//// caller, which is why `sync` takes texts rather than paths to read.
////
//// **Every request is gated on what the server advertised.** A measured
//// server left an unadvertised request unanswered for as long as it was
//// watched, so `protocol.supports` is checked before an id is minted, and
//// an unadvertised request answers `Unsupported` without a byte reaching
//// the server.
////
//// **Only a channel transport is accepted.** Rule Zero puts a language
//// server in the jail, and the jail is reached through a
//// `ChannelTransport` built over the broker's exec in `packages/client`.
//// `mcp`'s unjailed port transport is refused at `start`, so no wiring
//// mistake can run a server on the harness's own host.
////
//// # The phases
////
//// `Initializing` sends `initialize`, decodes the capabilities and sends
//// `initialized`; callers cannot hold a handle yet, and anything that
//// arrives early is postponed into `Serving`. `Serving` is the working
//// life. `ShuttingDown` has sent `shutdown` and waits a caller-chosen
//// grace for its answer; then `exit` is sent and the transport closed.
//// `Retiring` has closed the transport and waits, bounded by `retire_ms`,
//// for the `TransportClosed` that proves the server is gone — the
//// transport's retirement witness, for which no deadline substitutes. The
//// actor exits only from `Retiring`, or at once when the transport
//// reports the close itself.
////
//// # Death is reported, never survived
////
//// A transport close, a framing fault, a body that is not JSON-RPC or a
//// failed write settles every pending caller and every settlement waiter
//// with `Unavailable(reason)`, closes the transport, and ends the actor
//// with an abnormal exit carrying the reason. Restarting is not this
//// module's job: the manager that monitors `pid` restarts the server and
//// re-sends its documents (ADR-013 §1).
////
//// # Settled diagnostics are two rules
////
//// ADR-013 §3, measured on two servers: `gleam lsp` never versions a
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
//// Callers reach the actor only through `mcp/call.try_call`, the
//// monitored call that answers a dead or wedged callee as a value rather
//// than crashing the asker as `process.call` would.

import core/corruption
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import lsp/framing
import lsp/protocol.{
  type CallHierarchyItem, type DocumentSymbols, type Feature, type HoverResult,
  type IncomingCall, type InitializeResult, type Location, type OutgoingCall,
  type PrepareRename, type PublishDiagnostics, type ServerCapabilities,
  type ServerDiagnostic, type WorkspaceEdit, type WorkspaceFolder,
}
import lsp/range.{type Position}
import mcp/call
import mcp/jsonrpc.{type Id}
import mcp/transport.{type Transport}
import weft/state_machine as sm

// --- bounds -----------------------------------------------------------------

/// The most documents the client holds open on the server. Opening one
/// more sends `didClose` for the least recently synced and forgets it
/// (ADR-013 §3). A server re-reads a closed document from disk, so the
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
/// its first query in 1.8 s cold (ADR-013); a handshake that includes a
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

/// Why `start` produced no serving client.
pub type StartError {
  /// The root is not an absolute path, so it has no `file://` URI.
  BadRoot(root: String)

  /// The transport could not be used: it is not a channel transport, or
  /// the actor that would own it could not start. `reason` says which.
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
  /// refused rename's message is the useful part (ADR-013 §4).
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
  /// hashline path cannot land; the whole edit is refused (ADR-013 §4).
  EditRefused(kind: String, uri: String)
}

/// One change to the server's view of the documents, computed by the
/// caller (ADR-013 §3's push and pull). The actor never reads disk, so
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

/// Whether a settlement met ADR-013 §3's two rules before its deadline.
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
    /// other files' publications are part of the answer (ADR-013 §3).
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
  /// broker's step abort is the backstop (ADR-013 §1).
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
  CallerWaits(reply: Subject(Result(JsonValue, RequestError)), deadline_ms: Int)
  BarrierFor(token: Int)
  HandshakeWaits(reply: Subject(Result(Nil, StartError)))
  ShutdownWaits
}

// One document the server holds open. `text` is exactly the last text
// sent, which is the rename base of ADR-013 §4. `version` is drawn from
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

type Waiter {
  Waiter(
    reply: Subject(Result(Settlement, RequestError)),
    mark: Int,
    targets: List(Target),
    barrier: Barrier,
  )
}

type Phase {
  Initializing
  Serving
  ShuttingDown(grace_ms: Int)
  Retiring(ending: Ending, reason: String)
}

// Why the client is retiring, which decides the stop report and whether
// the exit is normal.
type Ending {
  Requested(report: StopReport)
  Faulted
}

type Data {
  Data(
    server: String,
    language_id: String,
    root_uri: String,
    folders: List(WorkspaceFolder),
    initialize_ms: Int,
    commands: Subject(Msg),
    connection: transport.Connection,
    buffer: framing.Buffer,
    capabilities: ServerCapabilities,
    next_id: Int,
    pending: Dict(Int, Pending),
    next_version: Int,
    documents: Dict(String, Document),
    sequence: Int,
    versioning: Versioning,
    publications: Dict(String, Publication),
    next_token: Int,
    waiters: Dict(Int, Waiter),
    progress: Dict(protocol.ProgressToken, Activity),
    next_activity: Int,
    // Moves on every change to the set of active tokens, so a quiet
    // timer armed while the set was empty knows, when it fires, whether
    // it has stayed empty since.
    quiet_epoch: Int,
    readiers: Dict(Int, Readier),
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
  use connect <- result.try(channel_of(transport_spec))
  let folders = [
    protocol.WorkspaceFolder(uri: root_uri, name: options.folder_name),
  ]
  use client <- result.try(spawn(connect, options, root_uri, folders))

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

/// Waits for settled diagnostics after a change to `paths` (ADR-013 §3),
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
/// ADR-013 §4 — or `None` when the document is not open.
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
/// ADR-013 §3 re-reads before a query.
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

fn read(
  client: Client,
  reading: fn(Subject(Result(a, RequestError))) -> Reading,
) -> Result(a, RequestError) {
  exchange(client, local_wait_ms, fn(reply) { Read(reading(reply)) })
  |> result.flatten
}

// Every exchange goes through `mcp/call.try_call`: the caller of a query
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

fn unreachable(fault: call.CallFault) -> RequestError {
  case fault {
    call.CalleeGone -> Unavailable(reason: "the lsp client is not running")
    call.NoReply -> Unavailable(reason: "the lsp client did not answer")
  }
}

fn uri_of(path: String) -> Result(String, RequestError) {
  protocol.path_to_uri(path) |> result.replace_error(InvalidPath(path:))
}

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

// The jail is reached only through a channel transport; the port
// transport would run the server unjailed on the harness's host.
fn channel_of(
  transport_spec: Transport,
) -> Result(
  fn(Subject(transport.TransportEvent)) -> transport.Connection,
  StartError,
) {
  case transport_spec {
    transport.ChannelTransport(connect:) -> Ok(connect)
    transport.PortTransport(..) ->
      Error(TransportRefused(
        reason: "a language server runs only over a channel transport into the jail",
      ))
  }
}

// --- the actor ------------------------------------------------------------------

fn spawn(
  connect: fn(Subject(transport.TransportEvent)) -> transport.Connection,
  options: Options,
  root_uri: String,
  folders: List(WorkspaceFolder),
) -> Result(Client, StartError) {
  let owner = process.self()
  sm.new_with_initialiser(init_timeout_ms, fn(commands) {
    // The owner's death is the one stop nobody sends, so it is watched
    // from the first instruction the actor runs.
    let inbound = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(inbound, FromTransport)
      |> process.select_specific_monitor(process.monitor(owner), fn(_) {
        Abandoned
      })

    // `connect` runs here, in the actor, so the transport's events are
    // addressed to the process that will select them.
    let connection = connect(inbound)
    let data =
      Data(
        server: options.server,
        language_id: options.language_id,
        root_uri:,
        folders:,
        initialize_ms: int.max(options.initialize_ms, 1),
        commands:,
        connection:,
        buffer: framing.new(),
        capabilities: nothing_advertised(),
        next_id: 1,
        pending: dict.new(),
        next_version: 1,
        documents: dict.new(),
        sequence: 0,
        versioning: Unversioned,
        publications: dict.new(),
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
    Expire(..)
    | SettleExpired(..)
    | ReadyQuiet(..)
    | ReadyExpired(..)
    | GraceExpired
    | RetireExpired -> sm.keep(data)
  }
}

fn serving(data: Data, msg: Msg) -> sm.Next(Phase, Data, Msg) {
  case msg {
    Ask(feature:, build:, deadline_ms:, reply:) ->
      conclude(Serving, ask_server(data, feature, build, deadline_ms, reply))
    Expire(id:) -> conclude(Serving, expire(Flow(Serving, data), id))
    Sync(ops:, reply:) -> conclude(Serving, sync_documents(data, ops, reply))
    Settle(uris:, deadline_ms:, reply:) ->
      conclude(Serving, begin_settle(data, uris, deadline_ms, reply))
    SettleExpired(token:) ->
      conclude(Serving, settle_expired(Flow(Serving, data), token))
    Ready(quiet_ms:, deadline_ms:, reply:) ->
      sm.keep(begin_ready(data, quiet_ms, deadline_ms, reply))
    ReadyQuiet(token:, epoch:) -> sm.keep(quiet_lapsed(data, token, epoch))
    ReadyExpired(token:) -> sm.keep(ready_expired(data, token))
    Read(reading) -> {
      answer_read(data, reading)
      sm.keep(data)
    }
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
    FromTransport(transport.TransportData(bytes:)) -> feed(phase, data, bytes)

    // The server left before answering; the close is the witness.
    FromTransport(transport.TransportClosed(..)) ->
      witnessed(data, Requested(Forced), reason)

    GraceExpired -> conclude(phase, force_close(data))
    Stop(reply:, ..) ->
      sm.keep(Data(..data, stoppers: [reply, ..data.stoppers]))
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
    SettleExpired(..)
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
    FromTransport(transport.TransportClosed(..)) ->
      witnessed(data, ending, reason)
    RetireExpired -> {
      list.each(data.stoppers, process.send(_, Unconfirmed))
      sm.stop_abnormal(
        "the language server's transport never confirmed its close: " <> reason,
      )
    }
    Stop(reply:, ..) ->
      sm.keep(Data(..data, stoppers: [reply, ..data.stoppers]))
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
fn reply_of(msg: Msg) -> fn(RequestError) -> Nil {
  case msg {
    Ask(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Sync(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Settle(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Ready(reply:, ..) -> fn(error) { process.send(reply, Error(error)) }
    Handshake(..)
    | HandshakeExpired
    | Expire(..)
    | SettleExpired(..)
    | ReadyQuiet(..)
    | ReadyExpired(..)
    | Read(..)
    | Stop(..)
    | GraceExpired
    | RetireExpired
    | FromTransport(..)
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

fn conclude(before: Phase, flow: Flow) -> sm.Next(Phase, Data, Msg) {
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
      let #(data, id) = mint(data, CallerWaits(reply:, deadline_ms:))

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
    Ok(CallerWaits(reply:, deadline_ms:)) -> {
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

fn cancel(flow: Flow, id: Int) -> Flow {
  case send(flow.data, protocol.cancel_request(jsonrpc.IdInt(id))) {
    Ok(Nil) -> flow
    Error(reason) -> fail(flow.data, reason)
  }
}

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
  case framing.push(data.buffer, bytes) {
    Error(fault) ->
      conclude(
        phase,
        fail(
          data,
          "the language server's output is not lsp framing: "
            <> describe_fault(fault),
        ),
      )
    Ok(#(buffer, bodies)) ->
      conclude(
        phase,
        list.fold(bodies, Flow(phase, Data(..data, buffer:)), body),
      )
  }
}

fn body(flow: Flow, text: String) -> Flow {
  case flow.phase {
    // A faulted client drains the rest of the chunk without acting on it.
    Retiring(..) -> flow
    Initializing | Serving | ShuttingDown(..) -> message(flow, text)
  }
}

// One whole message. A body that is not JSON-RPC is transport-fatal: the
// stream can no longer be trusted to carry the answers callers wait on.
// A well-formed message the client does not act on is dropped.
fn message(flow: Flow, text: String) -> Flow {
  case jsonrpc.decode(text) {
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
      Flow(..flow, data: notification(flow.data, method, params))
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
    CallerWaits(reply:, ..) -> {
      process.send(reply, result.map_error(outcome, server_error))
      flow
    }

    // Any answer, an error included, proves the server processed every
    // notification sent before the barrier: that is rule (a).
    BarrierFor(token:) -> Flow(..flow, data: barrier_answered(flow.data, token))

    HandshakeWaits(reply:) -> handshake_answered(flow.data, reply, outcome)
    ShutdownWaits -> acknowledged(flow.data)
  }
}

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
    Error(error) -> jsonrpc.error_response(id, error)
  }
  case send(flow.data, answer) {
    Ok(Nil) -> flow
    Error(reason) -> fail(flow.data, reason)
  }
}

// A malformed publication or progress is dropped rather than fatal: its
// envelope was well formed, so the stream is still trustworthy, and the
// next publication for that file replaces it anyway. A dropped progress
// costs at most a wait: a lost `end` holds readiness until the caller's
// deadline, and a lost `begin` comes back with the token's next report.
fn notification(data: Data, method: String, params: Option(JsonValue)) -> Data {
  case protocol.classify_notification(method, params) {
    Ok(protocol.Published(diagnostics:)) ->
      release_settled(record(data, diagnostics))
    Ok(protocol.Progressed(progress:)) -> progressed(data, progress)
    Ok(protocol.Ignored(..)) | Ok(protocol.Unrecognised(..)) | Error(..) -> data
  }
}

// --- documents ------------------------------------------------------------------

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
        let settlement = Settlement(Settled, collect(data, waiter))
        process.send(waiter.reply, Ok(settlement))
        Data(..data, waiters: dict.delete(data.waiters, token))
      }
    }
  })
}

// ADR-013 §3. Rule (a): the barrier answered. Rule (b): once this server
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
      let settlement = Settlement(DeadlineExpired, collect(flow.data, waiter))
      process.send(waiter.reply, Ok(settlement))
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
      process.send(reply, Ok(published))
    }
    CapabilitiesOf(reply:) -> process.send(reply, Ok(data.capabilities))
  }
}

fn refuse_read(reading: Reading, reason: String) -> Nil {
  let error = Unavailable(reason:)
  case reading {
    TextOf(reply:, ..) -> process.send(reply, Error(error))
    OpenPaths(reply:) -> process.send(reply, Error(error))
    PublishedFor(reply:, ..) -> process.send(reply, Error(error))
    CapabilitiesOf(reply:) -> process.send(reply, Error(error))
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
fn peer_closed(data: Data, reason: String) -> sm.Next(Phase, Data, Msg) {
  let reason = "the language server exited: " <> reason
  let _ = settle_all(Data(..data, connection: inert_connection()), reason)
  sm.stop_abnormal(reason)
}

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

fn settle_all(data: Data, reason: String) -> Data {
  let error = Unavailable(reason:)
  dict.each(data.pending, fn(_, pending) {
    case pending {
      CallerWaits(reply:, ..) -> process.send(reply, Error(error))
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
  data.connection.close()
  Data(..data, connection: inert_connection())
}

fn inert_connection() -> transport.Connection {
  transport.Connection(send: fn(_) { Error(Nil) }, close: fn() { Nil })
}

fn send(data: Data, message: JsonValue) -> Result(Nil, String) {
  data.connection.send(framing.frame(message))
  |> result.map_error(fn(_) {
    "the language server " <> data.server <> " no longer accepts input"
  })
}

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
