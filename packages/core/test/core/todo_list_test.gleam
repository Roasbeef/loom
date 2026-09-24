//// Todo board tests pin the stored shape, the total decoder, and the
//// bounds every written board is held to.

import core/corruption
import core/json
import core/todo_list.{
  Active, Blocked, Board, Done, Dropped, Pending, Phase, Task,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn sample() -> todo_list.Board {
  Board([
    Phase("Extract", [
      Task("Extract test units", Done),
      Task("Build judge states", Dropped),
    ]),
    Phase("Judge", [
      Task("Pilot the questions", Active),
      Task("Judge every unit", Blocked(Some("waiting on the operator"))),
      Task("Calibrate on the slow model", Blocked(None)),
      Task("Graph the calibration", Pending),
    ]),
  ])
}

pub fn a_board_round_trips_through_its_codec_test() {
  assert todo_list.decode(todo_list.encode(sample())) == Ok(sample())
}

pub fn a_board_round_trips_through_json_text_test() {
  let text = json.to_string(todo_list.encode(sample()))
  let assert Ok(value) = json.parse(text) as "an encoded board is valid JSON"
  assert todo_list.decode(value) == Ok(sample())
}

// Only a blocked task with a reason carries a third field, so the stored
// form of an ordinary task stays as small as the digest needs it to be.
pub fn only_a_reasoned_block_carries_a_reason_field_test() {
  let text = json.to_string(todo_list.encode(sample()))
  assert string.contains(text, "\"reason\":\"waiting on the operator\"")
  assert list.length(string.split(text, "\"reason\"")) == 2
}

pub fn decode_refuses_what_is_not_a_board_test() {
  let assert Error(_) = todo_list.decode(json.String("a board"))
  let assert Error(_) = todo_list.decode(json.Object([]))
  let assert Error(_) =
    todo_list.decode(
      json.Object([
        #("phases", json.Array([json.Object([#("name", json.Int(1))])])),
      ]),
    )
  let assert Error(reason) =
    todo_list.decode(
      json.Object([
        #(
          "phases",
          json.Array([
            json.Object([
              #("name", json.String("P")),
              #(
                "tasks",
                json.Array([
                  json.Object([
                    #("text", json.String("a")),
                    #("status", json.String("in_progress")),
                  ]),
                ]),
              ),
            ]),
          ]),
        ),
      ]),
    )
  assert string.contains(corruption.describe(reason), "in_progress")
}

pub fn counts_treat_a_dropped_task_as_closed_test() {
  assert todo_list.count(sample()) == #(2, 6)
  assert todo_list.count(todo_list.empty()) == #(0, 0)
}

pub fn active_and_focus_name_the_working_phase_test() {
  let assert Some(#(phase, task)) = todo_list.active(sample())
    as "the sample has an active task"
  assert phase.name == "Judge"
  assert task.text == "Pilot the questions"
  let assert Some(focus) = todo_list.focus(sample()) as "a focused phase"
  assert focus.name == "Judge"
}

// A board whose open work is all blocked has no active task, and the
// phase holding the blocked work is still the one to show.
pub fn focus_falls_back_to_the_first_phase_with_open_work_test() {
  let board =
    Board([
      Phase("Done", [Task("a", Done)]),
      Phase("Stuck", [Task("b", Blocked(None))]),
    ])
  assert todo_list.active(board) == None
  let assert Some(focus) = todo_list.focus(board) as "a focused phase"
  assert focus.name == "Stuck"
}

pub fn focus_on_a_finished_board_is_its_last_phase_test() {
  let board =
    Board([Phase("One", [Task("a", Done)]), Phase("Two", [Task("b", Done)])])
  let assert Some(focus) = todo_list.focus(board) as "a focused phase"
  assert focus.name == "Two"
  assert todo_list.focus(todo_list.empty()) == None
}

pub fn validate_refuses_duplicate_names_test() {
  let assert Error(reason) =
    todo_list.validate(
      Board([
        Phase("P", [Task("same", Pending)]),
        Phase("Q", [Task("same", Done)]),
      ]),
    )
  assert string.contains(reason, "duplicate task \"same\"")
  let assert Error(reason) =
    todo_list.validate(Board([Phase("P", []), Phase("P", [])]))
  assert string.contains(reason, "duplicate phase")
}

pub fn validate_refuses_blank_and_oversized_text_test() {
  let assert Error(_) =
    todo_list.validate(Board([Phase("P", [Task("   ", Pending)])]))
  let assert Error(_) =
    todo_list.validate(
      Board([
        Phase("P", [
          Task(string.repeat("x", todo_list.max_text_bytes + 1), Pending),
        ]),
      ]),
    )
  let assert Ok(_) =
    todo_list.validate(
      Board([
        Phase("P", [Task(string.repeat("x", todo_list.max_text_bytes), Pending)]),
      ]),
    )
    as "text at the bound is accepted"
}

pub fn validate_bounds_the_task_count_test() {
  let tasks = fn(count) {
    list.repeat(Nil, count)
    |> list.index_map(fn(_, index) {
      Task("task " <> string.inspect(index), Pending)
    })
  }
  let assert Ok(_) =
    todo_list.validate(Board([Phase("P", tasks(todo_list.max_tasks))]))
    as "a board at the task bound is accepted"
  let assert Error(_) =
    todo_list.validate(Board([Phase("P", tasks(todo_list.max_tasks + 1))]))
}
