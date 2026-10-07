//// SQLite custody for one exact executor scope, before any native action.
////
//// A weft actor owns each connection. Every operation takes SQLite's immediate
//// writer lock, reads the current version, reduces against that committed book,
//// and commits changed evidence before replying. Independent opens therefore
//// share SQLite's serialization point, even across VMs. A stale actor replays
//// the bounded journal through admission, discarding every historical effect.
////
//// Fresh creation never replaces tables. Recovery never initializes them. The
//// metadata binds exact scope, capacity, row count and encoded-byte count; gaps,
//// extra rows, unknown commands and invalid transitions refuse recovery. Exact
//// duplicates write nothing. Each retained key has at most six changed records,
//// plus one closure record, so storage grows only with reserved lifetime slots.
////
//// A database error poisons and closes the connection. `Uncertain` can include
//// a committed transition; callers must recover and inspect the original key.
//// Timeout also means uncertainty, never definite refusal. Recovery returns no
//// launch decisions. The live caller must apply a returned Launch at most once;
//// this module neither launches processes nor proves native restart recovery.
////
//// Named queries and their row decoders come from Parrot/sqlc. The SQL source
//// owns storage shape; this module owns transactions and admission ordering.
////
//// Owned recovery self-adopts while resource-free. Its narrow history actor
//// closes explicitly before normal exit; the original managed run joins it.
////
//// `recover_owned` enters resource-free adoption before `handle_owned` activates
//// shared SQL recovery. `release_owned` observes successful explicit close and
//// the original DOWN; `shutdown_owned` cannot turn failed close into normal proof.
////
//// `park_fresh` links a resource-free original to its permanent starter.
//// `initialise_fresh` installs acquired SQL before shared setup; `release_fresh`
//// requires checked close ACK and original normal DOWN. `handle` preserves that
//// custody through all live operations and failed setup cleanup.
//// `shutdown_live_connection` prevents failed SQL close from yielding normal exit.
//// Parent-death cleanup is best effort, never complete physical retirement proof.
////
//// ## Flow
////
//// `fresh` and `recover` enter `setup` then `load`. Calls enter `exchange` and
//// `handle`: `transact` reads `current`, applies the pure reducer and commits
//// before replying. `payload_write` performs the same locked admission preflight
//// before storing exact bytes. `read_payload` checks blob-free aggregate bounds
//// then decodes generated SQL rows; it never recreates a launch decision.

import executor/custody_schema
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal_codec as codec
import executor/remote/payload
import executor/sql
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import sqlight
import weft
import weft/actor

/// A serialized custody endpoint; the database connection never leaves its actor.
pub opaque type Journal {
  /// Only module functions construct requests and receive bounded responses.
  Journal(
    /// The private actor address, never a database handle or native capability.
    subject: process.Subject(Message),
    /// Scope validated against durable metadata before this handle is returned.
    scope: identity.Scope,
  )
}

/// A bounded failure whose meaning never depends on caller-controlled SQL text.
pub type Error {
  /// Durability requires an absolute filesystem path, not a SQLite memory URI.
  InvalidPath

  /// Fresh creation found an existing filesystem path.
  AlreadyExists

  /// Recovery found no existing file; it creates no ledger.
  Missing

  /// Stored scope or capacity differs, including an unknown metadata version.
  BindingMismatch

  /// Rows, counts, bytes or reducer history fail complete validation.
  Corrupt

  /// The pure reducer refused the request without changing durable evidence.
  Rejected(
    /// The reducer's fixed, payload-free refusal.
    reason: admission.AdmissionError,
  )

  /// Database or reply failure; a write may have committed. Recover exact evidence.
  Uncertain

  /// The endpoint was released or poisoned; reopen through recovery.
  Closed

  /// The weft actor could not start; no launch decision was returned.
  StartFailed
}

/// A committed live decision, without exposing a duplicable replacement book.
pub type Decision {
  /// Evidence and launch permission are exposed only after the commit succeeds.
  Decision(
    /// The exact current reducer evidence.
    evidence: admission.Evidence,
    /// A live first-launch decision; historical effects never cross recovery.
    effect: admission.Effect,
  )
}

type Mode {
  Fresh
  Recover
}

type Config {
  Config(path: String, scope: identity.Scope, capacity: admission.Capacity)
}

type Snapshot {
  Snapshot(book: admission.Book, version: Int, bytes: Int)
}

/// Checked immutable live creation inputs, without an open connection.
@internal
pub opaque type FreshInput {
  /// The exact configuration retained before the original actor starts.
  FreshInput(
    /// Absolute original path, full scope and checked lifetime ceilings.
    config: Config,
  )
}

/// The original linked, resource-free child recorded by its permanent parent.
@internal
pub opaque type ParkedFresh {
  /// This exact original endpoint, PID, parent and input cannot be replaced.
  ParkedFresh(
    /// The same original serialized business endpoint.
    subject: process.Subject(Message),
    /// The original connection-owning child, never a replacement lookup.
    pid: process.Pid,
    /// The actual process that called linked construction.
    parent: process.Pid,
    /// The immutable inputs retained before startup.
    input: FreshInput,
  )
}

/// Successful initialization of that same original child, with live operations.
@internal
pub opaque type LiveFresh {
  /// Readiness binds the original parked handle to its one business endpoint.
  LiveFresh(
    /// The same recorded original child and immutable parent binding.
    original: ParkedFresh,
    /// Its live business endpoint after successful metadata COMMIT.
    journal: Journal,
  )
}

/// Closed original boundaries for parent-owned live construction controls.
@internal
pub type FreshCheckpoint {
  /// Resource-free startup has not yet acknowledged the actual parent.
  BeforeFreshStartAck

  /// The recorded original is about to open its immutable Fresh path.
  BeforeFreshSqlOpen

  /// The actual SQL connection is installed before the fallible setup turn.
  AfterFreshOpen

  /// Schema and immutable metadata committed before live readiness publication.
  BeforeFreshReadyReply

  /// The actual connection is about to close before its explicit reply.
  BeforeFreshCloseReply

  /// Successful explicit close precedes the original normal DOWN.
  AfterFreshCloseBeforeExit
}

/// Production has no deterministic checkpoint or injected close failure.
@internal
pub type FreshProbe {
  /// Production immediately continues the actual operation.
  FreshUnobserved

  /// A test observes only a closed original boundary and its one permit.
  FreshObserved(
    /// The test-owned observer of closed original boundaries.
    subject: process.Subject(FreshObservation),
  )
}

/// One original live actor reports before awaiting its closed test permit.
@internal
pub type FreshObservation {
  /// The exact original actor owns the fresh single-boundary permit subject.
  FreshObservation(
    /// The closed original operation boundary.
    checkpoint: FreshCheckpoint,
    /// The actual original actor at that boundary.
    owner: process.Pid,
    /// Its one-boundary permit, never an arbitrary callback.
    permit: process.Subject(RecoveryPermit),
  )
}

type LiveCustody {
  LegacyCustody
  ParentCustody(parent: process.Pid, probe: FreshProbe)
}

type State {
  Waiting(config: Config, custody: LiveCustody)
  Ready(
    config: Config,
    connection: sqlight.Connection,
    snapshot: Snapshot,
    custody: LiveCustody,
  )

  // This state owns the connection before setup can fail or commit.
  AcquiredFresh(
    config: Config,
    connection: sqlight.Connection,
    custody: LiveCustody,
    reply: process.Subject(Result(Nil, Error)),
  )

  // Normal final exit can only follow successful explicit SQL close.
  ReleasedFresh(probe: FreshProbe)

  // Failed close preserves the real connection for abnormal shutdown cleanup.
  FailedCloseFresh(connection: sqlight.Connection)
}

