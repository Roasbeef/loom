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
import gleam/dict
import gleam/int
import gleam/list
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

fn changes_model(diff) {
  let details =
    json.Object([
      #("path", json.String("src/file.gleam")),
      #("diff", json.String(diff)),
    ])
  model()
  |> tui.accept_connection_message(
    connection.Incoming(gateway.user_entry("main", "CONVERSATION_MARKER", 1)),
  )
  |> received(call(2, "edit", "fs_edit", args()))
  |> received(outcome(3, "edit", False, Some(details)))
}

fn toggle_diff(model) {
  tui.update(
    backend.KeyPress("enter"),
    tui.Model(..model, input: textarea.state_from_string("/diff")),
  )
}

fn painted_buffer(model, width) {
  let updated = tui.update(backend.Resize(width, 40), model)
  let #(drawn, _) = tui.view(updated, geometry.rect_new(0, 0, width, 40))
  #(updated, drawn)
}

fn columns(drawn, left, width) {
  int.range(0, 40, [], fn(rows, row) {
    [frame.row_text(drawn, left, row, width), ..rows]
  })
  |> list.reverse
  |> string.join("\n")
}

pub fn wide_diff_keeps_the_conversation_visible_on_the_left_test() {
  let #(opened, drawn) =
    changes_model("--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new")
    |> toggle_diff
    |> painted_buffer(160)
  let left = columns(drawn, 0, 88)
  let right = columns(drawn, 88, 72)
  assert string.contains(left, "transcript / main")
  assert string.contains(left, "CONVERSATION_MARKER")
  assert string.contains(right, "captured changes")
  assert string.contains(right, "+new")
  assert !string.contains(right, "CONVERSATION_MARKER")

  // Copy selection is clipped to the pane, rather than spanning the live
  // conversation and unrelated diff cells on the same terminal row.
  let right_area = tui.hit_area(opened, geometry.Position(100, 10))
  assert right_area.position.x == 89
  assert right_area.size.width == 70
}

pub fn diff_resize_uses_one_panel_below_the_readable_split_width_test() {
  let #(wide, _) =
    changes_model("-old\n+new") |> toggle_diff |> painted_buffer(140)
  let #(narrow, single) = painted_buffer(wide, 139)
  let text = frame.buffer_to_text(single)
  assert string.contains(text, "captured changes")
  assert !string.contains(text, "CONVERSATION_MARKER")
  let #(restored, split) = painted_buffer(narrow, 160)
  assert string.contains(columns(split, 0, 88), "CONVERSATION_MARKER")
  assert string.contains(columns(split, 88, 72), "+new")
  assert restored.diff_view == tui.DiffVisible
}

pub fn diff_and_conversation_scroll_independently_test() {
  let long_diff =
    int.range(1, 101, [], fn(rows, index) {
      ["+changed line " <> int.to_string(index), ..rows]
    })
    |> list.reverse
    |> string.join("\n")
  let #(opened, _) =
    int.range(4, 64, changes_model(long_diff), fn(current, seq) {
      tui.accept_connection_message(
        current,
        connection.Incoming(gateway.user_entry(
          "main",
          "older conversation",
          seq,
        )),
      )
    })
    |> toggle_diff
    |> painted_buffer(160)
  assert opened.rendered_row_count > 40
    as "both panes must contain enough rows to exercise independent scrolling"
  let right = tui.update(backend.MouseScroll(100, 10, True), opened)
  assert right.diff_scroll_offset == 3
  assert right.scroll_offset == opened.scroll_offset
  let left = tui.update(backend.MouseScroll(10, 10, True), right)
  assert left.scroll_offset == 3
  assert left.diff_scroll_offset == right.diff_scroll_offset
  let paged = tui.update(backend.KeyPress("pageup"), left)
  assert paged.diff_scroll_offset == left.diff_scroll_offset
  assert paged.scroll_offset > left.scroll_offset
  let focused = tui.update(backend.KeyPress("ctrl+d"), paged)
  let patch_paged = tui.update(backend.KeyPress("pageup"), focused)
  assert patch_paged.diff_scroll_offset > focused.diff_scroll_offset
  assert patch_paged.scroll_offset == paged.scroll_offset
  let closed = tui.update(backend.KeyPress("esc"), patch_paged)
  assert closed.diff_view == tui.DiffHidden
  assert closed.scroll_offset == paged.scroll_offset
  assert closed.diff_rows == []
  assert dict.is_empty(closed.diff_line_cache)
}

