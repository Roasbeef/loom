//// Current note values are an auxiliary observation with explicit freshness.
//// The panel cannot relabel a stale run-start digest as a fresh read, nor
//// adopt inconsistent revisions or silently present an excerpt as complete.

import core/json
import core/message
import core/register
import etui/backend
import etui/geometry
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/notes_view
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import tui_test/gateway

fn board(revision, text, extent) {
  json.Object([
    #("strand", json.String("main")),
    #("as_of", json.Int(revision)),
    #("total", json.Int(2)),
    #(
      "notes",
      json.Array([
        json.Object([
          #("key", json.String("plan")),
          #("seq", json.Int(revision)),
          #("text", json.String(text)),
          #("extent", json.String(extent)),
        ]),
      ]),
    ),
  ])
}

fn delivered(model, raw) {
  let wire =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(1)),
        #("event", json.String("snapshot")),
        #(
          "body",
          json.Object([
            #("mode", json.String("notes")),
            #("board", raw),
          ]),
        ),
      ]),
    )
  let assert Ok(event) = protocol.decode_v2_presentation(wire)
    as "notes travel through the version-two auxiliary decoder"
  tui.apply_channel_update(model, session_channel.Auxiliary(event))
  |> fn(updated) { tui.update(backend.Resize(120, 30), updated) }
}

fn text(model) {
  let model = tui.update(backend.Tick, model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(buffer)
}

pub fn refreshed_notes_replace_values_and_show_revision_and_excerpt_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let first =
    delivered(
      tui.Model(..base, notes_open: True),
      board(10, "old plan", "complete"),
    )
  assert string.contains(text(first), "old plan")
  let second = delivered(first, board(20, "new plan", "excerpt"))
  let rendered = text(second)
  assert string.contains(rendered, "new plan")
  assert !string.contains(rendered, "old plan")
  assert string.contains(rendered, "read at revision 20")
  assert string.contains(rendered, "updated at revision 20 · excerpt")
  assert string.contains(rendered, "1 more notes")
}

pub fn malformed_note_freshness_is_rejected_before_adoption_test() {
  let assert json.Object(fields) = board(20, "value", "complete")
    as "the fixture is an object"
  let invalid =
    json.Object([
      #("as_of", json.Int(10)),
      ..{ list.filter(fields, fn(pair) { pair.0 != "as_of" }) }
    ])
  let assert Error(_) = notes_view.decode(invalid)
    as "a note cannot claim a write after its capture"
  let assert Error(_) =
    notes_view.decode(board(20, string.repeat("x", 4097), "complete"))
    as "an oversized value cannot enter the display unbounded"
}

pub fn structured_notes_render_paragraphs_and_keep_raw_inspection_test() {
  let raw =
    json.to_string(
      json.Object([
        #("status", json.String("Review complete")),
        #(
          "findings",
          json.Array([
            json.String("First finding\n\nSupporting evidence"),
            json.String("Second finding"),
          ]),
        ),
      ]),
    )
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let shown =
    delivered(tui.Model(..base, notes_open: True), board(20, raw, "complete"))
  let readable = text(shown)
  assert string.contains(readable, "Review complete")
  assert string.contains(readable, "Supporting evidence")
  assert string.contains(readable, "Second finding")
  assert !string.contains(readable, "\\n")
  let expanded = tui.update(backend.KeyPress("ctrl+g"), shown)
  assert string.contains(text(expanded), "\\n\\n")
    as "raw JSON remains available without replacing the stored note"
  assert expanded.note_board == shown.note_board
  assert notes_view.readable("{incomplete") == "{incomplete"
}

// A stale read and a note written before this turn are different facts. Only
// the accepted operation's revision can establish the latter relationship.
pub fn notes_distinguish_read_freshness_from_turn_age_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let view =
    snapshot_view.View(
      [],
      dict.new(),
      dict.new(),
      dict.from_list([#("main", "current")]),
      base.usage,
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      [snapshot_view.Cell(register.OpMeta, "current", 30, json.Null)],
      None,
      None,
      None,
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("session", "epoch", "incarnation"),
        "connection",
        message.Origin("owner", "Owner"),
        snapshot.Owner,
      ),
      41,
      json.Object([]),
      snapshot.Window([], 0, None),
      None,
    )
  let older =
    delivered(
      tui.Model(..base, notes_open: True, captured: Some(#(cut, view))),
      board(20, "Pending: inspect queue", "complete"),
    )
  assert string.contains(text(older), "Session advanced since this read")
  assert string.contains(text(older), "written before current turn")
  assert string.contains(text(older), "Pending: inspect queue")

  let fresh = delivered(older, board(40, "Done: inspected queue", "complete"))
  assert !string.contains(text(fresh), "Session advanced since this read")
  assert !string.contains(text(fresh), "written before current turn")
  assert !string.contains(text(fresh), "Pending: inspect queue")
  assert string.contains(text(fresh), "Done: inspected queue")
}

// Agent notes can carry structured JSON inside the tool's string value.
pub fn wrapped_note_objects_render_compact_hierarchy_test() {
  let document =
    json.Object([
      #("test_result", json.String("Passed")),
      #(
        "evidence",
        json.Object([
          #("parent_run", json.String("Expected failure")),
          #("fixed_run", json.String("Passed")),
        ]),
      ),
    ])
  let wrapped = json.String(json.to_string(document)) |> json.to_string
  let rendered = notes_view.readable(wrapped)
  assert rendered
    == "- **Test result**: Passed\n- **Evidence**\n  - **Parent run**: Expected failure\n  - **Fixed run**: Passed"
  assert notes_view.readable("\"ordinary prose\"") == "ordinary prose"
  assert notes_view.readable("{incomplete") == "{incomplete"
}

pub fn historical_digest_decodes_complete_cells_before_a_truncated_cell_test() {
  let payload =
    "progress = \"{\\\"done\\\":[\\\"Built modules\\\"]}\"\nenv = {\"status\":\"still working\"}\nbig = \"truncated\n[digest truncated at 4096 bytes]"
  let rendered = notes_view.historical(payload)
  assert string.contains(rendered, "### Progress")
  assert string.contains(rendered, "Built modules")
  assert !string.contains(rendered, "\\\"done")
  assert string.contains(rendered, "still working")
  assert string.contains(rendered, "Incomplete historical excerpt")
  assert string.contains(rendered, "[digest truncated at 4096 bytes]")
}

pub fn historical_notes_are_readable_compact_and_raw_after_detail_expansion_test() {
  let payload = "plan = {\"done\":[\"Built modules\"]}"
  let notes =
    "Your own notes for strand `main`\n\n```agent-notes\n" <> payload <> "\n```"
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.user_entry("main", notes, 1))
    as "the historical digest travels through the normal entry decoder"
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let compact = tui.Model(..base, notes_open: True, records: [record])
  assert string.contains(text(compact), "Built modules")
  assert !string.contains(text(compact), "{\"done\"")
  let expanded = tui.update(backend.KeyPress("ctrl+g"), compact)
  assert string.contains(
    text(expanded),
    "plan = {\"done\":[\"Built modules\"]}",
  )
}