type Message {
  InitialiseFresh(process.Subject(Result(Nil, Error)))
  FinishFresh
  StopFresh
  Initialise(mode: Mode, reply: process.Subject(Result(Nil, Error)))
  Change(
    command: codec.Command,
    reply: process.Subject(Result(Option(Decision), Error)),
  )
  Inspect(
    key: identity.RequestKey,
    digest: identity.Digest,
    reply: process.Subject(Result(admission.Evidence, Error)),
  )
  PutPayload(
    key: identity.RequestKey,
    digest: identity.Digest,
    item: payload.Item,
    reply: process.Subject(Result(Nil, Error)),
  )
  ReadPayload(
    key: identity.RequestKey,
    digest: identity.Digest,
    reply: process.Subject(Result(List(payload.Item), Error)),
  )
  Release(reply: process.Subject(Result(Nil, Error)))
}

/// Exact immutable metadata for temporary native recovery, without a live claim.
@internal
pub opaque type RecoveryInput {
  /// Checked original path, full scope and capacity, with no connection.
  RecoveryInput(
    /// The checked path, full immutable scope and lifetime capacity.
    config: Config,
  )
}

/// The original adopted native writer, restricted to history and exact receipt.
@internal
pub opaque type OwnedRecovery {
  /// The original adopted history door, bound once while resource-free.
  OwnedRecovery(
    /// The private message endpoint.
    subject: process.Subject(OwnedMessage),
    /// The exact original monitored writer.
    pid: process.Pid,
    /// Its complete immutable checked scope.
    scope: identity.Scope,
  )
}

/// Closed deterministic observation points for owned recovery controls.
@internal
pub type RecoveryCheckpoint {
  /// The actor is resource-free and has not asked for custody.
  BeforeAdopt

  /// Custody exists, but the actor has not acknowledged startup.
  BeforeStartAck

  /// The adopted actor is about to open the original database.
  BeforeSqlOpen

  /// Validated recovery precedes the initialization reply.
  BeforeInitialiseReply

  /// Explicit close precedes its reply and final exit.
  BeforeCloseReply

  /// Successful explicit close precedes the original DOWN.
  AfterCloseBeforeExit
}

/// A closed permit changes only a deterministic test observation.
@internal
pub type RecoveryPermit {
  /// Continue the original operation.
  Proceed

  /// Omit the original reply without changing custody or the operation.
  SuppressReply

  /// Synthetic close refusal over a real SQLite owner, never production I/O evidence.
  RefuseClose
}

/// Production does not observe or block at test checkpoints.
@internal
pub type RecoveryProbe {
  /// No observation or injected failure exists in production.
  Unobserved

  /// A test owns each bounded original checkpoint and its explicit permit.
  Observed(
    /// The test-owned mailbox receiving only closed original checkpoints.
    subject: process.Subject(RecoveryObservation),
  )
}

/// The exact original actor reports before waiting for the test's permit.
@internal
pub type RecoveryObservation {
  /// One original actor waits on a permit owned by that same actor.
  RecoveryObservation(
    /// The closed boundary reached by this original actor.
    checkpoint: RecoveryCheckpoint,
    /// This actual actor, never a registry lookup or replacement.
    owner: process.Pid,
    /// A fresh one-boundary permit subject.
    permit: process.Subject(RecoveryPermit),
  )
}

type OwnedState {
  OwnedWaiting(config: Config, probe: RecoveryProbe)
  OwnedReady(
    config: Config,
    connection: sqlight.Connection,
    snapshot: Snapshot,
    probe: RecoveryProbe,
  )

  // Failed setup keeps its actual connection for abnormal shutdown cleanup.
  FailedCloseOwned(connection: sqlight.Connection)

  // Successful explicit close removes the connection before the exit turn.
  ReleasedOwned(probe: RecoveryProbe)
}

type OwnedMessage {
  InitialiseOwned(process.Subject(Result(Nil, Error)))
  InspectOwned(
    identity.RequestKey,
    identity.Digest,
    process.Subject(Result(admission.Evidence, Error)),
  )
  PayloadsOwned(
    identity.RequestKey,
    identity.Digest,
    process.Subject(Result(List(payload.Item), Error)),
  )
  ReceiptOwned(
    identity.RequestKey,
    identity.Digest,
    identity.Digest,
    process.Subject(Result(Decision, Error)),
  )
  ReleaseOwned(process.Subject(Result(Nil, Error)))
  StopOwned
}

const timeout_ms = 30_000

/// Returns the original validated binding, never a re-registration capability.
///
/// ## Examples
///
/// ```gleam
/// // journal.scope(book) == configured_scope
/// ```
pub fn scope(journal: Journal) -> identity.Scope {
  journal.scope
}

/// Creates custody for an unused database path. Existing evidence is never reset.
/// Metadata and schema commit together before this endpoint is returned.
/// Paths must be absolute filesystem names of at most 4096 bytes without NUL.
///
/// ## Examples
///
/// ```gleam
/// journal.fresh(path, scope, capacity) // -> Ok(journal) for an unused path.
/// ```
pub fn fresh(
  path: String,
  scope: identity.Scope,
  capacity: admission.Capacity,
) -> Result(Journal, Error) {
  start(Config(path, scope, capacity), Fresh)
}

/// Opens existing custody and replays changed commands without returning effects.
/// Scope and capacity must match the original creation exactly.
///
/// ## Examples
///
/// ```gleam
/// journal.recover(path, scope, capacity) // -> retained evidence, never Launch.
/// ```
pub fn recover(
  path: String,
  scope: identity.Scope,
  capacity: admission.Capacity,
) -> Result(Journal, Error) {
  start(Config(path, scope, capacity), Recover)
}

/// Durably reserves bounded evidence before acknowledging the admission.
/// An exact duplicate returns existing evidence and does not append a record.
///
/// ## Examples
///
/// ```gleam
/// journal.admit(journal, key, digest) // -> Ok(Decision(_, NoLaunch)).
/// ```
pub fn admit(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Decision, Error) {
  change(journal, codec.Admit(key, digest)) |> require_decision
}

/// Commits changed custody before exposing its acknowledgement or first Launch.
/// The trusted native adapter supplies retirement and durable receipt evidence.
///
/// ## Examples
///
/// ```gleam
/// journal.apply(journal, key, digest, admission.AuthorizeLaunch)
/// // -> Launch only for the first successfully committed live authorization.
/// ```
pub fn apply(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  event: admission.Event,
) -> Result(Decision, Error) {
  change(journal, codec.Apply(key, digest, event)) |> require_decision
}

/// Permanently closes this scope's admission epoch without releasing evidence.
/// Repeated closure writes nothing; settlement and exact inspection remain valid.
///
/// ## Examples
///
/// ```gleam
/// journal.close_epoch(journal) // -> Ok(Nil) after the closure commits.
/// ```
pub fn close_epoch(journal: Journal) -> Result(Nil, Error) {
  change(journal, codec.CloseEpoch) |> result.map(fn(_) { Nil })
}

