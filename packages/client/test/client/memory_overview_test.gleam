//// The memory overview: what a run is handed, the newest notes, the approved
//// rules, and the bounds that keep the board small (protocol-change/087).
////
//// Every store here is a real SQLite memory session and every file a real
//// file. The one thing that is scripted is the pending count, which the
//// queue's own tests own.

import client/memory
import client/memory_config
import client/memory_overview as overview
import client/proposals
import core/clock
import core/entry
import core/ids
import core/json
import core/tx.{InsertEntry, Tx}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/storage
import tools/remember

// --- the files a run receives ---------------------------------------------

/// A workspace with no memory yet is the ordinary first state: every file is
/// missing, both lists are empty and answered, and nothing is unavailable.
pub fn a_fresh_workspace_reports_missing_files_and_empty_lists_test() {
  let wiring = wiring_in(fresh_root("fresh"), notes_mode())
  let read = overview.read(wiring)
  assert read.notes == overview.Listed(rows: [], total: 0)
  assert read.rules == overview.Listed(rows: [], total: 0)
  assert read.waiting == overview.Waiting(count: 2)
  assert list.map(read.receives, fn(file) { #(file.file, file.reach) })
    == [
      #("loom-rules.md", overview.Missing),
      #("loom-memory.notes", overview.Missing),
    ]
}

/// The rules file is read into every new session whatever `inject` says. The
/// notes index is injected when `inject` names it, and `off` injects nothing
/// from the store.
pub fn the_injected_file_follows_the_inject_mode_test() {
  let root = fresh_root("modes")
  write(
    root,
    "loom-rules.md",
    "### Rule prop-0000000001 (approved 2026-10-11, from session s1)\n\nRun make check.\n",
  )
  write(root, "loom-memory.notes", "- (fact, 2026-10-11) Tabs: Use tabs")
  let reach = fn(mode) {
    overview.read(wiring_in(root, mode)).receives
    |> list.map(fn(file) { file.reach })
  }
  assert reach(notes_mode()) == [overview.Injected, overview.Injected]
  assert reach(off_mode()) == [overview.Injected, overview.NotInjected]
  let assert [rules, notes] =
    overview.read(wiring_in(root, notes_mode())).receives
  assert rules.bytes > 0
  assert notes.bytes == string.byte_size("- (fact, 2026-10-11) Tabs: Use tabs")
}

/// A file over the ceiling its reader refuses above is reported as unusable
/// and never read, so the pane says why a run is missing it.
pub fn an_oversize_file_is_unavailable_and_unread_test() {
  let root = fresh_root("oversize")
  write(
    root,
    "loom-memory.notes",
    string.repeat("n", memory.max_notes_sidecar_bytes + 1),
  )
  write(
    root,
    "loom-rules.md",
    string.repeat("r", proposals.max_rules_bytes + 1),
  )
  let read = overview.read(wiring_in(root, notes_mode()))
  let assert [rules, notes] = read.receives
  let assert overview.Unreadable(..) = rules.reach
  let assert overview.Unreadable(..) = notes.reach
  let assert overview.Unavailable(..) = read.rules
}

// --- the notes --------------------------------------------------------------

/// Notes are listed newest first with their kind, UTC date, title and
/// description, and an untyped note is marked legacy and titled by its words.
pub fn notes_are_listed_newest_first_and_a_legacy_note_is_marked_test() {
  let root = fresh_root("notes")
  let opened = open_store(root)
  insert(opened, 1_790_000_000_000, [
    #("text", json.String("body one")),
    #("title", json.String("First")),
    #("description", json.String("the first one")),
    #("kind", json.String("decision")),
  ])
  insert(opened, 1_790_100_000_000, [
    #("text", json.String("an old note written before types existed")),
  ])
  insert(opened, 1_790_200_000_000, [
    #("text", json.String("body three")),
    #("title", json.String("Third")),
    #("description", json.String("newest")),
    #("kind", json.String("feedback")),
  ])

  // The writer's lease is still held, which is the point: the read must not
  // need it.
  let read = overview.read(wiring_in(root, notes_mode()))
  memory.close(opened)

  let assert overview.Listed(rows:, total: 3) = read.notes
  assert list.map(rows, fn(note) { #(note.title, note.kind, note.typing) })
    == [
      #("Third", "feedback", overview.Typed),
      #("an old note written before types existed", "fact", overview.Legacy),
      #("First", "decision", overview.Typed),
    ]
  let assert [third, ..] = rows

  // The store stamps each entry with its own clock, which `open_store` fixes.
  assert third.date == "2026-09-21"
  assert third.description == "newest"
}

/// A store that cannot be read is `Unavailable` with a reason, never an empty
/// list, so a broken file does not read as "no notes".
pub fn an_unreadable_store_is_unavailable_and_not_empty_test() {
  let root = fresh_root("garbage")
  write(root, "loom-memory.db", "this is not a sqlite file at all")
  let read = overview.read(wiring_in(root, notes_mode()))
  let assert overview.Unavailable(reason:) = read.notes
  assert reason != ""
}

/// More than fifty notes list fifty, and the board says how many it left out.
pub fn the_list_is_bounded_and_the_board_counts_what_it_omits_test() {
  let root = fresh_root("bounded")
  let opened = open_store(root)
  list.each(numbers(60), fn(number) {
    insert(opened, 1_790_000_000_000 + number * 1000, [
      #("text", json.String("body")),
      #("title", json.String("note " <> int.to_string(number))),
      #("description", json.String("d")),
      #("kind", json.String("fact")),
    ])
  })
  memory.close(opened)
  let read = overview.read(wiring_in(root, notes_mode()))
  let assert overview.Listed(rows:, total: 60) = read.notes
  assert list.length(rows) == 50
  let assert [newest, ..] = rows
  assert newest.title == "note 60"
  let assert json.Object(fields) = overview.board(read)
  let assert Ok(json.Object(notes)) = list.key_find(fields, "notes")
  assert list.key_find(notes, "total") == Ok(json.Int(60))
  assert list.key_find(notes, "omitted") == Ok(json.Int(10))
}

/// Every string is clipped to its own limit with a mark, on one line.
pub fn strings_are_clipped_to_their_limits_test() {
  let root = fresh_root("clipped")
  let opened = open_store(root)
  insert(opened, 1_790_000_000_000, [
    #("text", json.String("body")),
    #("title", json.String(string.repeat("t", 200))),
    #("description", json.String("a\nb " <> string.repeat("d", 300))),
    #("kind", json.String("fact")),
  ])
  memory.close(opened)
  let assert overview.Listed(rows: [note], ..) =
    overview.read(wiring_in(root, notes_mode())).notes
  assert string.length(note.title) == overview.max_title_chars
  assert string.ends_with(note.title, "…")
  assert string.length(note.description) == overview.max_description_chars
  assert string.starts_with(note.description, "a b ")
}

/// Even rows of the widest text cannot push the encoded board past its byte
/// bound: the longer list is cut and the cut is counted, never silent.
pub fn the_encoded_board_never_exceeds_its_byte_bound_test() {
  let root = fresh_root("fits")
  let opened = open_store(root)
  let wide = fn(length) { string.repeat("𝔘", length) }
  list.each(numbers(60), fn(number) {
    insert(opened, 1_790_000_000_000 + number * 1000, [
      #("text", json.String("body")),
      #("title", json.String(wide(80))),
      #("description", json.String(wide(160))),
      #("kind", json.String("fact")),
    ])
  })
  memory.close(opened)
  let read = overview.read(wiring_in(root, notes_mode()))
  let board = overview.board(read)
  assert string.byte_size(json.to_string(board)) <= overview.max_board_bytes
  let assert json.Object(fields) = board
  let assert Ok(json.Object(notes)) = list.key_find(fields, "notes")
  let assert Ok(json.Array(rows)) = list.key_find(notes, "rows")
  let assert Ok(json.Int(omitted)) = list.key_find(notes, "omitted")
  assert list.key_find(notes, "total") == Ok(json.Int(60))
  assert omitted == 60 - list.length(rows)
  assert omitted > 10
}

// --- the rules --------------------------------------------------------------

/// The rules the headers name, newest first, each with its first line, and
/// text outside any header is not a rule.
pub fn rules_are_listed_from_their_headers_test() {
  let text =
    "stray text from a hand edit\n\n"
    <> "### Rule prop-0000000001 (approved 2026-10-01, from session 0198c0de-aaaa)\n\n"
    <> "Run make check.\nA second line.\n\n"
    <> "### Rule prop-0000000002 (approved 2026-10-09, from session 0198c0de-bbbb)\n\n"
    <> "\n  Never touch vendor/.\n"
  assert overview.rules_in(text)
    == [
      overview.Rule(
        id: "prop-0000000002",
        approved: "2026-10-09",
        session: "0198c0de-bbbb",
        line: "Never touch vendor/.",
      ),
      overview.Rule(
        id: "prop-0000000001",
        approved: "2026-10-01",
        session: "0198c0de-aaaa",
        line: "Run make check.",
      ),
    ]
}

/// A header that lacks its date or session still names its rule, and the
/// parser never fails on odd text.
pub fn a_damaged_header_is_read_leniently_test() {
  assert overview.rules_in("### Rule prop-3\nbody")
    == [overview.Rule(id: "prop-3", approved: "", session: "", line: "body")]
  assert overview.rules_in("") == []
  assert overview.rules_in("no headers here") == []
}

/// The rules file is read through the same reader the queue writes it with,
/// so a rule the queue appended is listed.
pub fn a_rule_the_queue_wrote_is_listed_test() {
  let root = fresh_root("rules")
  let current = proposals.rules("")
  let proposal =
    proposals.Proposal(
      id: "prop-0123456789",
      kind: proposals.Rule,
      target: proposals.rules_file,
      base_digest: proposals.rules_digest(current),
      old: "",
      new: "Run make check before pushing.",
      rationale: "it failed twice",
      source: proposals.Source(session: "0198c0de-0000", entry: None),
      created_ms: 0,
      state: proposals.Pending,
    )
  let assert Ok(text) = proposals.edited(current, proposal, 1_790_000_000_000)
  let assert Ok(Nil) = proposals.write_rules(root <> "/loom-rules.md", text)
  let read = overview.read(wiring_in(root, notes_mode()))
  assert read.rules
    == overview.Listed(
      rows: [
        overview.Rule(
          id: "prop-0123456789",
          approved: "2026-09-21",
          session: "0198c0de-0000",
          line: "Run make check before pushing.",
        ),
      ],
      total: 1,
    )
}

// --- the board --------------------------------------------------------------

/// The board names files and never a path, and carries the mode words, so a
/// client can say where each file lives without a directory leaking.
pub fn the_board_carries_names_and_no_paths_test() {
  let root = fresh_root("names")
  write(
    root,
    "loom-rules.md",
    "### Rule prop-1 (approved 2026-10-11, from session s)\nx\n",
  )
  let board = overview.board(overview.read(wiring_in(root, notes_mode())))
  let text = json.to_string(board)
  assert !string.contains(text, root)
  assert string.contains(text, "\"loom-rules.md\"")
  assert string.contains(text, "\"loom-memory.notes\"")
  let assert json.Object(fields) = board
  assert list.key_find(fields, "inject") == Ok(json.String("notes"))
  assert list.key_find(fields, "distill") == Error(Nil)
}

/// A pending count the queue could not give is unavailable, never zero.
pub fn an_unknown_pending_count_is_unavailable_not_zero_test() {
  let root = fresh_root("pending")
  let wiring =
    overview.Wiring(..wiring_in(root, notes_mode()), pending: fn() {
      Error("the queue is down")
    })
  assert overview.read(wiring).waiting
    == overview.WaitingUnavailable(reason: "the queue is down")
}

// --- support ----------------------------------------------------------------

// One through `count`, for a fixture that needs that many distinct rows.
fn numbers(count: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, count), fn(_, index) { index + 1 })
}

fn notes_mode() -> memory_config.Options {
  memory_config.default_options()
}

fn off_mode() -> memory_config.Options {
  memory_config.Options(inject: memory_config.InjectsNothing, retired: [])
}

fn wiring_in(root: String, mode: memory_config.Options) -> overview.Wiring {
  overview.Wiring(
    store_path: root <> "/loom-memory.db",
    notes_path: root <> "/loom-memory.notes",
    rules_path: root <> "/loom-rules.md",
    memory: mode,
    pending: fn() { Ok(2) },
  )
}

fn fresh_root(lane: String) -> String {
  let root = "build/test_db/memory-overview-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> root
}

fn write(root: String, file: String, body: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(root <> "/" <> file, body)
    as "the fixture file must be writable"
  Nil
}

// Opens the memory store the way `remember` does, so it carries an identity.
fn open_store(root: String) -> memory.Opened {
  let assert Ok(opened) =
    memory.open(
      path: root <> "/loom-memory.db",
      owner: "overview-test",
      lease_ttl_ms: memory.lease_ttl_ms,
      clock: clock.fixed(at: 1_790_000_000_000),
      generator: ids.generator(clock.fixed(at: 1_790_000_000_000), seed: 11),
    )
    as "the memory store must open"
  opened
}

// Commits one `memory/note` entry with exactly the payload given, which is
// how a legacy note is written.
fn insert(
  opened: memory.Opened,
  at_ms: Int,
  fields: List(#(String, json.JsonValue)),
) -> Nil {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: at_ms), seed: at_ms))
  let stored =
    entry.CustomEntry(
      id:,
      parent: None,
      seq: 0,
      ts: at_ms,
      custom_type: remember.note_type,
      data: Some(json.Object(fields)),
    )
  let assert Ok(_) =
    storage.commit(
      opened.session.store,
      Tx(writes: [InsertEntry(stored)], expected: []),
    )
    as "the note must commit"
  Nil
}
