//// The history index holder and the wiring around it: where the index
//// file goes, that it is protected, and what the seam answers when the
//// holder is there, gone, or restarted.
////
//// The index here is a real file and the sessions are real stores. What
//// is *not* exercised here is the commit-driven path and the
//// cross-session recall it exists for — those are
//// `memory_recall_test`, over two real session files and a compaction.

import client/history
import client/serve
import core/clock
import core/entry.{type Entry, MessageEntry}
import core/ids.{type EntryId, type SessionId}
import core/message.{UserMessage, UserText}
import core/tx.{InsertEntry, Tx}
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import storage/memory
import storage/storage.{type Storage}
import tools/fs
import tools/history as history_tool

pub fn missing_holder_casts_are_no_ops_test() {
  let name = process.new_name(prefix: "missing-history-holder")
  history.poke(name)
  history.stop(name)
}

// --- where the index lives -------------------------------------------------

pub fn the_index_sits_beside_the_session_file_test() {
  assert history.index_beside("/data/review.db") == "/data/loom-search.db"
  assert history.index_beside("/loom.db") == "/loom-search.db"
}

// A session path with no directory of its own is a bare file name, and
// the index is one too; `client/serve` is what resolves it against the
// working directory before it reaches a policy.
pub fn a_bare_session_name_yields_a_bare_index_name_test() {
  assert history.index_beside("loom.db") == "loom-search.db"
}

// --- the protected index ---------------------------------------------------

// The security property: search snippets are read back into *future*
// sessions' contexts, so an index a model can write is a channel from
// one execution's output into a later execution's input. `protected`
// bars writes and leaves reads alone, which is the asymmetry wanted.
pub fn the_index_is_protected_from_every_write_test() {
  let base = serve.base_policy("/work")
  let composed = serve.protecting_index(base, "/data/loom-search.db")
  assert list.contains(composed.protected, "/data/loom-search.db")
  // The blob store's protection is not lost in the process.
  assert list.contains(composed.protected, "/work/.blobs")
  // And the composed policy is one the sandbox will actually accept, so
  // the boot's own validation cannot be what discovers the addition.
  assert serve.base_policy_fault(composed) == Ok(Nil)
}

pub fn a_relative_index_would_refuse_the_boot_test() {
  // Not a scenario `serve` can reach — it resolves the index against the
  // working directory first — but the reason it must: a relative
  // protected entry covers nothing while looking as though it did.
  let composed =
    serve.protecting_index(serve.base_policy("/work"), "loom-search.db")
  let assert Error(reason) = serve.base_policy_fault(composed)
    as "a relative protected entry must refuse the boot"
  assert string.contains(reason, "loom-search.db")
}

// The chain the protection actually runs through: an index inside the
// workspace, a model-side `fs_write` resolving its path, and the
// `protected` entry refusing it. Reads are untouched — `protected` bars
// writes only — which is the asymmetry the design asks for.
pub fn a_model_side_write_to_the_index_is_refused_test() {
  let workspace = absolute("build/test_db/history-protected")
  let _made = simplifile.create_directory_all(workspace)
  let index = history.index_beside(workspace <> "/session.db")
  let _seeded = simplifile.write(to: index, contents: "")
  let base = serve.protecting_index(serve.base_policy(workspace), index)

  let assert Error(fs.ProtectedPath(protected:, ..)) =
    fs.resolve_writable(
      filesystem: fs.real_filesystem(),
      workspace:,
      protected: base.protected,
      path: index,
    )
    as "a write reaching the index must be refused by the protected entry"
  assert protected == index

  // The ordinary security-conscious layout — the session, and so the
  // index, outside every writable root — must not grow protected
  // entries for files that never exist: the jail refuses to mask a
  // missing entry under a read-only parent, so the side files would
  // turn into a refusal of every jailed call. No write path reaches
  // them there. The database itself, which the boot's probe creates,
  // stays protected in every layout.
  let elsewhere = absolute("build/test_db/history-layout-sessions")
  let outside = history.index_beside(elsewhere <> "/loom.db")
  let narrow = serve.protecting_index(serve.base_policy(workspace), outside)
  assert list.contains(narrow.protected, outside)
  assert !list.contains(narrow.protected, outside <> "-wal")
  assert !list.contains(narrow.protected, outside <> "-journal")

  // The side files are the same door one filename to the right: the
  // index runs in WAL mode, WAL frame checksums are not cryptographic,
  // and a crafted `-wal` is served as index content on the next read.
  // The protection must cover the whole SQLite family, not the database
  // alone.
  let assert Error(fs.ProtectedPath(..)) =
    fs.resolve_writable(
      filesystem: fs.real_filesystem(),
      workspace:,
      protected: base.protected,
      path: index <> "-wal",
    )
    as "a write reaching the index's WAL must be refused"
  let assert Error(fs.ProtectedPath(..)) =
    fs.resolve_writable(
      filesystem: fs.real_filesystem(),
      workspace:,
      protected: base.protected,
      path: index <> "-shm",
    )
    as "a write reaching the index's shared-memory file must be refused"

  // The control: an ordinary workspace file is still writable, so the
  // refusal above is the index's and not a policy that refuses
  // everything.
  let assert Ok(_resolved) =
    fs.resolve_writable(
      filesystem: fs.real_filesystem(),
      workspace:,
      protected: base.protected,
      path: workspace <> "/notes.md",
    )
    as "an ordinary workspace write must still resolve"
}