/// Inspects the latest committed exact key, including after closure or compaction.
/// Independent writers are observed under the same SQLite transaction discipline.
///
/// ## Examples
///
/// ```gleam
/// journal.inspect(journal, key, digest) // -> Ok(retained_evidence).
/// ```
pub fn inspect(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(admission.Evidence, Error) {
  exchange(journal, Inspect(key, digest, _))
}

/// Commits immutable bounded bytes before admission, output or terminal acknowledgement.
/// Request reservation consumes a lifetime slot even if admission later fails.
/// Duplicate items compare exact bytes and append nothing; conflicting bytes fail.
///
/// ## Examples
///
/// ```gleam
/// journal.put_payload(journal, key, digest, payload.Request(bytes))
/// ```
pub fn put_payload(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  item: payload.Item,
) -> Result(Nil, Error) {
  exchange(journal, PutPayload(key, digest, item, _))
}

/// Retrieves original bounded immutable evidence, including after compaction.
/// No receipt or broker release deletes the only copy of result bytes.
///
/// ## Examples
///
/// ```gleam
/// journal.payloads(journal, key, digest) // -> exact retained items.
/// ```
pub fn payloads(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(List(payload.Item), Error) {
  exchange(journal, ReadPayload(key, digest, _))
}

/// Releases this connection without closing the epoch or declaring native drain.
/// The endpoint remains closed; recovery is a separate, explicit operation.
///
/// ## Examples
///
/// ```gleam
/// journal.release(journal) // -> Ok(Nil); journal.recover restores the ledger.
/// ```
pub fn release(journal: Journal) -> Result(Nil, Error) {
  case exchange(journal, Release) {
    Error(Closed) -> Ok(Nil)
    outcome -> outcome
  }
}

/// Checks exact live creation inputs without opening SQLite.
///
/// ## Examples
/// `fresh_input` alone grants no live Journal or execution claim.
@internal
pub fn fresh_input(
  path: String,
  scope: identity.Scope,
  capacity: admission.Capacity,
) -> Result(FreshInput, Error) {
  use Nil <- result.try(valid_owned_path(path))
  Ok(FreshInput(Config(path, scope, capacity)))
}

/// Starts a linked resource-free child from the actual permanent parent.
///
/// ## Examples
/// The host records `park_fresh(input)` before asking it to initialize.
@internal
pub fn park_fresh(input: FreshInput) -> Result(ParkedFresh, Error) {
  park_fresh_observed(input, FreshUnobserved)
}

/// Adds closed original checkpoints for real SQLite lifecycle controls.
///
/// ## Examples
/// Production uses `park_fresh` without a test probe.
@internal
pub fn park_fresh_observed(
  input: FreshInput,
  probe: FreshProbe,
) -> Result(ParkedFresh, Error) {
  let parent = process.self()
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(subject) {
      let _ = fresh_checkpoint(probe, BeforeFreshStartAck)
      Ok(
        actor.initialised(Waiting(input.config, ParentCustody(parent, probe)))
        |> actor.returning(subject),
      )
    })
    |> actor.trapping_exits(True)
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.start
    |> result.replace_error(StartFailed),
  )
  Ok(ParkedFresh(started.data, started.pid, parent, input))
}

/// Names this exact original child for the host's bounded staged ownership.
///
/// ## Examples
/// `fresh_owner(parked)` never performs a registry or replacement lookup.
@internal
pub fn fresh_owner(original: ParkedFresh) -> process.Pid {
  original.pid
}

/// Initializes only the original recorded child and exposes one live endpoint.
///
/// ## Examples
/// Duplicate initialization cannot mint another `LiveFresh`.
@internal
pub fn initialise_fresh(original: ParkedFresh) -> Result(LiveFresh, Error) {
  let book = Journal(original.subject, original.input.config.scope)
  use Nil <- result.try(exchange(book, InitialiseFresh))
  Ok(LiveFresh(original, book))
}

/// Projects the original business Journal only from successful live readiness.
///
/// ## Examples
/// Services use `fresh_journal(ready)` with their existing execution methods.
@internal
pub fn fresh_journal(ready: LiveFresh) -> Journal {
  ready.journal
}

/// Requires explicit close acknowledgement and the original normal DOWN.
///
/// ## Examples
/// Lost reply, late monitoring and abnormal close remain Uncertain.
@internal
pub fn release_fresh(original: ParkedFresh) -> Result(Nil, Error) {
  let watch = process.monitor(original.pid)
  let outcome = {
    use Nil <- result.try(exchange(
      Journal(original.subject, original.input.config.scope),
      Release,
    ))
    owned_down(watch)
  }
  process.demonitor_process(watch)
  outcome |> result.replace_error(Uncertain)
}

/// Validates the original full scope and actual permanent starter identity.
///
/// ## Examples
/// Resource calls this before park and again before opening its own SQL.
@internal
pub fn validate_fresh_dependency(
  ready: LiveFresh,
  expected_scope: identity.Scope,
  expected_parent: process.Pid,
) -> Result(Journal, Error) {
  use Nil <- result.try(
    case
      ready.original.parent == expected_parent
      && ready.journal.scope == expected_scope
    {
      True -> Ok(Nil)
      False -> Error(BindingMismatch)
    },
  )
  case process.is_alive(ready.original.pid) {
    True -> Ok(ready.journal)
    False -> Error(Closed)
  }
}

/// Checks original native recovery metadata without opening or granting authority.
///
/// ## Examples
/// `recovery_input(path, scope, capacity)` retains those exact recovery inputs.
@internal
pub fn recovery_input(
  path: String,
  scope: identity.Scope,
  capacity: admission.Capacity,
) -> Result(RecoveryInput, Error) {
  use Nil <- result.try(valid_owned_path(path))
  Ok(RecoveryInput(Config(path, scope, capacity)))
}

/// Reads the complete original scope from metadata, without acquiring custody.
///
/// ## Examples
/// Resource recovery compares this value with its enrollment-derived full scope.
@internal
pub fn recovery_scope(input: RecoveryInput) -> identity.Scope {
  input.config.scope
}

/// Recovers only historical native evidence under the original managed task.
///
/// ## Examples
/// `recover_owned(input, ledger)` adopts before opening the original SQLite file.
@internal
pub fn recover_owned(
  input: RecoveryInput,
  ledger: weft.Ledger,
) -> Result(OwnedRecovery, Error) {
  start_owned(input, ledger, None, Unobserved)
}

/// Stages this exact temporary native writer beneath its original resource owner.
///
/// ## Examples
/// The parent must already be an unresolved owner of this same ledger task.
@internal
pub fn recover_owned_under(
  input: RecoveryInput,
  ledger: weft.Ledger,
  parent: process.Pid,
) -> Result(OwnedRecovery, Error) {
  start_owned(input, ledger, Some(parent), Unobserved)
}

/// Adds closed deterministic checkpoints to a real owned recovery control.
///
/// ## Examples
/// Production callers use `recover_owned` without any probe.
@internal
pub fn recover_owned_observed(
  input: RecoveryInput,
  ledger: weft.Ledger,
  parent: Option(process.Pid),
  probe: RecoveryProbe,
) -> Result(OwnedRecovery, Error) {
  start_owned(input, ledger, parent, probe)
}

/// Reads the complete immutable scope of this original adopted writer.
///
/// ## Examples
/// Resource installation compares this value before opening its own SQL file.
@internal
pub fn scope_owned(original: OwnedRecovery) -> identity.Scope {
  original.scope
}

