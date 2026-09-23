//// Reviewer presentation retains accepted task identity through eviction,
//// while replacing live progress and receipt counts from each fresh cut.

import core/clock
import core/entry
import core/ids
import core/message
import core/register
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import tui
import tui/connection
import tui/frame
import tui/model as tui_model
import tui/protocol
import tui/reviewer_status
import tui/snapshot
import tui/snapshot_view
import tui/workspace

fn model() {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn fixture() {
  let prompt_id = ids.mint_entry(ids.generator(clock.fixed(1), 1)).0
  let op_id = ids.mint_op(ids.generator(clock.fixed(2), 2)).0
  let current = ids.op_id_to_string(op_id)
  let prompt =
    entry.MessageEntry(
      prompt_id,
      None,
      2,
      2,
      message.UserMessage(
        [
          message.UserText(
            "[task brief from main]\nReview queue delivery\n[end brief. This is a task]",
            None,
          ),
        ],
        2,
        None,
      ),
      False,
    )
  let meta =
    operation.Operation(
      op_id,
      "sub:queue",
      None,
      2,
      operation.RunIntent([prompt_id]),
    )
  let view =
    snapshot_view.View(
      [protocol.Strand("sub:queue", Some("sub:queue"), Some("assistant"))],
      dict.new(),
      dict.new(),
      dict.from_list([#("sub:queue", current)]),
      model().usage,
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      [
        snapshot_view.Cell(
          register.OpMeta,
          current,
          2,
          codec.encode_operation(meta),
        ),
      ],
      None,
      Some([
        snapshot_view.PendingInput(
          "input-1",
          "sub:queue",
          snapshot_view.Queue,
          "Also inspect reconnect",
          5,
          snapshot_view.ReadOnly,
        ),
      ]),
      None,
    )
  #(snapshot.Window([snapshot.Loaded(prompt, 100)], 100, None), view)
}

pub fn reviewer_task_survives_eviction_without_inventing_delivery_test() {
  let #(window, view) = fixture()
  let first = reviewer_status.observe([], window, view)
  let assert [row] = first as "the running reviewer has one row"
  assert row.task == "Review queue delivery"
  assert row.progress == "assistant"
  assert row.pending == "1 received, awaiting delivery"

  let updated =
    snapshot_view.View(..view, pending_inputs: Some([]), strands: [
      protocol.Strand("sub:queue", None, Some("checkpoint")),
    ])
  let assert [next] =
    reviewer_status.observe(first, snapshot.Window([], 0, None), updated)
    as "the same accepted task survives prompt eviction"
  assert next.task == row.task
  assert next.progress == "checkpoint"
  assert next.pending == "no pending input"

  let replaced =
    snapshot_view.View(
      ..updated,
      operations: dict.from_list([#("sub:queue", "successor")]),
    )
  let assert [successor] =
    reviewer_status.observe(first, snapshot.Window([], 0, None), replaced)
    as "a successor is still visible when its prompt is absent"
  assert successor.task == "task brief outside loaded history"
  assert !string.contains(successor.task, "Review queue")
}

pub fn reviewer_rows_remain_visible_beside_the_automatic_diff_test() {
  let #(window, view) = fixture()
  let initial =
    tui_model.Model(
      ..model(),
      reviewer_rows: reviewer_status.observe([], window, view),
      input: textarea.state_from_string("follow-up draft"),
    )
  let painted = tui.update(backend.Resize(160, 35), initial)
  let #(buffer, _) = tui.view(painted, geometry.rect_new(0, 0, 160, 35))
  let text = frame.buffer_to_text(buffer)
  assert string.contains(text, "Reviewer sub:queue")
  assert string.contains(text, "Task: Review queue delivery")
  assert string.contains(text, "1 received, awaiting delivery")
  assert painted.diff_view == tui_model.DiffAutomatic
  assert string.contains(text, "follow-up draft")
}

/// Reviewer completion replaces the two live rows with a truthful idle slot.
/// The composer title and cursor therefore stay fixed while no completed task
/// or running state survives the transition.
pub fn reviewer_completion_keeps_the_composer_fixed_test() {
  let #(window, view) = fixture()
  let live_rows =
    reviewer_status.observe([], window, view)
    |> list.map(fn(row) { reviewer_status.Row(..row, strand: "advisor") })
  let live =
    tui_model.Model(
      ..model(),
      strands: [protocol.Strand("advisor", Some("advisor"), Some("assistant"))],
      reviewer_rows: live_rows,
      input: textarea.state_from_string("follow-up draft"),
    )
    |> tui.update(backend.Resize(80, 24), _)
  let idle =
    tui_model.Model(
      ..live,
      strands: [protocol.Strand("advisor", Some("advisor"), None)],
      reviewer_rows: [],
      frame_cache: None,
    )
    |> tui.update(backend.Resize(80, 24), _)
  let #(live_buffer, live_cursor) =
    tui.view(live, geometry.rect_new(0, 0, 80, 24))
  let #(idle_buffer, idle_cursor) =
    tui.view(idle, geometry.rect_new(0, 0, 80, 24))
  let live_text = frame.buffer_to_text(live_buffer)
  let idle_text = frame.buffer_to_text(idle_buffer)
  let title_row = fn(text) {
    text
    |> string.split("\n")
    |> list.index_map(fn(line, index) { #(line, index) })
    |> list.find(fn(pair) { string.contains(pair.0, "To main") })
    |> result.map(fn(pair) { pair.1 })
  }
  let assert Ok(live_title) = title_row(live_text) as "live composer is visible"
  let assert Ok(idle_title) = title_row(idle_text) as "idle composer is visible"
  let assert Ok(_) = live_cursor as "the live editor has a cursor"
  assert live_title == idle_title
    as "reviewer completion moved the composer title"
  assert live_cursor == idle_cursor as "reviewer completion moved the cursor"
  assert string.contains(idle_text, "Advisor · idle")
  assert !string.contains(idle_text, "Review queue delivery")
    as "the idle slot retained a completed task"
}

pub fn no_advisor_does_not_reserve_an_idle_reviewer_slot_test() {
  let without = model() |> tui.update(backend.Resize(80, 24), _)
  let #(rendered, _) = tui.view(without, geometry.rect_new(0, 0, 80, 24))
  assert !string.contains(frame.buffer_to_text(rendered), "Advisor · idle")
}
