//// The full-text search service: a standalone SQLite FTS5 database
//// over a repository's sessions (spec WP-K; pi's search section).
////
//// Search is a standalone service with its own store. Sessions know
//// nothing about search; this module reads them through the ordinary
//// `Storage` scans and keeps its index plus a durable per-session
//// cursor (highest indexed entry seq) in one repository-wide SQLite
//// file — never inside a session file. The index is a rebuildable
//// projection with zero authority: indexing failures never affect
//// commits, and deleting the database only costs a re-sync.
////
//// **Indexing is pull-based; events are only hints.** `sync` reads
//// entries past the cursor and indexes them; a bus event (or any other
//// notification) should only prompt a `sync` call — it never carries
//// content. A lost hint is caught by the next sweep. The cursor is
//// *read* and advanced in the same `BEGIN IMMEDIATE` transaction as the
//// index rows: a crash mid-batch simply re-runs the batch into the same
//// state, and two concurrent syncs of the same session serialize on the
//// write lock instead of both reading the same stale cursor and both
//// inserting the same rows.
////
//// `sync_batch` is the bounded-entry alternative for shared coordinators. It
//// fetches outside the index transaction, then compares the captured cursor
//// under the write lock before publishing. A competing commit returns `Stale`;
//// scheduling another attempt belongs to the caller, not this database layer.
////
//// **Rewrite invalidation.** A precise rewrite swaps a session's store
//// and may renumber seqs, so the cursor is stored with the session's
//// store *generation*. `sync` compares the caller-supplied generation
//// with the stored one; on mismatch the session's index rows are
//// dropped and the session re-indexes from zero in the same
//// transaction.
////
//// **What a row records.** Besides the session and entry ids and the text,
//// each row stores the entry's `kind` (`user`, `assistant`, `tool`,
//// `summary`) and its commit time `ts`, both read from the entry at index
//// time. Queries filter on `kind` and page with `before`, an entry id whose
//// UUIDv7 text order is commit-time order. The schema version is kept in
//// `PRAGMA user_version`; `initialize` migrates an older file in place rather
//// than deleting it (see `migrate`).
////
//// **What is not indexed.** The notes index, and the digest a past release
//// attached, are committed to a session as user messages, and `index_row` skips them
//// (`is_memory_injection`): a copy of every note title in every session would
//// bury the real hits for a note's topic. This is not a schema change and the
//// version is not bumped. A session indexed before the rule still holds its old
//// injected rows, which are harmless noise until the session is re-synced, and
//// a re-sync of a session (a generation bump) drops its rows and rebuilds
//// them without the injections.
////
//// **Sessions are named by their canonical id.** `sync`, `notify`,
//// `remove` and `query_in_session` take a `core/ids.SessionId`
//// (`protocol-change/008`), with no caller-supplied-string form: this is
//// a *repository-wide* index, and a file-derived name is exactly the
//// thing that collides across repositories with nothing to notice it.
//// The stored `session_id` column and `Hit.session` hold that id's
//// canonical text; parse one back with `ids.parse_session_id` when the
//// typed value is wanted.
////
//// SQL: the named static statements live in `src/events/sql/search.sql`
//// and are compiled to `events/sql` by parrot (ADR-004 pilot;
//// regenerate with `scripts/gen-sql.sh`). Schema DDL and pragmas stay
//// hand-written below, mirrored byte-for-byte from `sql/schema.sql`
//// (a test pins the two together).
////
//// ## Flow
////
//// `open` → `initialize` → `migrate` → `sync` → `index_row` → `write_index` →
//// `query` → `match_text`
////
//// 1. `open` acquires the connection and calls `initialize`, which applies the
////    shared SQLite policy and then `migrate`.
//// 2. `migrate` reads `PRAGMA user_version` and, for an older file, rebuilds
////    the FTS table in place inside one transaction (`upgrade_entry_fts`).
//// 3. `sync` reads a session's entries past its cursor under the write lock
////    and turns each into a row with `index_row`, which extracts the text, the
////    kind and the commit time.
//// 4. `write_index` drops stale rows, inserts the new ones and advances the
////    cursor in that same transaction.
//// 5. `query` (and `query_in_session`, `query_authorized`) turns a `Query`
////    into a match expression with `match_text`, filters by kind and
////    the anchor, and returns ranked or newest-first `Hit`s.

import core/entry.{type Entry}
import core/ids.{type SessionId}
import core/json
import core/message.{type AgentMessage}
import events/sql
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/sqlite_policy
import storage/storage.{type Storage, type StorageError}

/// An open search service over one index database file.
///
/// Constructor invariants: `db` is an open connection. `open` initializes it;
/// owned callers use `acquire`, publish custody, then `initialize`. Queries
/// require initialization. Exactly the discipline SQLite always needs applies for
/// sharing the file between processes (WAL, busy timeout, idempotent
/// batches) — writers serialize.
pub opaque type Search {
  Search(db: sqlight.Connection)
}

/// Why a search operation failed.
pub type SearchError {
  /// The index database failed (open, SQL, or transaction error). The
  /// message is a human-readable description, not for dispatch. A
  /// syntactically invalid FTS5 query string also lands here.
  IndexFault(message: String)

  /// Reading the session being indexed failed; the index was left
  /// unchanged (the transaction never started or rolled back).
  SessionReadFault(error: StorageError)
}