/// Inspects exact original evidence without admitting a native execution.
///
/// ## Examples
/// `inspect_owned(original, key, digest)` cannot construct a Launch effect.
@internal
pub fn inspect_owned(
  original: OwnedRecovery,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(admission.Evidence, Error) {
  exchange_owned(original, InspectOwned(key, digest, _))
}

/// Reads the bounded retained payloads from this original adopted writer.
///
/// ## Examples
/// Original request, output and terminal evidence remain separately typed items.
@internal
pub fn payloads_owned(
  original: OwnedRecovery,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(List(payload.Item), Error) {
  exchange_owned(original, PayloadsOwned(key, digest, _))
}

/// Applies only the existing exact owner-receipt event, never a launch event.
///
/// ## Examples
/// The history caller validates complete receipt content before this operation.
@internal
pub fn confirm_owner_receipt_owned(
  original: OwnedRecovery,
  key: identity.RequestKey,
  prepared: identity.Digest,
  terminal: identity.Digest,
) -> Result(Decision, Error) {
  exchange_owned(original, ReceiptOwned(key, prepared, terminal, _))
}

/// Requires the explicit close reply and the normal original actor DOWN.
///
/// ## Examples
/// Missing reply, Closed, abnormal exit and late monitoring stay Uncertain.
@internal
pub fn release_owned(original: OwnedRecovery) -> Result(Nil, Error) {
  let watch = process.monitor(original.pid)
  let outcome = {
    use Nil <- result.try(exchange_owned(original, ReleaseOwned))
    owned_down(watch)
  }
  process.demonitor_process(watch)
  outcome
}

fn start_owned(
  input: RecoveryInput,
  ledger: weft.Ledger,
  parent: Option(process.Pid),
  probe: RecoveryProbe,
) -> Result(OwnedRecovery, Error) {
  // Startup acknowledges only custody; the initializer never owns SQLite.
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(subject) {
      let _ = recovery_checkpoint(probe, BeforeAdopt)

      // A queued close survives requester death and precedes any later activation.
      let cancel = fn() {
        process.send(subject, ReleaseOwned(process.new_subject()))
      }
      let adopted = case parent {
        None -> weft.adopt(ledger, owner: process.self(), cancel:)
        Some(parent) ->
          weft.adopt_under(ledger, parent:, owner: process.self(), cancel:)
      }
      case adopted {
        weft.Refused -> Error("owned recovery adoption refused")
        weft.Adopted -> {
          let _ = recovery_checkpoint(probe, BeforeStartAck)
          Ok(
            actor.initialised(OwnedWaiting(input.config, probe))
            |> actor.returning(subject),
          )
        }
      }
    })
    |> actor.on_message(handle_owned)
    |> actor.on_shutdown(shutdown_owned)
    |> actor.unlinked
    |> actor.start
    |> result.replace_error(StartFailed),
  )

  // This immutable handle names the actor that acquired the ledger custody.
  let original = OwnedRecovery(started.data, started.pid, input.config.scope)
  case exchange_owned(original, InitialiseOwned) {
    Ok(Nil) -> Ok(original)
    Error(error) -> {
      process.send(original.subject, ReleaseOwned(process.new_subject()))
      Error(error)
    }
  }
}

fn exchange_owned(
  original: OwnedRecovery,
  make: fn(process.Subject(Result(a, Error))) -> OwnedMessage,
) -> Result(a, Error) {
  let reply = process.new_subject()
  let watch = process.monitor(original.pid)
  process.send(original.subject, make(reply))
  let answer =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(watch, fn(_) { Error(Uncertain) })
    |> process.selector_receive(timeout_ms)
  process.demonitor_process(watch)
  result.unwrap(answer, Error(Uncertain))
}

fn owned_down(watch: process.Monitor) -> Result(Nil, Error) {
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(down) {
    case down {
      process.ProcessDown(reason: process.Normal, ..) -> Ok(Nil)
      process.ProcessDown(..) | process.PortDown(..) -> Error(Uncertain)
    }
  })
  |> process.selector_receive(timeout_ms)
  |> result.unwrap(Error(Uncertain))
}

fn handle_owned(
  state: OwnedState,
  message: OwnedMessage,
) -> actor.Next(OwnedState, OwnedMessage) {
  case state, message {
    OwnedWaiting(config, probe), InitialiseOwned(reply) ->
      initialise_owned(config, probe, reply)
    OwnedReady(config, connection, snapshot, probe),
      InspectOwned(key, digest, reply)
    -> {
      let outcome = {
        use current <- result.try(read_current(connection, config, snapshot))
        admission.inspect(current.book, key, digest)
        |> result.map_error(Rejected)
      }
      process.send(reply, outcome)
      case outcome {
        Ok(_) | Error(Rejected(_)) -> actor.continue(state)
        Error(_) -> stop_owned_connection(connection, probe)
      }
    }
    OwnedReady(config, connection, _, probe), PayloadsOwned(key, digest, reply)
    -> {
      let outcome = read_payload(connection, config, key, digest)
      process.send(reply, outcome)
      case outcome {
        Ok(_) | Error(Rejected(_)) -> actor.continue(state)
        Error(_) -> stop_owned_connection(connection, probe)
      }
    }
    OwnedReady(config, connection, snapshot, probe),
      ReceiptOwned(key, digest, terminal, reply)
    -> {
      let outcome =
        transact(
          connection,
          config,
          snapshot,
          codec.Apply(key, digest, admission.ConfirmOwnerReceipt(terminal)),
        )
      case outcome {
        Ok(#(next, decision)) -> {
          process.send(reply, require_decision(Ok(decision)))
          actor.continue(OwnedReady(config, connection, next, probe))
        }
        Error(Rejected(reason)) -> {
          process.send(reply, Error(Rejected(reason)))
          actor.continue(state)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          stop_owned_connection(connection, probe)
        }
      }
    }
    OwnedReady(_, connection, _, probe), ReleaseOwned(reply) -> {
      let decision = recovery_checkpoint(probe, BeforeCloseReply)
      case close_owned_connection(connection, decision) {
        Ok(Nil) -> {
          recovery_reply(decision, reply, Ok(Nil))
          actor.continue(ReleasedOwned(probe)) |> actor.then_handle(StopOwned)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.stop_abnormal("owned native SQL close failed")
        }
      }
    }
    OwnedWaiting(_, probe), ReleaseOwned(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(ReleasedOwned(probe)) |> actor.then_handle(StopOwned)
    }
    FailedCloseOwned(_), StopOwned ->
      actor.stop_abnormal("owned SQL cleanup failed")

    // Only this connection-free state may produce a normal exit witness.
    ReleasedOwned(probe), StopOwned -> {
      let _ = recovery_checkpoint(probe, AfterCloseBeforeExit)
      actor.stop()
    }
    OwnedWaiting(_, _), InspectOwned(_, _, reply)
    | ReleasedOwned(_), InspectOwned(_, _, reply)
    | FailedCloseOwned(_), InspectOwned(_, _, reply)
    -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    OwnedWaiting(_, _), PayloadsOwned(_, _, reply)
    | ReleasedOwned(_), PayloadsOwned(_, _, reply)
    | FailedCloseOwned(_), PayloadsOwned(_, _, reply)
    -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    OwnedWaiting(_, _), ReceiptOwned(_, _, _, reply)
    | ReleasedOwned(_), ReceiptOwned(_, _, _, reply)
    | FailedCloseOwned(_), ReceiptOwned(_, _, _, reply)
    -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    OwnedReady(_, _, _, _), InitialiseOwned(reply)
    | ReleasedOwned(_), InitialiseOwned(reply)
    | FailedCloseOwned(_), InitialiseOwned(reply)
    -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    ReleasedOwned(_), ReleaseOwned(reply)
    | FailedCloseOwned(_), ReleaseOwned(reply)
    -> {
      process.send(reply, Error(Uncertain))
      actor.continue(state)
    }
    OwnedWaiting(_, _), StopOwned | OwnedReady(_, _, _, _), StopOwned ->
      actor.stop_abnormal("owned native premature stop")
  }
}

