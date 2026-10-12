//// The memory plane's own rows: where the store and its sidecar live, the
//// caps at the `remember` door, the lease-free read of the notes, and the
//// notes index rebuilt from the store, each against a real memory session
//// file.
////
//// Everything that touches a store here touches a real SQLite file. The
//// only thing faked anywhere in this file is the clock.

import broker/broker
import broker/exec
import broker/policy
import client/memory
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx.{Expect, SetRegister, Tx}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import simplifile
import storage/storage
import support/tool_registry
import telemetry/log
import tools/directory_access
import tools/remember
import tools/tool

// --- the fold ---------------------------------------------------------------

pub fn memory_folds_on_the_session_directory_test() {
  assert memory.store_beside("/data/review.db") == "/data/loom-memory.db"
  assert memory.notes_beside("/data/loom-memory.db")
    == "/data/loom-memory.notes"
  assert memory.store_beside("review.db") == "loom-memory.db"
  assert memory.directory_of("/data/review.db") == "/data"
  assert memory.directory_of("review.db") == "."
}

// --- the `remember` door ----------------------------------------------------

/// The door end to end, through the registered tool: a note lands as one
/// `memory/note` row, redacted, and the row's text is the redacted text
/// rather than what the model typed.
pub fn remember_writes_one_redacted_note_test() {
  let root = fresh_root("remember")
  let outcome =
    dispatch(root, "prefer tabs, and the key is sk-ant-api03-abcdefghijkl")
  assert outcome.is_error == False

  let assert [row] = notes_in(root) as "exactly one note must have landed"
  let assert entry.CustomEntry(custom_type:, ..) = row
    as "a note is a custom entry"
  assert custom_type == remember.note_type
  let assert Ok(note) = memory.note_of(row) as "the row must decode as a note"
  assert string.contains(note.text, "prefer tabs")
  assert string.contains(note.text, "sk-ant-api03") == False
}

/// The tool is registered only where the memory plane is — the same gate
/// `history_search` sits behind, on the real boot path's own function.
pub fn the_tool_is_registered_only_when_memory_is_wired_test() {
  let root = fresh_root("gate")
  let with_memory =
    tool_registry.built_in(
      None,
      None,
      None,
      Some(a_seam(root <> "/loom-memory.db")),
      None,
    )
  assert list.contains(tool.names(with_memory), remember.tool_name)
  let without = tool_registry.built_in(None, None, None, None, None)
  assert list.contains(tool.names(without), remember.tool_name) == False
}

/// The size cap is measured after redaction, and refused in band rather
/// than truncated: there is a model at this door and it can write less.
pub fn a_note_over_the_cap_is_refused_in_band_test() {
  let root = fresh_root("cap")
  let outcome = dispatch(root, string.repeat("word ", 500))
  assert outcome.is_error
  assert string.contains(text_of(outcome), "characters after redaction")
  assert notes_in(root) == []
}

/// An empty note — or one that redaction emptied — is refused, and
/// nothing lands.
pub fn an_empty_note_is_refused_test() {
  let root = fresh_root("empty")
  let outcome = dispatch(root, "   \n  ")
  assert outcome.is_error
  assert notes_in(root) == []
}

/// The lifetime ceiling holds, and it holds against the durable counter
/// rather than against a count of rows: the counter is what a CAS in the
/// note's own transaction can guard.
pub fn the_lifetime_ceiling_refuses_the_next_note_test() {
  let root = fresh_root("ceiling")
  // Seed the counter at the ceiling directly — writing 256 notes here
  // would prove the same thing and cost a second of test time.
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(_committed) =
    storage.commit(
      opened.session.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactCustom,
            key: memory.note_count_key,
            value: register.value(json.Int(remember.max_notes)),
          ),
        ],
        expected: [
          Expect(ns: register.FactCustom, key: memory.note_count_key, seq: None),
        ],
      ),
    )
    as "the counter must be seedable"
  memory.close(opened)

  let outcome = dispatch(root, "one more thing")
  assert outcome.is_error
  assert string.contains(text_of(outcome), "lifetime limit")
  assert notes_in(root) == []
}

/// Another writer holds the memory session's lease, and a `remember` call
/// landing meanwhile is refused in band — never a crash, never a wait.
pub fn a_held_memory_session_refuses_the_note_in_band_test() {
  let root = fresh_root("held")
  let assert Ok(holder) = open_memory(root) as "the holder must open"
  let outcome = dispatch(root, "written while the lease is held")
  memory.close(holder)

  assert outcome.is_error
  assert string.contains(text_of(outcome), "another call")
  // And once the lease is released the same note lands.
  let again = dispatch(root, "written while the lease is held")
  assert again.is_error == False
  assert list.length(notes_in(root)) == 1
}

// --- the lease-free read and the rebuilt index -------------------------------

/// A store that does not exist yet holds no notes, and rebuilding its index
/// writes nothing: an empty repository gets no empty sidecar.
pub fn an_absent_store_holds_no_notes_and_gets_no_index_test() {
  let root = fresh_root("absent")
  let store = root <> "/loom-memory.db"
  let index = memory.notes_beside(store)
  assert memory.read_note_entries(store) == Ok([])
  assert memory.rebuild_notes_index(store, index) == Ok(Nil)
  assert simplifile.is_file(index) == Ok(False)
}