/// One ranked search hit. Ids are the stored strings — callers join
/// entries and metadata through the repository they already hold, and
/// a hit may be stale (the entry deleted by a rewrite since indexing).
///
/// Constructor invariants: `session` and `entry` are the ids the entry
/// was indexed under; `kind` is `user`, `assistant`, `tool` or `summary`, or
/// empty for a row indexed before the column existed; `ts` is the entry's
/// commit time in milliseconds since the epoch, or 0 for the same legacy
/// rows; `snippet` is FTS5 `snippet()` output with `[`/`]` marking matched
/// terms.
pub type Hit {
  Hit(session: String, entry: String, kind: String, ts: Int, snippet: String)
}

/// How a query's text is read.
pub type Syntax {
  /// Whitespace-separated words, each quoted for FTS5 and ANDed. No input
  /// can be a syntax error: `foo-bar`, `a:b` and a stray quote are text.
  Words

  /// FTS5 query syntax passed through unchanged: bare words, quoted phrases,
  /// `AND`/`OR`/`NOT`, column filters. A malformed query is an `IndexFault`.
  Raw
}

/// One ranked full-text question, shared by every scope.
///
/// Constructor invariants: `limit` is positive and already bounded by the
/// caller, because SQLite reads a negative `LIMIT` as unbounded; `kind` is
/// matched exactly against the indexed kind, so an unknown kind matches
/// nothing; `before` is a canonical entry id, and only hits whose id text sorts
/// below it are returned. Entry ids are UUIDv7, so that order is commit-time
/// order across sessions and `before` is a keyset over history.
pub type Query {
  Query(
    text: String,
    syntax: Syntax,
    kind: Option(String),
    before: Option(String),
    limit: Int,
  )
}

/// Whether another bounded read may find more entries.
pub type Continuation {
  /// The batch filled its limit; an additional read establishes exhaustion.
  MorePossible

  /// The source returned fewer entries than requested at this read.
  CaughtUp
}

/// One bounded indexing attempt, with no internal retry.
pub type Batch {
  /// Rows and cursor committed together, including non-indexable entries.
  Advanced(
    /// Highest consumed source sequence number.
    high_water: Int,
    /// Entries read, not merely entries containing searchable text.
    scanned: Int,
    /// Whether another batch may be needed.
    continuation: Continuation,
  )

  /// Another writer changed the cursor after the source read was planned.
  Stale
}

/// Maximum entries fetched by one batch; this is not a byte or time bound.
pub const max_batch_entries = 512

/// A captured index cursor, not a held writer transaction.
@internal
pub opaque type BatchPlan {
  BatchPlan(
    session: String,
    generation: Int,
    expected: Option(sql.GetCursor),
    after: Int,
  )
}

/// Captures the optimistic publication fence before a separately owned read.
///
/// ## Examples
///
/// ```gleam
/// // search.plan_batch(index, session_id, generation)
/// ```
@internal
pub fn plan_batch(search: Search, session: SessionId, generation: Int) {
  let session = ids.session_id_to_string(session)
  use expected <- result.map(read_cursor(search, session))

  // Resume from the saved high-water mark if the generation still matches.
  let after = case expected {
    Some(sql.GetCursor(generation: stored, high_water:))
      if stored == generation
    -> high_water
    Some(_) | None -> 0
  }

  BatchPlan(session, generation, expected, after)
}

/// The first unseen entry has a sequence strictly greater than this value.
///
/// ## Examples
///
/// ```gleam
/// // search.batch_after(plan)
/// ```
@internal
pub fn batch_after(plan: BatchPlan) -> Int {
  plan.after
}

/// Commits separately fetched entries only if the captured cursor still matches.
/// Bounds entry count, not total decoded bytes; callers bound their source read.
/// Empty batches still invalidate rewritten source generations atomically.
///
/// ## Examples
///
/// ```gleam
/// // search.commit_batch(index, plan, entries, requested: 10)
/// ```
@internal
pub fn commit_batch(
  search: Search,
  plan: BatchPlan,
  entries: List(Entry),
  requested requested: Int,
) -> Result(Batch, SearchError) {
  use <- bool.guard(
    when: requested <= 0
      || requested > max_batch_entries
      || list.length(entries) > requested,
    return: Error(IndexFault("invalid search publication batch size")),
  )
  use high_water <- result.try(
    list.try_fold(entries, plan.after, fn(after, entry) {
      case entry.seq > after {
        True -> Ok(entry.seq)
        False ->
          Error(IndexFault("search batch must advance in sequence order"))
      }
    }),
  )

  // Invalidate previous rows if the source generation changed.
  let invalidate = case plan.expected {
    Some(sql.GetCursor(generation:, ..)) -> generation != plan.generation
    None -> True
  }

  let rows = list.filter_map(entries, index_row)
  let scanned = list.length(entries)

  // Signal whether more entries may remain based on requested batch limit.
  let continuation = case scanned == requested {
    True -> MorePossible
    False -> CaughtUp
  }

  // Source work has finished before acquiring the index writer reservation.
  use <- in_transaction(search)
  use current <- result.try(read_cursor(search, plan.session))
  use <- bool.guard(when: current != plan.expected, return: Ok(Stale))
  use Nil <- result.try(write_index(
    search,
    plan.session,
    plan.generation,
    invalidate,
    rows,
    high_water,
  ))
  Ok(Advanced(high_water:, scanned:, continuation:))
}

// The schema DDL, hand-written per ADR-004 (parrot covers named static
// queries; DDL and pragmas stay out of codegen). Must stay identical to
// `sql/schema.sql`, which the codegen script loads — the
// `schema_matches_source_test` pins the two together.
const create_entry_fts =
  "CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
  session_id UNINDEXED,
  entry_id UNINDEXED,
  kind UNINDEXED,
  ts UNINDEXED,
  text
);"

