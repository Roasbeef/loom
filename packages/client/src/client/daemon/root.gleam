//// The daemon lifetime owner: private files, catalogue, and native drain fence.
////
//// Startup advances one resource at a time in an unlinked state machine. The
//// caller receives the root handle before filesystem work begins, so a failed
//// or timed-out readiness request cannot discard partially acquired resources.
//// Restoring metadata creates an empty runtime registry; it opens no sessions.
////
//// The original outer witness must report normal retirement before this owner
//// closes the catalogue and releases its stable kernel lock. Caller death
//// requests that same drain. Proof loss permanently fences readiness and keeps
//// available custody; a timeout is a reporting budget, never cleanup evidence.
////
//// Admission reserves at most 64 connections and 160MiB of bounded payload:
//// maximum inbound messages plus 8MiB of retained delivery allowance for each
//// session connection. This accounts for encoded/copy bounds, not exact BEAM
//// heap or RSS. HTTP reserves before upgrade; the actual WebSocket
//// PID takes over before its initializer returns and Mist activates the socket.
//// That bounded resource-accounting map is not an alternative effect-lifecycle
//// ledger. A socket PID's DOWN releases only connection capacity. Root shutdown
//// also requires the separate aggregate instance witness before releasing files.
////
//// Untrappable KILL of this root closes its lock port before transitive cleanup
//// is necessarily done. No finite chain of custodians removes that boundary.
//// The default launcher must also honor the endpoint's OS PID/birth identity
//// and refuse replacement while that VM remains alive. This module publishes
//// no endpoint and therefore does not claim to implement that final fence.

import broker/internal/call
import broker/token
import client/daemon/lifetime
import client/daemon/listener
import client/daemon/manager
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mist
import storage/access
import storage/catalogue
import weft/state_machine as sm

/// Configuration independent of session assembly and listener routing.
pub type Config {
  Config(
    /// The private daemon state directory, canonicalized before locking.
    state_root: String,
    /// Used only when establishing the first durable owner identity.
    owner_display_name: String,
    /// Maximum simultaneously reserved runtime slots.
    capacity: Int,
  )
}

/// A prepared lifetime owner, retained even when readiness fails or times out.
pub opaque type Root(instance) {
  Root(commands: Subject(Message(instance)), pid: process.Pid)
}

/// Parser reservation class chosen after authentication and authorization.
pub type ConnectionClass {
  /// Daemon control accepts only small control-plane commands.
  Control

  /// A read-only session peer accepts only small observer commands.
  Observer

  /// A session operator may submit the larger supported input messages.
  Operator
}

/// Whether an existing control request may inspect a draining registry.
pub type ControlUse {
  /// Read-only status, metadata, or operation inspection.
  ControlRead

  /// A command which can mutate metadata or session lifecycle.
  ControlMutation
}

/// One pre-upgrade reservation, transferable once to the actual WebSocket PID.
pub opaque type Permit {
  Permit(http_owner: process.Pid, identity: Reference)
}

/// Maximum simultaneously reserved HTTP upgrades and admitted WebSockets.
pub const max_connections = 64

/// Sum of inbound limits and bounded delivery allowances, not a VM RSS limit.
/// Decoded term overhead, parser copies, and kernel buffers remain separate.
pub const max_reserved_message_bytes = 167_772_160

type AdmissionPhase {
  HttpReserved
  WebsocketAdmitted
}

type Allocation {
  Allocation(
    identity: Reference,
    class: ConnectionClass,
    watch: process.Monitor,
    phase: AdmissionPhase,
  )
}

/// Non-secret capabilities exposed only after original monitors are installed.
pub type Ready(instance) {
  Ready(
    /// Empty on restoration until an authorized caller explicitly opens a session.
    registry: manager.Manager(instance),
    /// The stable owner identity, never its credential.
    owner: access.Principal,
    /// Canonical private directory for all daemon metadata.
    state_root: String,
    /// Private destination for newly reserved conversation databases.
    sessions_directory: String,
    /// Random identity of this daemon lifetime, never reused after restart.
    epoch: String,
  )
}

type Phase {
  Dormant
  Starting
  Serving
  Stopping
  Refused(reason: String)
  RecoveryBlocked(reason: String)
  Closed
}

type Paths {
  Paths(
    root: String,
    lock: String,
    catalogue: String,
    token: String,
    sessions: String,
  )
}

type Lease {
  Lease(paths: Paths, lock: bootstrap.LaunchLock, watch: process.Monitor)
}

type Store {
  Store(lease: Lease, catalogue: catalogue.Catalogue)
}

type Identity {
  Identity(store: Store, owner: access.Principal, credential: String)
}