/// The notes are read while another writer holds the lease, which is the
/// point of the path: a session open must neither wait for a `remember` call
/// nor fail because one is in flight.
pub fn the_notes_are_read_and_indexed_while_the_lease_is_held_test() {
  let root = fresh_root("leased")
  let store = root <> "/loom-memory.db"
  let index = memory.notes_beside(store)
  assert !dispatch(root, "a note").is_error
  assert simplifile.delete(index) == Ok(Nil)

  let assert Ok(holder) = open_memory(root) as "the holder must open"
  assert list.length(notes_in(root)) == 1
  assert memory.rebuild_notes_index(store, index) == Ok(Nil)
  memory.close(holder)

  let assert Ok(body) = simplifile.read(index) as "the index must be rebuilt"
  assert string.contains(body, "a note: for the tests")
}

/// A stale index is replaced by the one the store renders, and a current one
/// is left as it is.
pub fn rebuilding_replaces_a_stale_index_and_keeps_a_current_one_test() {
  let root = fresh_root("stale")
  let store = root <> "/loom-memory.db"
  let index = memory.notes_beside(store)
  assert !dispatch(root, "a note").is_error
  let assert Ok(current) = simplifile.read(index) as "the door writes an index"

  let assert Ok(Nil) = simplifile.write(to: index, contents: "- stale")
  assert memory.rebuild_notes_index(store, index) == Ok(Nil)
  assert simplifile.read(index) == Ok(current)

  assert memory.rebuild_notes_index(store, index) == Ok(Nil)
  assert simplifile.read(index) == Ok(current)
  assert no_temp_files(root)
}

/// A store that is not a readable session is an error, never an empty list,
/// and the sidecar it would have rendered is left alone.
pub fn a_damaged_store_is_an_error_and_leaves_the_index_alone_test() {
  let root = fresh_root("damaged")
  let store = root <> "/loom-memory.db"
  let index = memory.notes_beside(store)
  let assert Ok(Nil) = simplifile.write(to: store, contents: "not a database")
  let assert Ok(Nil) = simplifile.write(to: index, contents: "- kept")

  let assert Error(_reason) = memory.read_note_entries(store)
    as "a damaged store must not read as empty"
  let assert Error(_reason) = memory.rebuild_notes_index(store, index)
    as "a damaged store must not rebuild"
  assert simplifile.read(index) == Ok("- kept")
}

/// `open` links a storage actor to its caller, and a long-lived caller (the
/// gateway deciding proposals) opens once per decision, so `close` must stop
/// the actor or each decision leaks a process. The actor is found as the one
/// new link of this process, which no concurrent test can disturb.
pub fn closing_the_memory_session_stops_its_storage_actor_test() {
  let root = fresh_root("retire")
  let before = links()
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let started = list.filter(links(), fn(pid) { !list.contains(before, pid) })
  assert list.length(started) == 1
  assert list.all(started, process.is_alive)

  memory.close(opened)
  assert list.all(started, fn(pid) { !process.is_alive(pid) })

  // The link list carries no order, so the same links can come back in a
  // different one; compare them as sets.
  assert set.from_list(links()) == set.from_list(before)
}

fn links() -> List(Pid) {
  process_info(process.self(), atom.create("links")).1
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, item: Atom) -> #(Atom, List(Pid))

// --- the rig ----------------------------------------------------------------

fn open_memory(root: String) -> Result(memory.Opened, memory.MemoryFault) {
  memory.open(
    path: root <> "/loom-memory.db",
    owner: "memory-test",
    lease_ttl_ms: memory.lease_ttl_ms,
    clock: a_clock(),
    generator: ids.generator(a_clock(), seed: 7),
  )
}

fn a_seam(path: String) -> remember.Memory {
  memory.remember_seam(
    path,
    clock: a_clock(),
    entropy: fn() { 4242 },
    logger: log.discard(),
  )
}

// One `remember` call, dispatched through the production registry —
// which is what makes this a test of the tool and not of the closure.
fn dispatch(root: String, note: String) -> tool.ToolOutcome {
  let registry =
    tool_registry.built_in(
      None,
      None,
      None,
      Some(a_seam(root <> "/loom-memory.db")),
      None,
    )
  tool.dispatch(
    registry,
    a_ctx(),
    remember.tool_name,
    json.Object([
      #("title", json.String("a note")),
      #("description", json.String("for the tests")),
      #("kind", json.String("fact")),
      #("note", json.String(note)),
    ]),
  )
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

// A directory nothing survives into, so every memory session in this
// file starts empty. Checked rather than assumed, for the reason
// `memory_recall_test` records: ids here are deterministic, so a store
// left behind by the last run holds rows indistinguishable from this
// run's.
fn fresh_root(lane: String) -> String {
  let root = "build/test_db/memory-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  let assert Ok(False) = simplifile.is_file(root <> "/loom-memory.db")
    as "the memory store must not survive from the last run"
  root
}

fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-memory-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}

fn notes_in(root: String) -> List(entry.Entry) {
  let assert Ok(found) = memory.read_note_entries(root <> "/loom-memory.db")
    as "the notes must read without a lease"
  found
}

// Each index write names its own temp file, so the check is that the
// directory holds none after the rename.
fn no_temp_files(directory: String) -> Bool {
  let assert Ok(names) = simplifile.read_directory(directory)
    as "the root must be readable"
  !list.any(names, string.ends_with(_, ".tmp"))
}
