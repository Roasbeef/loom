//// The session layer (WP-C): opening a session over a chosen storage
//// backend with migrate-on-open, boot bookkeeping for strands, typed
//// access to the machine's register payloads through the machine codecs,
//// and the full context projection (pi §2.5) — stop-at-compaction,
//// response filtering, registered custom-entry projectors, orphan-call
//// healing, and the `transform_context` hook seam.
////
//// A `Session` wraps one open `Storage` handle with its handle type
//// erased, plus the lease-renewal capability the runtime's StorageWriter
//// schedules for SQLite sessions. Ownership: exactly one StorageWriter
//// process should commit through a session; reads may come from anywhere
//// (both shipped backends serialize through their own actor mailbox).
////
//// A session also has a name of its own: `ensure_id` mints the canonical
//// `core/ids.SessionId` once at creation and persists it in the reserved
//// `session/id` cell, so every later open of the same store yields the
//// same id (`protocol-change/008`).
////
//// The repository-level admin operations over sessions — forks (pi §2.7)
//// and the precise rewrite (pi §2.9) — live in `session/repo`.

import core/clock.{type Clock}
import core/corruption.{type CorruptionReport}
import core/entry.{type Entry}
import core/ids.{
  type EntryId, type Generator, type OpId, type Seq, type SessionId,
}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, AssistantMessage, AssistantToolCall, ToolResultMessage,
  ToolResultText, UserMessage, UserText,
}
import core/register.{type RegisterNs}
import core/tx.{Expect, SetRegister, Tx}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/codec
import machine/operation.{
  type LastResult, type Operation, type OperationState, type PendingEntry,
}
import machine/strand.{type StrandConfiguration, type StrandState, StrandState}
import storage/memory
import storage/sqlite
import storage/storage.{type Storage, type StorageError, Storage}

/// One open session: the handle-erased storage plus backend bookkeeping.
///
/// Constructor invariants: `store` is an open `Storage` whose operations
/// close over the real backend handle; `renew_lease` renews the SQLite
/// writer lease and is a no-op returning `Ok` for the memory backend;
/// `lease_interval_ms` is `Some` exactly when a lease exists and is the
/// interval at which the runtime's writer should call `renew_lease`
/// (well below the TTL); `record_identity` projects the canonical session
/// id and its parent's into the SQLite catalog row and is a no-op
/// returning `Ok` for the memory backend, which has no catalog.
pub type Session {
  Session(
    store: Storage(Nil),
    renew_lease: fn() -> Result(Nil, StorageError),
    lease_interval_ms: Option(Int),
    record_identity: fn(SessionId, Option(SessionId)) ->
      Result(Nil, StorageError),
  )
}

/// Why a session failed to open.
pub type OpenError {
  /// The memory backend's actor failed to start.
  MemoryOpenFailed(error: StorageError)
  /// The SQLite backend refused or failed (lease held, corrupt file,
  /// open failure).
  SqliteOpenFailed(error: sqlite.OpenError)
}

/// Why a typed session read or bookkeeping operation failed.
pub type SessionError {
  /// The underlying storage operation failed.
  StoreFailure(error: StorageError)
  /// A stored payload failed its total decode.
  SessionCorrupt(report: CorruptionReport)
}

/// Opens a fresh in-memory session (tests and ephemeral work).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = session.open_memory(clock.fixed(at: 1000))
/// ```
///
pub fn open_memory(clock: Clock) -> Result(Session, OpenError) {
  case memory.open(clock) {
    Ok(store) ->
      Ok(Session(
        store: erase(store),
        renew_lease: fn() { Ok(Nil) },
        lease_interval_ms: None,
        // No catalog row to project onto: for a memory session the
        // `session/id` cell is the whole of its identity.
        record_identity: fn(_id, _parent) { Ok(Nil) },
      ))
    Error(error) -> Error(MemoryOpenFailed(error:))
  }
}