fn absolute(path: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> path
}

// --- probing ---------------------------------------------------------------

pub fn an_index_in_a_missing_directory_does_not_open_test() {
  let assert Error(reason) =
    history.probe("/nonexistent/loom-history-test/loom-search.db")
    as "an index under a directory that does not exist must not open"
  // The path is in the message: an operator reading `history.unavailable`
  // must be told which file, since sqlite's own message can be empty.
  assert string.contains(reason, "/nonexistent/loom-history-test")
}

pub fn a_fresh_index_opens_test() {
  let path = fresh_index("probe")
  assert history.probe(path) == Ok(Nil)
}

// --- the seam --------------------------------------------------------------

pub fn a_missing_holder_refuses_in_band_test() {
  let name = process.new_name(prefix: "loom_history_absent")
  let seam = history.seam(name, timeout_ms: 200)
  let assert Error(history_tool.IndexUnavailable(reason:)) =
    seam.search("anything", 10, history_tool.Repository)
    as "a seam over no holder must refuse rather than crash"
  assert string.contains(reason, "no history index")
}

pub fn a_synced_session_is_findable_through_the_seam_test() {
  let path = fresh_index("seam")
  let #(store, id) = a_store(1, ["the auth migration plan", "grocery list"])
  let name = process.new_name(prefix: "loom_history_seam")
  let assert Ok(_started) = history.start(config(name, path, id, store))
    as "the holder must start"
  let assert Ok(Nil) = history.synchronize(name, timeout_ms: 5000)
    as "the first sync must succeed"

  let seam = history.seam(name, timeout_ms: 5000)
  let assert Ok([hit]) = seam.search("migration", 10, history_tool.Repository)
    as "the indexed entry must be findable"
  assert hit.session == ids.session_id_to_string(id)
  assert string.contains(hit.snippet, "[migration]")
  history.stop(name)
}

// A malformed FTS5 query is the index's own refusal, and it must reach
// the model as an in-band refusal rather than as a dead tool call.
pub fn a_malformed_query_refuses_in_band_test() {
  let path = fresh_index("malformed")
  let #(store, id) = a_store(2, ["something"])
  let name = process.new_name(prefix: "loom_history_malformed")
  let assert Ok(_started) = history.start(config(name, path, id, store))
  let seam = history.seam(name, timeout_ms: 5000)
  let assert Error(history_tool.IndexRefused(..)) =
    seam.search("\"unbalanced", 10, history_tool.Repository)
    as "a malformed query is a refusal, not a crash"
  history.stop(name)
}

// --- scope -----------------------------------------------------------------

