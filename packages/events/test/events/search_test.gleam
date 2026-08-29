//// Search service semantics: pull-based sync, idempotent cursors,
//// rewrite-generation invalidation, and ranked FTS5 queries.

import core/clock
import core/entry as core_entry
import core/ids
import core/message
import events/search
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/sqlite
import storage/storage
import support/fixtures

// A stable session id per test lane. The index is repository-wide and
// keys by the canonical id (`protocol-change/008`), so the tests need one
// that is the same on every run and different per lane.
fn sid(n: Int) -> ids.SessionId {
  let #(id, _generator) =
    ids.mint_session(ids.generator(
      clock.fixed(at: 1_700_000_000_000 + n),
      seed: n,
    ))
  id
}

fn open_search() -> search.Search {
  let assert Ok(service) = search.open(":memory:")
    as "in-memory search database must open"
  service
}

// Scratch layout for the two tests below that need a real on-disk
// index file (SQLite's locking discipline — WAL, busy timeout, two
// independent connections — only shows up against a real file, never
// `:memory:`). Each lane gets its own subdirectory, wiped and
// re-created here rather than trusting a bare delete of the `.db` file
// alone: a long-lived worktree can carry a leftover `build/test_db`
// from an interrupted prior run, and a stray `-wal`/`-shm`/`-journal`
// file left behind by a crash is exactly what makes a *fresh* open see
// the database as locked. The delete is checked, not assumed —
// `client/memory_recall_test`'s `fresh_root` learned that the hard way
// (a stale index once let a removed sync path pass unnoticed).
fn fresh_index_path(lane: String) -> String {
  let dir = "build/test_db/events-search-" <> lane
  let _stale = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the test scratch directory must be creatable"
  let path = dir <> "/index.db"
  let assert Ok(False) = simplifile.is_file(path)
    as "the index file must not survive from the last run"
  path
}

// A bounded retry around a `sync` call that races another connection's
// write lock. `search.open`'s busy timeout (5s, hard-coded in
// `packages/events/src` and left untouched here) already covers
// ordinary contention — the forced interleaving below never holds the
// lock longer than its ~1.5s slow scan — but a heavily loaded machine
// can stretch the whole exchange past that budget. `sync` re-running
// after a lock timeout is exactly as idempotent as re-running after a
// crash (its own doc comment), so retrying tolerates that without
// touching the production timeout or weakening what the test proves:
// still two syncs, still no duplicate rows.
fn sync_tolerating_lock_contention(
  service: search.Search,
  store: storage.Storage(handle),
  session: ids.SessionId,
  generation: Int,
  retries_left retries_left: Int,
) -> Result(Nil, search.SearchError) {
  case search.sync(service, store, session:, generation:) {
    Error(search.IndexFault(message)) as failed ->
      case retries_left > 0 && string.contains(message, "locked") {
        True -> {
          process.sleep(300)
          sync_tolerating_lock_contention(
            service,
            store,
            session,
            generation,
            retries_left: retries_left - 1,
          )
        }
        False -> failed
      }
    result -> result
  }
}

pub fn sync_then_query_returns_known_entries_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(first, ctx) =
    fixtures.message_entry(ctx, None, "the auth migration plan")
  let #(second, _ctx) =
    fixtures.message_entry(ctx, Some(first.id), "unrelated grocery list")
  fixtures.commit_entries(store, [first, second])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok([hit]) = search.query(service, text: "migration", limit: 10)
  assert hit.session == ids.session_id_to_string(sid(1))
  assert hit.entry == ids.entry_id_to_string(first.id)
  assert string.contains(hit.snippet, "[migration]")
  let assert Ok(Nil) = search.close(service)
}

pub fn repeated_sync_does_not_duplicate_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "singular fact")
  fixtures.commit_entries(store, [entry])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(hits) = search.query(service, text: "singular", limit: 10)
  assert list.length(hits) == 1
}

