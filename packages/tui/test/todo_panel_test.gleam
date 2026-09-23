//// The pinned todo panel: which board it takes from the transcript, how
//// many rows it asks for, and what those rows say. Rows are compared as
//// plain text, since the glyphs are what must survive a terminal without
//// color.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/todo_list.{
  type Board, Active, Blocked, Board, Done, Dropped, Pending, Phase, Task,
}
import etui/span
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import tui/notes_view
import tui/protocol
import tui/todo_panel

fn board() -> Board {
  Board([
    Phase("Extract", [
      Task("Extract test units", Done),
      Task("Build states", Done),
    ]),
    Phase("Judge", [
      Task("Pilot the questions", Done),
      Task("Judge every unit", Active),
      Task("Calibrate on the slow model", Pending),
    ]),
    Phase("Delete", [Task("Delete the purge set", Pending)]),
  ])
}

fn result(details: json.JsonValue, is_error: Bool) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call-1",
    tool_name: todo_panel.tool_name,
    content: [],
    details: Some(details),
    usage: None,
    added_tool_names: None,
    is_error:,
    timestamp: 0,
  )
}

fn carrying(board: Board) -> json.JsonValue {
  json.Object([
    #("op", json.String("done")),
    #("todo", todo_list.encode(board)),
  ])
}

fn rows(board: Board, width: Int, budget: Int) -> List(String) {
  todo_panel.lines(board, width, todo_panel.height(Some(board), budget))
  |> list.map(fn(line) {
    line.spans
    |> list.map(fn(each: span.Span) { each.content })
    |> string.concat
    |> string.trim_end
  })
}

fn record(strand: String, seed: Int, body: message.AgentMessage) {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at: 0), seed:))
  protocol.EntryRecord(
    strand:,
    entry: entry.MessageEntry(
      id:,
      parent: None,
      seq: seed,
      ts: 0,
      message: body,
      terminate: False,
    ),
  )
}

// Records arrive newest first, so the first board found is the newest; a
// failed call never replaces the board the strand already showed.
pub fn the_newest_successful_result_wins_test() {
  let first = Board([Phase("A", [Task("one", Active)])])
  let later = Board([Phase("A", [Task("one", Done)])])
  let failed = Board([Phase("B", [Task("two", Active)])])
  let records = [
    record("main", 4, result(carrying(failed), True)),
    record("main", 3, message.UserMessage([], 0, None)),
    record("main", 2, result(carrying(later), False)),
    record("main", 1, result(carrying(first), False)),
  ]
  assert todo_panel.newest(records) == Some(later)
  assert todo_panel.newest([]) == None
}

pub fn boards_are_remembered_per_strand_test() {
  let main = Board([Phase("A", [Task("main task", Active)])])
  let child = Board([Phase("B", [Task("child task", Active)])])
  let boards =
    todo_panel.remember(dict.new(), [
      record("sub:main/review", 2, result(carrying(child), False)),
      record("main", 1, result(carrying(main), False)),
    ])
  assert dict.get(boards, "main") == Ok(main)
  assert dict.get(boards, "sub:main/review") == Ok(child)

  // A later capture whose window no longer reaches the `todo` call keeps
  // the board the strand already had.
  let kept =
    todo_panel.remember(boards, [
      record("main", 9, message.UserMessage([], 0, None)),
    ])
  assert kept == boards
}

pub fn a_result_without_a_board_carries_nothing_test() {
  assert todo_panel.from_message(result(json.Object([]), False)) == None
  assert todo_panel.from_message(result(json.String("noise"), False)) == None
}

pub fn the_panel_shows_the_focused_phase_and_folds_the_rest_test() {
  assert rows(board(), 60, 8)
    == [
      "TODO  Judge 1/3                                     3/6 done",
      "  ✓ Pilot the questions",
      "  ▸ Judge every unit",
      "  ○ Calibrate on the slow model",
      "  Extract ✓ · Delete 0/1",
    ]
}

pub fn no_board_and_an_empty_board_take_no_rows_test() {
  assert todo_panel.height(None, 8) == 0
  assert todo_panel.height(Some(todo_list.empty()), 8) == 0
}

pub fn a_finished_board_is_one_row_test() {
  let finished =
    Board([
      Phase("A", [Task("a", Done), Task("b", Dropped)]),
      Phase("B", [Task("c", Done)]),
    ])
  assert rows(finished, 60, 8) == ["TODO ✓  all 3 tasks closed across 2 phases"]
}