type Running(instance) {
  Running(
    identity: Identity,
    lifetime: lifetime.Lifetime(instance),
    watch: process.Monitor,
    epoch: String,
  )
}

type Stage(instance) {
  Empty
  Directory(Paths)
  Locked(Lease)
  Catalogued(Store)
  Authenticated(Identity)
  Live(Running(instance))
  WitnessedClosed(Identity)
}

type Book(instance) {
  Book(
    config: Config,
    assembly: manager.Assembly(instance),
    commands: Subject(Message(instance)),
    selector: process.Selector(Message(instance)),
    stage: Stage(instance),
    allocations: Dict(process.Pid, Allocation),
    reserved_bytes: Int,
    listener: Option(listener.Listener),
  )
}

type Message(instance) {
  Advance
  Readiness(Subject(Result(Ready(instance), String)))
  ControlState(ControlUse, Subject(Result(Ready(instance), String)))
  Credential(Subject(Result(String, String)))
  Stop(Subject(Result(Nil, String)))
  CallerGone
  LockGone
  WitnessGone(process.ExitReason)
  Finish
  Acquire(
    process.Pid,
    Reference,
    ConnectionClass,
    Subject(Result(Permit, String)),
  )
  Transfer(Permit, process.Pid, Subject(Result(Nil, String)))
  Release(Permit)
  AbortTransfer(Permit, process.Pid)
  ConnectionGone(process.Pid, process.Monitor)
  StartListener(
    mist.Builder(mist.Connection, mist.ResponseData),
    Subject(Result(listener.Listener, String)),
  )
  ListenerGone(process.ExitReason)
}