fn initialise_owned(
  config: Config,
  probe: RecoveryProbe,
  reply: process.Subject(Result(Nil, Error)),
) -> actor.Next(OwnedState, OwnedMessage) {
  let _ = recovery_checkpoint(probe, BeforeSqlOpen)
  case open_owned(config) {
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(ReleasedOwned(probe)) |> actor.then_handle(StopOwned)
    }
    Ok(connection) ->
      settle_owned_setup(
        config,
        connection,
        probe,
        reply,
        setup(connection, config, Recover),
      )
  }
}

fn settle_owned_setup(
  config: Config,
  connection: sqlight.Connection,
  probe: RecoveryProbe,
  reply: process.Subject(Result(Nil, Error)),
  outcome: Result(Snapshot, Error),
) -> actor.Next(OwnedState, OwnedMessage) {
  case outcome {
    Ok(snapshot) -> {
      let decision = recovery_checkpoint(probe, BeforeInitialiseReply)
      recovery_reply(decision, reply, Ok(Nil))
      actor.continue(OwnedReady(config, connection, snapshot, probe))
    }
    Error(error) -> {
      process.send(reply, Error(error))

      // Setup has opened SQL, so failure must retain or explicitly close it.
      stop_owned_connection(connection, probe)
    }
  }
}

fn valid_owned_path(path: String) -> Result(Nil, Error) {
  case
    string.starts_with(path, "/")
    && string.byte_size(path) <= 4096
    && !string.contains(path, "\u{0}")
  {
    True -> Ok(Nil)
    False -> Error(InvalidPath)
  }
}

fn open_owned(config: Config) -> Result(sqlight.Connection, Error) {
  use exists <- result.try(
    simplifile.exists(config.path, False) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(case exists {
    True -> Ok(Nil)
    False -> Error(Missing)
  })
  sqlight.open(config.path) |> sql_error
}

fn stop_owned_connection(
  connection: sqlight.Connection,
  probe: RecoveryProbe,
) -> actor.Next(OwnedState, OwnedMessage) {
  let decision = recovery_checkpoint(probe, BeforeCloseReply)
  case close_owned_connection(connection, decision) {
    Ok(Nil) ->
      actor.continue(ReleasedOwned(probe)) |> actor.then_handle(StopOwned)
    Error(_) ->
      // The next abnormal turn carries the actual connection into shutdown.
      actor.continue(FailedCloseOwned(connection))
      |> actor.then_handle(StopOwned)
  }
}

fn close_owned_connection(
  connection: sqlight.Connection,
  decision: RecoveryPermit,
) -> Result(Nil, Error) {
  case decision {
    RefuseClose -> Error(Uncertain)
    Proceed | SuppressReply -> sqlight.close(connection) |> sql_error
  }
}

// Abnormal failure remains lost proof even if this final cleanup succeeds.
// A close failure on system termination must never leave a normal DOWN.
fn shutdown_owned(state: OwnedState, _reason: process.ExitReason) -> Nil {
  case state {
    OwnedWaiting(_, _) | ReleasedOwned(_) -> Nil
    OwnedReady(_, connection, _, _) | FailedCloseOwned(connection) -> {
      case sqlight.close(connection) {
        Ok(Nil) -> Nil
        Error(_) -> process.kill(process.self())
      }
    }
  }
}

/// Reports one closed test checkpoint; production immediately continues.
///
/// ## Examples
/// A test releases the exact actor through the reported one-boundary permit.
@internal
pub fn recovery_checkpoint(
  probe: RecoveryProbe,
  checkpoint: RecoveryCheckpoint,
) -> RecoveryPermit {
  case probe {
    Unobserved -> Proceed
    Observed(subject) -> {
      let permit = process.new_subject()
      process.send(
        subject,
        RecoveryObservation(checkpoint, process.self(), permit),
      )
      process.new_selector()
      |> process.select(permit)
      |> process.selector_receive_forever()
    }
  }
}

/// Preserves reply-loss controls without changing the actual operation.
///
/// ## Examples
/// Suppressing a reply does not cancel the admitted original writer.
@internal
pub fn recovery_reply(
  decision: RecoveryPermit,
  reply: process.Subject(a),
  value: a,
) -> Nil {
  case decision {
    Proceed | RefuseClose -> process.send(reply, value)
    SuppressReply -> Nil
  }
}

fn start(config: Config, mode: Mode) -> Result(Journal, Error) {
  use Nil <- result.try(
    case
      string.starts_with(config.path, "/")
      && string.byte_size(config.path) <= 4096
      && !string.contains(config.path, "\u{0}")
    {
      True -> Ok(Nil)
      False -> Error(InvalidPath)
    },
  )
  use started <- result.try(
    actor.new(Waiting(config, LegacyCustody))
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.unlinked
    |> actor.start
    |> result.map_error(fn(_) { StartFailed }),
  )
  let journal = Journal(started.data, config.scope)
  case exchange(journal, Initialise(mode, _)) {
    Ok(Nil) -> Ok(journal)
    Error(error) -> {
      // Startup uncertainty may leave initialization queued. Releasing behind
      // it ensures that an endpoint withheld from the caller cannot linger.
      process.send(journal.subject, Release(process.new_subject()))
      Error(error)
    }
  }
}

fn change(
  journal: Journal,
  command: codec.Command,
) -> Result(Option(Decision), Error) {
  exchange(journal, Change(command, _))
}

fn exchange(
  journal: Journal,
  make_request: fn(process.Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  use owner <- result.try(
    process.subject_owner(journal.subject) |> result.map_error(fn(_) { Closed }),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error(Closed)
  })
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  process.send(journal.subject, make_request(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) { Error(Uncertain) })
    |> process.selector_receive(timeout_ms)

  // Death after sending cannot prove that the transaction did not commit.
  // Demonitoring flushes its notification; timeout only abandons the wait.
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(Uncertain))
}

fn require_decision(
  value: Result(Option(Decision), Error),
) -> Result(Decision, Error) {
  use decision <- result.try(value)
  case decision {
    Some(value) -> Ok(value)
    None -> Error(Corrupt)
  }
}

// Acquired state is installed before an injected setup turn. The admitted setup
// may finish or COMMIT before a queued parent exit; this is not preemption.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case state, message {
    Waiting(config, custody), InitialiseFresh(reply) -> {
      case custody {
        LegacyCustody -> reject_live_message(state, message)
        ParentCustody(..) -> {
          let _ = fresh_checkpoint(live_probe(custody), BeforeFreshSqlOpen)
          case open_fresh(config, custody) {
            Ok(connection) ->
              actor.continue(AcquiredFresh(config, connection, custody, reply))
              |> actor.then_handle(FinishFresh)
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(ReleasedFresh(live_probe(custody)))
              |> actor.then_handle(StopFresh)
            }
          }
        }
      }
    }
    AcquiredFresh(config, connection, custody, reply), FinishFresh -> {
      let _ = fresh_checkpoint(live_probe(custody), AfterFreshOpen)
      case setup(connection, config, Fresh) {
        Ok(snapshot) -> {
          let permit =
            fresh_checkpoint(live_probe(custody), BeforeFreshReadyReply)
          recovery_reply(permit, reply, Ok(Nil))
          actor.continue(Ready(config, connection, snapshot, custody))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          stop_live_connection(connection, custody)
        }
      }
    }
    ReleasedFresh(probe), StopFresh -> {
      let _ = fresh_checkpoint(probe, AfterFreshCloseBeforeExit)
      actor.stop()
    }
    FailedCloseFresh(_), StopFresh ->
      actor.stop_abnormal("live Fresh SQL close failed")
    Waiting(..), FinishFresh
    | Ready(..), FinishFresh
    | ReleasedFresh(_), FinishFresh
    | FailedCloseFresh(_), FinishFresh
    | Waiting(..), StopFresh
    | Ready(..), StopFresh
    | AcquiredFresh(..), StopFresh
    -> actor.stop_abnormal("live Fresh invalid lifecycle turn")
    _, _ -> handle_business(state, message)
  }
}

