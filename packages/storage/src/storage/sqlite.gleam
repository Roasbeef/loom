//// The SQLite backend: one database file per session.
////
//// The file is the session — corruption is confined to one session and
//// deletion is unlinking a file. The schema follows the implementation
//// spec WP-B (which transcribes pi §1.7): write-once `entries` and
//// `usage_ledger` rows, mutable `registers`, the private segmented
//// branch index (`branch_entries` + `branch_meta`, pi §2.6), a
//// single-row `session` catalog, and the `writer_lease` table.
////
//// Non-negotiables enforced here:
////
//// - **Every transaction opens with `BEGIN IMMEDIATE`.** Allocating the
////   seq range reads `session.next_seq` before writing it, so every
////   commit reads before it writes; a deferred `BEGIN` could take a read
////   snapshot it cannot upgrade, and `busy_timeout` cannot rescue that.
//// - **The writer lease enforces the single-writer rule.** WAL happily
////   lets two processes alternate writes to one file; the lease is what
////   makes "one process owns one session" enforced rather than assumed.
////   `open` acquires expiring fenced ownership and may steal an expired
////   lease (with a bumped fence); every commit renews the lease and a
////   commit whose `(owner_id, fence)` pair no longer matches fails with
////   `Faulted` and applies nothing; `close` deletes only its own pair,
////   so a stale owner cannot release its replacement.
//// - **Branch reads never fall back to a table scan or parent walk.**
////   `scan_branch` drives from `branch_entries` via a `CROSS JOIN`
////   (forcing the join order) and pages segment windows;
////   `scan_branch_plan` exposes the `EXPLAIN QUERY PLAN` output so the
////   conformance suite can fail on any temp-sort or entries-scan
////   regression.
////
//// Like the Memory backend, the handle is an actor: all operations
//// serialize through one mailbox ("one writer, one queue"), and the
//// injected clock is threaded through it. The esqlite connection is only
//// ever used from the actor process after `open` returns.

import core/clock.{type Clock}
import core/codec
import core/corruption.{type CorruptionReport}
import core/entry.{
  type Entry, type UsageRow, BranchSummaryEntry, CompactionEntry, CustomEntry,
  MessageEntry, UsageRow,
}
import core/ids.{type EntryId, type Seq}
import core/json.{type JsonValue}
import core/register.{type RegisterNs}
import core/tx.{
  type CommitError, type CommitResult, type SeqExpectation, type Tx,
  CommitResult, Corruption, DeleteRegister, Expect, Faulted, InsertEntry,
  InsertUsage, LeaseLost, SetRegister, StaleExpectation,
}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import simplifile
import sqlight.{type Connection}
import storage/internal/branch
import storage/storage.{
  type BranchScan, type EntryScan, type Register, type ScanOrder,
  type SessionStats, type Storage, type StorageError, type UsageScan,
  BackendFault, CorruptRow, HandleClosed, NewestFirst, OldestFirst, Register,
  SessionStats, Storage, UnknownEntry,
}

/// How to open a session file. Built with `config` and the setters below.
///
/// Constructor invariants: `path` is the session's database file (created
/// if absent; parent directory must exist); `owner` uniquely identifies
/// this writer for the lease (the runtime mints one per process);
/// `lease_ttl_ms` and `busy_timeout_ms` are positive milliseconds.
pub type Config {
  Config(
    /// The session database file, one per session.
    path: String,
    /// This writer's lease identity. Must differ between processes that
    /// could contend for the same file.
    owner: String,
    /// How long an acquired or renewed lease lasts before another opener
    /// may steal it.
    lease_ttl_ms: Int,
    /// `PRAGMA busy_timeout` for cross-process lock contention.
    busy_timeout_ms: Int,
  )
}

/// A config with defaults: 30 s lease, 5 s busy timeout.
///
/// ## Examples
///
/// ```gleam
/// let config = sqlite.config(path: "/tmp/session.db", owner: "writer-1")
/// ```
///
pub fn config(path path: String, owner owner: String) -> Config {
  Config(path:, owner:, lease_ttl_ms: 30_000, busy_timeout_ms: 5000)
}

/// Sets the lease time-to-live in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let config = sqlite.config(path:, owner:) |> sqlite.lease_ttl(1000)
/// ```
///
pub fn lease_ttl(config: Config, ms: Int) -> Config {
  Config(..config, lease_ttl_ms: ms)
}

/// Sets the SQLite busy timeout in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let config = sqlite.config(path:, owner:) |> sqlite.busy_timeout(100)
/// ```
///
pub fn busy_timeout(config: Config, ms: Int) -> Config {
  Config(..config, busy_timeout_ms: ms)
}

/// Why `open` refused or failed.
pub type OpenError {
  /// Another writer holds an unexpired lease on this session file. Retry
  /// after it expires, or shut the other writer down.
  LeaseHeld(owner: String, expires_at_ms: Int)

  /// The file's catalog failed a total decode, or the file is not a Loom
  /// session at all.
  CorruptSession(report: CorruptionReport)

  /// The stored `storage_version` cannot be opened by this build:
  /// `found > supported` means the file was written by a newer Loom
  /// (refuse rather than misread it); `found < supported` means an older
  /// file for which the caller's migration chain has no step (see
  /// `open_with_migrations`).
  UnsupportedVersion(found: Int, supported: Int)

  /// The database could not be opened or initialized.
  OpenFailed(reason: String)
}

/// One migrate-on-open step: `statements` upgrade a session file from
/// `from_version` to `from_version + 1`.
///
/// Constructor invariants: `statements` is a semicolon-separated SQL batch
/// executed inside one transaction together with the version bump; a step
/// advances exactly one version. Steps run after the current schema's
/// `CREATE ... IF NOT EXISTS` DDL has been applied, so they mostly alter
/// or backfill. The chain owner (the session layer, WP-C) keeps steps
/// ordered and contiguous.
pub type Migration {
  Migration(from_version: Int, statements: String)
}