/// Prepares the unlinked owner without acquiring files or starting a registry.
/// Keep the returned handle through readiness errors and shutdown reporting.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(root) = root.start(config, assembly)
/// // root.ready(root, within: 20_000)
/// ```
@internal
pub fn start(
  config: Config,
  assembly: manager.Assembly(instance),
) -> Result(Root(instance), String) {
  let caller = process.self()
  sm.new_with_initialiser(1000, fn(commands) {
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_specific_monitor(process.monitor(caller), fn(_) {
        CallerGone
      })
    sm.initialised(
      Dormant,
      Book(config, assembly, commands, selector, Empty, dict.new(), 0, None),
    )
    |> sm.selecting(selector)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.trapping_exits(True)
  |> sm.unlinked
  |> sm.on_event(handle)
  |> sm.start
  |> result.map(fn(started) { Root(started.data, started.pid) })
  |> result.map_error(string.inspect)
}

/// Starts or queries readiness with a bounded wait and no implicit session open.
///
/// This is a pure bounded query: the caller's budget stops the caller's wait
/// and nothing else. It used to request a daemon-wide drain on its own
/// timeout, which put whole-daemon shutdown behind a one-second budget on the
/// unauthenticated HTTP path and on every inbound session frame. Startup is
/// the one caller that owns "readiness never arrived", and `main.listen`
/// already answers a failure there by calling `shutdown` itself.
///
/// ## Examples
///
/// ```gleam
/// // root.ready(daemon, within: 20_000)
/// ```
@internal
pub fn ready(
  root: Root(instance),
  within within: Int,
) -> Result(Ready(instance), String) {
  exchange(root, within, Readiness)
}

/// Returns metadata authority for an existing control socket during drain.
/// This does not grant parser admission or session readiness. The control
/// protocol must continue restricting mutations once the registry is draining.
///
/// ## Examples
///
/// ```gleam
/// // root.control_state(daemon, root.ControlRead, within: 1000)
/// ```
@internal
pub fn control_state(
  root: Root(instance),
  use_for: ControlUse,
  within within: Int,
) -> Result(Ready(instance), String) {
  exchange(root, within, ControlState(use_for, _))
}

/// Returns the private owner credential solely for internal listener wiring.
/// Do not include this value in status, endpoint metadata, logs, or errors.
///
/// ## Examples
///
/// ```gleam
/// // root.listener_credential(daemon)
/// ```
@internal
pub fn listener_credential(root: Root(instance)) -> Result(String, String) {
  exchange(root, 1000, Credential)
}

/// Starts the sole listener after publishing its parked owner's original monitor.
/// A readiness failure retains root custody and requests aggregate shutdown.
///
/// ## Examples
///
/// ```gleam
/// // root.start_listener(daemon, mist.new(handle), within: 15_000)
/// ```
@internal
pub fn start_listener(
  root: Root(instance),
  builder: mist.Builder(mist.Connection, mist.ResponseData),
  within within: Int,
) -> Result(listener.Bound, String) {
  let deadline = bootstrap.monotonic_time_ms() + within
  let outcome = {
    use transport <- result.try(
      exchange(root, within, StartListener(builder, _)),
    )
    listener.ready(transport, within: deadline - bootstrap.monotonic_time_ms())
  }
  case outcome {
    Error(_) -> request_shutdown(root)
    Ok(_) -> Nil
  }
  outcome
}

/// Returns the lifetime owner's PID for the caller's original monitor.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(root.pid(daemon))
/// ```
@internal
pub fn pid(root: Root(instance)) -> process.Pid {
  root.pid
}

/// Requests shutdown without waiting, after a listener has accepted its reply.
/// This cast provides no retirement proof; keep monitoring the root's lifetime.
///
/// ## Examples
///
/// ```gleam
/// // root.request_shutdown(daemon)
/// ```
@internal
pub fn request_shutdown(root: Root(instance)) -> Nil {
  process.send(root.commands, Stop(process.new_subject()))
}

/// Returns the maximum message size reserved by one connection class.
/// Use this same value for the bounded Mist frame and message limits.
///
/// ## Examples
///
/// ```gleam
/// assert root.message_limit(root.Observer) == 65_536
/// ```
@internal
pub fn message_limit(class: ConnectionClass) -> Int {
  case class {
    Control | Observer -> 65_536
    Operator -> 33_554_432
  }
}

// Session delivery can overlap two 1MiB metadata cuts, two bounded 2MiB
// encodings, two 190KiB fragments and 40KiB replies, plus descriptor/presence
// identifiers and one 24KiB ephemeral slot. The 8MiB allowance rounds this
// retained payload upward; it does not claim to measure JSON-term heap size.
fn connection_charge(class: ConnectionClass) -> Int {
  let delivery = case class {
    Control -> 0
    Observer | Operator -> 8_388_608
  }
  message_limit(class) + delivery
}

/// Reserves capacity in the calling HTTP handler before sending an upgrade.
/// One PID can own only one reservation. A timeout cancels its exact request;
/// a late reply cannot leave untracked capacity behind on a keep-alive socket.
///
/// ## Examples
///
/// ```gleam
/// // root.acquire(daemon, root.Control, within: 1000)
/// ```
@internal
pub fn acquire(
  root: Root(instance),
  class: ConnectionClass,
  within within: Int,
) -> Result(Permit, String) {
  let http_owner = process.self()
  let identity = reference.new()
  let result =
    exchange(root, within, fn(reply) {
      Acquire(http_owner, identity, class, reply)
    })
  case result {
    Ok(permit) -> Ok(permit)
    Error(reason) -> {
      release(root, Permit(http_owner, identity))
      Error(reason)
    }
  }
}

/// Transfers a reservation inside the real WebSocket initializer.
/// Mist's HTTP actor waits for that initializer; the new PID is monitored
/// before the HTTP monitor is removed and before this acknowledgement returns.
/// An error must abort the initializer, never expose an unadmitted parser.
///
/// ## Examples
///
/// ```gleam
/// // root.transfer(daemon, permit, within: 1000)
/// ```
@internal
pub fn transfer(
  root: Root(instance),
  permit: Permit,
  within within: Int,
) -> Result(Nil, String) {
  let websocket = process.self()
  case
    exchange(root, within, fn(reply) { Transfer(permit, websocket, reply) })
  {
    Ok(Nil) -> Ok(Nil)
    Error(reason) -> {
      process.send(root.commands, AbortTransfer(permit, websocket))
      Error(reason)
    }
  }
}

/// Releases a failed HTTP upgrade, but never a transferred WebSocket permit.
/// Actual WebSocket death is the only event that releases admitted capacity.
///
/// ## Examples
///
/// ```gleam
/// // root.release(daemon, permit)
/// ```
@internal
pub fn release(root: Root(instance), permit: Permit) -> Nil {
  process.send(root.commands, Release(permit))
}

/// Requests orderly shutdown and waits for both confirmation and normal DOWN.
/// A dead owner or timeout cannot authorize replacement of uncertain custody.
///
/// ## Examples
///
/// ```gleam
/// // root.shutdown(daemon, within: 5000)
/// ```
@internal
pub fn shutdown(
  root: Root(instance),
  within within: Int,
) -> Result(Nil, String) {
  let deadline = bootstrap.monotonic_time_ms() + int.max(within, 0)
  let watch = process.monitor(root.pid)
  let outcome = exchange(root, within, Stop)
  let answer = case outcome {
    Error(error) -> Error(error)
    Ok(Nil) ->
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) {
        case down.reason {
          process.Normal -> Ok(Nil)
          process.Killed | process.Abnormal(_) ->
            Error("daemon root retirement was not confirmed")
        }
      })
      |> process.selector_receive(int.max(
        deadline - bootstrap.monotonic_time_ms(),
        0,
      ))
      |> result.replace_error("daemon root retirement timed out")
      |> result.flatten
  }
  process.demonitor_process(watch)
  answer
}