/// EV-sync-txn: the cursor must be read inside the same write
/// transaction it is advanced in, or two concurrent syncs of a
/// session's new entries both read the same not-stale cursor and both
/// insert the same rows — five entries indexing as ten, permanently
/// (nothing about the incremental path ever deletes-then-reinserts to
/// heal it, unlike the generation-mismatch path).
///
/// Two real connections to one on-disk index file race a "slow" and a
/// "fast" sync of the same second wave of entries. The interleaving is
/// forced with a slow entry scan (what a large session file's scan looks
/// like) rather than a hard rendezvous: the slow sync's cursor-read
/// decision is made either before the write lock (pre-fix — reads the
/// same not-yet-advanced cursor the fast sync will race against) or
/// while holding it (post-fix — the fast sync then simply waits its
/// turn and re-reads).
pub fn concurrent_sync_does_not_duplicate_rows_test() {
  let path = fresh_index_path("concurrent-sync")

  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(first, ctx) = fixtures.message_entry(ctx, None, "first wave alpha")
  fixtures.commit_entries(store, [first])

  // Establish a real, non-stale cursor first. The race under test is
  // the incremental "second wave" path (`stale == False`), which is the
  // one with no self-healing delete.
  let assert Ok(warm_up) = search.open(path) as "search database must open"
  let assert Ok(Nil) =
    search.sync(warm_up, store, session: sid(2), generation: 0)
  let assert Ok(Nil) = search.close(warm_up)

  // A second wave of five new entries for the two racing syncs to index.
  let _ctx =
    int.range(from: 1, to: 6, with: ctx, run: fn(ctx, i) {
      let #(entry, ctx) =
        fixtures.message_entry(
          ctx,
          Some(first.id),
          "second wave " <> int.to_string(i),
        )
      fixtures.commit_entries(store, [entry])
      ctx
    })

  // Two independent connections to the same file, exactly as two
  // independent processes would open it.
  let slow_store =
    storage.Storage(..store, scan_entries: fn(handle, query) {
      process.sleep(1500)
      store.scan_entries(handle, query)
    })
  let done = process.new_subject()
  let _slow =
    process.spawn_unlinked(fn() {
      let assert Ok(service_slow) = search.open(path)
        as "search database must open"
      let result =
        sync_tolerating_lock_contention(
          service_slow,
          slow_store,
          sid(2),
          0,
          retries_left: 4,
        )
      process.send(done, result)
    })
  // Let the slow sync start (and, pre-fix, finish its unlocked cursor
  // read) before the fast one runs to completion underneath it.
  process.sleep(200)
  let assert Ok(fast_service) = search.open(path) as "search database must open"
  let assert Ok(Nil) =
    sync_tolerating_lock_contention(
      fast_service,
      store,
      sid(2),
      0,
      retries_left: 4,
    )
  // A generous wait for the spawned slow sync: its own retries above
  // can each add up to ~300ms, and this is a wall-clock budget for a
  // background process on a shared machine, not a lock timeout — wide
  // margin costs nothing here.
  let assert Ok(slow_result) = process.receive(done, 20_000)
  let assert Ok(Nil) = slow_result

  let assert Ok(hits) = search.query(fast_service, text: "second", limit: 100)
  assert list.length(hits) == 5
}

pub fn incremental_sync_indexes_new_entries_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(first, ctx) = fixtures.message_entry(ctx, None, "chapter one")
  fixtures.commit_entries(store, [first])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let #(second, _ctx) =
    fixtures.message_entry(ctx, Some(first.id), "chapter two arrives")
  fixtures.commit_entries(store, [second])
  let assert Ok(Nil) =
    search.notify(service, store, session: sid(1), generation: 0)
  let assert Ok(hits) = search.query(service, text: "chapter", limit: 10)
  assert list.length(hits) == 2
}

