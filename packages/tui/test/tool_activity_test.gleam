//// Compact history must preserve invocation identity and replace a cached
//// pending row when a later result arrives. The rendered panel is checked
//// through the same wire decoder and reducer as a live terminal.

import core/codec
import core/entry
import core/json
import core/message
import core/register
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/option.{None, Some}
import gleam/string
import machine/codec as machine_codec
import machine/operation
import machine/strand
import tui
import tui/connection
import tui/frame
import tui/protocol
import tui/snapshot_view
import tui/tool_activity
import tui/workspace
import tui_test/gateway

fn original(seq) {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry("main", "bash", "same", seq))
    as "the fixture is a valid entry"
  let assert entry.MessageEntry(message: body, ..) as placed = record.entry
    as "the fixture carries a message"
  #(placed, body)
}

fn call(seq, id, name, arguments) {
  let #(placed, body) = original(seq)
  let assert entry.MessageEntry(..) = placed as "the fixture is a message"
  let assert message.AssistantMessage(..) = body
    as "the fixture is an assistant"
  entry.MessageEntry(
    ..placed,
    message: message.AssistantMessage(..body, content: [
      message.AssistantToolCall(message.ToolCall(
        id,
        name,
        arguments,
        None,
        None,
      )),
    ]),
  )
}

fn outcome(seq, id, failed, details) {
  let #(placed, _) = original(seq)
  let assert entry.MessageEntry(..) = placed as "the fixture is a message"
  entry.MessageEntry(
    ..placed,
    message: message.ToolResultMessage(
      tool_call_id: id,
      tool_name: "fs_edit",
      content: [message.ToolResultText("completed", None)],
      details: details,
      usage: None,
      added_tool_names: None,
      is_error: failed,
      timestamp: 0,
    ),
  )
}

fn args() {
  json.Object([#("path", json.String("src/file.gleam"))])
}

pub fn parallel_results_match_ids_despite_repeated_arguments_test() {
  let a = call(1, "a", "fs_edit", args())
  let b = call(2, "b", "fs_edit", args())
  let rb = outcome(3, "b", False, None)
  let ra = outcome(4, "a", True, None)
  let assert [tool_activity.Tools([first, second])] =
    tool_activity.project([a, b, rb, ra])
    as "consecutive calls form one group"
  assert first.invocation.id == "a"
  assert second.invocation.id == "b"
  let assert Some(message.ToolResultMessage(
    tool_call_id: "a",
    is_error: True,
    ..,
  )) = first.outcome
    as "the failure belongs to call a"
  let assert Some(message.ToolResultMessage(
    tool_call_id: "b",
    is_error: False,
    ..,
  )) = second.outcome
    as "the success belongs to call b"
}

pub fn an_orphan_result_does_not_attach_to_a_same_named_call_test() {
  let a = call(1, "a", "fs_edit", args())
  let orphan = outcome(2, "old", True, None)
  let assert [tool_activity.Tools([pending]), tool_activity.Narrative(value)] =
    tool_activity.project([a, orphan])
    as "the orphan keeps its own entry"
  assert pending.outcome == None
  assert value == orphan
}

pub fn reused_provider_ids_never_replace_an_earlier_invocation_test() {
  let a = call(1, "reused", "fs_edit", args())
  let ra = outcome(2, "reused", True, None)
  let b = call(3, "reused", "fs_read", args())
  let rb = outcome(4, "reused", False, None)
  let assert [tool_activity.Tools([first]), tool_activity.Tools([second])] =
    tool_activity.project([a, ra, b, rb])
    as "id reuse starts a new group instead of overwriting history"
  assert first.invocation.name == "fs_edit"
  assert second.invocation.name == "fs_read"
  let assert Some(message.ToolResultMessage(is_error: True, ..)) = first.outcome
    as "the first invocation retains its failure"
  let assert Some(message.ToolResultMessage(is_error: False, ..)) =
    second.outcome
    as "the second invocation has its own result"
}

pub fn current_action_comes_from_the_captured_batch_not_an_old_unmatched_call_test() {
  let old = call(1, "old", "fs_edit", args())
  let current = call(2, "current", "fs_read", args())
  let batch =
    operation.ToolBatch(
      current.id,
      strand.StrandConfiguration(
        strand.ModelIdentity("test", "test"),
        strand.ThinkingOff,
        [],
      ),
      "step",
      [operation.CallEffectPending(0, current.id, operation.ReplaySafe)],
    )
  let settings =
    operation.RunSettings(
      operation.CompactionSettings(False, 0, 0),
      operation.ConsumeAll,
      operation.ConsumeAll,
      operation.Parallel,
    )
  let state =
    operation.RunState(
      operation.Running,
      settings,
      operation.Tools(batch),
      operation.Inbox([], [], []),
      Some(current.id),
    )
  let cells = [
    snapshot_view.Cell(
      register.OpState,
      "current-op",
      3,
      machine_codec.encode_state(state),
    ),
  ]
  let assert [active] =
    tool_activity.running(cells, [old, current], "current-op")
    as "only the captured effect-pending call is current"
  assert active.id == "current"
  assert tool_activity.running(cells, [old, current], "old-op") == []
  assert tool_activity.running(cells, [old], "current-op") == []
}

fn received(model, value) {
  tui.accept_connection_message(
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

fn painted(model) {
  let model = tui.update(backend.Resize(120, 40), model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, 120, 40))
  #(model, frame.buffer_to_text(buffer))
}

fn model() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui.Model(..base, transcript: [], records: [], notice: "fixture")
}

pub fn a_result_replaces_the_cached_pending_group_row_test() {
  let #(pending, before) =
    model() |> received(call(1, "a", "fs_edit", args())) |> painted
  assert string.contains(before, "awaiting result")
  let #(_, after) = pending |> received(outcome(2, "a", False, None)) |> painted
  assert string.contains(after, "tools · 1 call")
  assert !string.contains(after, "awaiting result")
  assert string.contains(after, "✓ fs_edit · src/file.gleam")
}

pub fn the_diff_panel_shows_only_successful_captured_edits_test() {
  let details =
    json.Object([
      #("path", json.String("src/file.gleam")),
      #(
        "diff",
        json.String(
          "--- a/src/file.gleam\n+++ b/src/file.gleam\n@@ -1 +1 @@\n-old\n+new",
        ),
      ),
    ])
  let model =
    model()
    |> received(call(1, "a", "fs_edit", args()))
    |> received(outcome(2, "a", False, Some(details)))
  let opened =
    tui.update(
      backend.KeyPress("enter"),
      tui.Model(..model, input: textarea.state_from_string("/diff")),
    )
  let #(opened, text) = painted(opened)
  assert opened.diff_view == tui.DiffVisible
  assert string.contains(text, "captured changes")
  assert string.contains(text, "-old")
  assert string.contains(text, "+new")
  assert !string.contains(text, "awaiting result")
  let closed = tui.update(backend.KeyPress("esc"), opened)
  assert closed.diff_view == tui.DiffHidden
  assert closed.interrupt == None
}