// The within-session row: two sessions in one index, and a scoped query
// that sees only its own. Scoping is in the SQL, so `limit` counts hits
// in this session rather than hits anywhere that happen to belong to it.
pub fn a_session_scope_excludes_the_other_sessions_rows_test() {
  let path = fresh_index("scope")
  let #(mine, my_id) = a_store(3, ["the decision was msgpack over json"])
  let #(theirs, their_id) =
    a_store(4, ["the decision was sqlite over postgres"])

  let my_name = process.new_name(prefix: "loom_history_scope_mine")
  let their_name = process.new_name(prefix: "loom_history_scope_theirs")
  let assert Ok(_mine) = history.start(config(my_name, path, my_id, mine))
  let assert Ok(_theirs) =
    history.start(config(their_name, path, their_id, theirs))
  let assert Ok(Nil) = history.synchronize(my_name, timeout_ms: 5000)
  let assert Ok(Nil) = history.synchronize(their_name, timeout_ms: 5000)

  let seam = history.seam(my_name, timeout_ms: 5000)
  // Repository scope sees both sessions' rows.
  let assert Ok(everywhere) =
    seam.search("decision", 10, history_tool.Repository)
  assert list.length(everywhere) == 2
  // This session's scope sees exactly its own.
  let assert Ok([only_mine]) =
    seam.search("decision", 10, history_tool.ThisSession)
    as "a scoped query must see one session's row and no other"
  assert only_mine.session == ids.session_id_to_string(my_id)
  assert string.contains(only_mine.snippet, "msgpack")
  history.stop(my_name)
  history.stop(their_name)
}

// --- restart ---------------------------------------------------------------

// The holder is in the restartable tier because everything it holds is
// one connection to a rebuildable projection: a replacement under the
// same name reopens the file and answers the same questions.
pub fn a_restarted_holder_reopens_the_index_test() {
  let path = fresh_index("restart")
  let #(store, id) = a_store(5, ["the fetcher grew a retry"])
  let name = process.new_name(prefix: "loom_history_restart")
  let assert Ok(_first) = history.start(config(name, path, id, store))
  let assert Ok(Nil) = history.synchronize(name, timeout_ms: 5000)
  await_gone(name)
  // A restart is a fresh `start` under the same name, which is exactly
  // what the supervisor does.
  let assert Ok(_second) = history.start(config(name, path, id, store))
    as "the holder must start again under the same name"
  let seam = history.seam(name, timeout_ms: 5000)
  let assert Ok([hit]) = seam.search("retry", 10, history_tool.Repository)
    as "the reopened index must still hold what was synced before"
  assert string.contains(hit.snippet, "[retry]")
  history.stop(name)
}

// An index that will not open must not fail the start: the holder is a
// restartable child, and a start that can fail turns a bad file on disk
// into a restart loop that spends the tier's shared budget for a
// projection with no authority. It starts empty-handed and answers in
// band; a restart over the repaired file — which always succeeds,
// because the start no longer can fail — is the recovery.
pub fn an_unopenable_index_starts_and_repairs_in_band_test() {
  let root = absolute("build/test_db/history-unopenable")
  let _stale = simplifile.delete(root)
  // The obstruction is the path itself being a directory — the one
  // unopenable state SQLite refuses deterministically. A missing parent
  // is refused too, but lazily enough that the refusal's timing is the
  // platform's, which is exactly what a test must not depend on.
  let path = root <> "/loom-search.db"
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the obstruction must exist before the holder starts"
  let #(store, id) = a_store(7, ["a decision worth recalling"])
  let name = process.new_name(prefix: "loom_history_unopenable")
  let assert Ok(_started) = history.start(config(name, path, id, store))
    as "an unopenable index must not fail the start"
  let seam = history.seam(name, timeout_ms: 5000)
  let assert Error(history_tool.IndexUnavailable(reason:)) =
    seam.search("decision", 10, history_tool.Repository)
    as "a holder with no index must answer unavailability, not crash"
  assert string.contains(reason, "could not be opened")
  // The repair: remove the obstruction and restart the holder — a fresh
  // start under the same name, which is exactly what the supervisor
  // does, and which cannot fail whatever it finds on disk.
  let assert Ok(Nil) = simplifile.delete(path)
  history.stop(name)
  await_gone(name)
  let assert Ok(_second) = history.start(config(name, path, id, store))
    as "the restart over the repaired file must start"
  let assert Ok(Nil) = history.synchronize(name, timeout_ms: 5000)
    as "the restarted holder must sync the repaired index"
  let assert Ok([hit]) = seam.search("decision", 10, history_tool.Repository)
    as "the repaired index must serve what the sync indexed"
  assert string.contains(hit.snippet, "[decision]")
  history.stop(name)
}