/// The precise-rewrite invalidation: bumping the generation drops the
/// session's index rows and re-indexes from zero, so entries the
/// rewrite erased stop matching (the rewrite is simulated by a fresh
/// store under the same session id, exactly what a store swap is).
pub fn generation_bump_invalidates_and_reindexes_test() {
  let old_store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(secret, _ctx) =
    fixtures.message_entry(ctx, None, "confidential launch codes")
  fixtures.commit_entries(old_store, [secret])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, old_store, session: sid(1), generation: 0)
  let assert Ok(before) = search.query(service, text: "confidential", limit: 10)
  assert list.length(before) == 1

  // The rewrite: a fresh store (fresh seq numbering) without the erased
  // entry, and a bumped generation counter in the session metadata.
  let new_store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(kept, _ctx) = fixtures.message_entry(ctx, None, "retained material")
  fixtures.commit_entries(new_store, [kept])
  let assert Ok(Nil) =
    search.sync(service, new_store, session: sid(1), generation: 1)

  let assert Ok(after) = search.query(service, text: "confidential", limit: 10)
  assert after == []
  let assert Ok(retained) = search.query(service, text: "retained", limit: 10)
  assert list.length(retained) == 1
}

/// Without a generation bump the cursor stands, so the same seqs are
/// not re-read — the stale-generation path is precise, not a sweep.
pub fn same_generation_keeps_cursor_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "cursor anchor")
  fixtures.commit_entries(store, [entry])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  // Re-sync against an *empty* fresh store at the same generation: if
  // the cursor were reset this would drop the indexed row.
  let empty_store = fixtures.open_store()
  let assert Ok(Nil) =
    search.sync(service, empty_store, session: sid(1), generation: 0)
  let assert Ok(hits) = search.query(service, text: "anchor", limit: 10)
  assert list.length(hits) == 1
}

pub fn remove_drops_session_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "ephemeral note")
  fixtures.commit_entries(store, [entry])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(Nil) = search.remove(service, session: sid(1))
  let assert Ok(hits) = search.query(service, text: "ephemeral", limit: 10)
  assert hits == []
  // After removal a sync re-indexes from zero (the cursor is gone too).
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(back) = search.query(service, text: "ephemeral", limit: 10)
  assert list.length(back) == 1
}

pub fn sessions_are_distinguished_in_hits_test() {
  let store_a = fixtures.open_store()
  let store_b = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(entry_a, ctx) =
    fixtures.message_entry(ctx, None, "shared keyword alpha")
  let #(entry_b, _ctx) =
    fixtures.message_entry(ctx, None, "shared keyword beta")
  fixtures.commit_entries(store_a, [entry_a])
  fixtures.commit_entries(store_b, [entry_b])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store_a, session: sid(3), generation: 0)
  let assert Ok(Nil) =
    search.sync(service, store_b, session: sid(4), generation: 0)
  let assert Ok(hits) = search.query(service, text: "shared", limit: 10)
  let sessions = list.map(hits, fn(hit) { hit.session })
  assert list.sort(sessions, string.compare)
    == list.sort(
      [ids.session_id_to_string(sid(3)), ids.session_id_to_string(sid(4))],
      string.compare,
    )
}

/// The session filter runs in SQL, so `limit` counts hits in the scoped
/// session rather than hits anywhere that happen to belong to it.
pub fn query_in_session_scopes_to_one_session_test() {
  let store_a = fixtures.open_store()
  let store_b = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(mine, ctx) = fixtures.message_entry(ctx, None, "scoped keyword mine")
  let #(theirs, _ctx) =
    fixtures.message_entry(ctx, None, "scoped keyword theirs")
  fixtures.commit_entries(store_a, [mine])
  fixtures.commit_entries(store_b, [theirs])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store_a, session: sid(6), generation: 0)
  let assert Ok(Nil) =
    search.sync(service, store_b, session: sid(7), generation: 0)

  // Unscoped: both sessions answer.
  let assert Ok(both) = search.query(service, text: "scoped", limit: 10)
  assert list.length(both) == 2

  // Scoped: the other session's entry is excluded, ids and all.
  let assert Ok([hit]) =
    search.query_in_session(service, session: sid(6), text: "scoped", limit: 10)
  assert hit.session == ids.session_id_to_string(sid(6))
  assert hit.entry == ids.entry_id_to_string(mine.id)
  let assert Ok([other]) =
    search.query_in_session(service, session: sid(7), text: "scoped", limit: 10)
  assert other.entry == ids.entry_id_to_string(theirs.id)

  // A session with nothing indexed answers with nothing rather than with
  // everybody else's hits.
  assert search.query_in_session(
      service,
      session: sid(8),
      text: "scoped",
      limit: 10,
    )
    == Ok([])
}