/// A branch-index segment's metadata, for diagnostics and conformance
/// assertions. Mirrors one `branch_meta` row.
///
/// Constructor invariants: `tip_seq` is the seq of `tip_entry_id`; `base`,
/// when present, names the segment whose logical range through `base.1`
/// this segment extends.
pub type Segment {
  Segment(
    branch_id: String,
    tip_entry_id: String,
    tip_seq: Int,
    base: Option(#(String, Int)),
  )
}

/// Messages understood by the SQLite storage actor. Opaque: callers go
/// through the `Storage` interface or this module's helpers.
pub opaque type Message {
  /// Commit a transaction.
  Commit(tx: Tx, reply: Subject(Result(CommitResult, CommitError)))

  /// Batch entry fetch.
  GetEntries(
    ids: List(EntryId),
    reply: Subject(Result(Dict(EntryId, Entry), StorageError)),
  )

  /// Read one register cell.
  GetRegister(
    ns: RegisterNs,
    key: String,
    reply: Subject(Result(Option(Register), StorageError)),
  )

  /// List a namespace's cells.
  ListRegisters(
    ns: RegisterNs,
    key_prefix: Option(String),
    reply: Subject(Result(List(#(String, Register)), StorageError)),
  )

  /// Branch query.
  ScanBranch(q: BranchScan, reply: Subject(Result(List(Entry), StorageError)))

  /// Entry inventory scan.
  ScanEntries(q: EntryScan, reply: Subject(Result(List(Entry), StorageError)))

  /// Ledger read.
  ScanUsage(q: UsageScan, reply: Subject(Result(List(UsageRow), StorageError)))

  /// Stats projection read.
  Stats(reply: Subject(Result(SessionStats, StorageError)))

  /// Renew the writer lease without committing anything.
  RenewLease(reply: Subject(Result(Nil, StorageError)))

  /// Project the session's canonical identity into the catalog row.
  RecordIdentity(
    session_id: String,
    parent_session_id: Option(String),
    reply: Subject(Result(Nil, StorageError)),
  )

  /// Read the query plan of the branch segment query for one scan order.
  ScanBranchPlan(
    order: ScanOrder,
    reply: Subject(Result(List(String), StorageError)),
  )

  /// Read the branch-index segment metadata.
  Segments(reply: Subject(Result(List(Segment), StorageError)))

  /// Seal the handle: release the lease, close the file. Idempotent.
  Close(reply: Subject(Result(Nil, StorageError)))
}

type ActorState {
  ActorState(
    conn: Connection,
    clock: Clock,
    owner: String,
    fence: Int,
    lease_ttl_ms: Int,
    closed: Bool,
  )
}

// Failures inside a transaction, mapped to `CommitError` or
// `StorageError` at the boundary.
type Fail {
  FailSql(error: sqlight.Error)
  FailCorrupt(report: CorruptionReport)
  FailStale(failed: SeqExpectation)
  FailLease(held_by: Option(String))
  FailUnknownEntry(id: EntryId)
}

const page_size = 256

/// The current schema version written to fresh session files.
pub const storage_version = 1

// --- open ----------------------------------------------------------------

/// Opens (creating if absent) the session file, initializes or verifies
/// the schema, acquires the writer lease — stealing an expired one with a
/// bumped fence, refusing an unexpired one with `LeaseHeld` — and returns
/// the uniform `Storage` handle backed by an actor.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(store) =
///   sqlite.open(sqlite.config(path:, owner: "writer-1"), clock)
/// ```
///
pub fn open(
  config: Config,
  clock: Clock,
) -> Result(Storage(Subject(Message)), OpenError) {
  open_with_migrations(config, clock, [])
}

/// `open` with a migrate-on-open chain: a stored `storage_version` below
/// this build's runs the matching `Migration` steps in ascending order —
/// each step's statements and its version bump commit atomically — under
/// the writer lease, which is acquired first (pi §2.8: migrations run
/// under the lease, over quiescent state). A version above this build's
/// is refused with `UnsupportedVersion` (never misread), as is an older
/// version the chain has no step for; either refusal — and a `LeaseHeld`
/// one — leaves the file's bytes untouched. The chain itself is owned by
/// the session layer (WP-C), which passes it here; today it is empty
/// because version 1 is the only version that has ever existed.
///
/// ## Examples
///
/// ```gleam
/// // sqlite.open_with_migrations(config, clock, session.migration_chain())
/// ```
///
pub fn open_with_migrations(
  config: Config,
  clock: Clock,
  migrations: List(Migration),
) -> Result(Storage(Subject(Message)), OpenError) {
  use conn <- result.try(
    sqlight.open(config.path)
    |> result.map_error(fn(error) {
      OpenFailed(reason: "sqlite open: " <> describe_sqlight(error))
    }),
  )
  let #(now, clock) = clock.read(clock)
  case initialize(conn, config, now, migrations) {
    Ok(fence) -> start_actor(conn, config, clock, fence)
    Error(open_error) -> {
      let _ = sqlight.close(conn)
      Error(open_error)
    }
  }
}

// The open path in refuse-before-write order. First the connection-local
// busy timeout (no file write), then one BEGIN IMMEDIATE admission
// transaction that reads the stored version, refuses anything this build
// cannot own (a newer file, an uncovered older one, a held lease) with
// *nothing* written, and otherwise claims the lease — creating the schema
// and catalog first when the file is fresh. Holding the write lock across
// the whole probe is also what serializes racing creators: exactly one
// writes the catalog row, the rest wait on the lock and then find it.
// Only after admission commits do the migration chain and the WAL switch
// run, both under the lease this writer now holds (pi §2.8: migrations
// run under the writer lease, over quiescent state).
fn initialize(
  conn: Connection,
  config: Config,
  now: Int,
  migrations: List(Migration),
) -> Result(Int, OpenError) {
  use Nil <- result.try(set_busy_timeout(conn, config.busy_timeout_ms))
  use Nil <- result.try(begin_immediate(conn) |> result.map_error(open_failed))
  let admitted = case admit(conn, config, now, migrations) {
    Ok(opened) ->
      commit_sql(conn)
      |> result.map_error(open_failed)
      |> result.replace(opened)
    Error(open_error) -> {
      let _ = rollback(conn)
      Error(open_error)
    }
  }
  use Opened(fence:, migrate_from:) <- result.try(admitted)
  let readied = {
    use Nil <- result.try(migrate(conn, migrate_from, migrations))
    set_wal_journal(conn)
  }
  case readied {
    Ok(Nil) -> Ok(fence)

    // The lease was claimed but this open cannot deliver a usable handle;
    // release the claim so the file is not locked out for a whole TTL.
    Error(open_error) -> {
      let _ = abandon_lease(conn, config.owner, fence)
      Error(open_error)
    }
  }
}

fn open_failed(fail: Fail) -> OpenError {
  case fail {
    FailSql(error) -> OpenFailed(reason: describe_sqlight(error))
    FailCorrupt(report) -> CorruptSession(report:)
    FailStale(_) | FailLease(_) | FailUnknownEntry(_) ->
      OpenFailed(reason: "unexpected failure during open")
  }
}

// Pragmas (and the other row-less statements on contended paths) run
// through `sqlight.exec`, never `run`: the prepared-statement step path
// surfaces SQLITE_BUSY as an atom the binding has no clause for — a crash
// in the caller — while sqlite3_exec returns it as an ordinary error this
// open can report as `OpenFailed`. The journal-mode switch is the one
// statement that reliably contends cross-process, so this totality is
// load-bearing (a contended open must refuse, never crash).
fn set_busy_timeout(
  conn: Connection,
  busy_timeout_ms: Int,
) -> Result(Nil, OpenError) {
  sqlight.exec(
    "PRAGMA busy_timeout = " <> int.to_string(busy_timeout_ms),
    on: conn,
  )
  |> result.map_error(fn(error) {
    OpenFailed(reason: "busy_timeout: " <> describe_sqlight(error))
  })
}

// WAL only after admission: switching the journal mode writes the file
// header, and a refused open must leave the file byte-identical.
fn set_wal_journal(conn: Connection) -> Result(Nil, OpenError) {
  sqlight.exec("PRAGMA journal_mode = WAL", on: conn)
  |> result.map_error(fn(error) {
    OpenFailed(reason: "journal_mode: " <> describe_sqlight(error))
  })
}

// What the admission transaction concluded: the lease fence this writer
// now holds, and the stored version the migration chain resumes from
// (`storage_version` itself when no migration is needed).
type Opened {
  Opened(fence: Int, migrate_from: Int)
}

// The admission body, run inside the caller's BEGIN IMMEDIATE. Decides
// fresh-create versus existing-open, refuses before writing, and claims
// the lease. The caller commits on Ok and rolls back on Error.
fn admit(
  conn: Connection,
  config: Config,
  now: Int,
  migrations: List(Migration),
) -> Result(Opened, OpenError) {
  use versions <- result.try(read_catalog_versions(conn))
  case versions {
    // No catalog row: a fresh file, or one whose creation crashed between
    // the DDL and the catalog write (the IF NOT EXISTS batch makes the
    // retry harmless). Create everything and claim the first lease inside
    // this same transaction — a racing creator either waits on the write
    // lock and then finds the row, or finds it outright; neither can
    // insert a second one.
    None | Some([]) -> {
      use Nil <- result.try(exec_schema(conn))
      use Nil <- result.try(insert_catalog_row(conn, now))
      use fence <- result.try(claim_lease(conn, config, now))
      Ok(Opened(fence:, migrate_from: storage_version))
    }

    // A newer file is refused before any write: a schema the newer build
    // dropped or renamed must not be resurrected into it.
    Some([version]) if version > storage_version ->
      Error(UnsupportedVersion(found: version, supported: storage_version))
    Some([version]) -> {
      // Refuse a version the chain cannot reach *before* taking the
      // lease — an unopenable file must not be written at all — then
      // claim, and only then apply this build's DDL. The DDL stays ahead
      // of the chain's steps (`Migration` doc: steps run after the
      // current CREATE ... IF NOT EXISTS batch).
      use Nil <- result.try(check_chain(version, migrations))
      use fence <- result.try(claim_lease(conn, config, now))
      use Nil <- result.try(exec_schema(conn))
      Ok(Opened(fence:, migrate_from: version))
    }
    Some([_, ..]) ->
      Error(
        CorruptSession(report: corruption.report(
          at: "storage/sqlite.open",
          on: "session catalog",
          expected: "exactly one session row",
          context: "multiple rows",
        )),
      )
  }
}

// The stored versions, or `None` when the file has no `session` table at
// all (a genuinely fresh database — reading the catalog directly would
// conjure an error, not an answer).
fn read_catalog_versions(
  conn: Connection,
) -> Result(Option(List(Int)), OpenError) {
  let probed =
    run(
      conn,
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session'",
      [],
      decode.at([0], decode.string),
    )
  use tables <- result.try(probed |> result.map_error(open_failed))
  case tables {
    [] -> Ok(None)
    [_, ..] ->
      run(
        conn,
        "SELECT storage_version FROM session",
        [],
        decode.at([0], decode.int),
      )
      |> result.map(Some)
      |> result.map_error(open_failed)
  }
}

fn exec_schema(conn: Connection) -> Result(Nil, OpenError) {
  sqlight.exec(schema_sql, on: conn)
  |> result.map_error(fn(error) {
    OpenFailed(reason: "schema: " <> describe_sqlight(error))
  })
}

fn insert_catalog_row(conn: Connection, now: Int) -> Result(Nil, OpenError) {
  run(
    conn,
    "INSERT INTO session(created_at, parent_session_id, storage_version,
       metadata, message_count, usage_payload, next_seq)
     VALUES (?1, NULL, ?2, NULL, 0, ?3, 1)",
    [
      sqlight.int(now),
      sqlight.int(storage_version),
      blob_of_json(codec.encode_usage(storage.empty_usage())),
    ],
    decode.dynamic,
  )
  |> result.map_error(open_failed)
  |> result.replace(Nil)
}

// Verifies, purely, that the chain has a step for every version from
// `from` up to this build's; the first gap is the refusal, reported
// before anything has been written.
fn check_chain(
  from: Int,
  migrations: List(Migration),
) -> Result(Nil, OpenError) {
  case from >= storage_version {
    True -> Ok(Nil)
    False ->
      case list.find(migrations, fn(step) { step.from_version == from }) {
        Ok(_) -> check_chain(from + 1, migrations)
        Error(Nil) ->
          Error(UnsupportedVersion(found: from, supported: storage_version))
      }
  }
}

// Runs the migrate-on-open chain from `from` up to `storage_version`. One
// transaction per step: the step's statements and its version bump commit
// together, so a crash mid-chain leaves a file that simply resumes the
// chain on the next open.
fn migrate(
  conn: Connection,
  from: Int,
  migrations: List(Migration),
) -> Result(Nil, OpenError) {
  use <- bool.guard(when: from == storage_version, return: Ok(Nil))
  use Migration(statements:, ..) <- result.try(
    list.find(migrations, fn(step) { step.from_version == from })
    |> result.replace_error(UnsupportedVersion(
      found: from,
      supported: storage_version,
    )),
  )
  use Nil <- result.try(run_migration_step(conn, from, statements))
  migrate(conn, from + 1, migrations)
}

// One step's statements plus its version bump, inside one transaction:
// rolls back and translates the failure on error, otherwise commits.
fn run_migration_step(
  conn: Connection,
  from: Int,
  statements: String,
) -> Result(Nil, OpenError) {
  let stepped = {
    use Nil <- result.try(begin_immediate(conn))
    let body = {
      use Nil <- result.try(
        sqlight.exec(statements, on: conn) |> result.map_error(FailSql),
      )
      use _ <- result.try(run(
        conn,
        "UPDATE session SET storage_version = ?1",
        [sqlight.int(from + 1)],
        decode.dynamic,
      ))
      commit_sql(conn)
    }
    case body {
      Ok(Nil) -> Ok(Nil)
      Error(fail) -> {
        let _ = rollback(conn)
        Error(fail)
      }
    }
  }
  result.map_error(stepped, open_failed)
}

// Claims the writer lease inside the caller's admission transaction: a
// missing lease is claimed at fence 1, an expired one stolen with a
// bumped fence (so the previous holder's commits are fenced out even if
// it comes back), and an unexpired one refuses the open. The refusal
// happens before this writer has written anything durable — an
// existing-file admission claims last, and a create-path admission's
// writes roll back with the refusal.
fn claim_lease(
  conn: Connection,
  config: Config,
  now: Int,
) -> Result(Int, OpenError) {
  let lease_decoder = {
    use owner <- decode.field(0, decode.string)
    use fence <- decode.field(1, decode.int)
    use expires_at_ms <- decode.field(2, decode.int)
    decode.success(#(owner, fence, expires_at_ms))
  }
  use rows <- result.try(
    run(
      conn,
      "SELECT owner_id, fence, expires_at_ms FROM writer_lease",
      [],
      lease_decoder,
    )
    |> result.map_error(open_failed),
  )
  use fence <- result.try(case rows {
    [] -> Ok(1)
    [#(_, fence, expires_at_ms)] if expires_at_ms <= now -> Ok(fence + 1)
    [#(owner, _, expires_at_ms), ..] -> Error(LeaseHeld(owner:, expires_at_ms:))
  })
  let written = {
    use _ <- result.try(run(
      conn,
      "DELETE FROM writer_lease",
      [],
      decode.dynamic,
    ))
    run(
      conn,
      "INSERT INTO writer_lease(owner_id, fence, expires_at_ms) VALUES (?1, ?2, ?3)",
      [
        sqlight.text(config.owner),
        sqlight.int(fence),
        sqlight.int(now + config.lease_ttl_ms),
      ],
      decode.dynamic,
    )
  }
  written
  |> result.map_error(open_failed)
  |> result.replace(fence)
}

// Best-effort release of a lease this open claimed but cannot use (a
// migration or journal-mode failure after admission committed). Scoped to
// our own (owner, fence) pair like `Close`, and issued through `exec` —
// the busy-total path — with the owner quoted as a SQL literal, because
// no transaction protects this statement from cross-process contention.
fn abandon_lease(
  conn: Connection,
  owner: String,
  fence: Int,
) -> Result(Nil, Nil) {
  sqlight.exec(
    "DELETE FROM writer_lease WHERE owner_id = "
      <> sql_quote(owner)
      <> " AND fence = "
      <> int.to_string(fence),
    on: conn,
  )
  |> result.replace(Nil)
  |> result.replace_error(Nil)
}

const schema_sql = "
CREATE TABLE IF NOT EXISTS entries(
  id TEXT PRIMARY KEY, parent_id TEXT, seq INTEGER, type TEXT,
  custom_type TEXT, ts INTEGER, payload BLOB) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_entry_parent ON entries(parent_id);
CREATE INDEX IF NOT EXISTS ix_entry_seq ON entries(seq, type);
CREATE TABLE IF NOT EXISTS registers(
  ns TEXT NOT NULL, key TEXT NOT NULL, seq INTEGER NOT NULL,
  value BLOB NOT NULL, PRIMARY KEY(ns, key));
CREATE TABLE IF NOT EXISTS usage_ledger(
  id TEXT PRIMARY KEY, seq INTEGER, entry_id TEXT, adjustment INTEGER,
  usage BLOB, details BLOB) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_usage_seq ON usage_ledger(seq);
CREATE TABLE IF NOT EXISTS branch_entries(
  branch_id TEXT, entry_id TEXT, entry_seq INTEGER, entry_type TEXT,
  PRIMARY KEY(branch_id, entry_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_be_seq
  ON branch_entries(branch_id, entry_seq, entry_id, entry_type);
CREATE INDEX IF NOT EXISTS ix_be_type
  ON branch_entries(branch_id, entry_type, entry_seq, entry_id);
CREATE INDEX IF NOT EXISTS ix_be_entry ON branch_entries(entry_id);
CREATE TABLE IF NOT EXISTS branch_meta(
  branch_id TEXT PRIMARY KEY, tip_entry_id TEXT, tip_seq INTEGER,
  base_branch_id TEXT, base_seq INTEGER);
CREATE UNIQUE INDEX IF NOT EXISTS ix_bm_tip ON branch_meta(tip_entry_id);
CREATE TABLE IF NOT EXISTS session(
  created_at INTEGER, parent_session_id TEXT, storage_version INTEGER,
  metadata BLOB, message_count INTEGER, usage_payload BLOB, next_seq INTEGER);
CREATE TABLE IF NOT EXISTS writer_lease(
  owner_id TEXT, fence INTEGER, expires_at_ms INTEGER);
"

fn start_actor(
  conn: Connection,
  config: Config,
  clock: Clock,
  fence: Int,
) -> Result(Storage(Subject(Message)), OpenError) {
  let state =
    ActorState(
      conn:,
      clock:,
      owner: config.owner,
      fence:,
      lease_ttl_ms: config.lease_ttl_ms,
      closed: False,
    )
  let started =
    actor.new(state)
    |> actor.on_message(handle_message)
    |> actor.start
  case started {
    Ok(started) ->
      Ok(
        Storage(
          handle: started.data,
          commit: fn(handle, tx) { process.call_forever(handle, Commit(tx, _)) },
          get_entries: fn(handle, entry_ids) {
            process.call_forever(handle, GetEntries(entry_ids, _))
          },
          get_register: fn(handle, ns, key) {
            process.call_forever(handle, GetRegister(ns, key, _))
          },
          list_registers: fn(handle, ns, prefix) {
            process.call_forever(handle, ListRegisters(ns, prefix, _))
          },
          scan_branch: fn(handle, q) {
            process.call_forever(handle, ScanBranch(q, _))
          },
          scan_entries: fn(handle, q) {
            process.call_forever(handle, ScanEntries(q, _))
          },
          scan_usage: fn(handle, q) {
            process.call_forever(handle, ScanUsage(q, _))
          },
          stats: fn(handle) { process.call_forever(handle, Stats) },
          close: fn(handle) { process.call_forever(handle, Close) },
        ),
      )
    Error(error) ->
      Error(OpenFailed(
        reason: "sqlite storage actor failed to start: "
        <> start_error_reason(error),
      ))
  }
}

fn start_error_reason(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "initialisation timeout"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "initialiser exited"
  }
}

/// Renews the writer lease without committing anything, for idle-period
/// keep-alive (the WP-E writer calls this on a timer). Fails with
/// `BackendFault` if the lease has been stolen.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = sqlite.renew_lease(store.handle)
/// ```
///
pub fn renew_lease(handle: Subject(Message)) -> Result(Nil, StorageError) {
  process.call_forever(handle, RenewLease)
}

/// Projects a session's canonical identity (`protocol-change/008`) into
/// the catalog row: `parent_session_id` into the column pi's schema
/// reserved for it, and the session's own id into the `metadata` blob
/// beside `generation`, which needs no column and therefore no schema
/// version bump.
///
/// This is a **projection, not the truth**. The truth is the session's
/// own `session/id` and `session/parent` register cells, which both
/// backends carry; the row exists so a repository lister or an operator
/// with a `sqlite3` shell can read the parent→child graph without opening
/// and leasing every file (see `identity`). Writing it is idempotent, and
/// a session layer repairs it on every open.
///
/// ## Examples
///
/// ```gleam
/// // sqlite.record_identity(store.handle, session_id: "0195…",
/// //   parent_session_id: option.None)
/// ```
///
pub fn record_identity(
  handle: Subject(Message),
  session_id session_id: String,
  parent_session_id parent_session_id: Option(String),
) -> Result(Nil, StorageError) {
  process.call_forever(handle, RecordIdentity(session_id, parent_session_id, _))
}

/// Reads a session file's recorded identity — its own canonical id and
/// its parent's, if either was ever projected — without acquiring the
/// writer lease. The lease-free pairing `generation(path:)` established:
/// an outside reader (a repository lister, a cross-session index) needs
/// these to build the parent→child graph and must not have to lease every
/// file to do it.
///
/// Both halves are `None` on a session that predates
/// `protocol-change/008` or has never been opened by a runtime; the next
/// open mints and records.
///
/// ## Examples
///
/// ```gleam
/// // sqlite.identity(path: "/tmp/s.db") == Ok(#(Some("0195…"), None))
/// ```
///
pub fn identity(
  path path: String,
) -> Result(#(Option(String), Option(String)), RewriteError) {
  use Nil <- result.try(require_session_file(path))
  case sqlight.open(path) {
    Error(error) ->
      Error(RewriteFailed(reason: "sqlite open: " <> describe_sqlight(error)))
    Ok(conn) -> {
      let outcome = read_identity(conn)
      let _ = sqlight.close(conn)
      outcome
    }
  }
}

/// Reads one complete entry without acquiring or renewing a writer lease.
///
/// The host supplies the path; callers must never accept it from a model.
/// Identity and entry are read through one connection, so a replaced file
/// cannot pair another session's identity with this session's payload.
/// Read-only mode also prevents creating a missing source database.
///
/// ## Examples
///
/// ```gleam
/// // sqlite.read_entry(path: source, session: session_id, entry: entry_id)
/// ```
pub fn read_entry(
  path path: String,
  session session: ids.SessionId,
  entry entry: EntryId,
) -> Result(Entry, StorageError) {
  let encoded_path =
    path
    |> string.split("/")
    |> list.map(uri.percent_encode)
    |> string.join("/")
  use conn <- result.try(
    sqlight.open("file:" <> encoded_path <> "?mode=ro&cache=private")
    |> result.map_error(fn(error) { BackendFault(describe_sqlight(error)) }),
  )
  let outcome = read_identified_entry(conn, session, entry)
  let _closed = sqlight.close(conn)
  outcome
}

fn read_identified_entry(
  conn: Connection,
  session: ids.SessionId,
  entry: EntryId,
) -> Result(Entry, StorageError) {
  use #(identity, _parent) <- result.try(
    read_identity(conn)
    |> result.map_error(fn(error) { BackendFault(string.inspect(error)) }),
  )
  use Nil <- result.try(
    case identity == Some(ids.session_id_to_string(session)) {
      True -> Ok(Nil)
      False -> Error(BackendFault("history source session identity mismatch"))
    },
  )
  use entries <- result.try(do_get_entries(conn, [entry]))
  dict.get(entries, entry) |> result.map_error(fn(_) { UnknownEntry(entry) })
}

fn read_identity(
  conn: Connection,
) -> Result(#(Option(String), Option(String)), RewriteError) {
  use rows <- result.try(
    run(conn, "SELECT parent_session_id, metadata FROM session", [], {
      use parent <- decode.field(0, decode.optional(decode.string))
      use metadata <- decode.field(1, decode.optional(decode.bit_array))
      decode.success(#(parent, metadata))
    })
    |> result.map_error(rewrite_fail),
  )
  case rows {
    [#(parent, metadata)] -> {
      use fields <- result.map(
        metadata_fields(metadata)
        |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
      )
      #(metadata_session_id(fields), parent)
    }
    [] | [_, ..] ->
      Error(
        RewriteCorrupt(report: corruption.report(
          at: "storage/sqlite.identity",
          on: "session catalog",
          expected: "exactly one session row",
          context: int.to_string(list.length(rows)) <> " rows",
        )),
      )
  }
}

// The recorded id out of the metadata blob's fields; a missing or
// non-string field reads as "no id recorded" rather than as corruption,
// because this row is a projection and the register cell is the truth.
fn metadata_session_id(fields: List(#(String, JsonValue))) -> Option(String) {
  case list.key_find(fields, metadata_session_id_field) {
    Ok(json.String(text)) -> Some(text)
    Ok(_) | Error(Nil) -> None
  }
}

/// The `EXPLAIN QUERY PLAN` detail lines of the branch segment query in
/// the given scan order (`NewestFirst` explains the `ORDER BY … DESC`
/// page query, `OldestFirst` the `… ASC` variant), for the conformance
/// suite's plan assertions: in both orders the plan must open with a
/// covering search of `ix_be_seq` on `branch_entries`, probe `entries` by
/// primary key, and contain neither a `TEMP B-TREE FOR ORDER BY` step nor
/// a scan of `entries`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(lines) =
///   sqlite.scan_branch_plan(store.handle, storage.NewestFirst)
/// ```
///
pub fn scan_branch_plan(
  handle: Subject(Message),
  order: ScanOrder,
) -> Result(List(String), StorageError) {
  process.call_forever(handle, ScanBranchPlan(order, _))
}

/// The branch-index segment metadata, for diagnostics and conformance
/// assertions (tip uniqueness, base validity).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(segments) = sqlite.segments(store.handle)
/// ```
///
pub fn segments(
  handle: Subject(Message),
) -> Result(List(Segment), StorageError) {
  process.call_forever(handle, Segments)
}

// --- precise rewrite (pi §2.9, repo-level admin op) -----------------------

/// The outcome of a precise rewrite: the file's new generation counter —
/// external indexes (WP-K search) key their cursors on it and re-index on
/// a mismatch — and how many entries the transform replaced.
pub type Rewrite {
  Rewrite(generation: Int, entries_rewritten: Int)
}

/// Why a precise rewrite refused or failed. In every failure case the
/// original session file's *content* is untouched: the rewrite works on a
/// copy and only an atomic rename replaces the original. (A failed
/// rewrite also releases the writer lease it held while running.)
pub type RewriteError {
  /// A writer holds an unexpired lease on the session file — or stole it
  /// mid-rewrite after the rewrite's own lease expired. A rewrite is an
  /// offline admin operation; close (or let expire) the writer first.
  RewriteLeaseHeld(owner: String, expires_at_ms: Int)

  /// A stored payload failed its total decode, the file is not a
  /// current-version Loom session, or a transform broke an invariant
  /// (changed an entry's id, parent, or kind, or reported corruption).
  RewriteCorrupt(report: CorruptionReport)

  /// The copy, update, vacuum, swap, or sibling cleanup failed at the SQL
  /// or file level.
  RewriteFailed(reason: String)
}

// The reserved lease identity a precise rewrite holds while it runs.
// Writer configs must not use this owner id, or their lease is
// indistinguishable from a rewrite's.
const rewrite_owner = "rewrite"

// The rewrite's lease TTL. Generous, because it must cover the whole
// copy-transform-vacuum-swap pass; bounded, so a crashed rewrite does not
// lock the file out forever — the lease expires and the next opener
// steals it with a bumped fence.
const rewrite_lease_ttl_ms = 600_000

/// Precisely rewrites a **closed** session file. The rewrite first claims
/// the writer lease in the original under the reserved `"rewrite"` owner
/// and holds it for the whole operation, so a concurrent `open` is
/// refused with `LeaseHeld` instead of committing into a file the swap
/// would discard. It then retires the original's WAL (checkpointing every
/// frame into the main file and truncating the `-wal` to zero bytes, so
/// no pre-rewrite page can ever be replayed into the swapped-in file),
/// copies the file coherently with `VACUUM INTO`, applies `rewrite` to
/// every entry payload in the copy (`Ok(None)` keeps the entry,
/// `Ok(Some(new))` replaces its payload — id, parent, and kind must be
/// preserved; retained-tail copies inside compaction entries are ordinary
/// payload content and are rewritten with them) and `rewrite_value` to
/// every register payload and usage-ledger details blob, bumps the
/// generation counter in the session metadata, vacuums the copy so the
/// replaced bytes do not survive in free pages, re-verifies the lease is
/// still its own, and atomically swaps the copy over the original via
/// rename. The swapped-in file starts unleased.
///
/// This is the sole sanctioned exception to "entries are never modified"
/// (pi §2.9): compliance-grade erasure. No harness surface calls it; it is
/// repository tooling above the harness. The audit contract is that after
/// erasing a string, that string appears nowhere in the new file's raw
/// bytes — entries, registers (queued pending messages, tool arguments,
/// compaction preparation, facts), and usage details included.
///
/// The clock is read once, to judge lease expiry and stamp the rewrite's
/// own claim; an unexpired writer lease refuses the rewrite with
/// `RewriteLeaseHeld`.
///
/// ## Examples
///
/// ```gleam
/// // sqlite.rewrite_into(path: "/tmp/s.db", clock:,
/// //   rewrite: erase, rewrite_value: erase_value)
/// // -> Ok(sqlite.Rewrite(generation: 1, entries_rewritten: 3))
/// ```
///
pub fn rewrite_into(
  path path: String,
  clock clock: Clock,
  rewrite rewrite: fn(Entry) -> Result(Option(Entry), CorruptionReport),
  rewrite_value rewrite_value: fn(JsonValue) ->
    Result(Option(JsonValue), CorruptionReport),
) -> Result(Rewrite, RewriteError) {
  let #(now, _clock) = clock.read(clock)
  use Nil <- result.try(require_session_file(path))
  case sqlight.open(path) {
    Error(error) ->
      Error(RewriteFailed(reason: "sqlite open: " <> describe_sqlight(error)))
    Ok(conn) ->
      case stage_rewrite(conn, path, now, rewrite, rewrite_value) {
        Ok(#(temp, fence, outcome)) -> swap(conn, path, temp, fence, outcome)
        Error(error) -> {
          let _ = sqlight.close(conn)
          Error(error)
        }
      }
  }
}

// Everything up to (but not including) the swap: claim the lease in the
// original, retire its WAL, take the copy, transform it, and re-verify
// the lease. On any failure after the claim the lease is released and the
// temp copy removed, leaving the original exactly as it was found.
fn stage_rewrite(
  conn: Connection,
  path: String,
  now: Int,
  rewrite: fn(Entry) -> Result(Option(Entry), CorruptionReport),
  rewrite_value: fn(JsonValue) -> Result(Option(JsonValue), CorruptionReport),
) -> Result(#(String, Int, Rewrite), RewriteError) {
  // The claim transaction below contends with concurrent open probes;
  // without a busy timeout it would fail spuriously instead of waiting.
  use Nil <- result.try(
    sqlight.exec("PRAGMA busy_timeout = 5000", on: conn)
    |> result.map_error(fn(error) {
      RewriteFailed(reason: "busy_timeout: " <> describe_sqlight(error))
    }),
  )
  use fence <- result.try(claim_rewrite_lease(conn, now))
  let temp = path <> ".rewrite"
  let staged = {
    // Only a lease holder reaps a leftover copy from a crashed rewrite,
    // so a refused rewrite can never delete a live one's temp file.
    use Nil <- result.try(remove_file(temp, "stale rewrite copy"))
    use Nil <- result.try(retire_wal(conn))
    use Nil <- result.try(
      run(conn, "VACUUM INTO " <> sql_quote(temp), [], decode.dynamic)
      |> result.map_error(rewrite_fail)
      |> result.replace(Nil),
    )
    use outcome <- result.try(rewrite_copy(temp, rewrite, rewrite_value))

    // Re-verify immediately before the swap: if the rewrite outlived its
    // TTL and a writer stole the lease, that writer's commits are in the
    // original and the copy is stale — abort rather than discard them
    // with the rename.
    use Nil <- result.map(verify_rewrite_lease(conn, fence))
    #(temp, fence, outcome)
  }
  case staged {
    Ok(ok) -> Ok(ok)
    Error(error) -> {
      let _ = simplifile.delete(temp)
      let _ = release_rewrite_lease(conn, fence)
      Error(error)
    }
  }
}

// The atomic swap and its aftermath. After the rename, the original's
// inode (still open on `conn`) is unlinked from the path and the copy —
// erased, vacuumed, lease cleared — is the session file; closing `conn`
// then drops the last reference to the old bytes. The sibling deletes are
// belt-and-braces (the WAL was retired before the copy was even taken),
// but a failure to remove an on-disk remnant is an audit failure and is
// reported, never discarded (M3-01: a swallowed unlink error reported a
// clean erasure that the next open silently undid).
fn swap(
  conn: Connection,
  path: String,
  temp: String,
  fence: Int,
  outcome: Rewrite,
) -> Result(Rewrite, RewriteError) {
  case simplifile.rename(at: temp, to: path) {
    Ok(Nil) -> {
      let _ = sqlight.close(conn)
      use Nil <- result.try(remove_file(path <> "-wal", "stale wal sibling"))
      use Nil <- result.map(remove_file(path <> "-shm", "stale shm sibling"))
      outcome
    }
    Error(error) -> {
      // The rename never happened, so the original is intact: release the
      // rewrite's lease from it before reporting.
      let _ = simplifile.delete(temp)
      let _ = release_rewrite_lease(conn, fence)
      let _ = sqlight.close(conn)
      Error(RewriteFailed(reason: "swap: " <> simplifile.describe_error(error)))
    }
  }
}

// Deletes a file, treating "already absent" as success and any other
// failure as a real error — a rewrite that cannot remove an on-disk
// remnant must say so, not report a clean erasure over it.
fn remove_file(path: String, what: String) -> Result(Nil, RewriteError) {
  case simplifile.delete(path) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(RewriteFailed(
        reason: what <> " " <> path <> ": " <> simplifile.describe_error(error),
      ))
  }
}

// Retires the original's WAL before the copy is taken: a TRUNCATE
// checkpoint moves every frame into the main database file and truncates
// the `-wal` to zero bytes, so nothing on disk can replay pre-rewrite
// pages into the swapped-in file (M3-01 — SQLite recovers any WAL whose
// checksums and page size match the database at its path, and the old
// WAL matches the copy by construction). The pragma reports rather than
// fails when it cannot finish — a lingering reader leaves its first
// column at 1 — so the row is read and anything short of a complete
// checkpoint refuses the rewrite instead of shipping an audit that the
// next open would undo. (Leaving WAL mode entirely would delete the
// siblings too, but that needs every other connection to the file gone,
// which a freshly closed handle's not-yet-collected statement objects
// can defeat; a truncated WAL is just as unreplayable.) On a non-WAL
// file the pragma is a no-op reporting success.
fn retire_wal(conn: Connection) -> Result(Nil, RewriteError) {
  use rows <- result.try(
    run(conn, "PRAGMA wal_checkpoint(TRUNCATE)", [], decode.at([0], decode.int))
    |> result.map_error(rewrite_fail),
  )
  case rows {
    [0] -> Ok(Nil)
    [_, ..] | [] ->
      Error(RewriteFailed(
        reason: "wal checkpoint could not complete (readers still active)",
      ))
  }
}

// Admission for the rewrite, in one immediate transaction: verify the
// file is a current-version session with exactly one catalog row, then
// claim the writer lease under the reserved owner — refusing an unexpired
// holder, stealing an expired one with a bumped fence. Unlike the
// sample-once check this replaces (M3-02), the claim *holds*: from here
// until the swap, or a failure's release, a concurrent `open` is refused
// with `LeaseHeld` instead of committing into a file the rename is about
// to discard.
fn claim_rewrite_lease(
  conn: Connection,
  now: Int,
) -> Result(Int, RewriteError) {
  use Nil <- result.try(begin_immediate(conn) |> result.map_error(rewrite_fail))
  let claimed = {
    use Nil <- result.try(check_source_version(conn))
    let lease_decoder = {
      use owner <- decode.field(0, decode.string)
      use fence <- decode.field(1, decode.int)
      use expires_at_ms <- decode.field(2, decode.int)
      decode.success(#(owner, fence, expires_at_ms))
    }
    use rows <- result.try(
      run(
        conn,
        "SELECT owner_id, fence, expires_at_ms FROM writer_lease",
        [],
        lease_decoder,
      )
      |> result.map_error(rewrite_fail),
    )
    use fence <- result.try(case rows {
      [] -> Ok(1)
      [#(_, fence, expires_at_ms)] if expires_at_ms <= now -> Ok(fence + 1)
      [#(owner, _, expires_at_ms), ..] ->
        Error(RewriteLeaseHeld(owner:, expires_at_ms:))
    })
    use _ <- result.try(
      run(conn, "DELETE FROM writer_lease", [], decode.dynamic)
      |> result.map_error(rewrite_fail),
    )
    use _ <- result.try(
      run(
        conn,
        "INSERT INTO writer_lease(owner_id, fence, expires_at_ms) VALUES (?1, ?2, ?3)",
        [
          sqlight.text(rewrite_owner),
          sqlight.int(fence),
          sqlight.int(now + rewrite_lease_ttl_ms),
        ],
        decode.dynamic,
      )
      |> result.map_error(rewrite_fail),
    )
    use Nil <- result.map(commit_sql(conn) |> result.map_error(rewrite_fail))
    fence
  }
  case claimed {
    Ok(fence) -> Ok(fence)
    Error(error) -> {
      let _ = rollback(conn)
      Error(error)
    }
  }
}

// Re-reads the lease: it must still be the claim this rewrite made.
// Anything else means the TTL lapsed and another owner took over.
fn verify_rewrite_lease(
  conn: Connection,
  fence: Int,
) -> Result(Nil, RewriteError) {
  let lease_decoder = {
    use owner <- decode.field(0, decode.string)
    use held_fence <- decode.field(1, decode.int)
    use expires_at_ms <- decode.field(2, decode.int)
    decode.success(#(owner, held_fence, expires_at_ms))
  }
  use rows <- result.try(
    run(
      conn,
      "SELECT owner_id, fence, expires_at_ms FROM writer_lease",
      [],
      lease_decoder,
    )
    |> result.map_error(rewrite_fail),
  )
  case rows {
    [#(owner, held_fence, _)] if owner == rewrite_owner && held_fence == fence ->
      Ok(Nil)
    [#(owner, _, expires_at_ms), ..] ->
      Error(RewriteLeaseHeld(owner:, expires_at_ms:))
    [] -> Error(RewriteFailed(reason: "writer lease vanished during rewrite"))
  }
}

// Best-effort release scoped to this rewrite's own claim; runs on every
// failure path where the original file survives. Issued through `exec` —
// the busy-total path — with program-constant operands, because no
// transaction protects this statement from cross-process contention.
fn release_rewrite_lease(conn: Connection, fence: Int) -> Result(Nil, Nil) {
  sqlight.exec(
    "DELETE FROM writer_lease WHERE owner_id = "
      <> sql_quote(rewrite_owner)
      <> " AND fence = "
      <> int.to_string(fence),
    on: conn,
  )
  |> result.replace(Nil)
  |> result.replace_error(Nil)
}

/// Reads the session file's precise-rewrite generation counter without
/// acquiring the writer lease. Fresh files are generation 0; every
/// precise rewrite bumps it by one, so an external index whose cursors
/// are keyed on an older generation knows to re-index from scratch.
///
/// ## Examples
///
/// ```gleam
/// // sqlite.generation(path: "/tmp/s.db") == Ok(0)
/// ```
///
pub fn generation(path path: String) -> Result(Int, RewriteError) {
  use Nil <- result.try(require_session_file(path))
  case sqlight.open(path) {
    Error(error) ->
      Error(RewriteFailed(reason: "sqlite open: " <> describe_sqlight(error)))
    Ok(conn) -> {
      let outcome = {
        use #(_fields, generation) <- result.map(read_generation(conn))
        generation
      }
      let _ = sqlight.close(conn)
      outcome
    }
  }
}

// `sqlight.open` creates a missing file, so path-level operations that
// must not conjure empty databases check existence first.
fn require_session_file(path: String) -> Result(Nil, RewriteError) {
  case simplifile.is_file(path) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(RewriteFailed(reason: "no session file at " <> path))
    Error(error) ->
      Error(RewriteFailed(reason: simplifile.describe_error(error)))
  }
}

fn rewrite_fail(fail: Fail) -> RewriteError {
  case fail {
    FailSql(error) ->
      RewriteFailed(reason: "sqlite: " <> describe_sqlight(error))
    FailCorrupt(report) -> RewriteCorrupt(report:)
    FailStale(_) | FailLease(_) | FailUnknownEntry(_) ->
      RewriteFailed(reason: "unexpected failure during rewrite")
  }
}

// Verifies, inside the claim transaction, that the source is a
// current-version session file with exactly one catalog row.
fn check_source_version(conn: Connection) -> Result(Nil, RewriteError) {
  use versions <- result.try(
    run(
      conn,
      "SELECT storage_version FROM session",
      [],
      decode.at([0], decode.int),
    )
    |> result.map_error(rewrite_fail),
  )
  case versions {
    [version] -> {
      use <- bool.guard(when: version == storage_version, return: Ok(Nil))
      Error(
        RewriteCorrupt(report: corruption.report(
          at: "storage/sqlite.rewrite_into",
          on: "session.storage_version",
          expected: "version "
            <> int.to_string(storage_version)
            <> " (open the file once to migrate it first)",
          context: int.to_string(version),
        )),
      )
    }
    [] | [_, ..] ->
      Error(
        RewriteCorrupt(report: corruption.report(
          at: "storage/sqlite.rewrite_into",
          on: "session catalog",
          expected: "exactly one session row",
          context: int.to_string(list.length(versions)) <> " rows",
        )),
      )
  }
}

// Applies the transforms to the copy inside one transaction — entry
// payloads through `rewrite`, register payloads and usage details through
// `rewrite_value` (the audit contract covers every store a needle can
// reach, not just entries: queued pending messages, tool arguments,
// compaction preparation, facts, and usage details are exactly where a
// leaked secret also lands) — clears the lease table so the swapped-in
// file starts unleased, bumps the generation, then vacuums so no replaced
// bytes survive in free pages.
fn rewrite_copy(
  temp: String,
  rewrite: fn(Entry) -> Result(Option(Entry), CorruptionReport),
  rewrite_value: fn(JsonValue) -> Result(Option(JsonValue), CorruptionReport),
) -> Result(Rewrite, RewriteError) {
  case sqlight.open(temp) {
    Error(error) ->
      Error(RewriteFailed(reason: "sqlite open: " <> describe_sqlight(error)))
    Ok(conn) -> {
      let outcome = rewrite_copy_transaction(conn, rewrite, rewrite_value)
      let _ = sqlight.close(conn)
      outcome
    }
  }
}

// The whole rewrite transaction over the copy: both transforms, then the
// lease-table clear and generation bump, committed together; on any
// failure the transaction rolls back before the error is reported. Only
// a committed rewrite is vacuumed, so the replaced bytes never survive in
// free pages of an aborted attempt.
fn rewrite_copy_transaction(
  conn: Connection,
  rewrite: fn(Entry) -> Result(Option(Entry), CorruptionReport),
  rewrite_value: fn(JsonValue) -> Result(Option(JsonValue), CorruptionReport),
) -> Result(Rewrite, RewriteError) {
  use Nil <- result.try(begin_immediate(conn) |> result.map_error(rewrite_fail))
  let row_decoder = {
    use id_text <- decode.field(0, decode.string)
    use payload <- decode.field(1, decode.bit_array)
    decode.success(#(id_text, payload))
  }
  let body = {
    use rows <- result.try(
      run(conn, "SELECT id, payload FROM entries", [], row_decoder)
      |> result.map_error(rewrite_fail),
    )
    use rewritten <- result.try(
      list.try_fold(over: rows, from: 0, with: fn(count, row) {
        rewrite_row(conn, row, rewrite, count)
      }),
    )
    use Nil <- result.try(rewrite_registers(conn, rewrite_value))
    use Nil <- result.try(rewrite_usage_details(conn, rewrite_value))

    // The lease this rewrite holds lives in the *original* and dies
    // with it at the swap; the copy must not carry it over.
    use _ <- result.try(
      run(conn, "DELETE FROM writer_lease", [], decode.dynamic)
      |> result.map_error(rewrite_fail),
    )
    use generation <- result.try(bump_generation(conn))
    use Nil <- result.map(commit_sql(conn) |> result.map_error(rewrite_fail))
    Rewrite(generation:, entries_rewritten: rewritten)
  }
  case body {
    Ok(outcome) ->
      run(conn, "VACUUM", [], decode.dynamic)
      |> result.map_error(rewrite_fail)
      |> result.replace(outcome)
    Error(error) -> {
      let _ = rollback(conn)
      Error(error)
    }
  }
}

// Runs the value transform over every register payload in the copy.
// Register payloads are free-form JSON at this boundary (the machine
// codecs interpret them later), so the rewritten value needs no
// structural re-decode here — but a needle that collides with an id a
// register carries (a strand leaf, an operation id) will surface as
// corruption at the machine-level read, exactly like an id collision
// inside an entry surfaces at the entry codec.
fn rewrite_registers(
  conn: Connection,
  rewrite_value: fn(JsonValue) -> Result(Option(JsonValue), CorruptionReport),
) -> Result(Nil, RewriteError) {
  let cell_decoder = {
    use ns <- decode.field(0, decode.string)
    use key <- decode.field(1, decode.string)
    use blob <- decode.field(2, decode.bit_array)
    decode.success(#(ns, key, blob))
  }
  use rows <- result.try(
    run(conn, "SELECT ns, key, value FROM registers", [], cell_decoder)
    |> result.map_error(rewrite_fail),
  )
  list.try_fold(over: rows, from: Nil, with: fn(_, row) {
    let #(ns, key, blob) = row
    use value <- result.try(
      json_of_blob(blob, ns <> "/" <> key)
      |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
    )
    use replacement <- result.try(
      rewrite_value(value)
      |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
    )
    case replacement {
      None -> Ok(Nil)
      Some(new) ->
        run(
          conn,
          "UPDATE registers SET value = ?1 WHERE ns = ?2 AND key = ?3",
          [blob_of_json(new), sqlight.text(ns), sqlight.text(key)],
          decode.dynamic,
        )
        |> result.map_error(rewrite_fail)
        |> result.replace(Nil)
    }
  })
}

// Runs the value transform over every usage-ledger details blob in the
// copy. Details are opaque JSON written straight through at commit, and
// straight through here on the way back out.
fn rewrite_usage_details(
  conn: Connection,
  rewrite_value: fn(JsonValue) -> Result(Option(JsonValue), CorruptionReport),
) -> Result(Nil, RewriteError) {
  let row_decoder = {
    use id_text <- decode.field(0, decode.string)
    use blob <- decode.field(1, decode.bit_array)
    decode.success(#(id_text, blob))
  }
  use rows <- result.try(
    run(
      conn,
      "SELECT id, details FROM usage_ledger WHERE details IS NOT NULL",
      [],
      row_decoder,
    )
    |> result.map_error(rewrite_fail),
  )
  list.try_fold(over: rows, from: Nil, with: fn(_, row) {
    let #(id_text, blob) = row
    use value <- result.try(
      json_of_blob(blob, id_text)
      |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
    )
    use replacement <- result.try(
      rewrite_value(value)
      |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
    )
    case replacement {
      None -> Ok(Nil)
      Some(new) ->
        run(
          conn,
          "UPDATE usage_ledger SET details = ?1 WHERE id = ?2",
          [blob_of_json(new), sqlight.text(id_text)],
          decode.dynamic,
        )
        |> result.map_error(rewrite_fail)
        |> result.replace(Nil)
    }
  })
}

fn rewrite_row(
  conn: Connection,
  row: #(String, BitArray),
  rewrite: fn(Entry) -> Result(Option(Entry), CorruptionReport),
  count: Int,
) -> Result(Int, RewriteError) {
  let #(id_text, blob) = row
  use entry <- result.try(
    entry_of_blob(blob)
    |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
  )
  use replacement <- result.try(
    rewrite(entry) |> result.map_error(fn(report) { RewriteCorrupt(report:) }),
  )
  case replacement {
    None -> Ok(count)
    Some(new) -> {
      use Nil <- result.try(check_placement(entry, new))

      // Re-stamp placement from the stored row so a transform cannot move
      // an entry even accidentally.
      let stamped = storage.stamp(new, seq: entry.seq, ts: entry.ts)
      use _ <- result.map(
        run(
          conn,
          "UPDATE entries SET payload = ?1, custom_type = ?2 WHERE id = ?3",
          [
            blob_of_json(codec.encode_entry(stamped)),
            sqlight.nullable(sqlight.text, custom_type_of(stamped)),
            sqlight.text(id_text),
          ],
          decode.dynamic,
        )
        |> result.map_error(rewrite_fail),
      )
      count + 1
    }
  }
}

fn check_placement(old: Entry, new: Entry) -> Result(Nil, RewriteError) {
  let preserved =
    old.id == new.id
    && old.parent == new.parent
    && storage.kind_of(old) == storage.kind_of(new)
  case preserved {
    True -> Ok(Nil)
    False ->
      Error(
        RewriteCorrupt(report: corruption.report(
          at: "storage/sqlite.rewrite_into",
          on: ids.entry_id_to_string(old.id),
          expected: "a rewrite preserving entry id, parent, and kind",
          context: "transform changed entry placement",
        )),
      )
  }
}

// Reads `(other metadata fields, current generation)`; an absent metadata
// blob or absent field is generation 0.
fn read_generation(
  conn: Connection,
) -> Result(#(List(#(String, JsonValue)), Int), RewriteError) {
  use rows <- result.try(
    run(
      conn,
      "SELECT metadata FROM session",
      [],
      decode.at([0], decode.optional(decode.bit_array)),
    )
    |> result.map_error(rewrite_fail),
  )
  case rows {
    [None] -> Ok(#([], 0))
    [Some(blob)] -> parse_generation_metadata(blob)
    [] | [_, ..] ->
      Error(
        RewriteCorrupt(report: corruption.report(
          at: "storage/sqlite.rewrite_into",
          on: "session catalog",
          expected: "exactly one session row",
          context: int.to_string(list.length(rows)) <> " rows",
        )),
      )
  }
}

// Parses the session metadata blob into its other fields plus the
// generation counter (a missing "generation" field means generation 0).
fn parse_generation_metadata(
  blob: BitArray,
) -> Result(#(List(#(String, JsonValue)), Int), RewriteError) {
  let parsed = {
    use fields <- result.try(metadata_fields(Some(blob)))
    parse_generation_field(fields)
  }
  result.map_error(parsed, fn(report) { RewriteCorrupt(report:) })
}

/// The field of the catalog's `metadata` blob holding the session's own
/// canonical id (`protocol-change/008`). It rides in the blob rather than
/// in a column of its own precisely so that recording an identity needs
/// no schema version bump and no migration step.
pub const metadata_session_id_field = "session_id"

// The session catalog's metadata blob as its JSON fields: an absent blob
// is an empty field list, since a fresh file writes NULL there. Shared by
// the generation reader and the identity projection, which both
// read-modify-write the same object and must agree about its shape.
fn metadata_fields(
  metadata: Option(BitArray),
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  case metadata {
    None -> Ok([])
    Some(blob) -> {
      use value <- result.try(json_of_blob(blob, "session.metadata"))
      case value {
        json.Object(fields) -> Ok(fields)
        other ->
          Error(corruption.report(
            at: "storage/sqlite.metadata",
            on: "session.metadata",
            expected: "a json object",
            context: json.to_string(other),
          ))
      }
    }
  }
}

fn parse_generation_field(
  fields: List(#(String, JsonValue)),
) -> Result(#(List(#(String, JsonValue)), Int), CorruptionReport) {
  case list.key_find(fields, "generation") {
    Ok(json.Int(generation)) -> Ok(#(fields, generation))
    Error(Nil) -> Ok(#(fields, 0))
    Ok(other) ->
      Error(corruption.report(
        at: "storage/sqlite.rewrite_into",
        on: "session.metadata generation",
        expected: "an integer",
        context: json.to_string(other),
      ))
  }
}

fn bump_generation(conn: Connection) -> Result(Int, RewriteError) {
  use #(fields, current) <- result.try(read_generation(conn))
  let generation = current + 1
  let metadata =
    json.Object(list.key_set(fields, "generation", json.Int(generation)))
  run(
    conn,
    "UPDATE session SET metadata = ?1",
    [blob_of_json(metadata)],
    decode.dynamic,
  )
  |> result.map_error(rewrite_fail)
  |> result.replace(generation)
}

// Quotes a file path as a SQL string literal — `VACUUM INTO` takes an
// expression, and binding parameters is not supported for it everywhere.
fn sql_quote(text: String) -> String {
  "'" <> string.replace(in: text, each: "'", with: "''") <> "'"
}

// --- the actor -----------------------------------------------------------

fn handle_message(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case state.closed {
    True -> handle_closed(state, message)
    False -> handle_open(state, message)
  }
}

fn handle_closed(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message {
    Close(reply:) -> process.send(reply, Ok(Nil))
    Commit(reply:, ..) ->
      process.send(reply, Error(Faulted(reason: "storage handle closed")))
    GetEntries(reply:, ..) -> process.send(reply, Error(HandleClosed))
    GetRegister(reply:, ..) -> process.send(reply, Error(HandleClosed))
    ListRegisters(reply:, ..) -> process.send(reply, Error(HandleClosed))
    ScanBranch(reply:, ..) -> process.send(reply, Error(HandleClosed))
    ScanEntries(reply:, ..) -> process.send(reply, Error(HandleClosed))
    ScanUsage(reply:, ..) -> process.send(reply, Error(HandleClosed))
    Stats(reply:) -> process.send(reply, Error(HandleClosed))
    RenewLease(reply:) -> process.send(reply, Error(HandleClosed))
    RecordIdentity(reply:, ..) -> process.send(reply, Error(HandleClosed))
    ScanBranchPlan(reply:, ..) -> process.send(reply, Error(HandleClosed))
    Segments(reply:) -> process.send(reply, Error(HandleClosed))
  }
  actor.continue(state)
}

fn handle_open(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message {
    Commit(tx:, reply:) -> {
      let #(now, clock) = clock.read(state.clock)
      process.send(reply, do_commit(state, tx, now))
      actor.continue(ActorState(..state, clock:))
    }
    GetEntries(ids: entry_ids, reply:) -> {
      process.send(reply, do_get_entries(state.conn, entry_ids))
      actor.continue(state)
    }
    GetRegister(ns:, key:, reply:) -> {
      process.send(reply, do_get_register(state.conn, ns, key))
      actor.continue(state)
    }
    ListRegisters(ns:, key_prefix:, reply:) -> {
      process.send(reply, do_list_registers(state.conn, ns, key_prefix))
      actor.continue(state)
    }
    ScanBranch(q:, reply:) -> {
      process.send(reply, do_scan_branch(state.conn, q))
      actor.continue(state)
    }
    ScanEntries(q:, reply:) -> {
      process.send(reply, do_scan_entries(state.conn, q))
      actor.continue(state)
    }
    ScanUsage(q:, reply:) -> {
      process.send(reply, do_scan_usage(state.conn, q))
      actor.continue(state)
    }
    Stats(reply:) -> {
      process.send(reply, do_stats(state.conn))
      actor.continue(state)
    }
    RenewLease(reply:) -> {
      let #(now, clock) = clock.read(state.clock)
      process.send(reply, do_renew_lease(state, now))
      actor.continue(ActorState(..state, clock:))
    }
    RecordIdentity(session_id:, parent_session_id:, reply:) -> {
      let #(now, clock) = clock.read(state.clock)
      process.send(
        reply,
        do_record_identity(state, now, session_id, parent_session_id),
      )
      actor.continue(ActorState(..state, clock:))
    }
    ScanBranchPlan(order:, reply:) -> {
      process.send(reply, do_scan_branch_plan(state.conn, order))
      actor.continue(state)
    }
    Segments(reply:) -> {
      process.send(reply, do_segments(state.conn))
      actor.continue(state)
    }
    Close(reply:) -> {
      // Matching on this writer's own (owner, fence) pair means a stale
      // owner that lost the lease to a steal cannot delete its
      // replacement's row on the way out (module doc: close is scoped to
      // the writer's own pair).
      let released =
        run(
          state.conn,
          "DELETE FROM writer_lease WHERE owner_id = ?1 AND fence = ?2",
          [sqlight.text(state.owner), sqlight.int(state.fence)],
          decode.dynamic,
        )
      let closed = sqlight.close(state.conn)
      let outcome = case released, closed {
        Ok(_), Ok(Nil) -> Ok(Nil)
        Error(fail), _ -> Error(fail_to_storage_error(fail))
        _, Error(error) ->
          Error(BackendFault(
            reason: "sqlite close: " <> describe_sqlight(error),
          ))
      }
      process.send(reply, outcome)
      actor.continue(ActorState(..state, closed: True))
    }
  }
}

// --- commit --------------------------------------------------------------

type Session {
  Session(next_seq: Seq, message_count: Int, usage_total: json.JsonValue)
}

fn do_commit(
  state: ActorState,
  tx: Tx,
  now: Int,
) -> Result(CommitResult, CommitError) {
  let applied = {
    use Nil <- result.try(begin_immediate(state.conn))
    let body = {
      // Lease first: a fenced-out writer must apply nothing.
      use Nil <- result.try(check_and_renew_lease(state, now))
      use session <- result.try(read_session(state.conn))

      // Rule 4: evaluate every CAS expectation against the
      // pre-transaction register state before applying any write.
      use Nil <- result.try(check_expectations(state.conn, tx.expected))
      use #(session, reversed_seqs) <- result.try(
        list.try_fold(
          over: tx.writes,
          from: #(session, []),
          with: fn(step, write) { apply_write(state.conn, step, write, now) },
        ),
      )
      use Nil <- result.try(write_session(state.conn, session))
      use Nil <- result.map(commit_sql(state.conn))
      CommitResult(
        first_seq: session.next_seq - list.length(tx.writes),
        seqs: list.reverse(reversed_seqs),
        ts: now,
      )
    }
    case body {
      Ok(commit_result) -> Ok(commit_result)
      Error(fail) -> {
        let _ = rollback(state.conn)
        Error(fail)
      }
    }
  }
  result.map_error(applied, fail_to_commit_error)
}

fn fail_to_commit_error(fail: Fail) -> CommitError {
  case fail {
    FailSql(error) -> Faulted(reason: "sqlite: " <> describe_sqlight(error))
    FailCorrupt(report) -> Corruption(report:)
    FailStale(failed) -> StaleExpectation(failed:)

    // The one commit failure with its own remedy: this process is not
    // the writer any more, so no reload and no retry can help
    // (`protocol-change/005`).
    FailLease(held_by:) -> LeaseLost(held_by:)
    FailUnknownEntry(id) ->
      Faulted(reason: "unknown entry " <> ids.entry_id_to_string(id))
  }
}

fn check_and_renew_lease(state: ActorState, now: Int) -> Result(Nil, Fail) {
  let lease_decoder = {
    use owner <- decode.field(0, decode.string)
    use fence <- decode.field(1, decode.int)
    decode.success(#(owner, fence))
  }
  use rows <- result.try(run(
    state.conn,
    "SELECT owner_id, fence FROM writer_lease",
    [],
    lease_decoder,
  ))
  case rows {
    [#(owner, fence)] if owner == state.owner && fence == state.fence ->
      run(
        state.conn,
        "UPDATE writer_lease SET expires_at_ms = ?1
         WHERE owner_id = ?2 AND fence = ?3",
        [
          sqlight.int(now + state.lease_ttl_ms),
          sqlight.text(state.owner),
          sqlight.int(state.fence),
        ],
        decode.dynamic,
      )
      |> result.replace(Nil)

    // Someone else's claim is in the table: the lease was stolen after
    // it expired, and this writer is fenced out.
    [#(owner, _), ..] -> Error(FailLease(held_by: Some(owner)))

    // No claim at all — a precise rewrite clears the table so the
    // swapped-in file starts unleased. Same conclusion, no owner to
    // name.
    [] -> Error(FailLease(held_by: None))
  }
}

fn read_session(conn: Connection) -> Result(Session, Fail) {
  let session_decoder = {
    use next_seq <- decode.field(0, decode.int)
    use message_count <- decode.field(1, decode.int)
    use usage_blob <- decode.field(2, decode.bit_array)
    decode.success(#(next_seq, message_count, usage_blob))
  }
  use rows <- result.try(run(
    conn,
    "SELECT next_seq, message_count, usage_payload FROM session",
    [],
    session_decoder,
  ))
  case rows {
    [#(next_seq, message_count, usage_blob)] -> {
      use usage_total <- result.map(
        json_of_blob(usage_blob, "session.usage_payload")
        |> result.map_error(FailCorrupt),
      )
      Session(next_seq:, message_count:, usage_total:)
    }
    [] | [_, ..] ->
      Error(
        FailCorrupt(report: corruption.report(
          at: "storage/sqlite.commit",
          on: "session catalog",
          expected: "exactly one session row",
          context: int.to_string(list.length(rows)) <> " rows",
        )),
      )
  }
}

fn write_session(conn: Connection, session: Session) -> Result(Nil, Fail) {
  run(
    conn,
    "UPDATE session SET next_seq = ?1, message_count = ?2, usage_payload = ?3",
    [
      sqlight.int(session.next_seq),
      sqlight.int(session.message_count),
      blob_of_json(session.usage_total),
    ],
    decode.dynamic,
  )
  |> result.replace(Nil)
}

fn check_expectations(
  conn: Connection,
  expected: List(SeqExpectation),
) -> Result(Nil, Fail) {
  list.try_fold(over: expected, from: Nil, with: fn(_, expectation) {
    let Expect(ns:, key:, seq:) = expectation
    use rows <- result.try(run(
      conn,
      "SELECT seq FROM registers WHERE ns = ?1 AND key = ?2",
      [sqlight.text(register.ns_to_string(ns)), sqlight.text(key)],
      decode.at([0], decode.int),
    ))
    case rows, seq {
      [], None -> Ok(Nil)
      [current], Some(expected_seq) if current == expected_seq -> Ok(Nil)
      _, _ -> Error(FailStale(failed: expectation))
    }
  })
}

// Every write — including a register delete — consumes the next seq
// before it is dispatched, so seqs stay strictly increasing across a
// transaction's writes in write order even though only some write kinds
// touch `entries` (storage rule: seqs increase strictly, gaps legal).
fn apply_write(
  conn: Connection,
  step: #(Session, List(Seq)),
  write: tx.Write,
  ts: Int,
) -> Result(#(Session, List(Seq)), Fail) {
  let #(session, seqs) = step
  let seq = session.next_seq
  let session = Session(..session, next_seq: seq + 1)
  use session <- result.map(case write {
    InsertEntry(entry:) -> insert_entry(conn, session, entry, seq, ts)
    InsertUsage(row:) -> insert_usage(conn, session, row, seq)
    SetRegister(ns:, key:, value:) -> {
      use _ <- result.map(run(
        conn,
        "INSERT INTO registers(ns, key, seq, value) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(ns, key) DO UPDATE
         SET seq = excluded.seq, value = excluded.value",
        [
          sqlight.text(register.ns_to_string(ns)),
          sqlight.text(key),
          sqlight.int(seq),
          blob_of_json(codec.encode_register_value(value)),
        ],
        decode.dynamic,
      ))
      session
    }
    DeleteRegister(ns:, key:) -> {
      // Deleting an absent cell is a no-op by SQL semantics.
      use _ <- result.map(run(
        conn,
        "DELETE FROM registers WHERE ns = ?1 AND key = ?2",
        [sqlight.text(register.ns_to_string(ns)), sqlight.text(key)],
        decode.dynamic,
      ))
      session
    }
  })
  #(session, [seq, ..seqs])
}

fn insert_entry(
  conn: Connection,
  session: Session,
  entry: Entry,
  seq: Seq,
  ts: Int,
) -> Result(Session, Fail) {
  let id_text = ids.entry_id_to_string(entry.id)
  use Nil <- result.try(check_fresh_id(conn, id_text))
  use Nil <- result.try(case entry.parent {
    Some(parent) -> {
      let parent_text = ids.entry_id_to_string(parent)
      use rows <- result.try(run(
        conn,
        "SELECT 1 FROM entries WHERE id = ?1",
        [sqlight.text(parent_text)],
        decode.at([0], decode.int),
      ))
      case rows {
        [_, ..] -> Ok(Nil)
        [] ->
          Error(
            FailCorrupt(report: corruption.report(
              at: "storage/sqlite.commit",
              on: id_text,
              expected: "an existing parent entry",
              context: "parent " <> parent_text <> " absent",
            )),
          )
      }
    }
    None -> Ok(Nil)
  })
  let stamped = storage.stamp(entry, seq:, ts:)
  let kind = storage.kind_of(stamped)
  use _ <- result.try(run(
    conn,
    "INSERT INTO entries(id, parent_id, seq, type, custom_type, ts, payload)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    [
      sqlight.text(id_text),
      sqlight.nullable(
        sqlight.text,
        option.map(entry.parent, ids.entry_id_to_string),
      ),
      sqlight.int(seq),
      sqlight.text(storage.kind_to_string(kind)),
      sqlight.nullable(sqlight.text, custom_type_of(stamped)),
      sqlight.int(ts),
      blob_of_json(codec.encode_entry(stamped)),
    ],
    decode.dynamic,
  ))
  use Nil <- result.map(index_entry(conn, stamped, seq))
  let message_count = case stamped {
    MessageEntry(..) -> session.message_count + 1
    CompactionEntry(..) | BranchSummaryEntry(..) | CustomEntry(..) ->
      session.message_count
  }
  Session(..session, message_count:)
}

fn custom_type_of(entry: Entry) -> Option(String) {
  case entry {
    CustomEntry(custom_type:, ..) -> Some(custom_type)
    MessageEntry(..) | CompactionEntry(..) | BranchSummaryEntry(..) -> None
  }
}

fn insert_usage(
  conn: Connection,
  session: Session,
  row: UsageRow,
  seq: Seq,
) -> Result(Session, Fail) {
  let id_text = ids.usage_id_to_string(row.id)
  use Nil <- result.try(check_fresh_id(conn, id_text))
  use _ <- result.try(run(
    conn,
    "INSERT INTO usage_ledger(id, seq, entry_id, adjustment, usage, details)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    [
      sqlight.text(id_text),
      sqlight.int(seq),
      sqlight.nullable(
        sqlight.text,
        option.map(row.entry_id, ids.entry_id_to_string),
      ),
      sqlight.bool(row.adjustment),
      blob_of_json(codec.encode_usage(row.usage)),
      sqlight.nullable(fn(details) { blob_of_json(details) }, row.details),
    ],
    decode.dynamic,
  ))
  use total <- result.try(
    codec.decode_usage(session.usage_total) |> result.map_error(FailCorrupt),
  )
  let usage_total = codec.encode_usage(storage.add_usage(total, row.usage))
  Ok(Session(..session, usage_total:))
}

// Rule 2: entries and usage rows share one session-wide id namespace.
fn check_fresh_id(conn: Connection, id_text: String) -> Result(Nil, Fail) {
  use rows <- result.try(run(
    conn,
    "SELECT (SELECT COUNT(*) FROM entries WHERE id = ?1)
          + (SELECT COUNT(*) FROM usage_ledger WHERE id = ?1)",
    [sqlight.text(id_text)],
    decode.at([0], decode.int),
  ))
  case rows {
    [0] -> Ok(Nil)
    [_, ..] | [] ->
      Error(
        FailCorrupt(report: corruption.report(
          at: "storage/sqlite.commit",
          on: id_text,
          expected: "a fresh id (entries and usage share one namespace)",
          context: "id already written",
        )),
      )
  }
}

// --- branch index maintenance (pi §2.6) ----------------------------------
//
// `branch_entries` stores the rows physically present in one segment;
// `branch_meta` stores its tip and optional base `(branch_id, seq)`. A
// segment logically contains its own rows above `base_seq` plus the
// referenced base prefix through `base_seq`.
//
// The two mandatory correctness rules, transcribed from pi §2.6:
//
// 1. "The base branch must itself cover the leaf within its logical
//    range; merely containing the leaf in an ancestor is insufficient."
//    We satisfy this by construction: the covering segment is resolved
//    through a *physical* `branch_entries` row for the parent, which is
//    always inside that segment's own logical range, and the new
//    segment's base is that same resolved segment capped at the
//    compaction boundary its chain provably covers.
// 2. "The newest compaction search must traverse the base chain;
//    checking only the newest physical segment can miss it."
//    `newest_compaction` recurses through `branch_meta` bases with a
//    shrinking seq cap until a compaction row or the root is found.

fn index_entry(conn: Connection, entry: Entry, seq: Seq) -> Result(Nil, Fail) {
  let id_text = ids.entry_id_to_string(entry.id)
  let kind_text = storage.kind_to_string(storage.kind_of(entry))
  case entry.parent {
    // A root entry starts a fresh segment with no base.
    None -> index_root_entry(conn, id_text, seq, kind_text)
    Some(parent) ->
      index_child_entry(conn, entry, parent, id_text, seq, kind_text)
  }
}

// A root entry starts a fresh segment with no base.
fn index_root_entry(
  conn: Connection,
  id_text: String,
  seq: Seq,
  kind_text: String,
) -> Result(Nil, Fail) {
  let branch_id = "b" <> int.to_string(seq)
  use Nil <- result.try(insert_index_row(
    conn,
    branch_id,
    id_text,
    seq,
    kind_text,
  ))
  run(
    conn,
    "INSERT INTO branch_meta(branch_id, tip_entry_id, tip_seq,
       base_branch_id, base_seq) VALUES (?1, ?2, ?3, NULL, NULL)",
    [sqlight.text(branch_id), sqlight.text(id_text), sqlight.int(seq)],
    decode.dynamic,
  )
  |> result.replace(Nil)
}

// A non-root entry either extends its parent's segment (appending at the
// tip) or, when the parent is not a tip, starts a new segment that
// diverges from it (`diverge`).
fn index_child_entry(
  conn: Connection,
  entry: Entry,
  parent: EntryId,
  id_text: String,
  seq: Seq,
  kind_text: String,
) -> Result(Nil, Fail) {
  let parent_text = ids.entry_id_to_string(parent)
  use tips <- result.try(run(
    conn,
    "SELECT branch_id FROM branch_meta WHERE tip_entry_id = ?1",
    [sqlight.text(parent_text)],
    decode.at([0], decode.string),
  ))
  case tips {
    // Appending at a tip: one new row, move the tip.
    [branch_id] -> append_at_tip(conn, branch_id, id_text, seq, kind_text)

    // Diverging append: build a new segment covering the parent.
    [] -> diverge(conn, entry, parent_text, seq, id_text, kind_text)
    [_, ..] ->
      Error(
        FailCorrupt(report: corruption.report(
          at: "storage/sqlite.branch_index",
          on: parent_text,
          expected: "at most one branch tip per entry (ix_bm_tip)",
          context: "multiple branch_meta tips",
        )),
      )
  }
}

fn append_at_tip(
  conn: Connection,
  branch_id: String,
  id_text: String,
  seq: Seq,
  kind_text: String,
) -> Result(Nil, Fail) {
  use Nil <- result.try(insert_index_row(
    conn,
    branch_id,
    id_text,
    seq,
    kind_text,
  ))
  run(
    conn,
    "UPDATE branch_meta SET tip_entry_id = ?1, tip_seq = ?2
     WHERE branch_id = ?3",
    [sqlight.text(id_text), sqlight.int(seq), sqlight.text(branch_id)],
    decode.dynamic,
  )
  |> result.replace(Nil)
}

fn diverge(
  conn: Connection,
  entry: Entry,
  parent_text: String,
  seq: Seq,
  id_text: String,
  kind_text: String,
) -> Result(Nil, Fail) {
  // Resolve a segment that covers the parent. A physical row is always
  // within its segment's own logical range, which is what mandatory rule
  // 1 demands of anything used as a base (see the section comment).
  let cover_decoder = {
    use branch_id <- decode.field(0, decode.string)
    use entry_seq <- decode.field(1, decode.int)
    decode.success(#(branch_id, entry_seq))
  }
  use covers <- result.try(run(
    conn,
    "SELECT branch_id, entry_seq FROM branch_entries
     WHERE entry_id = ?1 ORDER BY branch_id LIMIT 1",
    [sqlight.text(parent_text)],
    cover_decoder,
  ))
  case covers {
    [] ->
      Error(
        FailCorrupt(report: corruption.report(
          at: "storage/sqlite.branch_index",
          on: parent_text,
          expected: "the parent to be present in the branch index",
          context: option.unwrap(
            option.map(entry.parent, ids.entry_id_to_string),
            or: "",
          )
            <> " has no branch_entries row",
        )),
      )
    [#(cover_id, parent_seq), ..] ->
      build_diverged_segment(
        conn,
        cover_id,
        parent_seq,
        seq,
        id_text,
        kind_text,
      )
  }
}

// Builds the new segment covering the parent: copies the post-compaction
// suffix of the chained path into a fresh branch (mandatory rule 2's
// result decides the floor and the new segment's base), then indexes the
// diverging entry at its tip.
fn build_diverged_segment(
  conn: Connection,
  cover_id: String,
  parent_seq: Seq,
  seq: Seq,
  id_text: String,
  kind_text: String,
) -> Result(Nil, Fail) {
  use windows <- result.try(chain_windows(conn, cover_id, parent_seq, [], []))

  // Mandatory rule 2: search for the newest compaction at or below
  // the parent through the complete segment chain, not just the
  // newest physical segment.
  use boundary <- result.try(newest_compaction(conn, windows))
  let branch_id = "b" <> int.to_string(seq)
  let floor = case boundary {
    Some(compaction_seq) -> compaction_seq
    None -> 0
  }

  // Copy only rows after the compaction through the parent; the
  // older prefix is reachable through the base link instead.
  use Nil <- result.try(copy_windows(conn, branch_id, windows, floor))
  use Nil <- result.try(insert_index_row(
    conn,
    branch_id,
    id_text,
    seq,
    kind_text,
  ))
  insert_diverged_meta(conn, branch_id, id_text, seq, cover_id, boundary)
}

fn insert_diverged_meta(
  conn: Connection,
  branch_id: String,
  id_text: String,
  seq: Seq,
  cover_id: String,
  boundary: Option(Seq),
) -> Result(Nil, Fail) {
  case boundary {
    Some(compaction_seq) ->
      run(
        conn,
        "INSERT INTO branch_meta(branch_id, tip_entry_id, tip_seq,
           base_branch_id, base_seq) VALUES (?1, ?2, ?3, ?4, ?5)",
        [
          sqlight.text(branch_id),
          sqlight.text(id_text),
          sqlight.int(seq),
          sqlight.text(cover_id),
          sqlight.int(compaction_seq),
        ],
        decode.dynamic,
      )
      |> result.replace(Nil)
    None ->
      run(
        conn,
        "INSERT INTO branch_meta(branch_id, tip_entry_id, tip_seq,
           base_branch_id, base_seq) VALUES (?1, ?2, ?3, NULL, NULL)",
        [sqlight.text(branch_id), sqlight.text(id_text), sqlight.int(seq)],
        decode.dynamic,
      )
      |> result.replace(Nil)
  }
}

fn insert_index_row(
  conn: Connection,
  branch_id: String,
  id_text: String,
  seq: Seq,
  kind_text: String,
) -> Result(Nil, Fail) {
  run(
    conn,
    "INSERT INTO branch_entries(branch_id, entry_id, entry_seq, entry_type)
     VALUES (?1, ?2, ?3, ?4)",
    [
      sqlight.text(branch_id),
      sqlight.text(id_text),
      sqlight.int(seq),
      sqlight.text(kind_text),
    ],
    decode.dynamic,
  )
  |> result.replace(Nil)
}

// The newest compaction on the chained path: the windows partition the
// path in descending seq order, so the first window holding a compaction
// holds the newest one at or below the original cap.
fn newest_compaction(
  conn: Connection,
  windows: List(Window),
) -> Result(Option(Seq), Fail) {
  case windows {
    [] -> Ok(None)
    [window, ..rest] -> {
      use own <- result.try(run(
        conn,
        "SELECT entry_seq FROM branch_entries
         WHERE branch_id = ?1 AND entry_type = 'compaction'
           AND entry_seq > ?2 AND entry_seq <= ?3
         ORDER BY entry_seq DESC LIMIT 1",
        [
          sqlight.text(window.branch_id),
          sqlight.int(window.lo),
          sqlight.int(window.hi),
        ],
        decode.at([0], decode.int),
      ))
      case own {
        [compaction_seq, ..] -> Ok(Some(compaction_seq))
        [] -> newest_compaction(conn, rest)
      }
    }
  }
}

// Copies the chained path's rows with floor < seq into `dest`, window by
// window.
fn copy_windows(
  conn: Connection,
  dest: String,
  windows: List(Window),
  floor: Seq,
) -> Result(Nil, Fail) {
  case windows {
    [] -> Ok(Nil)
    [window, ..rest] ->
      case window.hi <= floor {
        // Windows descend: everything from here down is at or below the
        // floor and stays reachable through the base link instead.
        True -> Ok(Nil)
        False -> {
          use _ <- result.try(run(
            conn,
            "INSERT INTO branch_entries(branch_id, entry_id, entry_seq, entry_type)
             SELECT ?1, entry_id, entry_seq, entry_type FROM branch_entries
             WHERE branch_id = ?2 AND entry_seq > ?3 AND entry_seq <= ?4",
            [
              sqlight.text(dest),
              sqlight.text(window.branch_id),
              sqlight.int(int.max(window.lo, floor)),
              sqlight.int(window.hi),
            ],
            decode.dynamic,
          ))
          copy_windows(conn, dest, rest, floor)
        }
      }
  }
}

fn base_of(
  conn: Connection,
  branch_id: String,
) -> Result(Option(#(String, Int)), Fail) {
  let base_decoder = {
    use base_id <- decode.field(0, decode.optional(decode.string))
    use base_seq <- decode.field(1, decode.optional(decode.int))
    decode.success(#(base_id, base_seq))
  }
  use rows <- result.try(run(
    conn,
    "SELECT base_branch_id, base_seq FROM branch_meta WHERE branch_id = ?1",
    [sqlight.text(branch_id)],
    base_decoder,
  ))
  case rows {
    [#(Some(base_id), Some(base_seq))] -> Ok(Some(#(base_id, base_seq)))
    [#(None, None)] -> Ok(None)
    [] | [_] | [_, ..] ->
      Error(
        FailCorrupt(report: corruption.report(
          at: "storage/sqlite.branch_index",
          on: branch_id,
          expected: "one branch_meta row with both or neither base fields",
          context: "inconsistent branch_meta",
        )),
      )
  }
}

// --- reads ---------------------------------------------------------------

fn do_get_entries(
  conn: Connection,
  entry_ids: List(EntryId),
) -> Result(Dict(EntryId, Entry), StorageError) {
  list.try_fold(over: entry_ids, from: dict.new(), with: fn(found, id) {
    let rows =
      run(
        conn,
        "SELECT payload FROM entries WHERE id = ?1",
        [sqlight.text(ids.entry_id_to_string(id))],
        decode.at([0], decode.bit_array),
      )
      |> result.map_error(fail_to_storage_error)
    use rows <- result.try(rows)
    case rows {
      [] -> Ok(found)
      [payload, ..] -> {
        use entry <- result.map(
          entry_of_blob(payload) |> result.map_error(CorruptRow),
        )
        dict.insert(found, id, entry)
      }
    }
  })
}

fn do_get_register(
  conn: Connection,
  ns: RegisterNs,
  key: String,
) -> Result(Option(Register), StorageError) {
  let cell_decoder = {
    use seq <- decode.field(0, decode.int)
    use value <- decode.field(1, decode.bit_array)
    decode.success(#(seq, value))
  }
  let rows =
    run(
      conn,
      "SELECT seq, value FROM registers WHERE ns = ?1 AND key = ?2",
      [sqlight.text(register.ns_to_string(ns)), sqlight.text(key)],
      cell_decoder,
    )
    |> result.map_error(fail_to_storage_error)
  use rows <- result.try(rows)
  case rows {
    [] -> Ok(None)
    [#(seq, blob), ..] -> {
      use value <- result.map(
        register_of_blob(blob) |> result.map_error(CorruptRow),
      )
      Some(Register(value:, seq:))
    }
  }
}

fn do_list_registers(
  conn: Connection,
  ns: RegisterNs,
  key_prefix: Option(String),
) -> Result(List(#(String, Register)), StorageError) {
  let cell_decoder = {
    use key <- decode.field(0, decode.string)
    use seq <- decode.field(1, decode.int)
    use value <- decode.field(2, decode.bit_array)
    decode.success(#(key, seq, value))
  }
  let ns_arg = sqlight.text(register.ns_to_string(ns))
  let rows =
    case key_prefix {
      Some(prefix) ->
        run(
          conn,
          "SELECT key, seq, value FROM registers
           WHERE ns = ?1 AND key LIKE ?2 ESCAPE '\\' ORDER BY key ASC",
          [ns_arg, sqlight.text(like_prefix_pattern(prefix))],
          cell_decoder,
        )
      None ->
        run(
          conn,
          "SELECT key, seq, value FROM registers WHERE ns = ?1 ORDER BY key ASC",
          [ns_arg],
          cell_decoder,
        )
    }
    |> result.map_error(fail_to_storage_error)
  use rows <- result.try(rows)
  list.try_map(rows, fn(row) {
    let #(key, seq, blob) = row
    use value <- result.map(
      register_of_blob(blob) |> result.map_error(CorruptRow),
    )
    #(key, Register(value:, seq:))
  })
}

// Escapes LIKE metacharacters so a register key prefix matches literally.
fn like_prefix_pattern(prefix: String) -> String {
  let escaped =
    prefix
    |> string.replace(each: "\\", with: "\\\\")
    |> string.replace(each: "%", with: "\\%")
    |> string.replace(each: "_", with: "\\_")
  escaped <> "%"
}

fn do_scan_entries(
  conn: Connection,
  q: EntryScan,
) -> Result(List(Entry), StorageError) {
  let #(clauses, arguments) =
    []
    |> add_clause(q.kind, fn(kind) {
      #("type = ?", sqlight.text(storage.kind_to_string(kind)))
    })
    |> add_clause(q.custom_type, fn(name) {
      #("custom_type = ?", sqlight.text(name))
    })
    |> add_clause(q.from_seq, fn(seq) { #("seq >= ?", sqlight.int(seq)) })
    |> add_clause(q.to_seq, fn(seq) { #("seq <= ?", sqlight.int(seq)) })
    |> finish_clauses
  let sql =
    "SELECT payload FROM entries"
    <> where_sql(clauses)
    <> " ORDER BY seq "
    <> direction_sql(q.order)
    <> limit_sql(q.limit)
  let rows =
    run(conn, sql, arguments, decode.at([0], decode.bit_array))
    |> result.map_error(fail_to_storage_error)
  use rows <- result.try(rows)
  list.try_map(rows, fn(blob) {
    entry_of_blob(blob) |> result.map_error(CorruptRow)
  })
}

fn do_scan_usage(
  conn: Connection,
  q: UsageScan,
) -> Result(List(UsageRow), StorageError) {
  let row_decoder = {
    use id <- decode.field(0, decode.string)
    use seq <- decode.field(1, decode.int)
    use entry_id <- decode.field(2, decode.optional(decode.string))
    use adjustment <- decode.field(3, decode.int)
    use usage <- decode.field(4, decode.bit_array)
    use details <- decode.field(5, decode.optional(decode.bit_array))
    decode.success(#(id, seq, entry_id, adjustment, usage, details))
  }
  let #(clauses, arguments) =
    []
    |> add_clause(q.from_seq, fn(seq) { #("seq >= ?", sqlight.int(seq)) })
    |> add_clause(q.to_seq, fn(seq) { #("seq <= ?", sqlight.int(seq)) })
    |> finish_clauses
  let sql =
    "SELECT id, seq, entry_id, adjustment, usage, details FROM usage_ledger"
    <> where_sql(clauses)
    <> " ORDER BY seq "
    <> direction_sql(q.order)
    <> limit_sql(q.limit)
  let rows =
    run(conn, sql, arguments, row_decoder)
    |> result.map_error(fail_to_storage_error)
  use rows <- result.try(rows)
  list.try_map(rows, fn(row) {
    usage_row_of_columns(row) |> result.map_error(CorruptRow)
  })
}

fn usage_row_of_columns(
  row: #(String, Int, Option(String), Int, BitArray, Option(BitArray)),
) -> Result(UsageRow, CorruptionReport) {
  let #(id_text, seq, entry_id_text, adjustment_int, usage_blob, details_blob) =
    row
  use id <- result.try(ids.parse_usage_id(id_text))
  use entry_id <- result.try(case entry_id_text {
    Some(text) -> result.map(ids.parse_entry_id(text), Some)
    None -> Ok(None)
  })
  use adjustment <- result.try(case adjustment_int {
    0 -> Ok(False)
    1 -> Ok(True)
    other ->
      Error(corruption.report(
        at: "storage/sqlite.scan_usage",
        on: id_text,
        expected: "adjustment 0 or 1",
        context: int.to_string(other),
      ))
  })
  use usage_json <- result.try(json_of_blob(usage_blob, id_text))
  use usage <- result.try(codec.decode_usage(usage_json))
  use details <- result.map(case details_blob {
    Some(blob) -> result.map(json_of_blob(blob, id_text), Some)
    None -> Ok(None)
  })
  UsageRow(id:, seq:, entry_id:, adjustment:, usage:, details:)
}

fn do_stats(conn: Connection) -> Result(SessionStats, StorageError) {
  let stats_decoder = {
    use message_count <- decode.field(0, decode.int)
    use usage_blob <- decode.field(1, decode.bit_array)
    decode.success(#(message_count, usage_blob))
  }
  let rows =
    run(
      conn,
      "SELECT message_count, usage_payload FROM session",
      [],
      stats_decoder,
    )
    |> result.map_error(fail_to_storage_error)
  use rows <- result.try(rows)
  case rows {
    [#(message_count, usage_blob)] -> {
      use usage_json <- result.try(
        json_of_blob(usage_blob, "session.usage_payload")
        |> result.map_error(CorruptRow),
      )
      use usage <- result.map(
        codec.decode_usage(usage_json) |> result.map_error(CorruptRow),
      )
      SessionStats(message_count:, usage:)
    }
    [] | [_, ..] ->
      Error(
        CorruptRow(report: corruption.report(
          at: "storage/sqlite.stats",
          on: "session catalog",
          expected: "exactly one session row",
          context: int.to_string(list.length(rows)) <> " rows",
        )),
      )
  }
}

fn do_renew_lease(state: ActorState, now: Int) -> Result(Nil, StorageError) {
  let renewed = {
    use Nil <- result.try(begin_immediate(state.conn))
    case check_and_renew_lease(state, now) {
      Ok(Nil) -> commit_sql(state.conn)
      Error(fail) -> {
        let _ = rollback(state.conn)
        Error(fail)
      }
    }
  }
  result.map_error(renewed, fail_to_storage_error)
}

// The catalog identity projection. Runs under the same
// `BEGIN IMMEDIATE` + lease check every other write takes: a handle that
// no longer owns the session must not stamp its idea of the identity
// onto the file. The register cells remain the truth either way, so a
// refusal here costs a repair on the next open and nothing else.
fn do_record_identity(
  state: ActorState,
  now: Int,
  session_id: String,
  parent_session_id: Option(String),
) -> Result(Nil, StorageError) {
  let recorded = {
    use Nil <- result.try(begin_immediate(state.conn))
    case write_identity(state.conn, session_id, parent_session_id, state, now) {
      Ok(Nil) -> commit_sql(state.conn)
      Error(fail) -> {
        let _ = rollback(state.conn)
        Error(fail)
      }
    }
  }
  result.map_error(recorded, fail_to_storage_error)
}

fn write_identity(
  conn: Connection,
  session_id: String,
  parent_session_id: Option(String),
  state: ActorState,
  now: Int,
) -> Result(Nil, Fail) {
  use Nil <- result.try(check_and_renew_lease(state, now))
  use rows <- result.try(run(
    conn,
    "SELECT metadata FROM session",
    [],
    decode.at([0], decode.optional(decode.bit_array)),
  ))
  use fields <- result.try(
    metadata_fields(list_head_or_none(rows))
    |> result.map_error(FailCorrupt),
  )
  let metadata =
    json.Object(list.key_set(
      fields,
      metadata_session_id_field,
      json.String(session_id),
    ))
  run(
    conn,
    "UPDATE session SET parent_session_id = ?1, metadata = ?2",
    [
      case parent_session_id {
        Some(parent) -> sqlight.text(parent)
        None -> sqlight.null()
      },
      blob_of_json(metadata),
    ],
    decode.dynamic,
  )
  |> result.replace(Nil)
}

// The catalog holds exactly one row; a file with none has nothing to
// project onto and reads as an absent metadata blob, which the UPDATE
// below then touches zero rows of.
fn list_head_or_none(rows: List(Option(BitArray))) -> Option(BitArray) {
  case rows {
    [metadata, ..] -> metadata
    [] -> None
  }
}

// --- branch scan ---------------------------------------------------------

// One segment window: rows with lo < seq <= hi belong to this segment on
// the scanned path.
type Window {
  Window(branch_id: String, lo: Seq, hi: Seq)
}

fn do_scan_branch(
  conn: Connection,
  q: BranchScan,
) -> Result(List(Entry), StorageError) {
  let outcome = {
    let start_text = ids.entry_id_to_string(q.start)
    use start_rows <- result.try(run(
      conn,
      "SELECT seq FROM entries WHERE id = ?1",
      [sqlight.text(start_text)],
      decode.at([0], decode.int),
    ))
    use start_seq <- result.try(case start_rows {
      [seq, ..] -> Ok(seq)
      [] -> Error(FailUnknownEntry(id: q.start))
    })
    use covers <- result.try(run(
      conn,
      "SELECT branch_id FROM branch_entries
       WHERE entry_id = ?1 ORDER BY branch_id LIMIT 1",
      [sqlight.text(start_text)],
      decode.at([0], decode.string),
    ))
    use cover_id <- result.try(case covers {
      [branch_id, ..] -> Ok(branch_id)
      [] ->
        Error(
          FailCorrupt(report: corruption.report(
            at: "storage/sqlite.scan_branch",
            on: start_text,
            expected: "the start entry to be present in the branch index",
            context: "no branch_entries row",
          )),
        )
    })
    use windows <- result.try(chain_windows(conn, cover_id, start_seq, [], []))

    // Resolve any stop to a seq boundary on the unfiltered path first
    // (the stop applies before the cursor), then clip the windows by
    // that boundary and the cursor so pages never fetch — or decode —
    // rows the pipeline would discard.
    use stop_bound <- result.try(resolve_stop(conn, windows, q))
    let clipped = clip_windows(windows, q.order, stop_bound, q.cursor)
    let ordered_windows = case q.order {
      // `windows` is built nearest-segment-first, which is descending
      // seq: exactly newest-first.
      NewestFirst -> clipped
      OldestFirst -> list.reverse(clipped)
    }
    use refined <- result.map(scan_windows(
      conn,
      ordered_windows,
      q,
      branch.new(q),
    ))
    branch.results(refined)
  }
  result.map_error(outcome, fail_to_storage_error)
}

// The seq of the entry the scan stops at, if any: the first row in scan
// order matching `stop_at_kind` or `stop_at_id`. Resolved via the index's
// denormalized `entry_type` (ix_be_type) and the `(branch_id, entry_id)`
// primary key, so no payload is touched.
fn resolve_stop(
  conn: Connection,
  windows: List(Window),
  q: BranchScan,
) -> Result(Option(Seq), Fail) {
  use kind_seq <- result.try(case q.stop_at_kind {
    Some(kind) -> {
      let ordered = case q.order {
        NewestFirst -> windows
        OldestFirst -> list.reverse(windows)
      }
      stop_kind_seq(conn, ordered, storage.kind_to_string(kind), q.order)
    }
    None -> Ok(None)
  })
  use id_seq <- result.try(case q.stop_at_id {
    Some(id) -> stop_id_seq(conn, windows, ids.entry_id_to_string(id))
    None -> Ok(None)
  })

  // The first stop in scan order wins: the largest matching seq when
  // scanning newest-first, the smallest when scanning oldest-first.
  case kind_seq, id_seq, q.order {
    None, None, _ -> Ok(None)
    Some(a), None, _ | None, Some(a), _ -> Ok(Some(a))
    Some(a), Some(b), NewestFirst -> Ok(Some(int.max(a, b)))
    Some(a), Some(b), OldestFirst -> Ok(Some(int.min(a, b)))
  }
}

fn stop_kind_seq(
  conn: Connection,
  ordered: List(Window),
  kind_text: String,
  order: ScanOrder,
) -> Result(Option(Seq), Fail) {
  case ordered {
    [] -> Ok(None)
    [window, ..rest] -> {
      let direction = case order {
        NewestFirst -> "DESC"
        OldestFirst -> "ASC"
      }
      use rows <- result.try(run(conn, "SELECT entry_seq FROM branch_entries
         WHERE branch_id = ?1 AND entry_type = ?2
           AND entry_seq > ?3 AND entry_seq <= ?4
         ORDER BY entry_seq " <> direction <> " LIMIT 1", [
        sqlight.text(window.branch_id),
        sqlight.text(kind_text),
        sqlight.int(window.lo),
        sqlight.int(window.hi),
      ], decode.at([0], decode.int)))
      case rows {
        [seq, ..] -> Ok(Some(seq))
        [] -> stop_kind_seq(conn, rest, kind_text, order)
      }
    }
  }
}

fn stop_id_seq(
  conn: Connection,
  windows: List(Window),
  id_text: String,
) -> Result(Option(Seq), Fail) {
  case windows {
    [] -> Ok(None)
    [window, ..rest] -> {
      use rows <- result.try(run(
        conn,
        "SELECT entry_seq FROM branch_entries
         WHERE branch_id = ?1 AND entry_id = ?2",
        [sqlight.text(window.branch_id), sqlight.text(id_text)],
        decode.at([0], decode.int),
      ))
      case rows {
        [seq, ..] if seq > window.lo && seq <= window.hi -> Ok(Some(seq))
        [_, ..] | [] -> stop_id_seq(conn, rest, id_text)
      }
    }
  }
}

// Clips windows so pages fetch only rows the pipeline can emit: rows on
// the stop side of the boundary and inside the cursor bound. The refine
// pipeline still applies both rules row-by-row; clipping is purely an
// I/O reduction.
fn clip_windows(
  windows: List(Window),
  order: ScanOrder,
  stop_bound: Option(Seq),
  cursor: Option(Seq),
) -> List(Window) {
  list.filter_map(windows, fn(window) {
    let #(lo, hi) = case order {
      // Newest-first keeps seq >= stop and seq < cursor.
      NewestFirst -> {
        let lo = case stop_bound {
          Some(stop) -> int.max(window.lo, stop - 1)
          None -> window.lo
        }
        let hi = case cursor {
          Some(bound) -> int.min(window.hi, bound - 1)
          None -> window.hi
        }
        #(lo, hi)
      }

      // Oldest-first keeps seq <= stop and seq > cursor.
      OldestFirst -> {
        let hi = case stop_bound {
          Some(stop) -> int.min(window.hi, stop)
          None -> window.hi
        }
        let lo = case cursor {
          Some(bound) -> int.max(window.lo, bound)
          None -> window.lo
        }
        #(lo, hi)
      }
    }
    case lo < hi {
      True -> Ok(Window(..window, lo:, hi:))
      False -> Error(Nil)
    }
  })
}

// The segment chain from the covering segment toward the root, as windows
// partitioning the path `(0, cap]` in descending seq order. A segment
// whose base boundary sits at or above the current cap contributes an
// empty window (skipped by consumers) and the cap flows through
// unchanged; a revisited branch id means the chain is cyclic, which is
// reported as corruption instead of looping forever.
fn chain_windows(
  conn: Connection,
  branch_id: String,
  cap: Seq,
  visited: List(String),
  accumulator: List(Window),
) -> Result(List(Window), Fail) {
  case list.contains(visited, branch_id) {
    True ->
      Error(
        FailCorrupt(report: corruption.report(
          at: "storage/sqlite.branch_index",
          on: branch_id,
          expected: "an acyclic base chain",
          context: "segment chain revisits " <> branch_id,
        )),
      )
    False -> {
      use base <- result.try(base_of(conn, branch_id))
      case base {
        None ->
          Ok(list.reverse([Window(branch_id:, lo: 0, hi: cap), ..accumulator]))
        Some(#(base_id, base_seq)) -> {
          let lo = int.min(base_seq, cap)
          chain_windows(conn, base_id, lo, [branch_id, ..visited], [
            Window(branch_id:, lo:, hi: cap),
            ..accumulator
          ])
        }
      }
    }
  }
}

fn scan_windows(
  conn: Connection,
  windows: List(Window),
  q: BranchScan,
  refined: branch.Refine,
) -> Result(branch.Refine, Fail) {
  case windows, refined.done {
    [], _ | _, True -> Ok(refined)
    [window, ..rest], False -> {
      use refined <- result.try(scan_window_pages(conn, window, q, refined))
      scan_windows(conn, rest, q, refined)
    }
  }
}

// The canonical segment page query. `CROSS JOIN` is load-bearing: it
// forces `branch_entries` to be the outer loop so the plan is a covering
// `ix_be_seq` search plus an `entries` primary-key probe, with no
// temporary sort. `scan_branch_plan` exposes the plan for CI assertions.
const segment_sql_desc = "SELECT e.payload
FROM branch_entries b CROSS JOIN entries e ON e.id = b.entry_id
WHERE b.branch_id = ?1 AND b.entry_seq > ?2 AND b.entry_seq <= ?3
ORDER BY b.entry_seq DESC LIMIT ?4"

const segment_sql_asc = "SELECT e.payload
FROM branch_entries b CROSS JOIN entries e ON e.id = b.entry_id
WHERE b.branch_id = ?1 AND b.entry_seq > ?2 AND b.entry_seq <= ?3
ORDER BY b.entry_seq ASC LIMIT ?4"

fn scan_window_pages(
  conn: Connection,
  window: Window,
  q: BranchScan,
  refined: branch.Refine,
) -> Result(branch.Refine, Fail) {
  // Without kind filters, the clipped windows contain only emittable
  // rows, so the page fetch never needs more than the remaining limit —
  // this is what keeps a recent-window scan from decoding whole pages.
  let fetch_cap = case q.kind, q.custom_type, q.limit {
    None, None, Some(limit) ->
      int.min(page_size, int.max(limit - refined.count, 0))
    _, _, _ -> page_size
  }
  case refined.done || window.lo >= window.hi || fetch_cap <= 0 {
    True -> Ok(refined)
    False -> {
      let sql = case q.order {
        NewestFirst -> segment_sql_desc
        OldestFirst -> segment_sql_asc
      }
      use blobs <- result.try(run(
        conn,
        sql,
        [
          sqlight.text(window.branch_id),
          sqlight.int(window.lo),
          sqlight.int(window.hi),
          sqlight.int(fetch_cap),
        ],
        decode.at([0], decode.bit_array),
      ))
      use entries <- result.try(
        list.try_map(blobs, fn(blob) {
          entry_of_blob(blob) |> result.map_error(FailCorrupt)
        }),
      )
      let refined = list.fold(over: entries, from: refined, with: branch.step)

      // The page came back under a `LIMIT fetch_cap`, so the only question
      // is whether it came back short — and a row at `fetch_cap - 1` settles
      // that without counting the page. `list.length` would walk every
      // decoded entry of every page to answer it, on the scan path.
      case list.drop(entries, fetch_cap - 1) {
        // Fewer rows than requested: the window is exhausted.
        [] -> Ok(refined)
        [_, ..] -> {
          let window = case q.order, list.last(entries) {
            NewestFirst, Ok(last) -> Window(..window, hi: last.seq - 1)
            OldestFirst, Ok(last) -> Window(..window, lo: last.seq)
            _, Error(Nil) -> Window(..window, hi: window.lo)
          }
          scan_window_pages(conn, window, q, refined)
        }
      }
    }
  }
}

fn do_scan_branch_plan(
  conn: Connection,
  order: ScanOrder,
) -> Result(List(String), StorageError) {
  let sql = case order {
    NewestFirst -> segment_sql_desc
    OldestFirst -> segment_sql_asc
  }
  run(
    conn,
    "EXPLAIN QUERY PLAN " <> sql,
    [sqlight.text("b1"), sqlight.int(0), sqlight.int(100), sqlight.int(50)],
    decode.at([3], decode.string),
  )
  |> result.map_error(fail_to_storage_error)
}

fn do_segments(conn: Connection) -> Result(List(Segment), StorageError) {
  let meta_decoder = {
    use branch_id <- decode.field(0, decode.string)
    use tip_entry_id <- decode.field(1, decode.string)
    use tip_seq <- decode.field(2, decode.int)
    use base_id <- decode.field(3, decode.optional(decode.string))
    use base_seq <- decode.field(4, decode.optional(decode.int))
    decode.success(#(branch_id, tip_entry_id, tip_seq, base_id, base_seq))
  }
  let rows =
    run(
      conn,
      "SELECT branch_id, tip_entry_id, tip_seq, base_branch_id, base_seq
       FROM branch_meta ORDER BY branch_id",
      [],
      meta_decoder,
    )
    |> result.map_error(fail_to_storage_error)
  use rows <- result.try(rows)
  list.try_map(rows, fn(row) {
    let #(branch_id, tip_entry_id, tip_seq, base_id, base_seq) = row
    case base_id, base_seq {
      Some(id), Some(seq) ->
        Ok(Segment(branch_id:, tip_entry_id:, tip_seq:, base: Some(#(id, seq))))
      None, None -> Ok(Segment(branch_id:, tip_entry_id:, tip_seq:, base: None))
      Some(_), None | None, Some(_) ->
        Error(
          CorruptRow(report: corruption.report(
            at: "storage/sqlite.segments",
            on: branch_id,
            expected: "both or neither base fields",
            context: "inconsistent branch_meta",
          )),
        )
    }
  })
}

// --- SQL plumbing --------------------------------------------------------

fn run(
  conn: Connection,
  sql: String,
  arguments: List(sqlight.Value),
  decoder: Decoder(row),
) -> Result(List(row), Fail) {
  sqlight.query(sql, on: conn, with: arguments, expecting: decoder)
  |> result.map_error(FailSql)
}

fn begin_immediate(conn: Connection) -> Result(Nil, Fail) {
  sqlight.exec("BEGIN IMMEDIATE", on: conn) |> result.map_error(FailSql)
}

fn commit_sql(conn: Connection) -> Result(Nil, Fail) {
  sqlight.exec("COMMIT", on: conn) |> result.map_error(FailSql)
}

fn rollback(conn: Connection) -> Result(Nil, Fail) {
  sqlight.exec("ROLLBACK", on: conn) |> result.map_error(FailSql)
}

fn fail_to_storage_error(fail: Fail) -> StorageError {
  case fail {
    FailSql(error) ->
      BackendFault(reason: "sqlite: " <> describe_sqlight(error))
    FailCorrupt(report) -> CorruptRow(report:)
    FailStale(_) -> BackendFault(reason: "unexpected stale expectation")
    FailLease(held_by:) -> BackendFault(reason: tx.describe_lease_loss(held_by))
    FailUnknownEntry(id) -> UnknownEntry(id:)
  }
}

fn describe_sqlight(error: sqlight.Error) -> String {
  let sqlight.SqlightError(code:, message:, offset: _) = error
  int.to_string(sqlight.error_code_to_int(code)) <> " " <> message
}

fn blob_of_json(value: JsonValue) -> sqlight.Value {
  sqlight.blob(bit_array.from_string(json.to_string(value)))
}

fn json_of_blob(
  blob: BitArray,
  subject: String,
) -> Result(JsonValue, CorruptionReport) {
  case bit_array.to_string(blob) {
    Ok(text) -> json.parse(text)
    Error(Nil) ->
      Error(corruption.report(
        at: "storage/sqlite.decode",
        on: subject,
        expected: "utf-8 json payload",
        context: "invalid utf-8",
      ))
  }
}

fn entry_of_blob(blob: BitArray) -> Result(Entry, CorruptionReport) {
  use value <- result.try(json_of_blob(blob, "entry payload"))
  codec.decode_entry(value)
}

fn register_of_blob(
  blob: BitArray,
) -> Result(register.RegisterValue, CorruptionReport) {
  use value <- result.try(json_of_blob(blob, "register payload"))
  codec.decode_register_value(value)
}

// --- dynamic WHERE clause assembly ---------------------------------------

fn add_clause(
  clauses: List(#(String, sqlight.Value)),
  value: Option(a),
  make: fn(a) -> #(String, sqlight.Value),
) -> List(#(String, sqlight.Value)) {
  case value {
    Some(inner) -> [make(inner), ..clauses]
    None -> clauses
  }
}

// Clauses are accumulated in reverse; restore write order so the plain
// `?` placeholders line up with the argument list positionally.
fn finish_clauses(
  clauses: List(#(String, sqlight.Value)),
) -> #(List(String), List(sqlight.Value)) {
  let ordered = list.reverse(clauses)
  #(
    list.map(ordered, fn(clause) { clause.0 }),
    list.map(ordered, fn(clause) { clause.1 }),
  )
}

fn where_sql(clauses: List(String)) -> String {
  case clauses {
    [] -> ""
    _ -> " WHERE " <> string.join(clauses, with: " AND ")
  }
}

fn direction_sql(order: ScanOrder) -> String {
  case order {
    NewestFirst -> "DESC"
    OldestFirst -> "ASC"
  }
}

// A non-positive limit must return no rows (the shared scan contract —
// see `storage.EntryScan`/`storage.UsageScan`). SQLite itself treats a
// negative LIMIT as "no limit at all", the opposite meaning, so clamp
// before it reaches the SQL text.
fn limit_sql(limit: Option(Int)) -> String {
  case limit {
    Some(n) if n > 0 -> " LIMIT " <> int.to_string(n)
    Some(_) -> " LIMIT 0"
    None -> ""
  }
}