/// Reports one closed live boundary; production immediately continues.
///
/// ## Examples
/// A test permits the exact original actor through its reported subject.
@internal
pub fn fresh_checkpoint(
  probe: FreshProbe,
  checkpoint: FreshCheckpoint,
) -> RecoveryPermit {
  case probe {
    FreshUnobserved -> Proceed
    FreshObserved(subject) -> {
      let permit = process.new_subject()
      process.send(
        subject,
        FreshObservation(checkpoint, process.self(), permit),
      )
      process.new_selector()
      |> process.select(permit)
      |> process.selector_receive_forever()
    }
  }
}

fn live_probe(custody: LiveCustody) -> FreshProbe {
  case custody {
    LegacyCustody -> FreshUnobserved
    ParentCustody(_, probe) -> probe
  }
}

fn open_fresh(
  config: Config,
  _custody: LiveCustody,
) -> Result(sqlight.Connection, Error) {
  use exists <- result.try(
    simplifile.exists(config.path, False) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(case exists {
    True -> Error(AlreadyExists)
    False -> Ok(Nil)
  })
  sqlight.open(config.path) |> sql_error
}

fn release_live_connection(
  connection: sqlight.Connection,
  custody: LiveCustody,
  reply: process.Subject(Result(Nil, Error)),
) -> actor.Next(State, Message) {
  case custody {
    LegacyCustody -> {
      process.send(reply, sqlight.close(connection) |> sql_error)
      actor.stop()
    }
    ParentCustody(..) -> {
      let probe = live_probe(custody)
      let permit = fresh_checkpoint(probe, BeforeFreshCloseReply)
      let closed = close_owned_connection(connection, permit)
      recovery_reply(permit, reply, closed)
      finish_live_close(connection, probe, closed)
    }
  }
}

fn stop_live_connection(
  connection: sqlight.Connection,
  custody: LiveCustody,
) -> actor.Next(State, Message) {
  case custody {
    LegacyCustody -> {
      actor.stop()
    }
    ParentCustody(..) -> {
      let probe = live_probe(custody)
      let permit = fresh_checkpoint(probe, BeforeFreshCloseReply)
      finish_live_close(
        connection,
        probe,
        close_owned_connection(connection, permit),
      )
    }
  }
}

// Legacy settlement completes rollback and close before publishing its error.
// Owned settlement publishes first, then retains checked original close custody.
fn stop_settlement_connection(
  connection: sqlight.Connection,
  custody: LiveCustody,
  error: Error,
  reply: process.Subject(Result(a, Error)),
) -> actor.Next(State, Message) {
  case custody {
    LegacyCustody -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      process.send(reply, Error(error))
      actor.stop()
    }
    ParentCustody(..) -> {
      process.send(reply, Error(error))
      stop_live_connection(connection, custody)
    }
  }
}

fn finish_live_close(
  connection: sqlight.Connection,
  probe: FreshProbe,
  closed: Result(Nil, Error),
) -> actor.Next(State, Message) {
  case closed {
    Ok(Nil) ->
      actor.continue(ReleasedFresh(probe)) |> actor.then_handle(StopFresh)
    Error(_) ->
      actor.continue(FailedCloseFresh(connection))
      |> actor.then_handle(StopFresh)
  }
}

fn shutdown_live_connection(connection: sqlight.Connection) -> Nil {
  case sqlight.close(connection) {
    Ok(Nil) -> Nil
    Error(_) -> process.kill(process.self())
  }
}

fn reject_live_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Initialise(_, reply) | InitialiseFresh(reply) | Release(reply) ->
      process.send(reply, Error(Closed))
    Change(_, reply) -> process.send(reply, Error(Closed))
    Inspect(_, _, reply) -> process.send(reply, Error(Closed))
    PutPayload(_, _, _, reply) -> process.send(reply, Error(Closed))
    ReadPayload(_, _, reply) -> process.send(reply, Error(Closed))
    FinishFresh | StopFresh -> Nil
  }
  actor.continue(state)
}

fn handle_business(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message, state {
    Initialise(mode, reply), Waiting(config, LegacyCustody) -> {
      case initialise(config, mode) {
        Ok(#(connection, snapshot)) -> {
          process.send(reply, Ok(Nil))
          actor.continue(Ready(config, connection, snapshot, LegacyCustody))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.stop()
        }
      }
    }
    Change(command, reply), Ready(config, connection, snapshot, custody) -> {
      let outcome = transact(connection, config, snapshot, command)
      settle_change(outcome, config, connection, snapshot, custody, reply)
    }
    Inspect(key, digest, reply), Ready(config, connection, snapshot, custody) -> {
      let outcome = read_current(connection, config, snapshot)
      settle_inspect(outcome, config, connection, custody, key, digest, reply)
    }
    PutPayload(key, digest, item, reply),
      Ready(config, connection, snapshot, custody)
    -> {
      let outcome =
        payload_write(connection, config, snapshot, key, digest, item)
      process.send(reply, outcome)
      case outcome {
        Ok(_) | Error(Rejected(_)) -> actor.continue(state)
        Error(_) -> stop_live_connection(connection, custody)
      }
    }
    ReadPayload(key, digest, reply), Ready(config, connection, _, custody) -> {
      let outcome = read_payload(connection, config, key, digest)
      process.send(reply, outcome)
      case outcome {
        Ok(_) | Error(Rejected(_)) -> actor.continue(state)
        Error(_) -> stop_live_connection(connection, custody)
      }
    }
    PutPayload(_, _, _, reply), Waiting(_, _) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    ReadPayload(_, _, reply), Waiting(_, _) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Release(reply), Ready(_, connection, _, custody) -> {
      release_live_connection(connection, custody, reply)
    }
    Release(reply), Waiting(_, custody) -> {
      process.send(reply, Ok(Nil))
      case custody {
        LegacyCustody -> actor.stop()
        ParentCustody(_, probe) ->
          actor.continue(ReleasedFresh(probe)) |> actor.then_handle(StopFresh)
      }
    }
    Initialise(_, reply), Ready(_, _, _, _) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Change(_, reply), Waiting(_, _) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Inspect(_, _, reply), Waiting(_, _) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Initialise(_, _), Waiting(_, ParentCustody(..)) ->
      reject_live_message(state, message)
    _, AcquiredFresh(..) | _, ReleasedFresh(_) | _, FailedCloseFresh(_) ->
      reject_live_message(state, message)
    InitialiseFresh(_), _ | FinishFresh, _ | StopFresh, _ ->
      reject_live_message(state, message)
  }
}