const create_search_cursor =
  "CREATE TABLE IF NOT EXISTS search_cursor (
  session_id TEXT NOT NULL PRIMARY KEY,
  generation INTEGER NOT NULL,
  high_water INTEGER NOT NULL
) WITHOUT ROWID;"

const create_search_source =
  "CREATE TABLE IF NOT EXISTS search_source (
  session_id TEXT NOT NULL PRIMARY KEY,
  path TEXT NOT NULL
) WITHOUT ROWID;"

/// The schema statements `open` ensures, in order. Exposed so the test
/// suite can pin them to `sql/schema.sql`.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(search.schema()) == 3
/// ```
///
pub fn schema() -> List(String) {
  [create_entry_fts, create_search_cursor, create_search_source]
}

/// Opens (creating if absent) the search database at `path` and ensures
/// its schema. One file per repository; `":memory:"` works for tests.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(search) = search.open(":memory:")
/// ```
///
pub fn open(path: String) -> Result(Search, SearchError) {
  use search <- result.try(acquire(path))

  // Ensure the database schema is initialized, closing the handle on failure.
  case initialize(search) {
    Ok(Nil) -> Ok(search)
    Error(error) -> {
      let _closed = close(search)
      Error(error)
    }
  }
}

/// Acquires the connection without schema or tuning effects.
/// An owned caller retains this handle before beginning initialization and
/// propagates close failure instead of treating it as confirmed retirement.
///
/// The path is refused here rather than by SQLite when it is one SQLite would
/// fail to open. The index is the database in this tree most likely to be
/// pointed at a path that is not there: it is a projection beside a session
/// file, it is safe to delete, and an operator repairing a corrupt index does
/// exactly that. A failed `sqlite3_open` frees a block through the binding's
/// double close, which `storage/sqlite_policy` documents, and corrupts
/// whichever connection is handed that block next, so the refusal has to come
/// first.
///
/// ## Examples
///
/// ```gleam
/// // search.acquire(path)
/// ```
@internal
pub fn acquire(path: String) -> Result(Search, SearchError) {
  use Nil <- result.try(
    sqlite_policy.refusing_unopenable_path(path)
    |> result.map_error(fn(reason) { IndexFault(message: reason) }),
  )
  sqlight.open(path)
  |> result.map(Search)
  |> result.map_error(index_fault)
}

/// Initializes an already retained connection; failure leaves custody intact.
/// Search has no conversation writer lease. Tuning uses the shared policy.
///
/// ## Examples
///
/// ```gleam
/// // search.initialize(acquired)
/// ```
@internal
pub fn initialize(search: Search) -> Result(Nil, SearchError) {
  let db = search.db
  let options = sqlite_policy.defaults()
  use Nil <- result.try(
    sqlite_policy.configure_connection(db, options)
    |> result.map_error(index_fault),
  )
  use Nil <- result.try(
    sqlite_policy.configure_database(db, options)
    |> result.map_error(index_fault),
  )
  migrate(search)
}

/// The schema version this build writes, kept in `PRAGMA user_version`. A file
/// that predates versioning reads 0; version 1 adds the `kind` and `ts`
/// columns to `entry_fts`.
const schema_version = 1

// An FTS5 table cannot be altered, so reaching the current version rebuilds
// `entry_fts` beside the old one and copies the rows across. The file is never
// deleted: the copied rows keep answering queries while their sessions are
// re-read, and a failed migration rolls back to the old table intact.
/// Runs pending migrations up to the current search schema version.
fn migrate(search: Search) -> Result(Nil, SearchError) {
  use version <- result.try(user_version(search))
  use <- bool.guard(when: version >= schema_version, return: Ok(Nil))
  use <- in_transaction(search)

  // The version is read again under the write lock. Two processes opening the
  // same old file would otherwise both rename the table, and the second would
  // copy rows out of the empty replacement the first had just created.
  use version <- result.try(user_version(search))
  use <- bool.guard(when: version >= schema_version, return: Ok(Nil))
  use Nil <- result.try(exec(search, create_search_cursor))
  use Nil <- result.try(exec(search, create_search_source))
  use legacy <- result.try(has_table(search, "entry_fts"))

  // Upgrade legacy unversioned FTS table or create fresh schema.
  use Nil <- result.try(case legacy {
    True -> upgrade_entry_fts(search)
    False -> exec(search, create_entry_fts)
  })

  exec(search, "PRAGMA user_version = " <> int.to_string(schema_version))
}

// Copies every row of the version-0 index into the current shape. A copied row
// has no kind and no time, because the index never recorded them. Forcing every
// cursor to a generation no store has (they count up from zero) makes the next
// sync of each session drop its rows and index them again with both columns, so
// a session heals as soon as it is read. Sessions that are never read again keep
// their copied rows, which a `kind` filter will not match.
/// Upgrades legacy entry_fts table to include kind and timestamp columns.
fn upgrade_entry_fts(search: Search) -> Result(Nil, SearchError) {
  use Nil <- result.try(exec(
    search,
    "ALTER TABLE entry_fts RENAME TO entry_fts_v0",
  ))
  use Nil <- result.try(exec(search, create_entry_fts))
  use Nil <- result.try(exec(
    search,
    "INSERT INTO entry_fts (session_id, entry_id, kind, ts, text)
SELECT session_id, entry_id, '', 0, text FROM entry_fts_v0 ORDER BY rowid",
  ))
  use Nil <- result.try(exec(search, "DROP TABLE entry_fts_v0"))
  exec(search, "UPDATE search_cursor SET generation = -1")
}