pub fn a_blocked_task_shows_its_reason_test() {
  let blocked =
    Board([
      Phase("Ship", [
        Task("Wait for review", Blocked(Some("operator decision"))),
        Task("Tag the release", Pending),
      ]),
    ])
  assert list.contains(
    rows(blocked, 60, 8),
    "  ⊘ Wait for review · operator decision",
  )
}

// A phase longer than the budget is windowed around its active task, and
// the last row says how many tasks it left out.
pub fn a_long_phase_is_windowed_around_the_active_task_test() {
  let tasks =
    list.index_map(list.repeat(Nil, 12), fn(_, index) {
      Task("step " <> string.inspect(index), case index {
        8 -> Active
        _ if index < 8 -> Done
        _ -> Pending
      })
    })
  let long = Board([Phase("Long", tasks)])
  let shown = rows(long, 40, 6)
  assert list.length(shown) == 6
  assert list.contains(shown, "  ▸ step 8")
  assert list.contains(shown, "  ✓ step 7")
  let assert Ok(last) = list.last(shown) as "a last row"
  assert last == "  ⋯ 7 above · 1 below"
}

pub fn every_row_is_cut_to_the_width_test() {
  let wide =
    Board([Phase("P", [Task(string.repeat("word ", 30) <> "end", Active)])])
  rows(wide, 24, 8)
  |> list.each(fn(row) {
    assert string.length(row) <= 24
  })
}

pub fn a_transcript_row_names_what_the_call_changed_test() {
  assert todo_panel.call_summary(
      json.Object([
        #("op", json.String("done")),
        #("task", json.String("Judge every unit")),
      ]),
    )
    == "todo · done \"Judge every unit\""
  assert todo_panel.call_summary(
      json.Object([
        #("op", json.String("block")),
        #("phase", json.String("Delete")),
      ]),
    )
    == "todo · block phase \"Delete\""
  assert todo_panel.result_summary(carrying(board())) == Some("3/6 done")
}

fn notes(strand: String, rows: List(notes_view.Note)) -> notes_view.Board {
  notes_view.Board(strand:, as_of: 30, total: list.length(rows), notes: rows)
}

fn note(key: String, text: String, extent: notes_view.Extent) {
  notes_view.Note(key:, seq: 30, text:, extent:)
}

pub fn a_complete_todo_note_seeds_a_strand_without_a_board_test() {
  let text = json.to_string(todo_list.encode(board()))
  let seeded =
    todo_panel.seed(
      dict.new(),
      notes("main", [
        note("plan", "{}", notes_view.Complete),
        note("todo", text, notes_view.Complete),
      ]),
    )
  assert dict.get(seeded, "main") == Ok(board())
}

// The transcript's board is at least as new as any read, an excerpt is
// not a board, and a note under another key is not the todo cell.
pub fn a_seed_never_replaces_or_guesses_test() {
  let text = json.to_string(todo_list.encode(board()))
  let known =
    dict.from_list([#("main", Board([Phase("K", [Task("k", Active)])]))])
  assert todo_panel.seed(
      known,
      notes("main", [note("todo", text, notes_view.Complete)]),
    )
    == known
  assert todo_panel.seed(
      dict.new(),
      notes("main", [note("todo", string.drop_end(text, 5), notes_view.Excerpt)]),
    )
    == dict.new()
  assert todo_panel.seed(
      dict.new(),
      notes("main", [note("plan", text, notes_view.Complete)]),
    )
    == dict.new()
  assert todo_panel.seed(
      dict.new(),
      notes("main", [note("todo", "{\"phases\": 3}", notes_view.Complete)]),
    )
    == dict.new()
}

pub fn a_strand_is_asked_about_once_test() {
  assert todo_panel.needs_seed(dict.new(), set.new(), "main")
  assert !todo_panel.needs_seed(dict.new(), set.from_list(["main"]), "main")
  assert !todo_panel.needs_seed(
    dict.from_list([#("main", board())]),
    set.new(),
    "main",
  )
}

// A capture routinely holds several todo results for one strand; the
// panel must show the newest, and the records arrive newest first.
pub fn remember_keeps_the_newest_of_several_boards_for_a_strand_test() {
  let older = Board([Phase("A", [Task("x", Active)])])
  let newer = Board([Phase("A", [Task("x", Done)])])
  let boards =
    todo_panel.remember(dict.new(), [
      record("main", 20, result(carrying(newer), False)),
      record("main", 10, result(carrying(older), False)),
    ])
  assert dict.get(boards, "main") == Ok(newer)
}
