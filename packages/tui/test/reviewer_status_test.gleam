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
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import tui
import tui/connection
import tui/frame
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
    tui.Model(
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
  assert painted.diff_view == tui.DiffAutomatic
  assert string.contains(text, "follow-up draft")
}
