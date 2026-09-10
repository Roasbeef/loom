//// Current note values are an auxiliary observation with explicit freshness.
//// The panel cannot relabel a stale run-start digest as a fresh read, nor
//// adopt inconsistent revisions or silently present an excerpt as complete.

import core/json
import etui/backend
import etui/geometry
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/notes_view
import tui/protocol
import tui/session_channel
import tui/workspace

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
