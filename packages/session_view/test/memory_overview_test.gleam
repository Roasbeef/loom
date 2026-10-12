//// The memory overview, as a client reads it: the board's total decoder, the
//// words both hosts use, the command, and what the shared record does with a
//// snapshot and a refusal (protocol-change/087).

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/event_fold
import session_view/inbox
import session_view/lane_fold
import session_view/memory_overview
import session_view/model.{type Shared} as session_model
import session_view/msg
import session_view/protocol
import session_view/session_channel
import session_view/step
import session_view/worktree_view

fn file(name: String, state: String, bytes: Int) -> json.JsonValue {
  json.Object([
    #("file", json.String(name)),
    #("state", json.String(state)),
    #("bytes", json.Int(bytes)),
  ])
}

fn note(title: String, legacy: Bool) -> json.JsonValue {
  json.Object([
    #("kind", json.String("fact")),
    #("date", json.String("2026-10-11")),
    #("title", json.String(title)),
    #("description", json.String("one line")),
    #("legacy", json.Bool(legacy)),
  ])
}

fn rule(id: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("approved", json.String("2026-10-09")),
    #("session", json.String("0198c0de-0000-7000-8000-000000000001")),
    #("line", json.String("Run make check before pushing.")),
  ])
}

fn ok(total: Int, omitted: Int, rows: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("state", json.String("ok")),
    #("total", json.Int(total)),
    #("omitted", json.Int(omitted)),
    #("rows", json.Array(rows)),
  ])
}

fn unavailable(reason: String) -> json.JsonValue {
  json.Object([
    #("state", json.String("unavailable")),
    #("reason", json.String(reason)),
  ])
}

fn board(
  notes: json.JsonValue,
  rules: json.JsonValue,
  receives: List(json.JsonValue),
) -> json.JsonValue {
  json.Object([
    #("inject", json.String("notes")),
    #("receives", json.Array(receives)),
    #("notes", notes),
    #("rules", rules),
    #(
      "proposals",
      json.Object([
        #("state", json.String("ok")),
        #("pending", json.Int(2)),
      ]),
    ),
  ])
}

fn typical() -> json.JsonValue {
  board(
    ok(2, 0, [note("Tabs", False), note("old words", True)]),
    ok(1, 0, [rule("prop-0123456789")]),
    [
      file("loom-rules.md", "injected", 900),
      file("loom-memory.notes", "injected", 112),
    ],
  )
}

fn snapshot_frame(board: json.JsonValue) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("reply_to", json.Int(9)),
      #("event", json.String("snapshot")),
      #(
        "body",
        json.Object([#("mode", json.String("memory")), #("board", board)]),
      ),
    ]),
  )
}

pub fn a_board_decodes_every_section_test() {
  let assert Ok(decoded) = memory_overview.decode(typical())
  assert decoded.inject == memory_overview.InjectsNotes
  assert decoded.proposals == memory_overview.Waiting(count: 2)
  let assert memory_overview.Listed(rows: [first, second], total: 2, omitted: 0) =
    decoded.notes
  assert first.title == "Tabs"
  assert first.typing == memory_overview.Typed
  assert second.typing == memory_overview.Legacy
  let assert memory_overview.Listed(rows: [only], total: 1, omitted: 0) =
    decoded.rules
  assert only.id == "prop-0123456789"
  assert only.line == "Run make check before pushing."
  let assert [rules_file, notes_file] = decoded.receives
  assert rules_file.reach == memory_overview.Injected
  assert notes_file.bytes == 112
}

pub fn the_tiles_count_and_never_turn_a_fault_into_zero_test() {
  let assert Ok(decoded) = memory_overview.decode(typical())
  assert memory_overview.tiles(decoded)
    == [
      #("notes", "2"),
      #("approved rules", "1"),
      #("pending proposals", "2"),
      #("injected", "1012 B"),
    ]
  let assert Ok(broken) =
    memory_overview.decode(
      board(unavailable("the store is damaged"), ok(0, 0, []), []),
    )
  assert memory_overview.tiles(broken)
    == [
      #("notes", "unavailable"),
      #("approved rules", "0"),
      #("pending proposals", "2"),
      #("injected", "0 B"),
    ]
}

pub fn an_unavailable_section_keeps_its_reason_and_is_not_empty_test() {
  let assert Ok(decoded) =
    memory_overview.decode(
      board(unavailable("the store is damaged"), unavailable("too big"), []),
    )
  assert decoded.notes
    == memory_overview.Unavailable(reason: "the store is damaged")
  assert decoded.rules == memory_overview.Unavailable(reason: "too big")
}

pub fn an_unknown_mode_and_state_are_kept_not_refused_test() {
  let assert json.Object(fields) = typical()
  let odd =
    json.Object(
      list.map(fields, fn(field) {
        case field.0 {
          "inject" -> #("inject", json.String("graph"))
          "receives" -> #("receives", json.Array([file("x.md", "frozen", 1)]))
          _ -> field
        }
      }),
    )
  let assert Ok(decoded) = memory_overview.decode(odd)
  assert decoded.inject == memory_overview.UnknownInject(mode: "graph")
  assert string.contains(
    memory_overview.inject_words(decoded),
    "unknown (graph)",
  )
  let assert [unknown] = decoded.receives
  assert unknown.reach == memory_overview.UnknownReach(state: "frozen")
  assert memory_overview.injected_bytes(decoded) == 0
}