pub fn replacement_history_releases_the_open_diffs_old_layout_test() {
  let #(opened, _) =
    changes_model("-old\n+DISCARDED_DIFF_MARKER")
    |> toggle_diff
    |> painted_buffer(160)
  let #(replaced, drawn) =
    opened
    |> tui.accept_connection_message(
      connection.Incoming(gateway.full_snapshot("new")),
    )
    |> painted_buffer(160)
  assert !string.contains(frame.buffer_to_text(drawn), "DISCARDED_DIFF_MARKER")
  assert !list.any(dict.keys(replaced.diff_line_cache), fn(line) {
    string.contains(line.text, "DISCARDED_DIFF_MARKER")
  })
    as "replacement history cannot keep the old diff reachable through layout hints"
}

pub fn an_open_diff_keeps_up_with_new_captured_edits_test() {
  let #(opened, _) =
    changes_model("-old\n+new") |> toggle_diff |> painted_buffer(160)
  let details =
    json.Object([
      #("path", json.String("src/second.gleam")),
      #("diff", json.String("-second old\n+SECOND_EDIT_MARKER")),
    ])
  let #(updated, drawn) =
    opened
    |> received(call(4, "second", "fs_edit", args()))
    |> received(outcome(5, "second", False, Some(details)))
    |> painted_buffer(160)
  assert updated.diff_view == tui.DiffVisible
  assert string.contains(columns(drawn, 88, 72), "SECOND_EDIT_MARKER")
  assert string.contains(columns(drawn, 0, 88), "CONVERSATION_MARKER")
}

pub fn diff_toggle_restores_the_agent_rail_preference_test() {
  let base = tui.Model(..changes_model("-old\n+new"), agent_rail_visible: True)
  let #(opened, _) = base |> toggle_diff |> painted_buffer(160)
  assert opened.agent_rail_visible
  assert tui.hit_area(opened, geometry.Position(100, 10)).position.x == 89
  let #(closed, _) = opened |> toggle_diff |> painted_buffer(160)
  assert closed.diff_view == tui.DiffHidden
  assert closed.agent_rail_visible
  assert tui.hit_area(closed, geometry.Position(140, 10)).position.x == 127
}

pub fn compact_history_keeps_reasoning_between_tool_batches_test() {
  let #(placed, body) = original(3)
  let assert entry.MessageEntry(..) = placed as "the fixture is a message"
  let assert message.AssistantMessage(..) = body
    as "the fixture is an assistant"
  let reasoning =
    entry.MessageEntry(
      ..placed,
      message: message.AssistantMessage(..body, content: [
        message.AssistantThinking("REASONING_BETWEEN_BATCHES", None, False),
      ]),
    )
  let records = [
    call(1, "first", "bash", args()),
    outcome(2, "first", False, None),
    reasoning,
    call(4, "second", "bash", args()),
  ]
  let projected = tool_activity.project(records)
  assert list.any(projected, fn(item) {
    case item {
      tool_activity.Narrative(value) -> value.id == reasoning.id
      tool_activity.Tools(_) -> False
    }
  })
  let #(rendered, text) = list.fold(records, model(), received) |> painted
  assert !rendered.details_expanded
  assert string.contains(text, "REASONING_BETWEEN_BATCHES")
}