pub fn limit_caps_hits_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(one, ctx) = fixtures.message_entry(ctx, None, "repeated token")
  let #(two, ctx) = fixtures.message_entry(ctx, Some(one.id), "repeated token")
  let #(three, _ctx) =
    fixtures.message_entry(ctx, Some(two.id), "repeated token")
  fixtures.commit_entries(store, [one, two, three])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(hits) = search.query(service, text: "repeated", limit: 2)
  assert list.length(hits) == 2
}

pub fn summaries_are_indexed_and_customs_skipped_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(custom, ctx) = fixtures.custom_entry(ctx, None, "checkpoint-meta")
  let #(compaction, _ctx) =
    fixtures.compaction_entry(ctx, Some(custom.id), "condensed sprint recap")
  fixtures.commit_entries(store, [custom, compaction])
  let service = open_search()
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(hits) = search.query(service, text: "recap", limit: 10)
  assert list.length(hits) == 1
  // The custom entry contributed no text, but its seq advanced the
  // cursor: a re-sync finds nothing new to do.
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(1), generation: 0)
  let assert Ok(still) = search.query(service, text: "recap", limit: 10)
  assert list.length(still) == 1
}

/// The full invalidation loop against the real thing: a SQLite session
/// file, `storage/sqlite.rewrite_into` erasing an entry, and
/// `storage/sqlite.generation` supplying the counter the sync compares.
pub fn sqlite_rewrite_invalidates_index_test() {
  let path = fresh_index_path("rewrite")
  let clock = clock.stepping(from: 10_000, by: 1)

  // A session with one entry to erase and one to keep.
  let assert Ok(store) =
    sqlite.open(sqlite.config(path:, owner: "search-test"), clock)
  let ctx = fixtures.new_ctx()
  let #(secret, ctx) =
    fixtures.message_entry(ctx, None, "the doomed passphrase")
  let #(kept, _ctx) =
    fixtures.message_entry(ctx, Some(secret.id), "the surviving remark")
  fixtures.commit_entries(store, [secret, kept])

  let service = open_search()
  let assert Ok(generation) = sqlite.generation(path:)
  let assert Ok(Nil) =
    search.sync(service, store, session: sid(5), generation: generation)
  let assert Ok(before) = search.query(service, text: "passphrase", limit: 10)
  assert list.length(before) == 1

  // Rewrite offline: erase the secret entry's payload, keep the rest.
  let assert Ok(Nil) = storage.close(store)
  let secret_id = secret.id
  let erase = fn(entry) {
    case entry {
      core_entry.MessageEntry(id:, parent:, seq:, ts:, terminate:, message: _)
        if id == secret_id
      ->
        Ok(
          Some(core_entry.MessageEntry(
            id:,
            parent:,
            seq:,
            ts:,
            terminate:,
            message: message.UserMessage(
              content: [
                message.UserText(text: "[erased]", text_signature: None),
              ],
              timestamp: 0,
            ),
          )),
        )
      _ -> Ok(None)
    }
  }
  let assert Ok(sqlite.Rewrite(generation: bumped, ..)) =
    sqlite.rewrite_into(
      path:,
      clock:,
      rewrite: erase,
      rewrite_value: fn(_value) { Ok(None) },
    )
  assert bumped == generation + 1

  // Sync against the swapped store under the bumped generation: the
  // erased text stops matching, the kept text still matches.
  let assert Ok(reopened) =
    sqlite.open(sqlite.config(path:, owner: "search-test"), clock)
  let assert Ok(Nil) =
    search.sync(service, reopened, session: sid(5), generation: bumped)
  let assert Ok(gone) = search.query(service, text: "passphrase", limit: 10)
  assert gone == []
  let assert Ok(still) = search.query(service, text: "surviving", limit: 10)
  assert list.length(still) == 1
  let assert Ok(Nil) = storage.close(reopened)
}

pub fn malformed_query_is_an_error_not_a_crash_test() {
  let service = open_search()
  let assert Error(search.IndexFault(..)) =
    search.query(service, text: "\"unbalanced", limit: 10)
}