// Every question put to the root is a monitored call with a budget, so a root
// that dies mid-answer is reported rather than exiting the asker. The two ways
// to get no reply stay distinct as `call.CallFault` values rather than as error
// text a reader elsewhere has to recognize: a branch that turned on the exact
// wording of a message produced here is how a caller's timeout came to request
// the daemon's shutdown.
fn exchange(
  root: Root(instance),
  within: Int,
  message: fn(Subject(Result(a, String))) -> Message(instance),
) -> Result(a, String) {
  case
    call.try_call(root.commands, waiting: int.max(within, 0), sending: message)
  {
    Ok(answer) -> answer
    Error(call.NoReply) -> Error("daemon root request timed out")
    Error(call.CalleeGone) -> Error("daemon root is unavailable")
  }
}

fn handle(
  phase: Phase,
  book: Book(instance),
  message: Message(instance),
) -> sm.Next(Phase, Book(instance), Message(instance)) {
  case message {
    Readiness(reply) -> readiness(phase, book, reply)
    ControlState(use_for, reply) -> {
      let answer = case phase, use_for {
        Serving, _ | Stopping, ControlRead -> ready_value(book.stage)
        Stopping, ControlMutation
        | Dormant, _
        | Starting, _
        | Refused(_), _
        | RecoveryBlocked(_), _
        | Closed, _
        -> Error("daemon control is unavailable")
      }
      process.send(reply, answer)
      sm.keep(book)
    }
    Credential(reply) -> {
      process.send(reply, credential_for(phase, book.stage))
      sm.keep(book)
    }
    Stop(reply) -> stop(phase, book, reply)
    CallerGone -> stop(phase, book, process.new_subject())
    LockGone -> block(book, "daemon lifetime lock was lost")
    WitnessGone(reason) -> witness_gone(phase, book, reason)
    Acquire(owner, identity, class, reply) ->
      acquire_slot(phase, book, owner, identity, class, reply)
    Transfer(permit, websocket, reply) ->
      transfer_slot(phase, book, permit, websocket, reply)
    Release(permit) -> release_reserved(phase, book, permit)
    AbortTransfer(permit, websocket) ->
      abort_transfer(phase, book, permit, websocket)
    ConnectionGone(owner, watch) -> connection_gone(phase, book, owner, watch)
    StartListener(builder, reply) ->
      start_listener_owned(phase, book, builder, reply)
    ListenerGone(reason) -> listener_gone(phase, book, reason)
    Advance ->
      case phase {
        Starting -> advance(book)
        Dormant
        | Serving
        | Stopping
        | Refused(_)
        | RecoveryBlocked(_)
        | Closed -> sm.keep(book)
      }
    Finish ->
      case phase {
        Closed -> sm.stop()
        Dormant
        | Starting
        | Serving
        | Stopping
        | Refused(_)
        | RecoveryBlocked(_) -> sm.keep(book)
      }
  }
}

fn readiness(
  phase: Phase,
  book: Book(instance),
  reply: Subject(Result(Ready(instance), String)),
) -> sm.Next(Phase, Book(instance), Message(instance)) {
  case phase {
    Dormant -> {
      process.send(book.commands, Advance)
      sm.transition(Starting, book) |> sm.postpone
    }
    Starting -> sm.keep(book) |> sm.postpone
    Serving -> {
      process.send(reply, ready_value(book.stage))
      sm.keep(book)
    }
    Refused(reason) | RecoveryBlocked(reason) -> {
      process.send(reply, Error(reason))
      sm.keep(book)
    }
    Stopping | Closed -> {
      process.send(reply, Error("daemon is stopping"))
      sm.keep(book)
    }
  }
}

fn ready_value(stage: Stage(instance)) {
  case stage {
    Live(running) ->
      Ok(Ready(
        registry: lifetime.registry(running.lifetime),
        owner: running.identity.owner,
        state_root: running.identity.store.lease.paths.root,
        sessions_directory: running.identity.store.lease.paths.sessions,
        epoch: running.epoch,
      ))
    Empty
    | Directory(_)
    | Locked(_)
    | Catalogued(_)
    | Authenticated(_)
    | WitnessedClosed(_) -> Error("daemon has no serving registry")
  }
}