pub fn calls_in_one_response_keep_distinct_anchors_in_both_detail_modes_test() {
  let #(placed, body) = original(1)
  let assert entry.MessageEntry(..) = placed
    as "the fixture owns one durable response"
  let assert message.AssistantMessage(..) = body
    as "the fixture contains assistant blocks"
  let content =
    list.repeat(Nil, 40)
    |> list.index_map(fn(_, index) {
      message.AssistantToolCall(message.ToolCall(
        int.to_string(index),
        "bash",
        args(),
        None,
        None,
      ))
    })
  let entry =
    entry.MessageEntry(
      ..placed,
      message: message.AssistantMessage(..body, content:),
    )
  let #(live, _) = model() |> received(entry) |> painted
  assert live.rendered_anchors == []
    as "Following live output does no scroll-anchor projection."
  let compact = tui.update(backend.KeyPress("pageup"), live)
  assert compact.scroll_offset > 0
    as "The first history gesture captures the source anchors."
  let keys = fn(model: tui.Model) {
    model.rendered_anchors
    |> list.filter_map(fn(row) {
      case row {
        Some(row) -> Ok(row.entry)
        None -> Error(Nil)
      }
    })
    |> list.unique
    |> list.sort(string.compare)
  }
  assert list.length(keys(compact)) == 40
    as "identical arguments do not collapse distinct calls within one response"
  let #(expanded, _) =
    tui.update(backend.KeyPress("ctrl+g"), compact) |> painted
  assert keys(expanded) == keys(compact)
    as "detail mode retains the same durable call identities"
}

pub fn replacement_history_releases_compact_presentation_caches_test() {
  let #(loaded, _) =
    model()
    |> received(call(1, "old-call", "fs_edit", args()))
    |> received(outcome(2, "old-call", False, None))
    |> received(outcome(3, "orphan", True, None))
    |> painted
  assert !dict.is_empty(loaded.compact_call_cache)
  assert !dict.is_empty(loaded.compact_entry_cache)

  // The new capture supplies no old entries. Neither presentation cache may
  // keep their tool output reachable after the authoritative replacement.
  let #(replaced, _) =
    loaded
    |> tui.accept_connection_message(
      connection.Incoming(gateway.full_snapshot("replacement")),
    )
    |> painted
  assert dict.is_empty(replaced.compact_call_cache)
  assert dict.is_empty(replaced.compact_entry_cache)
}

