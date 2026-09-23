//// Agent notes are an inspected strand's notebook, not a second composer.
//// These tests drive the workspace reducer and the auxiliary notes event so
//// target identity, selection identity, and surface ownership stay visible.

import core/json
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/model as tui_model
import tui/notes_view
import tui/protocol
import tui/render
import tui/session_channel
import tui/workspace
import tui_test/gateway

fn model() {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn roster() {
  [
    protocol.Strand("main", Some("main"), None),
    protocol.Strand("worker", Some("worker"), Some("assistant")),
  ]
}

fn board(strand, notes) {
  notes_view.Board(strand, 20, list.length(notes), notes)
}

fn note(key, value) {
  notes_view.Note(key, 20, value, notes_view.Complete)
}

fn press(model, key) {
  tui.update(backend.KeyPress(key), model)
}

fn shown(model, width, height) {
  let model = tui.update(backend.Resize(width, height), model)
  let model = tui.update(backend.Tick, model)
  render.view(model, geometry.rect_new(0, 0, width, height)).0
  |> frame.buffer_to_text
}

fn inspect_worker_notes(initial) {
  initial
  |> press("f2")
  |> press("down")
  |> press("3")
}

pub fn inspected_worker_notes_keep_the_main_draft_and_target_test() {
  let initial =
    tui_model.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("draft for main"),
    )
  let inspected = inspect_worker_notes(initial)
  let loaded =
    tui.apply_channel_update(
      inspected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("worker", [note("plan", "Review the scheduler")]),
        ),
      ),
    )
  let rendered = shown(loaded, 100, 30)
  assert loaded.active_strand == "main"
  assert textarea.value(loaded.input) == "draft for main"
  assert string.contains(rendered, "Review the scheduler")
  assert string.contains(rendered, "[3 Notes]")
  assert string.contains(rendered, "worker")
}

pub fn late_reply_for_another_inspected_strand_cannot_replace_notes_test() {
  let inspected =
    inspect_worker_notes(tui_model.Model(..model(), strands: roster()))
  let worker =
    tui.apply_channel_update(
      inspected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("worker", [note("worker-plan", "worker value")]),
        ),
      ),
    )
  let main =
    tui.apply_channel_update(
      worker,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(board("main", [note("main-plan", "main value")])),
      ),
    )
  let rendered = shown(main, 100, 30)
  assert string.contains(rendered, "worker value")
  assert !string.contains(rendered, "main value")
  assert main.active_strand == "main"
}

pub fn notebook_selection_follows_key_when_rows_reorder_or_disappear_test() {
  let inspected =
    inspect_worker_notes(tui_model.Model(..model(), strands: roster()))
  let first =
    tui.apply_channel_update(
      inspected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("worker", [
            note("plan", "plan value"),
            note("status", "status value"),
          ]),
        ),
      ),
    )
  let selected = press(first, "]")
  let reordered =
    tui.apply_channel_update(
      selected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("worker", [
            note("new", "new value"),
            note("status", "status value"),
            note("plan", "plan value"),
          ]),
        ),
      ),
    )
  assert reordered.note_selected == Some("status")
  assert string.contains(shown(reordered, 100, 30), "status value")
  let deleted =
    tui.apply_channel_update(
      reordered,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(board("worker", [note("plan", "plan value")])),
      ),
    )
  assert deleted.note_selected == Some("plan")
  assert string.contains(shown(deleted, 100, 30), "plan value")
}

pub fn notes_own_the_surface_after_diff_at_wide_and_narrow_sizes_test() {
  let initial =
    tui_model.Model(
      ..model(),
      strands: roster(),
      diff_view: tui_model.DiffVisible,
      input: textarea.state_from_string("/notes"),
    )
  let opened = press(initial, "enter")
  let loaded =
    tui.apply_channel_update(
      opened,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("main", [note("plan", "notes win over diff")]),
        ),
      ),
    )
  list.each([#(80, 24), #(160, 50)], fn(size) {
    let rendered = shown(loaded, size.0, size.1)
    assert string.contains(rendered, "notes win over diff")
    assert !string.contains(rendered, "Captured edits")
    assert !string.contains(rendered, "captured changes")
  })
}