// This is the one door the owner credential leaves the root through, so the
// pairs are written out rather than collapsed: a new `Phase` that should also
// serve it, or a new `Stage` that must not, then arrives with a compiler
// prompt instead of silently inheriting whichever side a catch-all picked.
// Only a serving root holding a live registry serves it; everything else fails
// closed.
fn credential_for(phase: Phase, stage: Stage(instance)) {
  case phase, stage {
    Serving, Live(running) -> Ok(running.identity.credential)

    // A serving phase with no live stage is unreachable — `start_registry` is
    // the only writer of both — and refusing keeps it that way.
    Serving, Empty
    | Serving, Directory(_)
    | Serving, Locked(_)
    | Serving, Catalogued(_)
    | Serving, Authenticated(_)
    | Serving, WitnessedClosed(_)
    -> Error("daemon listener credential is unavailable")

    // Before Serving the identity may not exist yet; after it, the listener
    // is being retired or the root is fenced, and neither may mint a new one.
    Dormant, _
    | Starting, _
    | Stopping, _
    | Refused(_), _
    | RecoveryBlocked(_), _
    | Closed, _
    -> Error("daemon listener credential is unavailable")
  }
}

// Each turn commits its acquired handle into Book before advancing. Cancel or
// caller DOWN can run between stages; no admission capability escapes early.
//
// `advance` runs only in phase `Starting`, so the stages it can actually
// observe are the startup ladder `Empty` through `Authenticated`. `Live` is
// written by `start_registry`, which transitions to `Serving` in the same
// turn, and `WitnessedClosed` only by `witness_gone`, which cannot run before
// `Live` — so the last two arms are unreachable and record what the ordering
// would have to become for them to fire, rather than an ordering that exists.
fn advance(
  book: Book(instance),
) -> sm.Next(Phase, Book(instance), Message(instance)) {
  case book.stage {
    Empty -> prepared(book, directories(book.config) |> result.map(Directory))
    Directory(paths) ->
      case bootstrap.try_launch_lock(paths.lock) {
        Error(reason) -> sm.transition(Refused(reason), book)
        Ok(lock) -> {
          let watch = bootstrap.lock_monitor(lock)
          let selector =
            book.selector
            |> process.select_specific_monitor(watch, fn(_) { LockGone })
          progress(
            Book(..book, stage: Locked(Lease(paths, lock, watch)), selector:),
          )
          |> sm.with_selector(selector)
        }
      }
    Locked(lease) ->
      prepared(
        book,
        catalogue.open(lease.paths.catalogue)
          |> result.map(fn(store) { Catalogued(Store(lease, store)) })
          |> result.map_error(fn(_) { "daemon catalogue could not be opened" }),
      )
    Catalogued(store) ->
      prepared(
        book,
        authenticate_owner(store, book.config.owner_display_name)
          |> result.map(Authenticated),
      )
    Authenticated(identity) -> start_registry(book, identity)
    Live(_) -> sm.transition(Serving, book)
    WitnessedClosed(_) ->
      block(book, "daemon startup followed an already retired witness")
  }
}

fn prepared(book: Book(instance), outcome: Result(Stage(instance), String)) {
  case outcome {
    Ok(stage) -> progress(Book(..book, stage:))
    Error(reason) -> sm.transition(Refused(reason), book)
  }
}

fn progress(book: Book(instance)) {
  process.send(book.commands, Advance)
  sm.keep(book)
}

fn start_registry(book: Book(instance), identity: Identity) {
  let epoch = random_hex()
  case
    lifetime.start(
      identity.store.catalogue,
      book.assembly,
      epoch:,
      limit: book.config.capacity,
    )
  {
    Error(_) -> block(book, "daemon startup lost its aggregate custody proof")
    Ok(daemon) -> {
      let watch = process.monitor(lifetime.witness(daemon))
      let selector =
        book.selector
        |> process.select_specific_monitor(watch, fn(down) {
          WitnessGone(down.reason)
        })
      sm.transition(
        Serving,
        Book(
          ..book,
          stage: Live(Running(identity, daemon, watch, epoch)),
          selector:,
        ),
      )
      |> sm.with_selector(selector)
    }
  }
}

fn directories(config: Config) {
  use Nil <- result.try(case config.capacity > 0 {
    True -> Ok(Nil)
    False -> Error("daemon capacity must be positive")
  })
  use absolute <- result.try(bootstrap.absolute_path(config.state_root))
  use Nil <- result.try(bootstrap.ensure_private_directory(absolute))
  use root <- result.try(bootstrap.canonical_directory(absolute))
  let paths =
    Paths(
      root,
      root <> "/daemon.lock",
      root <> "/catalogue.db",
      root <> "/owner.token",
      root <> "/sessions",
    )
  use Nil <- result.try(bootstrap.ensure_private_directory(paths.sessions))
  use Nil <- result.try(unaliased_file(paths.lock))
  use Nil <- result.try(unaliased_file(paths.catalogue))
  Ok(paths)
}