/// Opens (creating if absent) a SQLite session file, acquiring the writer
/// lease under `owner`. The returned session's `lease_interval_ms` is a
/// third of the TTL — the runtime's writer renews on that timer.
///
/// Migrate-on-open: a file whose stored `storage_version` is below this
/// build's runs `migration_chain` under the open before the session is
/// returned; a file from a newer build is refused with
/// `SqliteOpenFailed(sqlite.UnsupportedVersion(..))` rather than misread.
///
/// ## Examples
///
/// ```gleam
/// // session.open_sqlite(path: "/tmp/s.db", owner: "writer-1",
/// //   lease_ttl_ms: 30_000, clock:)
/// ```
///
pub fn open_sqlite(
  path path: String,
  owner owner: String,
  lease_ttl_ms lease_ttl_ms: Int,
  clock clock: Clock,
) -> Result(Session, OpenError) {
  let config =
    sqlite.config(path:, owner:)
    |> sqlite.lease_ttl(lease_ttl_ms)
  case sqlite.open_with_migrations(config, clock, migration_chain()) {
    Ok(store) -> {
      let handle = store.handle
      Ok(
        Session(
          store: erase(store),
          renew_lease: fn() { sqlite.renew_lease(handle) },
          lease_interval_ms: Some(int_max(1, lease_ttl_ms / 3)),
          record_identity: fn(id, parent) {
            sqlite.record_identity(
              handle,
              session_id: ids.session_id_to_string(id),
              parent_session_id: option.map(parent, ids.session_id_to_string),
            )
          },
        ),
      )
    }
    Error(error) -> Error(SqliteOpenFailed(error:))
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// The ordered migrate-on-open chain for SQLite session files — the seam
/// every schema bump extends. Each step upgrades one version; `open_sqlite`
/// runs the steps a lower-versioned file needs before returning the
/// session, and refuses higher-versioned files outright.
///
/// The chain is empty today because storage version 1 is the only version
/// that has ever existed. Adding a step means: bump
/// `sqlite.storage_version`, append `sqlite.Migration(from_version:
/// old, statements: ...)` here, and cover the step in the session tests.
///
/// ## Examples
///
/// ```gleam
/// assert session.migration_chain() == []
/// ```
///
pub fn migration_chain() -> List(sqlite.Migration) {
  []
}

/// Erases a storage handle's type so sessions over different backends
/// share one shape. Every operation closes over the original handle.
fn erase(store: Storage(handle)) -> Storage(Nil) {
  Storage(
    handle: Nil,
    commit: fn(_, tx) { storage.commit(store, tx) },
    get_entries: fn(_, ids) { storage.get_entries(store, ids) },
    get_register: fn(_, ns, key) { storage.get_register(store, ns, key) },
    list_registers: fn(_, ns, prefix) {
      storage.list_registers(store, ns, prefix)
    },
    scan_branch: fn(_, q) { storage.scan_branch(store, q) },
    scan_entries: fn(_, q) { storage.scan_entries(store, q) },
    scan_usage: fn(_, q) { storage.scan_usage(store, q) },
    stats: fn(_) { storage.stats(store) },
    close: fn(_) { storage.close(store) },
  )
}

/// Closes the session's storage handle (idempotent; releases the SQLite
/// writer lease).
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = session.close(session)
/// ```
///
pub fn close(session: Session) -> Result(Nil, StorageError) {
  storage.close(session.store)
}

// --- session identity (protocol-change/008) ------------------------------

/// The reserved `fact.custom` key a session's canonical id lives under.
/// Reserved by the `session/` prefix in `runtime/api.reserved_fact_key`,
/// so no model-supplied `put_fact` can forge or rewrite it.
pub const session_id_key = "session/id"

/// The reserved `fact.custom` key a forked session records its source
/// session's id under. Absent on a session that was not forked — and on
/// one forked from a source that had no id of its own, since a fork never
/// mutates its source.
pub const parent_session_id_key = "session/parent"

/// This session's canonical id, or `None` for a session that has never
/// been through `ensure_id` — one created before `protocol-change/008`,
/// or one opened without booting a runtime.
///
/// ## Examples
///
/// ```gleam
/// // session.id(session) == Ok(Some(minted))
/// ```
///
pub fn id(session: Session) -> Result(Option(SessionId), SessionError) {
  read_identity_cell(session, session_id_key)
}

/// The id of the session this one was forked from, or `None` for a root
/// session.
///
/// ## Examples
///
/// ```gleam
/// // session.parent_id(forked) == Ok(Some(source_id))
/// ```
///
pub fn parent_id(session: Session) -> Result(Option(SessionId), SessionError) {
  read_identity_cell(session, parent_session_id_key)
}

/// Mints and persists this session's canonical id if it has none, and
/// returns the id either way — boot bookkeeping in the same slot and the
/// same shape as `ensure_strand`, committed through the session handle
/// because it runs before any writer exists (spec-gaps WP-E item 2).
///
/// Reopening a session therefore always yields the same id: the second
/// call finds the cell and mints nothing. A session that predates the
/// concept gains one on its first open here, and the generator comes back
/// unadvanced when nothing was minted.
///
/// The mint is CAS-guarded on the cell being absent, so a concurrent
/// minter's `StaleExpectation` is not a failure — the winner's id is the
/// session's id, and this re-reads it. Either way the SQLite catalog row
/// is repaired to match (see `storage/sqlite.record_identity`); that
/// projection failing is not a session failure, because the register cell
/// is the truth and the next open repairs it again.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(#(id, _generator)) = session.ensure_id(session, generator)
/// ```
///
pub fn ensure_id(
  session: Session,
  generator: Generator,
) -> Result(#(SessionId, Generator), SessionError) {
  use existing <- result.try(id(session))
  case existing {
    Some(id) -> {
      use Nil <- result.map(project_identity(session, id))
      #(id, generator)
    }
    None -> mint_identity(session, generator)
  }
}

fn mint_identity(
  session: Session,
  generator: Generator,
) -> Result(#(SessionId, Generator), SessionError) {
  let #(minted, generator) = ids.mint_session(generator)
  let seed =
    Tx(
      writes: [
        SetRegister(
          ns: register.FactCustom,
          key: session_id_key,
          value: register.value(json.String(ids.session_id_to_string(minted))),
        ),
      ],
      expected: [
        Expect(ns: register.FactCustom, key: session_id_key, seq: None),
      ],
    )
  case storage.commit(session.store, seed) {
    Ok(_) -> {
      use Nil <- result.map(project_identity(session, minted))
      #(minted, generator)
    }
    // A concurrent minter won; the session's id is theirs, not ours.
    Error(tx.StaleExpectation(..)) -> adopt_minted_identity(session, generator)
    Error(error) -> Error(commit_refusal(error))
  }
}

fn adopt_minted_identity(
  session: Session,
  generator: Generator,
) -> Result(#(SessionId, Generator), SessionError) {
  use existing <- result.try(id(session))
  case existing {
    Some(id) -> Ok(#(id, generator))
    None ->
      Error(
        StoreFailure(error: storage.BackendFault(
          reason: "the session id cell was refused as present and read as absent",
        )),
      )
  }
}

// Writes the catalog projection: the id and, when the session records
// one, its parent's. Only the read is allowed to fail the caller — a
// projection write that fails leaves the register cell (the truth)
// standing, and the next open repairs the row.
fn project_identity(
  session: Session,
  id: SessionId,
) -> Result(Nil, SessionError) {
  use parent <- result.map(parent_id(session))
  let _ = session.record_identity(id, parent)
  Nil
}

fn read_identity_cell(
  session: Session,
  key: String,
) -> Result(Option(SessionId), SessionError) {
  use cell <- result.try(
    storage.get_register(session.store, register.FactCustom, key)
    |> result.map_error(StoreFailure),
  )
  case cell {
    None -> Ok(None)
    Some(storage.Register(value:, ..)) ->
      decode_identity_cell(value.payload, key) |> result.map(Some)
  }
}

fn decode_identity_cell(
  payload: JsonValue,
  key: String,
) -> Result(SessionId, SessionError) {
  case payload {
    json.String(text) ->
      ids.parse_session_id(text)
      |> result.map_error(fn(report) { SessionCorrupt(report:) })
    other ->
      Error(
        SessionCorrupt(report: corruption.report(
          at: "session/session.read_identity_cell",
          on: key,
          expected: "a canonical session id string",
          context: json.to_string(other),
        )),
      )
  }
}

// --- boot bookkeeping ----------------------------------------------------

/// Seeds a strand's three registers (`strand.config`, `strand.leaf`,
/// `strand.state`) if the strand does not exist yet; leaves an existing
/// strand untouched. Boot bookkeeping for session create/open: creating a
/// session and reopening one converge on the same call.
///
/// The seed commit expects all three cells absent, so a concurrent seeder
/// loses with a stale expectation and this function reports success —
/// the strand exists either way.
///
/// ## Examples
///
/// ```gleam
/// // session.ensure_strand(session, "main", configuration)
/// ```
///
pub fn ensure_strand(
  session: Session,
  strand_name: String,
  configuration: StrandConfiguration,
) -> Result(Nil, SessionError) {
  use existing <- result.try(
    storage.get_register(session.store, register.StrandConfig, strand_name)
    |> result.map_error(StoreFailure),
  )
  use <- bool.guard(when: option.is_some(existing), return: Ok(Nil))
  let seed =
    Tx(
      writes: [
        SetRegister(
          ns: register.StrandConfig,
          key: strand_name,
          value: register.value(codec.encode_configuration(configuration)),
        ),
        SetRegister(
          ns: register.StrandLeaf,
          key: strand_name,
          value: register.leaf_value(None),
        ),
        SetRegister(
          ns: register.StrandState,
          key: strand_name,
          value: register.value(
            codec.encode_strand_state(
              StrandState(current_operation: None, pending_next_run: []),
            ),
          ),
        ),
      ],
      expected: [
        Expect(ns: register.StrandConfig, key: strand_name, seq: None),
        Expect(ns: register.StrandLeaf, key: strand_name, seq: None),
        Expect(ns: register.StrandState, key: strand_name, seq: None),
      ],
    )
  seed_commit_result(storage.commit(session.store, seed))
}

/// Maps the seed transaction's commit outcome to `ensure_strand`'s
/// result: a concurrent seeder's `StaleExpectation` is success (the
/// strand exists either way), and every other refusal this layer does
/// not otherwise recognize — `LeaseLost` included — flattens into
/// `StoreFailure(BackendFault(..))`, because this layer owns no tree to
/// reopen.
fn seed_commit_result(
  result: Result(tx.CommitResult, tx.CommitError),
) -> Result(Nil, SessionError) {
  case result {
    Ok(_) -> Ok(Nil)
    // A concurrent seeder won; the strand exists.
    Error(tx.StaleExpectation(..)) -> Ok(Nil)
    Error(error) -> Error(commit_refusal(error))
  }
}

/// Every commit refusal this layer does not otherwise recognize —
/// `LeaseLost` included — flattened into a `SessionError`, because this
/// layer owns no tree to reopen. A `StaleExpectation` never reaches here:
/// each CAS-guarded boot write decides for itself what losing the race
/// means, and for both of them it means success.
fn commit_refusal(error: tx.CommitError) -> SessionError {
  case error {
    tx.Corruption(report:) -> SessionCorrupt(report:)
    tx.Faulted(reason:) -> StoreFailure(error: storage.BackendFault(reason:))
    // Committing against a session another writer now owns is a backend
    // failure like any other from here: this layer has no tree to reopen,
    // and the caller that does gets the reason spelled out
    // (`protocol-change/005`).
    tx.LeaseLost(held_by:) ->
      StoreFailure(
        error: storage.BackendFault(reason: tx.describe_lease_loss(held_by)),
      )
    tx.StaleExpectation(failed:) ->
      StoreFailure(error: storage.BackendFault(
        reason: "a stale expectation reached the generic refusal path: "
        <> register.ns_to_string(failed.ns)
        <> "/"
        <> failed.key,
      ))
  }
}

// --- typed register access -----------------------------------------------

/// A decoded register cell with the seq CAS expectations compare against.
pub type Cell(payload) {
  Cell(seq: Seq, value: payload)
}

/// Reads and decodes a strand's configuration.
///
/// ## Examples
///
/// ```gleam
/// // session.strand_configuration(session, "main")
/// //   == Ok(Some(Cell(seq, configuration)))
/// ```
///
pub fn strand_configuration(
  session: Session,
  strand_name: String,
) -> Result(Option(Cell(StrandConfiguration)), SessionError) {
  read_cell(
    session,
    register.StrandConfig,
    strand_name,
    codec.decode_configuration,
  )
}

/// Reads and decodes a strand's operation-ownership state.
///
/// ## Examples
///
/// ```gleam
/// // session.strand_state(session, "main")
/// ```
///
pub fn strand_state(
  session: Session,
  strand_name: String,
) -> Result(Option(Cell(StrandState)), SessionError) {
  read_cell(
    session,
    register.StrandState,
    strand_name,
    codec.decode_strand_state,
  )
}

/// Reads a strand's current leaf. `Ok(None)` when the register is absent
/// (unseeded strand) — a seeded strand at the root reads `Ok(Some(Cell(_,
/// None)))`.
///
/// ## Examples
///
/// ```gleam
/// // session.strand_leaf(session, "main")
/// ```
///
pub fn strand_leaf(
  session: Session,
  strand_name: String,
) -> Result(Option(Cell(Option(EntryId))), SessionError) {
  use found <- result.try(
    storage.get_register(session.store, register.StrandLeaf, strand_name)
    |> result.map_error(StoreFailure),
  )
  case found {
    None -> Ok(None)
    Some(storage.Register(value:, seq:)) ->
      case register.read_leaf(value) {
        Ok(leaf) -> Ok(Some(Cell(seq:, value: leaf)))
        Error(report) -> Error(SessionCorrupt(report:))
      }
  }
}

/// Reads and decodes a strand's latest terminal result. Never a recovery
/// input (spec §3.1); exposed for inspection and completion waiting.
///
/// ## Examples
///
/// ```gleam
/// // session.last_result(session, "main")
/// ```
///
pub fn last_result(
  session: Session,
  strand_name: String,
) -> Result(Option(Cell(LastResult)), SessionError) {
  read_cell(
    session,
    register.StrandLastResult,
    strand_name,
    codec.decode_last_result,
  )
}

/// Reads and decodes an operation's immutable metadata.
///
/// ## Examples
///
/// ```gleam
/// // session.op_meta(session, op_id)
/// ```
///
pub fn op_meta(
  session: Session,
  operation: OpId,
) -> Result(Option(Cell(Operation)), SessionError) {
  read_cell(
    session,
    register.OpMeta,
    ids.op_id_to_string(operation),
    codec.decode_operation,
  )
}

/// Reads and decodes an operation's durable state — the program counter.
///
/// ## Examples
///
/// ```gleam
/// // session.op_state(session, op_id)
/// ```
///
pub fn op_state(
  session: Session,
  operation: OpId,
) -> Result(Option(Cell(OperationState)), SessionError) {
  read_cell(
    session,
    register.OpState,
    ids.op_id_to_string(operation),
    codec.decode_state,
  )
}

/// Reads and decodes every `pending.entry` payload, keyed by entry-id
/// text — the shape `PlannerInputs.pending` wants.
///
/// ## Examples
///
/// ```gleam
/// // session.pending_payloads(session)
/// ```
///
pub fn pending_payloads(
  session: Session,
) -> Result(Dict(String, PendingEntry), SessionError) {
  use cells <- result.try(
    storage.list_registers(session.store, register.PendingEntry, None)
    |> result.map_error(StoreFailure),
  )
  cells
  |> list.try_map(fn(pair) {
    let #(key, storage.Register(value:, ..)) = pair
    case codec.decode_pending_entry(value.payload) {
      Ok(pending) -> Ok(#(key, pending))
      Error(report) -> Error(SessionCorrupt(report:))
    }
  })
  |> result.map(dict.from_list)
}

/// Every existing register key under a namespace with the given prefix —
/// the terminal transaction's defensive delete lists (`op.tool_args`,
/// `op.preparation`).
///
/// ## Examples
///
/// ```gleam
/// // session.register_keys(session, register.OpToolArgs, op_key)
/// ```
///
pub fn register_keys(
  session: Session,
  ns: RegisterNs,
  prefix: String,
) -> Result(List(String), SessionError) {
  storage.list_registers(session.store, ns, Some(prefix))
  |> result.map(list.map(_, fn(pair) { pair.0 }))
  |> result.map_error(StoreFailure)
}

/// Reads and decodes an operation's tool-arguments register by exact key
/// (`op:step:idx`, as built by the machine).
///
/// ## Examples
///
/// ```gleam
/// // session.tool_arguments(session, arguments_key)
/// ```
///
pub fn tool_arguments(
  session: Session,
  key: String,
) -> Result(Option(Cell(JsonValue)), SessionError) {
  use found <- result.try(
    storage.get_register(session.store, register.OpToolArgs, key)
    |> result.map_error(StoreFailure),
  )
  case found {
    None -> Ok(None)
    Some(storage.Register(value:, seq:)) ->
      Ok(Some(Cell(seq:, value: value.payload)))
  }
}

/// Reads and decodes the first structural preparation register owned by
/// an operation, if any.
///
/// ## Examples
///
/// ```gleam
/// // session.preparation(session, op_id)
/// ```
///
pub fn preparation(
  session: Session,
  operation: OpId,
) -> Result(Option(operation.StructuralPreparation), SessionError) {
  use keys <- result.try(register_keys(
    session,
    register.OpPreparation,
    ids.op_id_to_string(operation),
  ))
  case keys {
    [] -> Ok(None)
    [key, ..] -> decode_preparation_cell(session, key)
  }
}

fn decode_preparation_cell(
  session: Session,
  key: String,
) -> Result(Option(operation.StructuralPreparation), SessionError) {
  use found <- result.try(
    storage.get_register(session.store, register.OpPreparation, key)
    |> result.map_error(StoreFailure),
  )
  case found {
    None -> Ok(None)
    Some(storage.Register(value:, ..)) ->
      codec.decode_preparation(value.payload)
      |> result.map(Some)
      |> result.map_error(fn(report) { SessionCorrupt(report:) })
  }
}

fn read_cell(
  session: Session,
  ns: RegisterNs,
  key: String,
  decode: fn(JsonValue) -> Result(payload, CorruptionReport),
) -> Result(Option(Cell(payload)), SessionError) {
  use found <- result.try(
    storage.get_register(session.store, ns, key)
    |> result.map_error(StoreFailure),
  )
  case found {
    None -> Ok(None)
    Some(storage.Register(value:, seq:)) ->
      case decode(value.payload) {
        Ok(payload) -> Ok(Some(Cell(seq:, value: payload)))
        Error(report) -> Error(SessionCorrupt(report:))
      }
  }
}

// --- context projection (pi §2.5, full) -----------------------------------

/// How custom entries and the final message list project into provider
/// context. Build with `projection`, then `with_projector` /
/// `with_transform`; pass to `project` or `project_entries`.
///
/// Invariants: projectors are pure per-entry computation registered by
/// `custom_type`; an unregistered custom entry never enters context. The
/// transform is pi's `transform_context` hook seam — request-local,
/// applied last, never persisted; the harness trusts it to preserve
/// conversation well-formedness (a violating transform is a defect in the
/// application, not a storage validation case).
pub opaque type Projection {
  Projection(
    projectors: Dict(String, fn(CustomView) -> Option(AgentMessage)),
    transform: fn(List(AgentMessage)) -> List(AgentMessage),
  )
}

/// What a custom-entry projector sees: the entry's identity, type tag,
/// opaque payload, and commit time.
///
/// Constructor invariants: mirrors one `CustomEntry` row; `data` is the
/// application payload exactly as stored.
pub type CustomView {
  CustomView(id: EntryId, custom_type: String, data: Option(JsonValue), ts: Int)
}

/// The default projection: no custom projectors (every custom entry is
/// skipped), identity transform.
///
/// ## Examples
///
/// ```gleam
/// assert session.project_entries([], session.projection()) == []
/// ```
///
pub fn projection() -> Projection {
  Projection(projectors: dict.new(), transform: fn(messages) { messages })
}

/// Registers a projector for one `custom_type`. Registering the same type
/// again replaces the earlier projector. The projector returns `Some` to
/// put one message into context or `None` to keep the entry out.
///
/// ## Examples
///
/// ```gleam
/// // session.projection()
/// // |> session.with_projector("note", fn(view) { Some(to_message(view)) })
/// ```
///
pub fn with_projector(
  projection: Projection,
  custom_type: String,
  project: fn(CustomView) -> Option(AgentMessage),
) -> Projection {
  let projectors = dict.insert(projection.projectors, custom_type, project)
  Projection(..projection, projectors:)
}

/// Sets the `transform_context` hook: a request-local transform applied
/// to the complete projected message list after every other rule. Setting
/// it again replaces the earlier hook.
///
/// ## Examples
///
/// ```gleam
/// // session.projection() |> session.with_transform(list.take(_, 100))
/// ```
///
pub fn with_transform(
  projection: Projection,
  transform: fn(List(AgentMessage)) -> List(AgentMessage),
) -> Projection {
  Projection(..projection, transform:)
}

/// Projects a strand's provider context from its leaf under a projection:
/// scan the branch newest-first stopping inclusively at the first
/// compaction, then run the pure pipeline (`project_entries`). A `None`
/// leaf projects to the empty context — the transform hook is not invoked
/// for it, since there is no request to construct.
///
/// ## Examples
///
/// ```gleam
/// // session.project(session, Some(leaf), projection)
/// ```
///
pub fn project(
  session: Session,
  leaf: Option(EntryId),
  projection: Projection,
) -> Result(List(AgentMessage), SessionError) {
  case leaf {
    None -> Ok([])
    Some(start) -> {
      let q =
        storage.branch_scan(from: start)
        |> storage.branch_stop_at_kind(storage.Compaction)
      storage.scan_branch(session.store, q)
      |> result.map_error(StoreFailure)
      |> result.map(project_entries(_, projection))
    }
  }
}

/// Projects a strand's provider context under the default projection (no
/// custom projectors, identity transform).
///
/// ## Examples
///
/// ```gleam
/// // session.project_context(session, Some(leaf))
/// ```
///
pub fn project_context(
  session: Session,
  leaf: Option(EntryId),
) -> Result(List(AgentMessage), SessionError) {
  project(session, leaf, projection())
}

/// The pure projection pipeline over a newest-first branch scan that
/// stopped at the first compaction (inclusive). Exposed separately so the
/// runtime can project entries it fetched through its own storage path.
///
/// Rules implemented (pi §2.5, in order):
///
/// 1. Reverse to oldest-first. If a compaction heads the result, the
///    context opens with its summary (as a user message — the summary is
///    injected context, not model output) followed by its retained tail;
///    nothing earlier is read (the scan already stopped).
/// 2. Drop assistant responses whose stop reason is `error`, `aborted`,
///    or `deferred`; retain genuine output-limit `length`. Branch
///    summaries project as user-message context, like compaction
///    summaries.
/// 3. Run custom entries through the projection's registered projectors;
///    an unprojected custom entry never enters context.
/// 4. Heal orphaned tool calls (pi §2.7: request construction heals): a
///    retained tool call whose result exists nowhere later in the
///    projected context — severed by a fork or navigation boundary —
///    gets a synthetic error result directly after its assistant
///    message, stating that the outcome is unknown on this branch. On a
///    settled history this is a no-op, which is what keeps successive
///    projections append-only.
/// 5. Apply the `transform_context` hook. Provider mapping stays the
///    caller's.
///
/// ## Examples
///
/// ```gleam
/// assert session.project_entries([], session.projection()) == []
/// ```
///
pub fn project_entries(
  newest_first: List(Entry),
  projection: Projection,
) -> List(AgentMessage) {
  let Projection(projectors:, transform:) = projection
  newest_first
  |> list.reverse
  |> list.flat_map(project_entry(_, projectors))
  |> heal_orphan_calls
  |> transform
}

/// The pure projection under the default projection — kept for the
/// runtime driver's request construction.
///
/// ## Examples
///
/// ```gleam
/// assert session.project_scan([]) == []
/// ```
///
pub fn project_scan(newest_first: List(Entry)) -> List(AgentMessage) {
  project_entries(newest_first, projection())
}

fn project_entry(
  entry: Entry,
  projectors: Dict(String, fn(CustomView) -> Option(AgentMessage)),
) -> List(AgentMessage) {
  case entry {
    entry.MessageEntry(message:, ..) ->
      case message {
        AssistantMessage(stop_reason: message.Errored, ..)
        | AssistantMessage(stop_reason: message.Aborted, ..)
        | AssistantMessage(stop_reason: message.Deferred, ..) -> []
        _ -> [message]
      }
    entry.CompactionEntry(summary:, retained_tail:, ts:, ..) -> [
      UserMessage(
        content: [UserText(text: summary, text_signature: None)],
        timestamp: ts,
      ),
      ..retained_tail
    ]
    entry.BranchSummaryEntry(summary:, ts:, ..) -> [
      UserMessage(
        content: [UserText(text: summary, text_signature: None)],
        timestamp: ts,
      ),
    ]
    entry.CustomEntry(id:, custom_type:, data:, ts:, ..) ->
      dict.get(projectors, custom_type)
      |> option.from_result
      |> option.then(fn(project) {
        project(CustomView(id:, custom_type:, data:, ts:))
      })
      |> option.map(fn(message) { [message] })
      |> option.unwrap([])
  }
}

// --- orphan-call healing (pi §2.7) ----------------------------------------

fn heal_orphan_calls(messages: List(AgentMessage)) -> List(AgentMessage) {
  heal_loop(messages, [])
}

fn heal_loop(
  remaining: List(AgentMessage),
  healed: List(AgentMessage),
) -> List(AgentMessage) {
  case remaining {
    [] -> list.reverse(healed)
    [message, ..rest] ->
      case message {
        AssistantMessage(content:, timestamp:, ..) -> {
          // A call is orphaned when no later message in the projected
          // context carries its result. The synthetic results go directly
          // after the assistant message; results that do exist stay where
          // they are (they are, by construction, not earlier than here).
          let synthetics =
            content
            |> list.filter_map(fn(block) {
              case block {
                AssistantToolCall(call:) ->
                  synthetic_result_if_orphan(call, rest, timestamp)
                message.AssistantText(..) | message.AssistantThinking(..) ->
                  Error(Nil)
              }
            })
          heal_loop(
            rest,
            list.append(list.reverse(synthetics), [message, ..healed]),
          )
        }
        UserMessage(..) | ToolResultMessage(..) | message.CustomMessage(..) ->
          heal_loop(rest, [message, ..healed])
      }
  }
}

fn has_result(messages: List(AgentMessage), call_id: String) -> Bool {
  list.any(messages, fn(message) {
    case message {
      ToolResultMessage(tool_call_id:, ..) -> tool_call_id == call_id
      UserMessage(..) | AssistantMessage(..) | message.CustomMessage(..) ->
        False
    }
  })
}

/// A tool call keeps its slot only when no later message in the branch
/// carries its result; an orphan gets a synthetic error result instead.
fn synthetic_result_if_orphan(
  call: message.ToolCall,
  later: List(AgentMessage),
  timestamp: Int,
) -> Result(AgentMessage, Nil) {
  use <- bool.guard(when: has_result(later, call.id), return: Error(Nil))
  Ok(synthetic_result(call, timestamp))
}

fn synthetic_result(call: message.ToolCall, timestamp: Int) -> AgentMessage {
  ToolResultMessage(
    tool_call_id: call.id,
    tool_name: call.name,
    content: [
      ToolResultText(
        text: "Tool call "
          <> call.name
          <> " ("
          <> call.id
          <> ") has no result on this branch: it was severed by a fork or "
          <> "navigation boundary, so whether the tool ran and what it "
          <> "produced is unknown.",
        text_signature: None,
      ),
    ],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: True,
    timestamp:,
  )
}