fn exec(search: Search, statement: String) -> Result(Nil, SearchError) {
  sqlight.exec(statement, on: search.db) |> result.map_error(index_fault)
}

/// Reads the SQLite user_version pragma from the database.
fn user_version(search: Search) -> Result(Int, SearchError) {
  sqlight.query(
    "PRAGMA user_version",
    on: search.db,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(index_fault)
  |> result.map(fn(rows) { result.unwrap(list.first(rows), 0) })
}

/// Checks whether a table exists in sqlite_master.
fn has_table(search: Search, name: String) -> Result(Bool, SearchError) {
  sqlight.query(
    "SELECT count(*) FROM sqlite_master WHERE name = ?1",
    on: search.db,
    with: [sqlight.text(name)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(index_fault)
  |> result.map(fn(rows) { result.unwrap(list.first(rows), 0) > 0 })
}

/// Registers a host-owned source path for exact reads by canonical identity.
///
/// This is a rebuildable locator, not an authority: readers must validate
/// the session identity in the source file before returning an entry.
///
/// ## Examples
///
/// ```gleam
/// // search.register_source(index, session, "/data/session.db")
/// ```
pub fn register_source(
  search: Search,
  session: SessionId,
  path: String,
) -> Result(Nil, SearchError) {
  run_statement(
    search,
    sql.register_source(ids.session_id_to_string(session), path),
  )
}

/// Resolves a source registered by the host, never a model-supplied path.
/// Old indexes gain locators as their sessions reopen.
///
/// ## Examples
///
/// ```gleam
/// // search.source(index, session) == Ok(Some("/data/session.db"))
/// ```
pub fn source(
  search: Search,
  session: SessionId,
) -> Result(Option(String), SearchError) {
  let #(statement, params, decoder) =
    sql.get_source(ids.session_id_to_string(session))
  sqlight.query(
    statement,
    on: search.db,
    with: list.map(params, param_to_sqlight),
    expecting: decoder,
  )
  |> result.map(fn(rows) {
    list.first(rows) |> result.map(fn(row) { row.path }) |> option.from_result
  })
  |> result.map_error(index_fault)
}

/// Closes the search database.
///
/// ## Examples
///
/// ```gleam
/// // search.close(search)
/// ```
///
pub fn close(search: Search) -> Result(Nil, SearchError) {
  sqlight.close(search.db)
  |> result.map_error(index_fault)
}

/// Pulls a session's entries past the stored cursor into the index —
/// the sync utility. Idempotent and crash-safe: the cursor is read,
/// index rows are written, and the advanced cursor is written, all
/// inside one transaction, so re-running after any failure — or racing
/// a concurrent sync of the same session — converges on the same state
/// rather than double-indexing. Run it at startup, on a schedule, and on
/// every notification hint.
///
/// `generation` is the session store's rewrite-generation counter,
/// bumped by the precise rewrite when it swaps the store: for SQLite
/// session files, read it with `storage/sqlite.generation(path:)`
/// (fresh files are generation 0); memory sessions have no rewrite, so
/// pass `0`. A mismatch with the stored cursor drops the session's
/// index rows and re-indexes from seq zero, because a rewrite may
/// renumber seqs.
///
/// ## Examples
///
/// ```gleam
/// // search.sync(search, store, session: id, generation: 0)
/// ```
///
pub fn sync(
  search: Search,
  store: Storage(handle),
  session session: SessionId,
  generation generation: Int,
) -> Result(Nil, SearchError) {
  let session_id = ids.session_id_to_string(session)

  // The cursor read decides what this call writes (how far back to
  // scan, whether to drop and re-index), so it must happen *inside* the
  // same `BEGIN IMMEDIATE` as the write, not before it. `BEGIN
  // IMMEDIATE` takes the write lock up front, so two concurrent syncs
  // serialize here: the second one's cursor read waits for the first's
  // commit and then sees the advanced high-water, rather than both
  // reading the same stale cursor and both inserting the same rows
  // (EV-sync-txn — was reproducible as five entries indexing as ten).
  in_transaction(search, fn() {
    use cursor <- result.try(read_cursor(search, session_id))

    // A missing cursor and a generation mismatch converge on the same
    // path: drop whatever rows the session may have and index from
    // zero.
    let #(stale, high_water) = case cursor {
      Some(sql.GetCursor(generation: stored, high_water:))
        if stored == generation
      -> #(False, high_water)
      Some(sql.GetCursor(..)) -> #(True, 0)
      None -> #(True, 0)
    }

    use entries <- result.try(
      storage.scan_entries(
        store,
        storage.entry_scan()
          |> storage.entry_seq_range(Some(high_water + 1), None)
          |> storage.entry_order(storage.OldestFirst),
      )
      |> result.map_error(SessionReadFault),
    )
    let new_high_water =
      list.fold(entries, high_water, fn(seen, entry) {
        int.max(seen, entry.seq)
      })
    let rows = list.filter_map(entries, index_row)

    // Nothing new, no invalidation, cursor already recorded: skip the
    // write entirely so hint-driven syncs on idle sessions stay cheap.
    // Now that the read happened under the lock, this is also what a
    // second racing sync converges on once the first commits.
    case stale, rows, new_high_water == high_water, cursor {
      False, [], True, Some(_) -> Ok(Nil)
      _, _, _, _ ->
        write_index(search, session_id, generation, stale, rows, new_high_water)
    }
  })
}

/// Reads and commits at most `limit` entries without holding the index writer
/// while waiting on the source. Limits outside `1..max_batch_entries` are refused
/// before any read. The caller owns scheduling, source deadlines, and a source
/// handle paired with its current rewrite generation. A full batch may require
/// a final empty read; `CaughtUp` says nothing about later source commits.
///
/// The optimistic cursor comparison prevents a delayed batch from overwriting
/// another writer's progress. `Stale` changes nothing and requests no retry on
/// its own. One oversized entry remains oversized: this API bounds entry count,
/// not decoded bytes, and the ordinary Storage read has no deadline argument.
///
/// ## Examples
///
/// ```gleam
/// // search.sync_batch(index, store, session: id, generation: 0, limit: 100)
/// ```
pub fn sync_batch(
  search: Search,
  store: Storage(handle),
  session session: SessionId,
  generation generation: Int,
  limit limit: Int,
) -> Result(Batch, SearchError) {
  use <- bool.guard(
    when: limit <= 0 || limit > max_batch_entries,
    return: Error(IndexFault("search batch limit must be between 1 and 512")),
  )
  use plan <- result.try(plan_batch(search, session, generation))

  // No index transaction spans this potentially slow source actor call.
  use entries <- result.try(
    storage.scan_entries(
      store,
      storage.entry_scan()
        |> storage.entry_seq_range(Some(plan.after + 1), None)
        |> storage.entry_order(storage.OldestFirst)
        |> storage.entry_limit(limit),
    )
    |> result.map_error(SessionReadFault),
  )
  commit_batch(search, plan, entries, requested: limit)
}

/// One entry as the index stores it. `kind` and `ts` are read from the entry at
/// index time, so a query filters and dates a hit without opening any session.
type Row {
  Row(entry_id: String, kind: String, ts: Int, text: String)
}

/// What an entry contributes to the index, or `Error(Nil)` for one that
/// indexes to nothing (its seq still advances the cursor).
fn index_row(entry: Entry) -> Result(Row, Nil) {
  let text = entry_text(entry)
  use <- bool.guard(when: text == "", return: Error(Nil))
  let kind = entry_kind(entry)

  // The harness commits the notes index, and a past release the digest, to
  // every session as a user message. Indexed, each session would hold a copy
  // of every note title and bury the real hits for a note's topic.
  use <- bool.guard(
    when: kind == "user" && is_memory_injection(text),
    return: Error(Nil),
  )
  Ok(Row(entry_id: ids.entry_id_to_string(entry.id), kind:, ts: entry.ts, text:))
}

// The kind a `history_search` caller filters on. A custom message and every
// custom entry but a note index no text, so their empty kind is never stored.
/// Returns the search filter kind string corresponding to an entry.
fn entry_kind(entry: Entry) -> String {
  case entry {
    entry.MessageEntry(message:, ..) ->
      case message {
        message.UserMessage(..) -> "user"
        message.AssistantMessage(..) -> "assistant"
        message.ToolResultMessage(..) -> "tool"
        message.CustomMessage(..) -> ""
      }
    entry.CompactionEntry(..) | entry.BranchSummaryEntry(..) -> "summary"
    entry.CustomEntry(custom_type:, ..) if custom_type == note_entry_type ->
      "note"
    entry.CustomEntry(..) -> ""
  }
}

/// How the digest a past release attached to a run begins, and its fence.
/// Sessions saved by that release still hold it. These mirror `session_view/composer.memory_attribution_lead` and `memory_fence`,
/// which this package cannot import; a test in `client` pins them equal.
pub const digest_attribution_lead =
  "Distilled memory from this repository's earlier "

/// The fence of the digest message. See `digest_attribution_lead`.
pub const digest_fence = "```loom-memory"

/// How the notes index the daemon attaches to a run begins, and its fence.
/// These mirror `composer.notes_attribution_lead` and `notes_fence`; a test in
/// `client` pins them equal.
pub const notes_attribution_lead = "Notes saved in this repository by earlier "

/// The fence of the notes index message. See `notes_attribution_lead`.
pub const notes_fence = "```loom-notes"

// Whether a user message's text is a memory context the harness injected: it
// begins with one injector's lead and carries that same injector's fence. The
// pairing is the one `composer.memory_context_lines` uses, so a lead with the
// other injector's fence is not an injection, and neither is a person's text
// that merely begins with a lead.
fn is_memory_injection(text: String) -> Bool {
  injected_by(text, digest_attribution_lead, digest_fence)
  || injected_by(text, notes_attribution_lead, notes_fence)
}

fn injected_by(text: String, lead: String, fence: String) -> Bool {
  string.starts_with(text, lead) && string.contains(text, fence <> "\n")
}

/// The custom entry type `remember` writes a note under. It is the one
/// custom entry the index reads: a note is text a model wrote deliberately,
/// through a capability-checked door, to be found again. Every other custom
/// entry stays out, including the distillate rows (`memory/fact`,
/// `memory/lesson`, `memory/preference`) an older store may still hold.
///
/// This is the same string as `tools/remember.note_type`, which this package
/// cannot import; a test in `client` pins the two equal.
pub const note_entry_type = "memory/note"

/// The write side of `sync`: drop the session's rows if the cursor was
/// stale, insert the freshly-scanned rows, and advance the cursor —
/// three writes inside the caller's transaction, in that order.
fn write_index(
  search: Search,
  session_id: String,
  generation: Int,
  stale: Bool,
  rows: List(Row),
  new_high_water: Int,
) -> Result(Nil, SearchError) {
  use Nil <- result.try(delete_if_stale(search, session_id, stale))
  use Nil <- result.try(
    list.try_fold(rows, Nil, fn(_nil, row) {
      insert_row(search, session_id, row)
    }),
  )
  run_statement(
    search,
    sql.set_cursor(
      session_id: session_id,
      generation: generation,
      high_water: new_high_water,
    ),
  )
}

// `False` is not "no-op eagerly" here: `run_statement` executes a real
// DELETE, so this stays a `case` rather than a `bool.guard` whose eager
// `return:` would fire the write unconditionally.
/// Deletes session index rows if the session state is marked stale.
fn delete_if_stale(
  search: Search,
  session_id: String,
  stale: Bool,
) -> Result(Nil, SearchError) {
  case stale {
    True -> run_statement(search, sql.delete_session_index(session_id))
    False -> Ok(Nil)
  }
}

/// Inserts one indexed entry row into the full-text search table.
fn insert_row(
  search: Search,
  session_id: String,
  row: Row,
) -> Result(Nil, SearchError) {
  run_statement(
    search,
    sql.insert_entry_text(
      session_id: session_id,
      entry_id: row.entry_id,
      kind: row.kind,
      ts: row.ts,
      text: row.text,
    ),
  )
}

/// The notification hint entry point: identical to `sync`, named for
/// the wiring. A notify never carries content — it is a poke that
/// triggers a pull of one session, and a lost poke is caught by the
/// next sweep. Debouncing (for search-as-you-type freshness) belongs in
/// the caller.
///
/// ## Examples
///
/// ```gleam
/// // bus event received -> search.notify(search, store, session: id, generation: g)
/// ```
///
pub fn notify(
  search: Search,
  store: Storage(handle),
  session session: SessionId,
  generation generation: Int,
) -> Result(Nil, SearchError) {
  sync(search, store, session:, generation:)
}

/// Removes a session's index rows and cursor — call alongside deleting
/// the session, or leave stale rows to the next sync reconciliation.
///
/// ## Examples
///
/// ```gleam
/// // search.remove(search, session: id)
/// ```
///
pub fn remove(
  search: Search,
  session session: SessionId,
) -> Result(Nil, SearchError) {
  let session_id = ids.session_id_to_string(session)
  in_transaction(search, fn() {
    use Nil <- result.try(run_statement(
      search,
      sql.delete_session_index(session_id),
    ))
    use Nil <- result.try(run_statement(search, sql.delete_cursor(session_id)))
    run_statement(search, sql.delete_source(session_id))
  })
}

/// A `Words` query with no kind or `before` filter, the common case.
///
/// ## Examples
///
/// ```gleam
/// assert search.words("auth", 10).syntax == search.Words
/// ```
///
pub fn words(text: String, limit: Int) -> Query {
  Query(text:, syntax: Words, kind: None, before: None, limit:)
}

/// The same query in FTS5 syntax, passed through unchanged.
///
/// ## Examples
///
/// ```gleam
/// assert search.raw("auth OR login", 10).syntax == search.Raw
/// ```
///
pub fn raw(text: String, limit: Int) -> Query {
  Query(text:, syntax: Raw, kind: None, before: None, limit:)
}

/// Runs a full-text query and returns hits ranked best-first (FTS5
/// `rank`). In `Words` syntax every input is valid text; in `Raw` syntax a
/// malformed query is an `IndexFault`, not a crash. `kind` and `before` narrow
/// the hits before `limit` is applied.
///
/// ## Examples
///
/// ```gleam
/// // search.query(search, search.Query("auth migration", search.Words, None, None, 10))
/// // -> Ok([Hit(session: "s1", entry: "018f...", kind: "user", ts: 1760000000000,
/// //            snippet: "the [auth] [migration]")])
/// ```
///
pub fn query(search: Search, query: Query) -> Result(List(Hit), SearchError) {
  let #(statement, params, decoder) =
    sql.search_entries(
      query: match_text(query),
      kind: option.unwrap(query.kind, ""),
      before: option.unwrap(query.before, ""),
      max_hits: query.limit,
    )
  run_hits(search, statement, params, decoder, fn(row) {
    let sql.SearchEntries(session_id:, entry_id:, kind:, ts:, snippet:) = row
    Hit(session: session_id, entry: entry_id, kind:, ts:, snippet:)
  })
}

/// The text FTS5 is asked to match. `Raw` is the caller's own syntax. `Words`
/// turns each whitespace-separated token into a quoted prefix term, so
/// punctuation is text and `deploy` also finds `deployment`; terms are ANDed,
/// and a bare `OR` between two words stays the OR operator. An `OR` at either
/// end, or next to another `OR`, has no word to join and is dropped.
///
/// ## Examples
///
/// ```gleam
/// assert search.match_text(search.Query("foo-bar x", search.Words, None, None, 5))
///   == "\"foo-bar\"* \"x\"*"
/// ```
///
pub fn match_text(query: Query) -> String {
  case query.syntax {
    Raw -> query.text
    Words ->
      query.text
      |> string.replace(each: "\n", with: " ")
      |> string.replace(each: "\r", with: " ")
      |> string.replace(each: "\t", with: " ")
      |> string.split(on: " ")
      |> list.filter(fn(token) { token != "" })
      |> joinable_ors
      |> list.map(fn(token) {
        case token {
          "OR" -> token
          _ -> "\"" <> string.replace(token, each: "\"", with: "\"\"") <> "\"*"
        }
      })
      |> string.join(" ")
      |> empty_matches_nothing
  }
}

// FTS5 refuses an empty expression, and a query of nothing but `OR` tokens
// reduces to one. An empty phrase is valid and matches no row.
fn empty_matches_nothing(expression: String) -> String {
  case expression {
    "" -> "\"\""
    _ -> expression
  }
}

// Leaves an `OR` only where a word stands on both sides of it.
/// Cleans up adjacent or leading/trailing OR query tokens.
fn joinable_ors(tokens: List(String)) -> List(String) {
  let trimmed =
    tokens
    |> list.drop_while(fn(token) { token == "OR" })
    |> list.reverse
    |> list.drop_while(fn(token) { token == "OR" })
    |> list.reverse
  list.fold(trimmed, [], fn(kept, token) {
    case token, kept {
      "OR", ["OR", ..] -> kept
      _, _ -> [token, ..kept]
    }
  })
  |> list.reverse
}

/// Executes a query statement and maps result rows into search hits.
fn run_hits(
  search: Search,
  statement: String,
  params: List(dev.Param),
  decoder: decode.Decoder(row),
  to_hit: fn(row) -> Hit,
) -> Result(List(Hit), SearchError) {
  sqlight.query(
    statement,
    on: search.db,
    with: list.map(params, param_to_sqlight),
    expecting: decoder,
  )
  |> result.map_error(index_fault)
  |> result.map(list.map(_, to_hit))
}

/// Returns hits only from the current authorized sessions, and spends the whole
/// limit on them: the filter is applied before `LIMIT`, so an unauthorized match
/// never consumes one of the caller's rows.
///
/// It is not applied before ranking. `session_id` is `UNINDEXED` in the FTS5
/// table, so SQLite filters rows the match has already produced and ordered by
/// rank. What authorization bounds is the result, not the work: a member of one
/// session issuing a common term still makes SQLite rank the match set of an
/// index that spans the workspace. Stale indexed rows never become authority
/// merely because a locator exists.
///
/// ## Examples
///
/// ```gleam
/// // search.query_authorized(index, [session_id], query)
/// ```
@internal
pub fn query_authorized(
  search: Search,
  sessions: List(SessionId),
  query: Query,
) -> Result(List(Hit), SearchError) {
  use <- bool.guard(
    when: query.limit < 1
      || query.limit > 50
      || list.length(list.take(sessions, 513)) > 512,
    return: Error(IndexFault("authorized search bounds exceeded")),
  )
  let sessions =
    sessions
    |> list.map(fn(id) { json.String(ids.session_id_to_string(id)) })
    |> json.Array
    |> json.to_string
  let #(statement, params, decoder) =
    sql.search_authorized_entries(
      query: match_text(query),
      sessions:,
      kind: option.unwrap(query.kind, ""),
      before: option.unwrap(query.before, ""),
      max_hits: query.limit,
    )
  run_hits(search, statement, params, decoder, fn(row) {
    Hit(row.session_id, row.entry_id, row.kind, row.ts, row.snippet)
  })
}

/// The searchable text of an entry, as indexed: user text, assistant
/// text, and tool-result text blocks of a message entry (thinking and
/// tool-call arguments are not indexed); compaction and branch-summary
/// text; for a `memory/note` entry its title, description and text, one
/// per line; nothing for any other custom entry. Blocks join with newlines;
/// an empty result means the entry is skipped (its seq still advances the
/// cursor).
///
/// ## Examples
///
/// ```gleam
/// // search.entry_text(message_entry) == "find the auth bug"
/// ```
///
pub fn entry_text(entry: Entry) -> String {
  case entry {
    entry.MessageEntry(message:, ..) -> message_text(message)
    entry.CompactionEntry(summary:, ..) -> summary
    entry.BranchSummaryEntry(summary:, ..) -> summary
    entry.CustomEntry(custom_type:, data:, ..)
      if custom_type == note_entry_type
    -> note_text(data)
    entry.CustomEntry(..) -> ""
  }
}

// A note's searchable words: the fields a typed note carries, in reading
// order. A note written before notes were typed has only `text`, and the
// absent fields contribute nothing.
/// Extracts concatenated search text from note JSON fields.
fn note_text(data: Option(json.JsonValue)) -> String {
  case data {
    Some(json.Object(fields)) ->
      ["title", "description", "text"]
      |> list.filter_map(fn(key) { non_empty_text(fields, key) })
      |> string.join("\n")
    Some(_other) | None -> ""
  }
}

/// Finds a non-empty string field in a JSON object field list.
fn non_empty_text(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(String, Nil) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) if text != "" -> Ok(text)
    Ok(_other) | Error(Nil) -> Error(Nil)
  }
}

