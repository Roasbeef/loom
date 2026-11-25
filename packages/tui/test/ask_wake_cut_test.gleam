//// The capture path of the ask poll's wake: a cut applied through the shipped
//// channel update raises `Shared.newest_ask_seq` for an `ask` result in its
//// window, whatever strand wrote it and wherever the operator is reading.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/option.{None, Some}
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import tui
import tui/connection
import tui/inbound
import tui/model as tui_model
import tui/workspace

fn model() -> tui_model.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/work", None),
    fn() { 0 },
  )
}

fn result_item(tool: String, seq: Int) -> snapshot.Item {
  let id = ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
  snapshot.Loaded(core_entry(id, tool, seq), 0)
}

fn core_entry(id, tool: String, seq: Int) {
  entry.MessageEntry(
    id:,
    parent: None,
    seq:,
    ts: seq,
    message: message.ToolResultMessage(
      tool_call_id: "call",
      tool_name: tool,
      content: [message.ToolResultText("done", None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: seq,
    ),
    terminate: False,
  )
}

fn cut_with(
  model: tui_model.Model,
  items: List(snapshot.Item),
  next_seq: Int,
) -> tui_model.Model {
  let view =
    snapshot_view.View(
      strands: [],
      leaves: dict.new(),
      configurations: dict.new(),
      operations: dict.new(),
      usage: model.shared.usage,
      settings: snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      peers: [],
      cells: [],
      preview: None,
      pending_inputs: Some([]),
      tools: None,
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(model.shared.session, "epoch", "instance"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      next_seq,
      json.Object([]),
      snapshot.Window(items, 0, None),
      None,
    )
  inbound.apply_channel_update(
    model,
    session_channel.Captured(cut, view, session_channel.Notified),
  )
}

// The window holds every strand's records, and this fixture gives the active
// strand no leaf, so the result can only have been found in the window.
pub fn a_cut_with_an_ask_result_on_another_strand_raises_the_value_test() {
  let none = cut_with(model(), [result_item("fs_read", 3)], 4)
  assert none.shared.newest_ask_seq == 0

  let asked =
    cut_with(none, [result_item("ask", 5), result_item("fs_read", 3)], 6)
  assert asked.shared.newest_ask_seq == 5
}

// The value only rises, so a later cut that no longer holds the result, or a
// window that evicted it, cannot send it back to a value the board has seen.
pub fn the_value_never_falls_and_a_newer_ask_raises_it_again_test() {
  let first = cut_with(model(), [result_item("ask", 5)], 6)
  let later = cut_with(first, [result_item("fs_read", 8)], 9)
  assert later.shared.newest_ask_seq == 5

  let newer =
    cut_with(later, [result_item("ask", 11), result_item("fs_read", 8)], 12)
  assert newer.shared.newest_ask_seq == 11
}