// Receiving the successful result must replace the cached pending row with a
// patch in ordinary transcript mode, without opening the separate diff pane.
pub fn successful_edits_show_inline_patches_in_compact_history_test() {
  let details =
    Some(json.Object([#("diff", json.String("-\told\n+\tnew\n ```"))]))
  let #(pending, _) =
    model() |> received(call(1, "edit", "fs_edit", args())) |> painted
  let #(completed, visible) =
    pending
    |> received(outcome(2, "edit", False, details))
    |> painted
  assert !completed.details_expanded
  assert completed.diff_view == tui.DiffAutomatic
  assert string.contains(visible, "✓ fs_edit · src/file.gleam")
  assert string.contains(visible, "-    old")
  assert string.contains(visible, "+    new")
  assert string.contains(visible, "```")
  assert !string.contains(visible, "awaiting result")
  let #(_, failed) =
    model()
    |> received(call(1, "edit", "fs_edit", args()))
    |> received(outcome(2, "edit", True, details))
    |> painted
  assert !string.contains(failed, "+    new")
}

pub fn compact_inline_patch_is_bounded_and_expansion_reveals_the_rest_test() {
  let patch = string.repeat("+preview row\n", 25) <> "+FULL_PATCH_END"
  let details = Some(json.Object([#("diff", json.String(patch))]))
  let #(compact, visible) =
    model()
    |> received(call(1, "edit", "fs_edit", args()))
    |> received(outcome(2, "edit", False, details))
    |> painted
  assert string.contains(visible, "+preview row")
  assert !string.contains(visible, "FULL_PATCH_END")
  let #(_, expanded) =
    compact |> tui.update(backend.KeyPress("ctrl+g"), _) |> painted
  assert string.contains(expanded, "FULL_PATCH_END")
}

// Pasted source travels through the user-message renderer, not Markdown code
// rendering. Display normalization must preserve its stanzas and indentation.
pub fn pasted_user_code_preserves_tabs_and_blank_lines_test() {
  let source =
    "Please review:\n\n\tif peer == nil {\n\t\treturn\n\t}\n\n\tcontinueWork()"
  let original =
    model()
    |> tui.accept_connection_message(
      connection.Incoming(gateway.user_entry("main", source, 1)),
    )
  let #(_, visible) = painted(original)
  assert string.contains(visible, "       if peer == nil {")
  assert string.contains(visible, "           return")
  assert string.contains(visible, "       continueWork()")
  assert !string.contains(visible, "�")
  let rows =
    visible
    |> string.split("\n")
    |> list.index_map(fn(line, index) { #(index, line) })
  let assert Ok(#(closing, _)) =
    list.find(rows, fn(row) { string.contains(row.1, "       }") })
    as "the pasted closing brace has its own row"
  let assert Ok(#(continuation, _)) =
    list.find(rows, fn(row) { string.contains(row.1, "       continueWork()") })
    as "the next stanza is visible"
  assert continuation == closing + 2
}

pub fn collapsing_a_long_result_keeps_its_call_visible_at_video_dimensions_test() {
  let populated =
    list.fold(
      list.index_map(list.repeat(Nil, 100), fn(_, index) { index + 1 }),
      model(),
      fn(state, index) {
        let key = "call-" <> int.to_string(index)
        let result = outcome(index * 2, key, False, None)
        let assert entry.MessageEntry(
          message: message.ToolResultMessage(..) as body,
          ..,
        ) = result
          as "the fixture owns a tool result"
        let result = case index {
          50 ->
            entry.MessageEntry(
              ..result,
              message: message.ToolResultMessage(..body, content: [
                message.ToolResultText(
                  string.repeat("long output line\n", 160),
                  None,
                ),
              ]),
            )
          _ -> result
        }
        state
        |> received(call(index * 2 - 1, key, "fs_edit", args()))
        |> received(result)
      },
    )
  let expanded =
    populated
    |> tui.update(backend.Resize(170, 104), _)
    |> tui.update(backend.KeyPress("ctrl+g"), _)
    |> tui.update(backend.MouseScroll(5, 5, True), _)
  let height = tui.hit_area(expanded, geometry.Position(5, 5)).size.height
  let prefix =
    expanded.rendered_row_count - list.length(expanded.rendered_anchors)
  let assert Ok(#(_, index)) =
    expanded.rendered_anchors
    |> list.index_map(fn(row, index) { #(row, index) })
    |> list.find(fn(pair) {
      case pair.0 {
        Some(row) ->
          string.ends_with(row.entry, "/call/call-50") && row.wrapped == 80
        None -> False
      }
    })
    as "expanded output shares the compact invocation's durable identity"
  let reading =
    tui.Model(..expanded, scroll_offset: prefix + index - height + 1)
  let compact = tui.update(backend.KeyPress("ctrl+g"), reading)
  let offset =
    compact.rendered_row_count - list.length(compact.rendered_anchors)
  let visible =
    compact.rendered_anchors
    |> list.index_map(fn(row, index) { #(row, offset + index) })
    |> list.filter(fn(pair) {
      pair.1 >= compact.scroll_offset && pair.1 < compact.scroll_offset + height
    })
  assert list.any(visible, fn(pair) {
    case pair.0 {
      Some(row) -> string.ends_with(row.entry, "/call/call-50")
      None -> False
    }
  })
    as "Ctrl+g retains the call whose long output the reader was inspecting"
}