/// Extracts concatenated searchable text from an agent message.
fn message_text(message: AgentMessage) -> String {
  case message {
    message.UserMessage(content:, ..) ->
      content |> list.filter_map(user_block_text) |> string.join("\n")
    message.AssistantMessage(content:, ..) ->
      content |> list.filter_map(assistant_block_text) |> string.join("\n")
    message.ToolResultMessage(content:, ..) ->
      content |> list.filter_map(tool_result_block_text) |> string.join("\n")
    message.CustomMessage(..) -> ""
  }
}

fn user_block_text(block: message.UserBlock) -> Result(String, Nil) {
  case block {
    message.UserText(text:, ..) -> Ok(text)
    message.UserImage(..) -> Error(Nil)
  }
}

fn assistant_block_text(block: message.AssistantBlock) -> Result(String, Nil) {
  case block {
    message.AssistantText(text:, ..) -> Ok(text)
    message.AssistantThinking(..) | message.AssistantToolCall(..) -> Error(Nil)
  }
}

/// Extracts indexed text from a tool result block if present.
fn tool_result_block_text(
  block: message.ToolResultBlock,
) -> Result(String, Nil) {
  case block {
    message.ToolResultText(text:, ..) -> Ok(text)
    message.ToolResultImage(..) -> Error(Nil)
  }
}