pub fn a_malformed_board_is_an_error_and_never_a_crash_test() {
  list.each(
    [
      json.Null,
      json.Object([]),
      json.Array([]),
      json.String("board"),
      board(json.Null, ok(0, 0, []), []),
      board(ok(0, 0, []), json.String("x"), []),
      board(json.Object([#("state", json.String("ok"))]), ok(0, 0, []), []),
      board(ok(1, 0, [json.Null]), ok(0, 0, []), []),
      board(ok(1, 0, [note("t", False)]), ok(0, 0, []), [json.Int(1)]),
      board(ok(-1, 0, []), ok(0, 0, []), []),
    ],
    fn(bad) {
      assert memory_overview.decode(bad) |> result.is_error
    },
  )
}

pub fn a_longer_list_than_the_bound_is_cut_not_refused_test() {
  let rows = list.repeat(note("n", False), 70)
  let assert Ok(decoded) =
    memory_overview.decode(board(ok(70, 20, rows), ok(0, 0, []), []))
  let assert memory_overview.Listed(rows: kept, total: 70, omitted: 20) =
    decoded.notes
  assert list.length(kept) == memory_overview.row_limit
}

pub fn text_cannot_carry_a_terminal_escape_into_a_line_test() {
  let assert Ok(decoded) =
    memory_overview.decode(
      board(
        ok(1, 0, [note("one\u{1b}[31mtwo\nthree", False)]),
        ok(0, 0, []),
        [],
      ),
    )
  let assert memory_overview.Listed(rows: [hostile], ..) = decoded.notes
  assert !string.contains(hostile.title, "\u{1b}")
  assert !string.contains(hostile.title, "\n")
}

pub fn the_words_for_a_row_are_stable_test() {
  let assert Ok(decoded) = memory_overview.decode(typical())
  let assert memory_overview.Listed(rows: [typed, legacy], ..) = decoded.notes
  assert memory_overview.note_head(typed) == "fact · 2026-10-11"
  assert memory_overview.note_head(legacy) == "fact · 2026-10-11 · legacy"
  assert memory_overview.note_text(typed) == "Tabs: one line"
  let assert memory_overview.Listed(rows: [only], ..) = decoded.rules
  assert memory_overview.rule_head(only)
    == "prop-0123456789 · approved 2026-10-09 · session 0198c0de"
  assert memory_overview.inject_words(decoded) == "[memory] inject = notes"
  assert memory_overview.size_words(0) == "0 B"
  assert memory_overview.size_words(1023) == "1023 B"
  assert memory_overview.size_words(1536) == "1.5 KiB"
  assert memory_overview.omitted_words(0, "x") == ""
  assert memory_overview.omitted_words(3, memory_overview.notes_pointer)
    == "+3 more not shown; history_search kind=note finds them"
  assert memory_overview.proposals_words(memory_overview.Waiting(1), "Alt+p")
    == "1 proposal pending. Review it with Alt+p."
}

pub fn each_file_says_what_a_run_does_with_it_test() {
  let assert Ok(decoded) = memory_overview.decode(typical())
  let words = list.map(decoded.receives, memory_overview.receives_words)
  assert words
    == [
      "loom-rules.md (approved rules) · 900 B · every run reads it",
      "loom-memory.notes (notes index) · 112 B · every run reads it",
    ]
  assert memory_overview.receives_words(memory_overview.Receives(
      file: "loom-memory.notes",
      bytes: 0,
      reach: memory_overview.NotInjected,
    ))
    == "loom-memory.notes (notes index) · 0 B · not read, [memory] inject is off"
}

pub fn the_command_and_the_snapshot_are_the_wire_forms_test() {
  assert string.contains(protocol.memory_get(4), "\"cmd\":\"memory_get\"")
  let assert Ok(protocol.MemorySnapshot(decoded)) =
    protocol.decode_v2_presentation(snapshot_frame(typical()))
  assert memory_overview.note_total(decoded) == Some(2)
  assert protocol.decode_v2_presentation(snapshot_frame(json.Null))
    |> result.is_error
}

fn fresh() -> Shared(String, Nil, String, String) {
  step.new(
    "main",
    "session",
    msg.Stamp(1000, 1000),
    inbox.new("frames"),
    inbox.new("replay"),
  )
}

pub fn the_record_starts_with_no_board_and_no_read_owed_test() {
  let shared = fresh()
  assert shared.memory == None
  assert shared.memory_refresh == worktree_view.Settled
  assert shared.memory_notice == ""
  assert shared.memory_read_ms == None
  assert shared.memory_watch == session_model.NotWatchingMemory
}

pub fn a_snapshot_is_kept_and_clears_the_last_refusal_test() {
  let assert Ok(decoded) = memory_overview.decode(typical())
  let refused = session_model.Shared(..fresh(), memory_notice: "forbidden: no")
  let kept = event_fold.apply_event(refused, protocol.MemorySnapshot(decoded))
  assert kept.memory == Some(decoded)
  assert kept.memory_notice == ""
}

pub fn a_refused_read_is_worded_and_does_not_ask_again_test() {
  let refused =
    lane_fold.apply_channel_update(
      fresh(),
      session_channel.RequestRefused("memory_get", 3, "forbidden", "no"),
      lane_fold.nothing_shown(),
    )
  assert string.contains(refused.memory_notice, "owner")
  assert refused.memory_refresh == worktree_view.Settled
}

pub fn refusal_words_cover_each_code_and_pass_an_unknown_one_through_test() {
  assert string.contains(
    memory_overview.refusal_words("unsupported", ""),
    "no memory overview",
  )
  assert memory_overview.refusal_words("odd", "line\none") == "odd: line one"
}