// The directory is already canonical and private. Existing lock/catalogue
// entries must not redirect their identity outside that directory via a link.
fn unaliased_file(path: String) {
  case bootstrap.path_exists(path) {
    False -> Ok(Nil)
    True -> {
      use canonical <- result.try(bootstrap.canonical_path(path))
      case canonical == path {
        True -> Ok(Nil)
        False -> Error("daemon metadata path must not be a symbolic link")
      }
    }
  }
}

fn authenticate_owner(store: Store, display_name: String) {
  use credential <- result.try(owner_token(store))
  use digest <- result.try(
    access.credential_digest(
      credential
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase,
    )
    |> result.map_error(fn(_) { "owner credential digest was invalid" }),
  )
  use owner <- result.try(
    access.bootstrap_owner(
      store.catalogue,
      "owner-" <> random_hex(),
      display_name,
      digest,
    )
    |> result.map_error(fn(_) {
      "durable owner credential was refused; no credential was reset"
    }),
  )
  Ok(Identity(store, owner, credential))
}

fn owner_token(store: Store) {
  let path = store.lease.paths.token
  case bootstrap.path_exists(path) {
    True -> read_token(path)
    False ->
      case access.owner(store.catalogue) {
        Ok(_) ->
          Error("durable owner token is missing; no credential was reset")
        Error(catalogue.Missing) -> {
          // The daemon's exclusive lifetime lock serializes first publication.
          // An existing entry, including a final symlink, never reaches this arm.
          let credential = random_hex()
          use Nil <- result.try(bootstrap.atomic_write_private(path, credential))
          read_token(path)
        }
        Error(_) -> Error("durable owner identity could not be read")
      }
  }
}

fn read_token(path: String) {
  use bytes <- result.try(bootstrap.read_private_bounded(path, 64))
  use credential <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("owner credential file is not UTF-8"),
  )
  case access.credential_digest(credential) {
    Ok(_) -> Ok(credential)
    Error(_) -> Error("owner credential file is not a canonical 256-bit token")
  }
}

fn random_hex() {
  token.production_entropy()(32) |> bit_array.base16_encode |> string.lowercase
}

// This bounded map accounts for connection payload, not transitive effects.
// Each entry has one exact owner monitor and disappears only by a matched
// cancellation before upgrade or by that owner's actual DOWN afterwards.
fn acquire_slot(
  phase: Phase,
  book: Book(instance),
  owner: process.Pid,
  identity: Reference,
  class: ConnectionClass,
  reply: Subject(Result(Permit, String)),
) {
  let fits =
    phase == Serving
    && !dict.has_key(book.allocations, owner)
    && dict.size(book.allocations) < max_connections
    && book.reserved_bytes + connection_charge(class)
    <= max_reserved_message_bytes
  case fits {
    False -> {
      process.send(reply, Error("daemon connection capacity is unavailable"))
      sm.keep(book)
    }
    True -> {
      let book = add_allocation(book, owner, identity, class, HttpReserved)
      process.send(reply, Ok(Permit(owner, identity)))
      sm.keep(book) |> sm.with_selector(book.selector)
    }
  }
}

fn add_allocation(
  book: Book(instance),
  owner: process.Pid,
  identity: Reference,
  class: ConnectionClass,
  phase: AdmissionPhase,
) {
  let watch = process.monitor(owner)
  let selector =
    book.selector
    |> process.select_specific_monitor(watch, fn(down) {
      ConnectionGone(owner, down.monitor)
    })
  Book(
    ..book,
    allocations: dict.insert(
      book.allocations,
      owner,
      Allocation(identity, class, watch, phase),
    ),
    reserved_bytes: book.reserved_bytes + connection_charge(class),
    selector:,
  )
}

fn remove_allocation(
  book: Book(instance),
  owner: process.Pid,
  allocation: Allocation,
) {
  process.demonitor_process(allocation.watch)
  Book(
    ..book,
    allocations: dict.delete(book.allocations, owner),
    reserved_bytes: book.reserved_bytes - connection_charge(allocation.class),
    selector: process.deselect_specific_monitor(book.selector, allocation.watch),
  )
}

fn transfer_slot(
  phase: Phase,
  book: Book(instance),
  permit: Permit,
  websocket: process.Pid,
  reply: Subject(Result(Nil, String)),
) {
  case phase {
    Serving -> transfer_serving(book, permit, websocket, reply)
    Dormant | Starting | Stopping | Refused(_) | RecoveryBlocked(_) | Closed -> {
      process.send(reply, Error("daemon is not admitting connections"))
      sm.keep(book)
    }
  }
}