/// Runs a full-text query scoped to one session — the same ranking and
/// the same FTS5 syntax as `query`, filtered to the rows indexed under
/// `session`. Scoping happens in SQL rather than over the results, so
/// `limit` counts hits *in this session* instead of hits anywhere that
/// happen to belong to it.
///
/// ## Examples
///
/// ```gleam
/// // search.query_in_session(search, session: id, query: query)
/// ```
///
pub fn query_in_session(
  search: Search,
  session session: SessionId,
  query query: Query,
) -> Result(List(Hit), SearchError) {
  let #(statement, params, decoder) =
    sql.search_entries_in_session(
      query: match_text(query),
      session: ids.session_id_to_string(session),
      kind: option.unwrap(query.kind, ""),
      before: option.unwrap(query.before, ""),
      max_hits: query.limit,
    )
  run_hits(search, statement, params, decoder, fn(row) {
    let sql.SearchEntriesInSession(session_id:, entry_id:, kind:, ts:, snippet:) =
      row
    Hit(session: session_id, entry: entry_id, kind:, ts:, snippet:)
  })
}

/// The newest entries one session has indexed, newest first, with no
/// query at all: how a session browses its own recent history.
///
/// FTS5 assigns rowids in insertion order and `sync` inserts a session's
/// entries in log order, so the highest rowids are its latest entries; a
/// resync after a generation change deletes and reinserts them in the same
/// order. With no `MATCH` there is nothing for `snippet()` to anchor on, so
/// each hit's excerpt is the opening of its indexed text and carries no
/// `[`/`]` markers.
///
/// ## Examples
///
/// ```gleam
/// // search.recent_in_session(search, session: id, limit: 10)
/// ```
///
pub fn recent_in_session(
  search: Search,
  session session: SessionId,
  limit limit: Int,
) -> Result(List(Hit), SearchError) {
  let #(statement, params, decoder) =
    sql.recent_entries_in_session(
      session_id: ids.session_id_to_string(session),
      limit:,
    )
  sqlight.query(
    statement,
    on: search.db,
    with: list.map(params, param_to_sqlight),
    expecting: decoder,
  )
  |> result.map_error(index_fault)
  |> result.map(
    list.map(_, fn(row) {
      let sql.RecentEntriesInSession(
        session_id:,
        entry_id:,
        kind:,
        ts:,
        snippet:,
      ) = row
      Hit(session: session_id, entry: entry_id, kind:, ts:, snippet:)
    }),
  )
}

