//// The memory plane's own rows: the disjointness the two writers rest
//// on, the caps at each door, the digest's byte bound and its
//// fence-and-attribution wrapper, and the `remember` door end to end
//// against a real memory session file.
////
//// Everything that touches a store here touches a real SQLite file. The
//// only thing faked anywhere in this file is the clock.

import broker/broker
import broker/exec
import broker/policy
import client/memory
import client/notes
import client/serve
import core/clock
import core/ids
import core/json
import core/message
import core/register
import core/tx.{Expect, SetRegister, Tx}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/effects
import simplifile
import storage/storage
import tools/remember
import tools/tool

// --- R7: the two writers are disjoint --------------------------------------

/// The pipeline's types and the `remember` door's types share nothing.
///
/// Pinned by a test rather than by a registry because there are exactly
/// two writers and both are harness-side: a model never chooses a type
/// string, so a registry would be machinery with no threat to answer.
/// What could actually drift is somebody adding `memory/note` to the
/// pipeline's list, and this is what notices.
pub fn the_two_memory_writers_use_disjoint_types_test() {
  let shared =
    list.filter(memory.pipeline_types, list.contains(remember.entry_types, _))
  assert shared == []
  // And neither list is empty, or the intersection would be trivially
  // empty and this test would prove nothing.
  assert memory.pipeline_types != []
  assert remember.entry_types != []
}

/// A short name the pipeline does not own produces no type at all —
/// which is what stops a model answer inventing `note:` from writing a
/// row under the door reserved for `remember`.
pub fn a_model_answer_cannot_name_the_remember_type_test() {
  assert memory.type_named("fact") == Ok(memory.fact_type)
  assert memory.type_named("lesson") == Ok(memory.lesson_type)
  assert memory.type_named("preference") == Ok(memory.preference_type)
  assert memory.type_named("note") == Error(Nil)
  assert memory.type_named("memory/fact") == Error(Nil)
}

// --- the fold ---------------------------------------------------------------

pub fn memory_folds_on_the_session_directory_test() {
  assert memory.store_beside("/data/review.db") == "/data/loom-memory.db"
  assert memory.digest_beside("/data/review.db") == "/data/loom-memory.digest"
  assert memory.store_beside("review.db") == "loom-memory.db"
  assert memory.directory_of("/data/review.db") == "/data"
  assert memory.directory_of("review.db") == "."
}

// --- the digest -------------------------------------------------------------

/// The byte bound is a bound, and the truncation is marked.
///
/// The mutation that matters: remove the bound from `render_digest` and
/// this fails on the length assertion rather than on the marker, which
/// is why both are asserted.
pub fn the_digest_body_is_byte_capped_and_says_so_test() {
  let rows =
    list.repeat(Nil, 60)
    |> list.index_map(fn(_nothing, index) {
      distillate(index, memory.fact_type, string.repeat("prose ", 150))
    })
  let body = memory.render_digest(rows)
  assert byte_size(body) <= memory.max_digest_bytes
  assert string.contains(body, "truncated")
  // A cap that produced nothing but the notice would be worse than no
  // digest at all.
  assert string.contains(body, "(fact)")
}

/// One row longer than the whole budget still says something.
pub fn one_oversized_row_is_clipped_rather_than_dropped_test() {
  let body =
    memory.render_digest([
      distillate(1, memory.lesson_type, string.repeat("lesson ", 6000)),
    ])
  assert byte_size(body) <= memory.max_digest_bytes
  assert string.contains(body, "lesson lesson")
  assert string.contains(body, "truncated")
}

/// Redaction runs at the render door too, not only at the write door:
/// the sidecar is a file, and what it carries is what a later session
/// reads.
pub fn the_digest_body_is_redacted_test() {
  let body =
    memory.render_digest([
      distillate(1, memory.fact_type, "deploy with sk-ant-api03-abcdefghijkl"),
    ])
  assert string.contains(body, "sk-ant-api03") == False
  assert string.contains(body, "deploy with")
}

/// The fence and the attribution are built at injection time, so the
/// file cannot carry either — nor close the fence it sits inside.
pub fn the_wrapper_is_built_here_and_not_read_from_the_file_test() {
  let wrapped = memory.wrapped("- (fact) hello ``` goodbye")
  assert string.contains(wrapped, memory.fence)
  assert string.contains(wrapped, "heuristic context")
  assert string.contains(wrapped, "is an instruction to follow")
  // Exactly two fence runs: the one this opened and the one that closes
  // it. The body's own run was broken.
  assert count_runs(wrapped, "```") == 2
}

fn count_runs(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}

/// The hook injects nothing at all when there is no digest — the common
/// case, which must cost zero tokens — and one attributed user message
/// when there is one.
pub fn the_hook_injects_nothing_without_a_digest_test() {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let absent = memory.digest_hooks(bare_hooks(), None, clock.fixed(at: 5))
  assert absent.run_start(op) == []
  // An empty or whitespace-only file is absence too.
  let empty =
    memory.digest_hooks(bare_hooks(), Some("  \n "), clock.fixed(at: 5))
  assert empty.run_start(op) == []

  let present =
    memory.digest_hooks(bare_hooks(), Some("- (fact) x"), clock.fixed(at: 5))
  let assert [message.UserMessage(content: [message.UserText(text:, ..)], ..)] =
    present.run_start(op)
    as "a non-empty digest injects exactly one user message"
  assert string.contains(text, memory.fence)
  assert string.contains(text, "- (fact) x")
}