fn transfer_serving(
  book: Book(instance),
  permit: Permit,
  websocket: process.Pid,
  reply: Subject(Result(Nil, String)),
) {
  case dict.get(book.allocations, websocket) {
    Ok(Allocation(identity:, phase: WebsocketAdmitted, ..))
      if identity == permit.identity
    -> {
      process.send(reply, Ok(Nil))
      sm.keep(book)
    }
    Ok(_) -> {
      process.send(reply, Error("connection PID already owns a reservation"))
      sm.keep(book)
    }
    Error(Nil) -> transfer_reserved(book, permit, websocket, reply)
  }
}

fn transfer_reserved(
  book: Book(instance),
  permit: Permit,
  websocket: process.Pid,
  reply: Subject(Result(Nil, String)),
) {
  case dict.get(book.allocations, permit.http_owner) {
    Ok(allocation)
      if allocation.identity == permit.identity
      && allocation.phase == HttpReserved
    -> {
      case process.is_alive(permit.http_owner) {
        False -> {
          process.send(
            reply,
            Error("HTTP upgrade owner exited before transfer"),
          )
          sm.keep(book)
        }
        True -> {
          // Install the actual parser owner's original monitor before removing
          // the HTTP monitor or acknowledging socket activation. These local
          // map updates are one root turn, so no admission can interleave.
          let book =
            add_allocation(
              book,
              websocket,
              permit.identity,
              allocation.class,
              WebsocketAdmitted,
            )
          let book = remove_allocation(book, permit.http_owner, allocation)
          process.send(reply, Ok(Nil))
          sm.keep(book) |> sm.with_selector(book.selector)
        }
      }
    }
    Ok(_) | Error(Nil) -> {
      process.send(reply, Error("HTTP upgrade reservation is no longer valid"))
      sm.keep(book)
    }
  }
}

fn release_reserved(phase: Phase, book: Book(instance), permit: Permit) {
  case phase, dict.get(book.allocations, permit.http_owner) {
    Stopping, _ | RecoveryBlocked(_), _ -> sm.keep(book)
    _, Ok(allocation)
      if allocation.identity == permit.identity
      && allocation.phase == HttpReserved
    -> {
      let book = remove_allocation(book, permit.http_owner, allocation)
      sm.keep(book) |> sm.with_selector(book.selector)
    }
    _, Ok(_) | _, Error(Nil) -> sm.keep(book)
  }
}

fn abort_transfer(
  phase: Phase,
  book: Book(instance),
  permit: Permit,
  websocket: process.Pid,
) {
  case dict.get(book.allocations, websocket) {
    Ok(Allocation(identity:, phase: WebsocketAdmitted, ..))
      if identity == permit.identity
    -> {
      // A timed-out transfer might have committed. Kill that exact initializer
      // and keep its capacity charged until DOWN, rather than freeing a parser
      // which could still become active after an unobserved acknowledgement.
      process.kill(websocket)
      sm.keep(book)
    }
    Ok(_) | Error(Nil) -> release_reserved(phase, book, permit)
  }
}

fn connection_gone(
  phase: Phase,
  book: Book(instance),
  owner: process.Pid,
  watch: process.Monitor,
) {
  case dict.get(book.allocations, owner) {
    Ok(allocation) if allocation.watch == watch -> {
      let book = remove_allocation(book, owner, allocation)
      case phase {
        Stopping -> finish_draining(book) |> sm.with_selector(book.selector)
        Dormant
        | Starting
        | Serving
        | Refused(_)
        | RecoveryBlocked(_)
        | Closed -> sm.keep(book) |> sm.with_selector(book.selector)
      }
    }
    Ok(_) | Error(Nil) -> sm.keep(book)
  }
}

fn cancel_connections(book: Book(instance)) {
  // Socket owners are BEAM leaves. KILL deliberately does not promise an
  // on_close callback; session presence/attachment owners must monitor peers.
  list.each(dict.keys(book.allocations), process.kill)
}

// Existing control sockets can query drain status until the session witness
// retires. Session ingress is cancelled as soon as aggregate shutdown begins.
fn cancel_session_connections(book: Book(instance)) {
  dict.each(book.allocations, fn(owner, allocation) {
    case allocation.class {
      Control -> Nil
      Observer | Operator -> process.kill(owner)
    }
  })
}