// --- the parrot bridge -----------------------------------------------------

/// The documented ten-line parrot-to-sqlight parameter bridge (ADR-004):
/// parrot is driver-agnostic and hands back `parrot/dev.Param` values;
/// sqlight wants its own `Value`. The temporal, list, and dynamic
/// variants never occur in this package's generated queries (they are
/// all TEXT/INTEGER-typed) and bind as SQL NULL if they ever appear —
/// a wrong-parameter bug surfaces as a failed query, not a crash.
fn param_to_sqlight(param: dev.Param) -> sqlight.Value {
  case param {
    dev.ParamInt(value) -> sqlight.int(value)
    dev.ParamString(value) -> sqlight.text(value)
    dev.ParamFloat(value) -> sqlight.float(value)
    dev.ParamBool(value) -> sqlight.bool(value)
    dev.ParamBitArray(value) -> sqlight.blob(value)
    dev.ParamNullable(Some(inner)) -> param_to_sqlight(inner)
    dev.ParamNullable(None) -> sqlight.null()
    dev.ParamTimestamp(_) | dev.ParamDate(_) -> sqlight.null()
    dev.ParamList(_) | dev.ParamDynamic(_) -> sqlight.null()
  }
}

// --- internals -------------------------------------------------------------

fn index_fault(error: sqlight.Error) -> SearchError {
  let sqlight.SqlightError(message:, ..) = error
  IndexFault(message:)
}

