//// The todo list in the whole frame. A settled `todo` call pins its board
//// between the conversation and the composer and stays one compact row in
//// the transcript; a failed call leaves the pinned board alone; another
//// session does not inherit it.

import core/codec
import core/entry
import core/json
import core/message
import core/todo_list.{Active, Board, Done, Pending, Phase, Task}
import etui/backend
import etui/geometry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/inbound
import tui/protocol
import tui/render
import tui/workspace
import tui_test/gateway

fn board() -> todo_list.Board {
  Board([
    Phase("Extract", [Task("Extract test units", Done)]),
    Phase("Judge", [
      Task("Pilot the questions", Done),
      Task("Judge every unit", Active),
      Task("Calibrate on the slow model", Pending),
    ]),
  ])
}

fn arguments() -> json.JsonValue {
  json.Object([
    #("op", json.String("done")),
    #("task", json.String("Pilot the questions")),
  ])
}

fn call(id: String, seq: Int) {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry("main", "todo", id, seq))
    as "the fixture is a valid tool-call entry"
  let assert entry.MessageEntry(message: body, ..) as placed = record.entry
    as "the fixture carries a message"
  let assert message.AssistantMessage(..) = body
    as "the fixture carries an assistant message"
  entry.MessageEntry(
    ..placed,
    message: message.AssistantMessage(..body, content: [
      message.AssistantToolCall(message.ToolCall(
        id,
        "todo",
        arguments(),
        None,
        None,
      )),
    ]),
  )
}

fn outcome(id: String, seq: Int, is_error: Bool, carried: todo_list.Board) {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry("main", "bash", "other", seq))
    as "the fixture supplies an entry envelope"
  let assert entry.MessageEntry(..) as placed = record.entry
    as "the fixture carries a message"
  entry.MessageEntry(
    ..placed,
    message: message.ToolResultMessage(
      tool_call_id: id,
      tool_name: "todo",
      content: [message.ToolResultText("2/4 closed", None)],
      details: Some(
        json.Object([
          #("op", json.String("done")),
          #("todo", todo_list.encode(carried)),
        ]),
      ),
      usage: None,
      added_tool_names: None,
      is_error:,
      timestamp: 0,
    ),
  )
}

fn received(model, value) {
  inbound.accept_connection_message(
    model,
    connection.Incoming(
      json.to_string(
        json.Object([
          #("v", json.Int(1)),
          #("event", json.String("entry")),
          #(
            "body",
            json.Object([
              #("strand", json.String("main")),
              #("entry", codec.encode_entry(value)),
            ]),
          ),
        ]),
      ),
    ),
  )
}

fn text(model) {
  let model = tui.update(backend.Resize(100, 30), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 100, 30))
  #(model, frame.buffer_to_text(buffer))
}

fn rows(text: String) -> List(String) {
  string.split(text, "\n")
}

fn index_of(rows: List(String), needle: String) -> Int {
  let assert Ok(#(index, _)) =
    rows
    |> list.index_map(fn(row, index) { #(index, row) })
    |> list.find(fn(entry) { string.contains(entry.1, needle) })
    as "the frame holds the row"
  index
}

fn base() {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

pub fn a_settled_call_pins_its_board_above_the_composer_test() {
  let #(_, frame) =
    base()
    |> received(call("t1", 1))
    |> received(outcome("t1", 2, False, board()))
    |> text
  let lines = rows(frame)

  // The panel carries the focused phase, its tasks, and the folded phase,
  // and it sits below the transcript row for the call that produced it.
  let header = index_of(lines, "TODO  Judge 1/3")
  assert index_of(lines, "✓ todo · done \"Pilot the questions\" · 2/4 done")
    < header
  assert index_of(lines, "▸ Judge every unit") == header + 2
  assert index_of(lines, "○ Calibrate on the slow model") == header + 3
  assert index_of(lines, "Extract ✓") == header + 4
  assert string.contains(frame, "2/4 done")
}

// The pending row is one row, and so is the settled one: the full board
// lives in the panel, not in the transcript.
pub fn the_transcript_row_stays_one_row_test() {
  let #(_, frame) =
    base()
    |> received(call("t1", 1))
    |> received(outcome("t1", 2, False, board()))
    |> text
  let lines = rows(frame)
  let row = index_of(lines, "✓ todo · done")
  let assert Ok(next) = list.first(list.drop(lines, row + 1))
    as "a row follows the call"
  assert !string.contains(next, "Judge every unit")
}

pub fn a_failed_call_leaves_the_pinned_board_test() {
  let later =
    Board([Phase("Other", [Task("A board the failure must not show", Active)])])
  let #(_, frame) =
    base()
    |> received(call("t1", 1))
    |> received(outcome("t1", 2, False, board()))
    |> received(call("t2", 3))
    |> received(outcome("t2", 4, True, later))
    |> text
  assert string.contains(frame, "TODO  Judge 1/3")
  assert !string.contains(frame, "A board the failure must not show")
}

pub fn no_board_draws_no_panel_test() {
  let #(_, frame) = base() |> text
  assert !string.contains(frame, "TODO ")
}