fn start_listener_owned(phase: Phase, book: Book(instance), builder, reply) {
  case phase, book.listener {
    Serving, None ->
      case listener.prepare(process.self(), builder) {
        Error(reason) -> {
          process.send(reply, Error(reason))
          sm.keep(book)
        }
        Ok(transport) -> {
          let selector =
            process.select_specific_monitor(
              book.selector,
              process.monitor(listener.pid(transport)),
              fn(down) { ListenerGone(down.reason) },
            )
          let book = Book(..book, listener: Some(transport), selector:)

          // Inventory and original monitor precede every socket acquisition.
          listener.begin(transport)
          process.send(reply, Ok(transport))
          sm.keep(book) |> sm.with_selector(selector)
        }
      }
    _, _ -> {
      process.send(reply, Error("daemon cannot start another listener"))
      sm.keep(book)
    }
  }
}

fn listener_gone(phase: Phase, book: Book(instance), reason) {
  case reason {
    process.Normal -> {
      let book = Book(..book, listener: None)
      case phase {
        Stopping -> finish_draining(book)
        Serving -> stop(phase, book, process.new_subject())
        Dormant | Starting | Refused(_) | RecoveryBlocked(_) | Closed ->
          sm.keep(book)
      }
    }
    process.Killed | process.Abnormal(_) ->
      block(book, "daemon listener retirement was not confirmed")
  }
}

fn finish_draining(book: Book(instance)) {
  case book.stage, dict.size(book.allocations), book.listener {
    WitnessedClosed(identity), 0, None -> close_store(book, identity.store)
    WitnessedClosed(_), _, listener -> {
      cancel_connections(book)
      case listener {
        Some(transport) -> listener.close(transport)
        None -> Nil
      }
      sm.transition(Stopping, book)
    }
    _, _, _ -> sm.transition(Stopping, book)
  }
}

fn stop(
  phase: Phase,
  book: Book(instance),
  reply: Subject(Result(Nil, String)),
) -> sm.Next(Phase, Book(instance), Message(instance)) {
  case phase {
    RecoveryBlocked(reason) -> {
      process.send(reply, Error(reason))
      sm.keep(book)
    }
    Closed -> {
      process.send(reply, Ok(Nil))
      sm.stop()
    }
    Stopping -> sm.keep(book) |> sm.postpone
    Serving -> {
      cancel_session_connections(book)
      cancel_lifetime(book.stage)
      sm.transition(Stopping, book) |> sm.postpone
    }
    Dormant | Starting | Refused(_) -> close_unstarted(book) |> sm.postpone
  }
}

fn cancel_lifetime(stage: Stage(instance)) {
  case stage {
    Live(running) -> lifetime.shutdown(running.lifetime)
    Empty
    | Directory(_)
    | Locked(_)
    | Catalogued(_)
    | Authenticated(_)
    | WitnessedClosed(_) -> Nil
  }
}

fn block(book: Book(instance), reason: String) {
  cancel_connections(book)
  cancel_lifetime(book.stage)
  case book.listener {
    Some(transport) -> listener.close(transport)
    None -> Nil
  }
  sm.transition(RecoveryBlocked(reason), book)
}

fn witness_gone(
  phase: Phase,
  book: Book(instance),
  reason: process.ExitReason,
) {
  case phase, reason, book.stage {
    RecoveryBlocked(_), _, _ -> sm.keep(book)
    _, process.Normal, Live(running) -> {
      cancel_connections(book)
      finish_draining(Book(..book, stage: WitnessedClosed(running.identity)))
    }
    _, process.Abnormal(_), _ | _, process.Killed, _ ->
      block(book, "daemon aggregate retirement was not confirmed")
    _, process.Normal, _ ->
      block(book, "daemon witness did not match retained custody")
  }
}

// Before registry admission, a partial startup has no instance effects. Once
// Live, only the original normal witness event may call close_store.
fn close_unstarted(book: Book(instance)) {
  case book.stage {
    Empty | Directory(_) -> closed(book)
    Locked(lease) -> {
      release_lock(lease)
      closed(book)
    }
    Catalogued(store) -> close_store(book, store)
    Authenticated(identity) -> close_store(book, identity.store)
    Live(_) | WitnessedClosed(_) ->
      block(book, "daemon shutdown skipped its original witness")
  }
}

fn close_store(book: Book(instance), store: Store) {
  case catalogue.close(store.catalogue) {
    Error(_) -> block(book, "daemon catalogue close was not confirmed")
    Ok(Nil) -> {
      release_lock(store.lease)
      closed(book)
    }
  }
}

fn release_lock(lease: Lease) {
  process.demonitor_process(lease.watch)
  bootstrap.release_launch_lock(lease.lock)
}

fn closed(book: Book(instance)) {
  // Postponed shutdown requests replay before this mailbox message. Caller
  // death has no waiter, so Finish also retires an otherwise unused root.
  process.send(book.commands, Finish)
  sm.transition(Closed, Book(..book, stage: Empty))
}