pub fn raw_note_expansion_preserves_the_original_json_document_test() {
  let raw =
    json.to_string(
      json.Object([
        #("status", json.String("ready")),
        #("evidence", json.Array([json.String("one"), json.String("two")])),
      ]),
    )
  let inspected =
    inspect_worker_notes(tui_model.Model(..model(), strands: roster()))
  let loaded =
    tui.apply_channel_update(
      inspected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(board("worker", [note("report", raw)])),
      ),
    )
  let compact = shown(loaded, 100, 30)
  let expanded = press(loaded, "ctrl+g")
  assert string.contains(compact, "Status")
  assert string.contains(compact, "ready")
  assert string.contains(shown(expanded, 100, 30), "\"status\": \"ready\"")
  assert expanded.note_board == loaded.note_board
}

pub fn changing_detail_or_closing_inspection_never_retargets_the_composer_test() {
  let initial =
    tui_model.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("keep main draft"),
    )
  let notes =
    tui.apply_channel_update(
      inspect_worker_notes(initial),
      session_channel.Auxiliary(
        protocol.NotesSnapshot(board("worker", [note("plan", "worker plan")])),
      ),
    )
  let activity = press(notes, "1")
  let messages = press(activity, "2")
  let closed = press(messages, "esc")
  assert activity.active_strand == "main"
  assert messages.active_strand == "main"
  assert closed.active_strand == "main"
  assert textarea.value(closed.input) == "keep main draft"
  assert closed.overlay == tui_model.NoOverlay
}

pub fn missing_notes_board_reports_unavailability_for_the_inspected_target_test() {
  let inspected =
    inspect_worker_notes(tui_model.Model(..model(), strands: roster()))
  let rendered = shown(inspected, 80, 24)
  assert string.contains(rendered, "no agent notes are available for worker")
  assert !string.contains(rendered, "notes for main")
}

pub fn changing_inspected_note_preserves_underlying_transcript_position_test() {
  let initial = tui.update(backend.Resize(90, 24), model())
  process.send(
    initial.inbox,
    connection.Incoming(gateway.stream_delta(
      "main",
      "text",
      string.repeat("A retained paragraph.\n\n", 40),
    )),
  )
  let streaming = tui.update(backend.Tick, initial)
  let reading = tui.update(backend.MouseScroll(5, 5, True), streaming)
  assert reading.scroll_offset > 0
  let inspected =
    inspect_worker_notes(tui_model.Model(..reading, strands: roster()))
  let loaded =
    tui.apply_channel_update(
      inspected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("worker", [
            note("plan", "first"),
            note("status", "second"),
          ]),
        ),
      ),
    )
  let settled = tui.update(backend.Tick, loaded)
  let selected = press(settled, "]")
  assert selected.note_selected == Some("status")
  assert selected.scroll_offset == settled.scroll_offset
  let closed = press(selected, "esc")
  assert closed.scroll_offset > 0
  assert closed.reading_lines == reading.reading_lines
}

pub fn closing_inspector_cannot_expose_worker_notes_as_main_notes_test() {
  let initial =
    tui_model.Model(..model(), strands: roster(), notes_open: True)
    |> tui.update(backend.Resize(100, 30), _)
  let inspected = inspect_worker_notes(initial)
  let loaded =
    tui.apply_channel_update(
      inspected,
      session_channel.Auxiliary(
        protocol.NotesSnapshot(
          board("worker", [note("plan", "WORKER ONLY BODY")]),
        ),
      ),
    )
  let settled = tui.update(backend.Tick, loaded)
  let inspected_frame =
    render.view(settled, geometry.rect_new(0, 0, 100, 30)).0
    |> frame.buffer_to_text
  assert string.contains(inspected_frame, "WORKER ONLY BODY")
  let closed = press(settled, "esc")
  let rendered =
    render.view(
      tui_model.Model(..closed, frame_cache: None),
      geometry.rect_new(0, 0, 100, 30),
    ).0
    |> frame.buffer_to_text
  assert closed.active_strand == "main"
  assert !string.contains(rendered, "WORKER ONLY BODY")
  assert string.contains(rendered, "No observed notes for main")
}
