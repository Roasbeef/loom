//// Typed notes: how a note is stored and decoded, the index rendered from
//// them, the bounded read that injects it, and the search that finds it.
////
//// Every store here is a real SQLite memory session written through the
//// production `remember` tool. The only thing faked is the clock.

import broker/broker
import broker/exec
import broker/policy
import client/memory
import client/notes
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/effects
import session_view/composer
import simplifile
import storage/storage
import support/tool_registry
import telemetry/level
import telemetry/log
import tools/directory_access
import tools/remember
import tools/tool

// --- decoding ---------------------------------------------------------------

/// A note written before notes were typed is a plain string, and it still
/// decodes: a fact, titled with the first sixty characters of its text on
/// one line, with no description.
pub fn a_legacy_note_decodes_as_a_fact_titled_by_its_text_test() {
  let text = "first line\nsecond line " <> string.repeat("x", 100)
  let legacy =
    a_custom_entry(remember.note_type, 5, [#("text", json.String(text))])
  let assert Ok(note) = memory.note_of(legacy) as "a legacy note must decode"
  assert note.kind == remember.Fact
  assert note.description == ""
  assert note.text == text
  assert note.at_ms == 5
  assert string.length(note.title) == memory.legacy_title_chars
  assert string.starts_with(note.title, "first line second line xxx")
  assert !string.contains(note.title, "\n")
}

/// The decoder is total: an unknown kind is a fact, a title or description
/// with a newline in it is folded to one line, and what is not a note is
/// not one.
pub fn the_note_decoder_is_total_test() {
  let odd =
    a_custom_entry(remember.note_type, 1, [
      #("text", json.String("body")),
      #("title", json.String("two\nlines")),
      #("description", json.String("also\r\ntwo")),
      #("kind", json.String("lesson")),
    ])
  let assert Ok(note) = memory.note_of(odd) as "an odd payload must decode"
  assert note.kind == remember.Fact
  assert note.title == "two lines"
  assert note.description == "also two"

  let no_text =
    a_custom_entry(remember.note_type, 1, [#("title", json.String("t"))])
  assert memory.note_of(no_text) == Error(Nil)
  // A distillate row an older store may still hold is not a note.
  let other = a_custom_entry("memory/fact", 1, [#("text", json.String("t"))])
  assert memory.note_of(other) == Error(Nil)
}

/// A typed note survives the store: the entry carries every field, the
/// date is the entry's own timestamp, and `text` is the field the search
/// indexes.
pub fn a_typed_note_round_trips_through_the_store_test() {
  let root = fresh_root("round-trip")
  let outcome =
    dispatch(
      root,
      "Use CBOR",
      "wire format choice",
      "decision",
      "It is smaller.",
    )
  assert !outcome.is_error

  let assert [stored] = stored_notes(root) as "one note must have landed"
  assert stored.kind == remember.Decision
  assert stored.title == "Use CBOR"
  assert stored.description == "wire format choice"
  assert stored.text == "It is smaller."
  assert stored.at_ms >= 1_756_000_000_000
  assert stored.at_ms < 1_756_000_001_000
}

/// Title and description are redacted and judged after redaction, and a
/// refused field writes nothing and leaves no index.
pub fn the_fields_are_redacted_and_bounded_test() {
  let root = fresh_root("fields")
  let secret = "sk-ant-api03-abcdefghijkl"
  assert !dispatch(root, "key " <> secret, "d", "fact", "n").is_error
  let assert [stored] = stored_notes(root)
  assert !string.contains(stored.title, "sk-ant-api03")

  // Words rather than one long token, which redaction would itself replace.
  let long_title = dispatch(root, string.repeat("tt ", 27), "d", "fact", "n")
  assert long_title.is_error
  assert string.contains(text_of(long_title), "`title`")
  let long_description =
    dispatch(root, "t", string.repeat("dd ", 54), "fact", "n")
  assert long_description.is_error
  let two_lines = dispatch(root, "t", "one\ntwo", "fact", "n")
  assert two_lines.is_error
  assert string.contains(text_of(two_lines), "single line")
  let empty = dispatch(root, "  ", "d", "fact", "n")
  assert empty.is_error
  assert list.length(stored_notes(root)) == 1
}

// --- the index --------------------------------------------------------------

/// One line per note, newest first, in the documented form, dated in UTC.
pub fn the_index_lists_notes_newest_first_with_kind_and_date_test() {
  let body =
    memory.render_notes_index([
      stored(remember.Decision, "Use CBOR", "wire format", 1_791_720_000_000),
      stored(remember.Feedback, "Tabs", "", 1_791_547_200_000),
    ])
  assert body
    == "- (decision, 2026-10-11) Use CBOR: wire format\n"
    <> "- (feedback, 2026-10-09) Tabs"
  assert memory.render_notes_index([]) == ""
}

/// The index holds to its byte cap, drops the oldest notes to fit, and says
/// how many it dropped and which search finds them. The tail is inside the
/// cap, not on top of it.
pub fn the_index_is_capped_and_says_how_many_it_dropped_test() {
  let notes =
    list.repeat(Nil, 100)
    |> list.index_map(fn(_nothing, offset) {
      let index = offset + 1
      stored(
        remember.Fact,
        "note number " <> string.pad_start(string.inspect(index), 3, "0"),
        string.repeat("d", 100),
        1_791_720_000_000 - index,
      )
    })
  let body = memory.render_notes_index(notes)
  assert byte_size(body) <= memory.max_index_bytes

  let lines = string.split(body, "\n")
  let assert Ok(tail) = list.last(lines)
  let kept = list.length(lines) - 1
  assert string.starts_with(tail, "+")
  assert string.ends_with(
    tail,
    " more notes; history_search kind=note finds them",
  )
  assert tail
    == "+"
    <> string.inspect(100 - kept)
    <> " more notes; history_search kind=note finds them"
  // The newest notes are the ones kept.
  let assert [first, ..] = lines
  assert string.contains(first, "note number 001")
}

/// When every note fits there is no tail, and one note too big for the cap
/// is clipped rather than dropped, with no `+0` line after it.
pub fn the_index_has_no_tail_unless_notes_were_dropped_test() {
  let few = [
    stored(remember.Fact, "a", "b", 0),
    stored(remember.Fact, "c", "d", 0),
  ]
  assert !string.contains(memory.render_notes_index(few), "more notes")

  let huge =
    memory.render_notes_index([
      stored(remember.Fact, string.repeat("é", 80), string.repeat("é", 160), 0),
    ])
  assert byte_size(huge) <= memory.max_index_bytes
  assert !string.contains(huge, "more notes")
}

/// Redaction runs when the index is rendered too: the sidecar is a file and
/// what it holds is what a later run reads.
pub fn the_index_is_redacted_test() {
  let body =
    memory.render_notes_index([
      stored(remember.Fact, "key sk-ant-api03-abcdefghijkl", "d", 0),
    ])
  assert !string.contains(body, "sk-ant-api03")
}

/// A remembered note rewrites the index beside the store, atomically, from
/// the store alone: deleting the file and writing another note brings back
/// every note.
pub fn remembering_rebuilds_the_index_from_the_store_test() {
  let root = fresh_root("rebuild")
  let path = root <> "/loom-memory.notes"
  assert memory.notes_beside(root <> "/loom-memory.db") == path
  assert simplifile.is_file(path) == Ok(False)

  assert !dispatch(root, "First", "one", "fact", "n1").is_error
  assert !dispatch(root, "Second", "two", "decision", "n2").is_error
  let assert Ok(index) = simplifile.read(path) as "the index must exist"
  let assert [newest, oldest] = string.split(index, "\n")
  assert string.contains(newest, "(decision, 2025-08-24) Second: two")
  assert string.contains(oldest, "(fact, 2025-08-24) First: one")
  assert no_temp_files(root)

  let assert Ok(Nil) = simplifile.delete(path)
  assert !dispatch(root, "Third", "three", "feedback", "n3").is_error
  let assert Ok(rebuilt) = simplifile.read(path) as "the index must be rebuilt"
  assert list.length(string.split(rebuilt, "\n")) == 3
}

/// The commit is logged with the kind and the length of the title, and
/// nothing a reader could use to recover the note.
pub fn a_commit_logs_the_kind_and_the_title_length_only_test() {
  let root = fresh_root("log")
  let records = process.new_subject()
  let seam =
    memory.remember_seam(
      root <> "/loom-memory.db",
      clock: a_clock(),
      entropy: fn() { 99 },
      logger: log.new(sink: log.to_subject(records), threshold: level.Debug),
    )
  let assert Ok(Nil) =
    seam.remember(remember.Note(
      kind: remember.Decision,
      title: "Use CBOR",
      description: "a distinctive description",
      text: "a distinctive body",
    ))
    as "the note must be written"
  let assert Ok(record) = process.receive(records, within: 200)
    as "a commit must be logged"
  assert record.event == "memory.note_written"
  let shown = string.inspect(record)
  assert string.contains(shown, "decision")
  assert string.contains(shown, "title_chars")
  assert !string.contains(shown, "distinctive")
  assert !string.contains(shown, "Use CBOR")
}

// --- the read and the hook --------------------------------------------------

/// The index read is bounded: absent is nothing, a file
/// past the refusal bound is refused unread and said once, and a plausible
/// one is clipped to the index cap.
pub fn the_index_read_is_bounded_test() {
  let root = fresh_root("read")
  let path = root <> "/loom-memory.notes"
  assert memory.read_notes_index(path) == None

  let assert Ok(Nil) = simplifile.write(to: path, contents: "  \n ")
  assert memory.read_notes_index(path) == None

  let assert Ok(Nil) =
    simplifile.write(to: path, contents: string.repeat("z", 3000))
  let assert Some(clipped) = memory.read_notes_index(path)
  assert byte_size(clipped) <= memory.max_index_bytes

  let assert Ok(Nil) =
    simplifile.write(
      to: path,
      contents: string.repeat("z", memory.max_notes_sidecar_bytes + 1),
    )
  assert memory.read_notes_index(path) == None
  let records = process.new_subject()
  let reader =
    memory.notes_reader(
      path,
      log.new(sink: log.to_subject(records), threshold: level.Debug),
    )
  assert reader() == None
  let assert Ok(record) = process.receive(records, within: 200)
  assert record.event == "memory.notes_oversize"
}

/// The hook injects nothing without an index, and one attributed message
/// with it, fenced by its own fence; the attribution is built here, so a
/// body cannot close the fence or claim to be anyone.
pub fn the_notes_hook_injects_one_message_or_none_test() {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let absent =
    memory.notes_hooks(bare_hooks(), fn() { None }, clock.fixed(at: 5))
  assert absent.run_start(op) == []

  let body = "- (fact, 2026-10-11) a: b\n- (fact, 2026-10-10) c ``` d"
  let present =
    memory.notes_hooks(bare_hooks(), fn() { Some(body) }, clock.fixed(at: 5))
  let assert [message.UserMessage(content: [message.UserText(text:, ..)], ..)] =
    present.run_start(op)
    as "an index injects exactly one user message"
  assert string.starts_with(text, composer.notes_attribution_lead)
  assert string.contains(text, memory.notes_fence)
  assert !string.contains(text, composer.memory_fence)
  assert list.length(string.split(text, "```")) == 3
  assert composer.memory_context_lines(text) == Some(2)
  assert composer.transcript_text(text, False)
    == "memory context (2 lines)  [Ctrl+G to expand]"
}

// --- helpers ----------------------------------------------------------------

fn stored(
  kind: remember.Kind,
  title: String,
  description: String,
  at_ms: Int,
) -> memory.StoredNote {
  memory.StoredNote(kind:, title:, description:, text: "body", at_ms:)
}

fn a_custom_entry(
  custom_type: String,
  ts: Int,
  fields: List(#(String, json.JsonValue)),
) -> entry.Entry {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed: 1))
  entry.CustomEntry(
    id:,
    parent: None,
    seq: 0,
    ts:,
    custom_type:,
    data: Some(json.Object(fields)),
  )
}

fn bare_hooks() -> effects.Hooks {
  effects.default_hooks()
}

fn byte_size(text: String) -> Int {
  notes.byte_size(text)
}

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

fn fresh_root(lane: String) -> String {
  let root = "build/test_db/memory-notes-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> root
}

// The entropy is the title's own code points, so two notes written to one
// store by seams that each start from the same clock still mint distinct ids.
fn a_seam(path: String, seed: String) -> remember.Memory {
  memory.remember_seam(
    path,
    clock: a_clock(),
    entropy: fn() {
      list.fold(string.to_utf_codepoints(seed), 1, fn(sum, point) {
        { sum * 31 + string.utf_codepoint_to_int(point) } % 1_000_003
      })
    },
    logger: log.discard(),
  )
}

fn dispatch(
  root: String,
  title: String,
  description: String,
  kind: String,
  note: String,
) -> tool.ToolOutcome {
  tool.dispatch(
    tool_registry.built_in(
      None,
      None,
      None,
      Some(a_seam(root <> "/loom-memory.db", title <> note)),
      None,
    ),
    a_ctx(),
    remember.tool_name,
    json.Object([
      #("title", json.String(title)),
      #("description", json.String(description)),
      #("kind", json.String(kind)),
      #("note", json.String(note)),
    ]),
  )
}

fn stored_notes(root: String) -> List(memory.StoredNote) {
  let assert Ok(opened) =
    memory.open(
      path: root <> "/loom-memory.db",
      owner: "notes-test",
      lease_ttl_ms: memory.lease_ttl_ms,
      clock: a_clock(),
      generator: ids.generator(a_clock(), seed: 7),
    )
    as "the memory session must open for reading"
  let assert Ok(found) =
    storage.scan_entries(
      opened.session.store,
      storage.entry_scan()
        |> storage.entry_kind(storage.Custom)
        |> storage.entry_custom_type(remember.note_type),
    )
    as "the notes must scan"
  memory.close(opened)
  list.filter_map(found, memory.note_of)
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

fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-memory-notes-test"
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

// Each index write names its own temp file, so the check is that the
// directory holds none after the rename.
fn no_temp_files(directory: String) -> Bool {
  let assert Ok(names) = simplifile.read_directory(directory)
    as "the root must be readable"
  !list.any(names, string.ends_with(_, ".tmp"))
}
