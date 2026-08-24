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
//// content. A lost hint is caught by the next sweep. The cursor
//// advances in the same database transaction as the index rows, so a
//// crash mid-batch simply re-runs the batch into the same state.
////
//// **Rewrite invalidation.** A precise rewrite swaps a session's store
//// and may renumber seqs, so the cursor is stored with the session's
//// store *generation*. `sync` compares the caller-supplied generation
//// with the stored one; on mismatch the session's index rows are
//// dropped and the session re-indexes from zero in the same
//// transaction.
////
//// SQL: the named static statements live in `src/events/sql/search.sql`
//// and are compiled to `events/sql` by parrot (ADR-004 pilot;
//// regenerate with `scripts/gen-sql.sh`). Schema DDL and pragmas stay
//// hand-written below, mirrored byte-for-byte from `sql/schema.sql`
//// (a test pins the two together).

import core/entry.{type Entry}
import core/ids
import core/message.{type AgentMessage}
import events/sql
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/storage.{type Storage, type StorageError}

/// An open search service over one index database file.
///
/// Constructor invariants: `db` is an open connection whose schema has
/// been ensured; exactly the discipline SQLite always needs applies for
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
/// was indexed under; `snippet` is FTS5 `snippet()` output with `[`/`]`
/// marking matched terms.
pub type Hit {
  Hit(session: String, entry: String, snippet: String)
}

// The schema DDL, hand-written per ADR-004 (parrot covers named static
// queries; DDL and pragmas stay out of codegen). Must stay identical to
// `sql/schema.sql`, which the codegen script loads — the
// `schema_matches_source_test` pins the two together.
const create_entry_fts = "CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
  session_id UNINDEXED,
  entry_id UNINDEXED,
  text
);"

const create_search_cursor = "CREATE TABLE IF NOT EXISTS search_cursor (
  session_id TEXT NOT NULL PRIMARY KEY,
  generation INTEGER NOT NULL,
  high_water INTEGER NOT NULL
) WITHOUT ROWID;"