fn initialise(
  config: Config,
  mode: Mode,
) -> Result(#(sqlight.Connection, Snapshot), Error) {
  use exists <- result.try(
    simplifile.exists(config.path, False)
    |> result.map_error(fn(_) { Uncertain }),
  )
  use Nil <- result.try(case mode, exists {
    Fresh, True -> Error(AlreadyExists)
    Recover, False -> Error(Missing)
    Fresh, False | Recover, True -> Ok(Nil)
  })
  use connection <- result.try(sqlight.open(config.path) |> sql_error)
  let outcome = setup(connection, config, mode)
  case outcome {
    Ok(snapshot) -> Ok(#(connection, snapshot))
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

fn setup(
  connection: sqlight.Connection,
  config: Config,
  mode: Mode,
) -> Result(Snapshot, Error) {
  // Require a crash-safe journal mode rather than inheriting a database's
  // configuration. FULL synchronization then makes commit the custody boundary.
  use Nil <- result.try(
    sqlight.exec("PRAGMA busy_timeout=5000", connection) |> sql_error,
  )
  use modes <- result.try(
    sqlight.query(
      "PRAGMA journal_mode=WAL",
      connection,
      [],
      decode.field(0, decode.string, decode.success),
    )
    |> sql_error,
  )
  use Nil <- result.try(case modes {
    ["wal"] -> Ok(Nil)
    _ -> Error(Uncertain)
  })
  use Nil <- result.try(
    sqlight.exec(
      "PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE",
      connection,
    )
    |> sql_error,
  )
  use Nil <- result.try(case mode {
    Fresh -> create(connection, config)
    Recover -> Ok(Nil)
  })
  use snapshot <- result.try(load(connection, config))
  use Nil <- result.try(sqlight.exec("COMMIT", connection) |> sql_error)
  Ok(snapshot)
}

fn create(
  connection: sqlight.Connection,
  config: Config,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    sqlight.exec(custody_schema.schema, connection)
    |> sql_error,
  )
  statement(
    connection,
    sql.initialize_custody(
      codec.binding(config.scope),
      admission.capacity_value(config.capacity),
    ),
  )
}

fn metadata(
  connection: sqlight.Connection,
  config: Config,
) -> Result(#(Int, Int), Error) {
  // SQLite affinity permits blobs in integer columns. Project only bounded
  // scalars so corruption cannot allocate a blob before the decoder refuses it.
  use rows <- result.try(
    query(connection, sql.custody_metadata())
    |> result.map_error(fn(_) { Corrupt }),
  )
  case rows {
    [sql.CustodyMetadata(binding:, capacity:, version:, bytes:)] -> {
      use Nil <- result.try(
        case
          binding == codec.binding(config.scope)
          && capacity == admission.capacity_value(config.capacity)
        {
          True -> Ok(Nil)
          False -> Error(BindingMismatch)
        },
      )
      let max_records = capacity * 6 + 1
      case
        version >= 0
        && version <= max_records
        && bytes >= 0
        && bytes <= version * codec.record_bytes
      {
        True -> Ok(#(version, bytes))
        False -> Error(Corrupt)
      }
    }
    _ -> Error(Corrupt)
  }
}

fn load(
  connection: sqlight.Connection,
  config: Config,
) -> Result(Snapshot, Error) {
  use meta <- result.try(metadata(connection, config))
  load_rows(connection, config, meta)
}

fn load_rows(
  connection: sqlight.Connection,
  config: Config,
  meta: #(Int, Int),
) -> Result(Snapshot, Error) {
  let #(version, bytes) = meta
  use rows <- result.try(
    query(
      connection,
      sql.custody_events(admission.capacity_value(config.capacity) * 6 + 2),
    )
    |> result.map_error(fn(_) { Corrupt }),
  )
  use snapshot <- result.try(
    list.try_fold(
      rows,
      Snapshot(admission.new(config.scope, config.capacity), 0, 0),
      fn(snapshot, row) {
        replay(snapshot, #(row.seq, row.payload), config.scope)
      },
    ),
  )
  case snapshot.version == version && snapshot.bytes == bytes {
    True -> Ok(snapshot)
    False -> Error(Corrupt)
  }
}

fn replay(
  snapshot: Snapshot,
  row: #(Int, BitArray),
  scope: identity.Scope,
) -> Result(Snapshot, Error) {
  let #(sequence, payload) = row
  use Nil <- result.try(case sequence == snapshot.version + 1 {
    True -> Ok(Nil)
    False -> Error(Corrupt)
  })
  use command <- result.try(
    codec.decode(payload, scope) |> result.map_error(fn(_) { Corrupt }),
  )
  use changed <- result.try(
    reduce(snapshot.book, command) |> result.map_error(fn(_) { Corrupt }),
  )
  let #(book, _historical_decision) = changed

  // A durable record must represent a real change. Discarding the historical
  // decision prevents recovery from exposing the first authorization again.
  case book != snapshot.book {
    True ->
      Ok(Snapshot(book, sequence, snapshot.bytes + bit_array.byte_size(payload)))
    False -> Error(Corrupt)
  }
}

fn reduce(
  book: admission.Book,
  command: codec.Command,
) -> Result(#(admission.Book, Option(Decision)), Error) {
  case command {
    codec.CloseEpoch -> Ok(#(admission.close(book), None))
    codec.Admit(key, digest) -> {
      use transition <- result.try(
        admission.admit(book, key, digest) |> result.map_error(Rejected),
      )
      Ok(#(
        transition.next,
        Some(Decision(transition.evidence, transition.effect)),
      ))
    }
    codec.Apply(key, digest, event) -> {
      use transition <- result.try(
        admission.reduce(book, key, digest, event) |> result.map_error(Rejected),
      )
      Ok(#(
        transition.next,
        Some(Decision(transition.evidence, transition.effect)),
      ))
    }
  }
}

fn current(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
) -> Result(Snapshot, Error) {
  use meta <- result.try(metadata(connection, config))
  case meta == #(snapshot.version, snapshot.bytes) {
    True -> Ok(snapshot)
    False -> load_rows(connection, config, meta)
  }
}

fn transact(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
  command: codec.Command,
) -> Result(#(Snapshot, Option(Decision)), Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = persist(connection, config, snapshot, command)
  finish_transaction(connection, outcome)
}

fn persist(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
  command: codec.Command,
) -> Result(#(Snapshot, Option(Decision)), Error) {
  use latest <- result.try(current(connection, config, snapshot))
  use changed <- result.try(reduce(latest.book, command))
  let #(book, decision) = changed
  case book == latest.book {
    True -> Ok(#(latest, decision))
    False -> {
      use next <- result.try(append(
        connection,
        latest,
        book,
        codec.encode(command),
      ))
      Ok(#(next, decision))
    }
  }
}

fn append(
  connection: sqlight.Connection,
  old: Snapshot,
  book: admission.Book,
  payload: BitArray,
) -> Result(Snapshot, Error) {
  let version = old.version + 1
  let bytes = old.bytes + bit_array.byte_size(payload)
  use _ <- result.try(statement(
    connection,
    sql.append_custody_event(version, payload),
  ))

  // The writer lock makes this CAS uncontended in normal operation. Checking
  // its returned row also refuses a schema or trigger that lost the head update.
  use rows <- result.try(query(
    connection,
    sql.advance_custody_head(version, bytes, old.version, old.bytes),
  ))
  case rows {
    [sql.AdvanceCustodyHead(version: value)] if value == version ->
      Ok(Snapshot(book, version, bytes))
    _ -> Error(Uncertain)
  }
}

fn finish_transaction(
  connection: sqlight.Connection,
  outcome: Result(a, Error),
) -> Result(a, Error) {
  case outcome {
    Ok(value) -> {
      use Nil <- result.try(sqlight.exec("COMMIT", connection) |> sql_error)
      Ok(value)
    }
    Error(error) -> {
      case sqlight.exec("ROLLBACK", connection) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(Uncertain)
      }
    }
  }
}

fn read_current(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
) -> Result(Snapshot, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  finish_transaction(connection, current(connection, config, snapshot))
}

fn settle_change(
  outcome: Result(#(Snapshot, Option(Decision)), Error),
  config: Config,
  connection: sqlight.Connection,
  previous: Snapshot,
  custody: LiveCustody,
  reply: process.Subject(Result(Option(Decision), Error)),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(#(snapshot, decision)) -> {
      process.send(reply, Ok(decision))
      actor.continue(Ready(config, connection, snapshot, custody))
    }
    Error(Rejected(reason)) -> {
      process.send(reply, Error(Rejected(reason)))

      // A reducer rejection rolled back safely. A cached older version stays
      // valid: the next transaction reloads if another connection advanced it.
      actor.continue(Ready(config, connection, previous, custody))
    }
    Error(error) -> {
      stop_settlement_connection(connection, custody, error, reply)
    }
  }
}

fn settle_inspect(
  outcome: Result(Snapshot, Error),
  config: Config,
  connection: sqlight.Connection,
  custody: LiveCustody,
  key: identity.RequestKey,
  digest: identity.Digest,
  reply: process.Subject(Result(admission.Evidence, Error)),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(snapshot) -> {
      process.send(
        reply,
        admission.inspect(snapshot.book, key, digest)
          |> result.map_error(Rejected),
      )
      actor.continue(Ready(config, connection, snapshot, custody))
    }
    Error(error) -> {
      stop_settlement_connection(connection, custody, error, reply)
    }
  }
}

// Generated statements run on the actor's existing transaction. The adapter
// preserves sqlc's parameter order and decoder instead of maintaining a second
// handwritten account of the query's columns.
fn statement(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, parameters) = generated
  query(connection, #(text, parameters, decode.success(Nil)))
  |> result.replace(Nil)
}

fn query(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, parameters, decoder) = generated
  use arguments <- result.try(list.try_map(parameters, parameter))
  sqlight.query(text, connection, arguments, decoder) |> sql_error
}

// The custody schema binds only integers and binary payloads. A generator or
// schema change introducing another kind must update this explicit boundary.
fn parameter(value: dev.Param) -> Result(sqlight.Value, Error) {
  case value {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
    dev.ParamString(_)
    | dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_)
    | dev.ParamNullable(_) -> Error(Uncertain)
  }
}