/// Reads the stored search cursor for a session if one exists.
fn read_cursor(
  search: Search,
  session_id: String,
) -> Result(Option(sql.GetCursor), SearchError) {
  let #(statement, params, decoder) = sql.get_cursor(session_id)
  sqlight.query(
    statement,
    on: search.db,
    with: list.map(params, param_to_sqlight),
    expecting: decoder,
  )
  |> result.map_error(index_fault)
  |> result.map(list.first)
  |> result.map(option.from_result)
}

/// Runs one generated parameterized statement that returns no rows.
fn run_statement(
  search: Search,
  statement: #(String, List(dev.Param)),
) -> Result(Nil, SearchError) {
  let #(text, params) = statement
  sqlight.query(
    text,
    on: search.db,
    with: list.map(params, param_to_sqlight),
    expecting: decode.success(Nil),
  )
  |> result.map_error(index_fault)
  |> result.replace(Nil)
}

/// Runs `body` inside `BEGIN IMMEDIATE .. COMMIT`, rolling back on any
/// error. The transaction is what makes sync batches idempotent: rows
/// and cursor land together or not at all.
fn in_transaction(
  search: Search,
  body: fn() -> Result(value, SearchError),
) -> Result(value, SearchError) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", on: search.db)
    |> result.map_error(index_fault),
  )

  // Commit transaction on success or rollback on failure.
  case body() {
    Ok(value) ->
      sqlight.exec("COMMIT", on: search.db)
      |> result.map_error(index_fault)
      |> result.replace(value)
    Error(error) -> {
      // Best-effort rollback; the original error is the one reported.
      let _ = sqlight.exec("ROLLBACK", on: search.db)
      Error(error)
    }
  }
}