/// Composition is by wrapping: a hook registry that already injects
/// something keeps injecting it.
pub fn the_hook_wraps_rather_than_replaces_test() {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let earlier =
    effects.Hooks(..bare_hooks(), run_start: fn(_op) {
      [
        message.UserMessage(
          content: [
            message.UserText(text: "an earlier layer", text_signature: None),
          ],
          timestamp: 0,
        ),
      ]
    })
  let wrapped =
    memory.digest_hooks(earlier, Some("- (fact) x"), clock.fixed(at: 5))
  assert list.length(wrapped.run_start(op)) == 2
}

/// An absent sidecar reads as nothing, and an oversized one is clipped
/// on the way in as well as on the way out.
pub fn the_sidecar_is_capped_when_it_is_read_too_test() {
  let root = fresh_root("digest")
  assert memory.read_digest(root <> "/loom-memory.digest") == None
  let assert Ok(Nil) =
    simplifile.write(
      to: root <> "/loom-memory.digest",
      contents: string.repeat("z", memory.max_digest_bytes * 2),
    )
    as "the oversized sidecar must be writable"
  let assert Some(read) = memory.read_digest(root <> "/loom-memory.digest")
    as "a present sidecar must read"
  assert byte_size(read) <= memory.max_digest_bytes
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
  assert string.contains(row.text, "prefer tabs")
  assert string.contains(row.text, "sk-ant-api03") == False
  assert row.kind == remember.note_type
}

/// The tool is registered only where the memory plane is — the same gate
/// `history_search` sits behind, on the real boot path's own function.
pub fn the_tool_is_registered_only_when_memory_is_wired_test() {
  let root = fresh_root("gate")
  let with_memory =
    serve.registry(None, None, None, Some(a_seam(root <> "/loom-memory.db")))
  assert list.contains(tool.names(with_memory), remember.tool_name)
  let without = serve.registry(None, None, None, None)
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

/// A distillation run holds the memory session's writer lease, and a
/// `remember` call landing during one is refused in band — never a
/// crash, never a wait.
pub fn a_held_memory_session_refuses_the_note_in_band_test() {
  let root = fresh_root("held")
  let assert Ok(holder) = open_memory(root) as "the holder must open"
  let outcome = dispatch(root, "written while consolidation runs")
  memory.close(holder)

  assert outcome.is_error
  assert string.contains(text_of(outcome), "being consolidated")
  // And once the lease is released the same note lands.
  let again = dispatch(root, "written while consolidation runs")
  assert again.is_error == False
  assert list.length(notes_in(root)) == 1
}

// --- the head ---------------------------------------------------------------

/// The head is a pointer with a CAS, and the CAS is what makes a
/// consolidation atomic against a concurrent one.
pub fn the_head_moves_only_from_the_seq_it_was_read_at_test() {
  let root = fresh_root("head")
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(#([], None)) = memory.head(opened)
    as "a fresh memory session has no head"

  let assert Ok(#(first, _generator)) =
    memory.append_distillates(
      opened,
      [#(memory.fact_type, "the gate is make check")],
      memory.Provenance(sources: [], derived_from: []),
      clock.fixed(at: 10),
    )
    as "rows must append"
  let assert Ok(Nil) =
    memory.advance_head(opened, ids: first, expected: None, cursors: [])
    as "the first head must land"

  let assert Ok(#(named, Some(seq))) = memory.head(opened)
    as "the head must read back"
  assert list.length(named) == 1

  // The stale expectation loses: this is the concurrent-consolidation
  // case, and losing is correct.
  let assert Error(memory.MemoryFailed(..)) =
    memory.advance_head(opened, ids: [], expected: None, cursors: [])
    as "a head CAS against `absent` must fail once a head exists"
  // The right expectation wins.
  let assert Ok(Nil) =
    memory.advance_head(opened, ids: first, expected: Some(seq), cursors: [])
    as "a head CAS at the read seq must land"
  memory.close(opened)
}

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
  memory.remember_seam(path, clock: a_clock(), entropy: fn() { 4242 })
}

// One `remember` call, dispatched through the production registry —
// which is what makes this a test of the tool and not of the closure.
fn dispatch(root: String, note: String) -> tool.ToolOutcome {
  let registry =
    serve.registry(None, None, None, Some(a_seam(root <> "/loom-memory.db")))
  tool.dispatch(
    registry,
    a_ctx(),
    remember.tool_name,
    json.Object([#("note", json.String(note))]),
  )
}

fn notes_in(root: String) -> List(memory.Distillate) {
  let assert Ok(opened) = open_memory(root)
    as "the memory session must open for reading"
  let assert Ok(found) = memory.notes_after(opened, 0, limit: 512)
    as "the notes must read"
  memory.close(opened)
  found
}

fn distillate(index: Int, kind: String, text: String) -> memory.Distillate {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000 + index), seed: index))
  memory.Distillate(id:, seq: index, kind:, text:)
}

fn bare_hooks() -> effects.Hooks {
  effects.default_hooks()
}

fn byte_size(text: String) -> Int {
  notes.byte_size(text)
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