fn sql_error(value: Result(a, sqlight.Error)) -> Result(a, Error) {
  result.map_error(value, fn(_) { Uncertain })
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Ready(_, connection, _, custody) -> {
      case custody {
        LegacyCustody -> {
          let _ = sqlight.close(connection)
          Nil
        }
        ParentCustody(..) -> shutdown_live_connection(connection)
      }
    }
    AcquiredFresh(_, connection, _, _) | FailedCloseFresh(connection) ->
      shutdown_live_connection(connection)
    Waiting(_, _) | ReleasedFresh(_) -> Nil
  }
}

fn read_payload(
  connection: sqlight.Connection,
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(List(payload.Item), Error) {
  use Nil <- result.try(case identity.key_scope(key) == config.scope {
    True -> Ok(Nil)
    False -> Error(Rejected(admission.ScopeMismatch))
  })

  // Aggregates contain no blobs. Corrupt counts and cumulative bytes are
  // refused before the driver can materialize any payload body.
  use Nil <- result.try(
    list.try_each(
      [
        #(0, 1, 131_072),
        #(1, 1, 1024),
        #(2, 64, 1_048_576),
        #(3, 1, 32_768),
        #(4, 1, 32_768),
      ],
      fn(bound) {
        let #(kind, count, bytes) = bound
        use inventory <- result.try(query(
          connection,
          sql.payload_inventory(payload_locator(key, digest), kind),
        ))
        case inventory {
          [sql.PayloadInventory(items, total)]
            if items >= 0 && items <= count && total >= 0 && total <= bytes
          -> Ok(Nil)
          _ -> Error(Corrupt)
        }
      },
    ),
  )
  use rows <- result.try(query(
    connection,
    sql.read_custody_payload(payload_locator(key, digest)),
  ))
  use items <- result.try(
    list.try_map(rows, fn(row) {
      use Nil <- result.try(case row.digest == identity.digest_bytes(digest) {
        True -> Ok(Nil)
        False -> Error(Rejected(admission.RequestConflict))
      })
      payload.from_fields(row.kind, row.ordinal, row.body)
      |> result.map_error(fn(_) { Corrupt })
    }),
  )
  payload.validate_inventory(items) |> result.map_error(fn(_) { Corrupt })
}

fn payload_write(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
  key: identity.RequestKey,
  digest: identity.Digest,
  item: payload.Item,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    payload.validate(item) |> result.map_error(fn(_) { Corrupt }),
  )
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use snapshot <- result.try(current(connection, config, snapshot))

    // Admission preflight is pure: a closed epoch cannot acquire new payload
    // custody, while existing keys still reconcile output and terminal bytes.
    use _ <- result.try(
      admission.admit(snapshot.book, key, digest) |> result.map_error(Rejected),
    )
    persist_payload(connection, config, key, digest, item)
  }
  case outcome {
    Ok(Nil) -> sqlight.exec("COMMIT", connection) |> sql_error
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
  }
}

fn persist_payload(
  connection: sqlight.Connection,
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
  item: payload.Item,
) -> Result(Nil, Error) {
  use previous <- result.try(read_payload(connection, config, key, digest))
  let #(kind, ordinal, body) = payload.fields(item)
  case
    list.find(previous, fn(old) {
      let #(old_kind, old_ordinal, _) = payload.fields(old)
      old_kind == kind && old_ordinal == ordinal
    })
  {
    Ok(old) if old == item -> Ok(Nil)
    Ok(_) -> Error(Rejected(admission.ResultConflict))
    Error(_) ->
      insert_payload(connection, config, key, digest, previous, item, body)
  }
}

fn insert_payload(
  connection: sqlight.Connection,
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
  previous: List(payload.Item),
  item: payload.Item,
  body: BitArray,
) -> Result(Nil, Error) {
  use _ <- result.try(
    payload.validate_inventory([item, ..previous])
    |> result.map_error(fn(_) { Rejected(admission.Saturated) }),
  )
  let #(kind, ordinal, _) = payload.fields(item)
  use Nil <- result.try(case item, previous {
    payload.Request(_), [] | payload.Cancellation(_), [] -> {
      use counts <- result.try(query(connection, sql.payload_reservations()))
      let maximum = admission.capacity_value(config.capacity)
      case counts {
        [sql.PayloadReservations(items)] if items >= 0 && items < maximum ->
          Ok(Nil)
        _ -> Error(Rejected(admission.Saturated))
      }
    }
    payload.Request(_), _ -> Error(Rejected(admission.RequestConflict))
    _, [] -> Error(Rejected(admission.UnknownRequest))
    _, _ -> Ok(Nil)
  })
  statement(
    connection,
    sql.insert_custody_payload(
      payload_locator(key, digest),
      identity.digest_bytes(digest),
      kind,
      ordinal,
      body,
    ),
  )
}

fn payload_locator(
  key: identity.RequestKey,
  digest: identity.Digest,
) -> BitArray {
  // Admit encoding ends in fixed 32-byte content evidence. The locator keeps
  // only logical identity so conflicting digests cannot reserve a second slot.
  let bytes = codec.encode(codec.Admit(key, digest))
  bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 32)
  |> result.lazy_unwrap(fn() { <<>> })
}
