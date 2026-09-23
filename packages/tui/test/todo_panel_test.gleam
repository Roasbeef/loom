//// The pinned todo panel: which board it takes from the transcript, how
//// many rows it asks for, and what those rows say. Rows are compared as
//// plain text, since the glyphs are what must survive a terminal without
//// color.

import core/json
import core/message
import core/todo_list.{
  type Board, Active, Blocked, Board, Done, Dropped, Pending, Phase, Task,
}
import etui/span
import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

pub fn the_latest_successful_result_wins_test() {
  let first = Board([Phase("A", [Task("one", Active)])])
  let failed = Board([Phase("B", [Task("two", Active)])])
  let messages = [
    result(carrying(first), False),
    result(carrying(failed), True),
    message.UserMessage([], 0, None),
  ]
  assert todo_panel.latest(messages, None) == Some(first)
  assert todo_panel.latest([], Some(first)) == Some(first)
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
  assert last == "  ⋯ 8 more in this phase"
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