/// The schema statements `open` ensures, in order. Exposed so the test
/// suite can pin them to `sql/schema.sql`.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(search.schema()) == 2
/// ```
///
pub fn schema() -> List(String) {
  [create_entry_fts, create_search_cursor]
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
  use db <- result.try(
    sqlight.open(path)
    |> result.map_error(index_fault),
  )
  // Pragmas return a result row each, so run them as queries and
  // discard the rows (same discipline as storage/sqlite).
  use _ <- result.try(
    sqlight.query("PRAGMA busy_timeout = 5000", on: db, with: [], expecting: {
      decode.success(Nil)
    })
    |> result.map_error(index_fault),
  )
  use _ <- result.try(
    sqlight.query("PRAGMA journal_mode = WAL", on: db, with: [], expecting: {
      decode.success(Nil)
    })
    |> result.map_error(index_fault),
  )
  use Nil <- result.try(
    sqlight.exec(create_entry_fts, on: db)
    |> result.map_error(index_fault),
  )
  use Nil <- result.try(
    sqlight.exec(create_search_cursor, on: db)
    |> result.map_error(index_fault),
  )
  Ok(Search(db:))
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
/// the sync utility. Idempotent and crash-safe: index rows and the
/// advanced cursor commit in one transaction, so re-running after any
/// failure converges on the same state. Run it at startup, on a
/// schedule, and on every notification hint.
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
/// // search.sync(search, store, session: "session-1", generation: 0)
/// ```
///
pub fn sync(
  search: Search,
  store: Storage(handle),
  session session_id: String,
  generation generation: Int,
) -> Result(Nil, SearchError) {
  use cursor <- result.try(read_cursor(search, session_id))
  // A missing cursor and a generation mismatch converge on the same
  // path: drop whatever rows the session may have and index from zero.
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
    list.fold(entries, high_water, fn(seen, entry) { int.max(seen, entry.seq) })
  let rows =
    list.filter_map(entries, fn(entry) {
      let text = entry_text(entry)
      case text {
        "" -> Error(Nil)
        _ -> Ok(#(ids.entry_id_to_string(entry.id), text))
      }
    })
  // Nothing new, no invalidation, cursor already recorded: skip the
  // write entirely so hint-driven syncs on idle sessions stay cheap.
  case stale, rows, new_high_water == high_water, cursor {
    False, [], True, Some(_) -> Ok(Nil)
    _, _, _, _ ->
      in_transaction(search, fn() {
        use Nil <- result.try(case stale {
          True -> run_statement(search, sql.delete_session_index(session_id))
          False -> Ok(Nil)
        })
        use Nil <- result.try(
          list.try_fold(rows, Nil, fn(_nil, row) {
            let #(entry_id, text) = row
            run_statement(
              search,
              sql.insert_entry_text(
                session_id: session_id,
                entry_id: entry_id,
                text: text,
              ),
            )
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
      })
  }
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
  session session_id: String,
  generation generation: Int,
) -> Result(Nil, SearchError) {
  sync(search, store, session: session_id, generation: generation)
}

/// Removes a session's index rows and cursor — call alongside deleting
/// the session, or leave stale rows to the next sync reconciliation.
///
/// ## Examples
///
/// ```gleam
/// // search.remove(search, session: "session-1")
/// ```
///
pub fn remove(
  search: Search,
  session session_id: String,
) -> Result(Nil, SearchError) {
  in_transaction(search, fn() {
    use Nil <- result.try(run_statement(
      search,
      sql.delete_session_index(session_id),
    ))
    run_statement(search, sql.delete_cursor(session_id))
  })
}

/// Runs a full-text query and returns hits ranked best-first (FTS5
/// `rank`). `text` uses FTS5 query syntax — bare words, quoted phrases,
/// `AND`/`OR`/`NOT` — and a malformed query is an `IndexFault`, not a
/// crash. `limit` caps the hits returned.
///
/// ## Examples
///
/// ```gleam
/// // search.query(search, "auth migration", limit: 10)
/// // -> Ok([Hit(session: "s1", entry: "018f...", snippet: "the [auth] [migration]")])
/// ```
///
pub fn query(
  search: Search,
  text text: String,
  limit limit: Int,
) -> Result(List(Hit), SearchError) {
  let #(statement, params, decoder) = sql.search_entries(text:, limit:)
  sqlight.query(
    statement,
    on: search.db,
    with: list.map(params, param_to_sqlight),
    expecting: decoder,
  )
  |> result.map_error(index_fault)
  |> result.map(
    list.map(_, fn(row) {
      let sql.SearchEntries(session_id:, entry_id:, snippet:) = row
      Hit(session: session_id, entry: entry_id, snippet:)
    }),
  )
}

/// The searchable text of an entry, as indexed: user text, assistant
/// text, and tool-result text blocks of a message entry (thinking and
/// tool-call arguments are not indexed); compaction and branch-summary
/// text; nothing for custom entries. Blocks join with newlines; an
/// empty result means the entry is skipped (its seq still advances the
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
    entry.CustomEntry(..) -> ""
  }
}

fn message_text(message: AgentMessage) -> String {
  case message {
    message.UserMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    message.AssistantMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantText(text:, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join("\n")
    message.ToolResultMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.ToolResultText(text:, ..) -> Ok(text)
          message.ToolResultImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    message.CustomMessage(..) -> ""
  }
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
  body: fn() -> Result(Nil, SearchError),
) -> Result(Nil, SearchError) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", on: search.db)
    |> result.map_error(index_fault),
  )
  case body() {
    Ok(Nil) ->
      sqlight.exec("COMMIT", on: search.db)
      |> result.map_error(index_fault)
    Error(error) -> {
      // Best-effort rollback; the original error is the one reported.
      let _ = sqlight.exec("ROLLBACK", on: search.db)
      Error(error)
    }
  }
}