// A generation that cannot be read skips the sync rather than guessing
// zero: guessing costs a full drop-and-reindex the moment the real
// number comes back.
pub fn an_unreadable_generation_skips_the_sync_test() {
  let path = fresh_index("generation")
  let #(store, id) = a_store(6, ["never indexed"])
  let name = process.new_name(prefix: "loom_history_generation")
  let unreadable =
    history.over_session(
      name:,
      path:,
      session: id,
      store:,
      generation: fn() { Error("no session file") },
      timeout_ms: 5000,
    )
  let assert Ok(_started) = history.start(unreadable)
  let assert Error(reason) = history.synchronize(name, timeout_ms: 5000)
    as "a sync with no generation must report rather than index"
  assert string.contains(reason, "no session file")
  let seam = history.seam(name, timeout_ms: 5000)
  assert seam.search("indexed", 10, history_tool.Repository) == Ok([])
  history.stop(name)
}

// The generation thunk for a session file that is not there answers an
// error rather than a number.
pub fn a_missing_session_file_has_no_generation_test() {
  let read = history.sqlite_generation("/nonexistent/loom-history/session.db")
  let assert Error(reason) = read()
    as "a missing session file has no rewrite generation"
  assert string.contains(reason, "rewrite generation")
}

// --- fixtures --------------------------------------------------------------

fn config(
  name: Name(history.Message),
  path: String,
  session: SessionId,
  store: Storage(handle),
) -> history.Config {
  history.over_session(
    name:,
    path:,
    session:,
    store:,
    // Memory stores have no rewrite, so the generation is always zero
    // (`events/search.sync`'s own documented answer for them).
    generation: fn() { Ok(0) },
    timeout_ms: 5000,
  )
}

// A memory store holding one user message per text, chained, plus the
// canonical session id they are indexed under. `seed` separates two
// stores in one test, which must not mint the same session id.
fn a_store(
  seed: Int,
  texts: List(String),
) -> #(Storage(process.Subject(memory.Message)), SessionId) {
  let assert Ok(store) = memory.open(clock.stepping(from: 5000, by: 1))
    as "the memory backend must open"
  let generator = ids.generator(clock.stepping(from: 1000, by: 1), seed:)
  let #(id, generator) = ids.mint_session(generator)
  let _leaf = append(store, generator, None, texts)
  #(store, id)
}

fn append(
  store: Storage(handle),
  generator: ids.Generator,
  parent: Option(EntryId),
  texts: List(String),
) -> Option(EntryId) {
  case texts {
    [] -> parent
    [text, ..rest] -> {
      let #(id, generator) = ids.mint_entry(generator)
      let assert Ok(_committed) =
        storage.commit(
          store,
          Tx(
            writes: [InsertEntry(entry: an_entry(id, parent, text))],
            expected: [],
          ),
        )
        as "the fixture entry must commit"
      append(store, generator, Some(id), rest)
    }
  }
}

fn an_entry(id: EntryId, parent: Option(EntryId), text: String) -> Entry {
  MessageEntry(
    id:,
    parent:,
    seq: 0,
    ts: 0,
    message: UserMessage(
      content: [UserText(text:, text_signature: None)],
      timestamp: 0,
    ),
    terminate: False,
  )
}

// `stop` is a cast, so the name outlives the send by a moment; a
// supervisor's restart waits for the exit signal, and so must this.
fn await_gone(name: Name(history.Message)) -> Nil {
  history.stop(name)
  wait_for_unregistered(name, 200)
}

fn wait_for_unregistered(name: Name(history.Message), left: Int) -> Nil {
  case process.named(name), left <= 0 {
    Error(Nil), _ -> Nil
    Ok(_pid), True -> Nil
    Ok(_pid), False -> {
      process.sleep(5)
      wait_for_unregistered(name, left - 5)
    }
  }
}

// A fresh index file per lane, so a rerun never inherits the last run's
// rows.
fn fresh_index(lane: String) -> String {
  let _made = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/client_history_" <> lane <> ".db"
  let _stale = simplifile.delete(path)
  let _wal = simplifile.delete(path <> "-wal")
  let _shm = simplifile.delete(path <> "-shm")
  path
}
