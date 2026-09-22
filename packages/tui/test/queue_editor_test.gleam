//// Queued drafts keep their identity and complete text across transport races.
//// These scenarios drive credited capture, correlated replies, keyboard input,
//// and rendered panels without creating a second socket or mutation channel.

import core/json
import core/register
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/strand
import tui
import tui/attempt
import tui/command
import tui/composer
import tui/connection
import tui/frame
import tui/protocol
import tui/queue_editor
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import tui_test/pushed

fn cell(namespace, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String("main")),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn pending(id) {
  pending_as(id, "queue", "same instruction", 3, snapshot_view.Editable)
}

fn pending_as(id, kind, text, revision, editing: snapshot_view.Editing) {
  json.Object([
    #("id", json.String(id)),
    #("strand", json.String("main")),
    #("kind", json.String(kind)),
    #("text", json.String(text)),
    #("revision", json.Int(revision)),
    #(
      "editable",
      json.Bool(case editing {
        snapshot_view.Editable -> True
        snapshot_view.ReadOnly -> False
      }),
    ),
  ])
}

fn metadata(rows) {
  let assert Ok(json.Object(base)) = json.parse(pushed.metadata())
    as "the capture fixture is a metadata object"
  let cells = [
    cell(
      register.StrandConfig,
      codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("test", "test"),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, json.Null),
    cell(
      register.StrandState,
      codec.encode_strand_state(strand.StrandState(None, [])),
    ),
  ]
  json.to_string(
    json.Object([
      #("cells", json.Array(cells)),
      #("pending_inputs", json.Array(rows)),
      ..list.filter(base, fn(pair) { pair.0 != "cells" })
    ]),
  )
}

fn receive(model: tui.Model, incoming: connection.Message) -> tui.Model {
  let assert Some(channel) = model.channel as "the fixture has an attached lane"
  let #(channel, updates) = session_channel.receive(channel, incoming)
  list.fold(
    updates,
    tui.Model(..model, channel: Some(channel)),
    tui.apply_channel_update,
  )
}

fn ready(rows) {
  ready_as(rows, snapshot.Expected("A", "epoch", "incarnation"), "connection")
}

fn ready_as(rows, expected: snapshot.Expected, connection_id: String) {
  let events = process.new_subject()
  let trace =
    attempt.Trace(attempt.Id(1), fn(event) { process.send(events, event) })
  let channel = session_channel.replay_traced(expected, fn() { 0 }, trace)
  let initial =
    tui.Model(
      ..tui.new_model(connection.new_inbox(), workspace.Context("/work", None)),
      peer: tui.Replaying,
      channel: Some(channel),
      input: textarea.state_from_string("ordinary composer draft"),
      attachments: [composer.Attachment("retained pasted context", 10)],
    )
  let assert [begin, ..rest] =
    pushed.transfer_with_metadata(1, "1:1", "recent", 10, metadata(rows))
    as "the transfer starts with its attachment-bearing begin frame"
  let model =
    list.fold(
      [retarget_begin(begin, expected, connection_id), ..rest],
      initial,
      receive,
    )
  let _ = requests(events, [])
  #(model, events)
}

// Replay the authenticated attachment change through the capture decoder,
// so the new model and its usable channel agree on the selected namespace.
fn retarget_begin(incoming, expected: snapshot.Expected, connection_id) {
  let assert connection.Incoming(text) = incoming
    as "the capture begin arrives as a wire frame"
  let assert Ok(json.Object(envelope)) = json.parse(text)
    as "the capture begin has a valid envelope"
  let assert Ok(json.Object(body)) = list.key_find(envelope, "body")
    as "the capture begin has attachment fields"
  let replacements = [
    #("session_id", json.String(expected.session)),
    #("epoch", json.String(expected.epoch)),
    #("incarnation", json.String(expected.incarnation)),
    #("connection_id", json.String(connection_id)),
  ]
  let keys = list.map(replacements, fn(pair) { pair.0 })
  let body =
    json.Object(list.append(
      replacements,
      list.filter(body, fn(pair) { !list.contains(keys, pair.0) }),
    ))
  connection.Incoming(
    json.to_string(
      json.Object([
        #("body", body),
        ..list.filter(envelope, fn(pair) { pair.0 != "body" })
      ]),
    ),
  )
}

fn requests(events, collected) {
  case process.receive(events, 0) {
    Error(Nil) -> list.reverse(collected)
    Ok(attempt.Issued(_, request)) -> requests(events, [request, ..collected])
    Ok(_) -> requests(events, collected)
  }
}

fn issued(events, kind) {
  let observed = requests(events, [])
  let assert [request] = observed as "exactly one command was issued"
  assert request.kind == kind
  request.id
}

fn key(model, name) {
  tui.update(backend.KeyPress(name), model)
}

fn painted(model) {
  painted_at(model, 120, 30)
}

fn painted_at(model, width, height) {
  let model = tui.update(backend.Resize(width, height), model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, width, height))
  frame.buffer_to_text(buffer)
}

fn board(id, revision, text, images) {
  json.Object([
    #("id", json.String(id)),
    #("strand", json.String("main")),
    #("revision", json.Int(revision)),
    #("kind", json.String("queue")),
    #("text", json.String(text)),
    #("attachment_count", json.Int(images)),
  ])
}

fn full_reply(model, request, id, revision, text) {
  receive(
    model,
    pushed.reply(
      request,
      "snapshot",
      json.Object([
        #("mode", json.String("queued_input")),
        #("board", board(id, revision, text, 2)),
      ]),
    ),
  )
}

fn draft(model: tui.Model) -> queue_editor.Draft {
  let assert Some(draft) = model.queue_editor.draft
    as "a credited complete fetch has opened the queue draft"
  draft
}

fn opened(text) {
  let #(model, events) = ready([pending("A")])
  let waiting = model |> tui.open_queue |> key("enter")
  let request = issued(events, "queued_input")
  #(full_reply(waiting, request, "A", 3, text), events)
}

fn refused(model, request, code) {
  receive(
    model,
    pushed.reply(
      request,
      "error",
      json.Object([
        #("code", json.String(code)),
        #(
          "message",
          json.String("input no longer matches the fetched revision"),
        ),
      ]),
    ),
  )
}

pub fn queue_inspector_preserves_composer_and_attachments_test() {
  let #(model, _) = ready([pending("A"), pending("B")])
  let opened = tui.open_queue(model)
  assert opened.queue_editor.surface == queue_editor.Inspector
  assert opened.input == model.input
  assert opened.attachments == model.attachments
  assert string.contains(painted(opened), "queued inputs")
  assert string.contains(painted(opened), "▸ same instruction · [QUEUE] [EDIT]")
  assert string.contains(painted(opened), "same instruction · [QUEUE] [EDIT]")
  assert string.contains(painted(opened), "Captured excerpt · revision 3")
  assert string.contains(painted(opened), "same instruction")
  assert string.contains(painted(opened), "ordinary composer draft")

  // The slash command consumes its own text, while pasted context remains
  // owned by the ordinary composer rather than becoming a queue mutation.
  assert command.parse("/queue") == command.QueueInspect
  let slash =
    key(
      tui.Model(..model, input: textarea.state_from_string("/queue")),
      "enter",
    )
  assert slash.queue_editor.surface == queue_editor.Inspector
  assert slash.attachments == model.attachments
  assert slash.queued == model.queued
}

pub fn passive_queue_is_message_first_and_alt_q_focuses_without_mutation_test() {
  let #(model, events) = ready([pending("A"), pending("B")])
  let frame = painted(model)
  assert string.contains(frame, "queue · 2 pending · Alt+q inspect")
  assert string.contains(frame, "same instruction · [QUEUE] [EDIT] · 1/2")
  assert !string.contains(frame, "Received · queued after this turn")

  let opened = key(model, "alt+q")
  assert opened.queue_editor.surface == queue_editor.Inspector
  assert textarea.value(opened.input) == "ordinary composer draft"
  assert opened.attachments == model.attachments
  assert requests(events, []) == []
}

pub fn queue_inspector_labels_priority_access_and_excerpt_provenance_test() {
  let rows = [
    pending_as(
      "普通-input",
      "steer",
      "urgent captured excerpt",
      7,
      snapshot_view.Editable,
    ),
    pending_as(
      "locked",
      "queue",
      "visible but not fetchable",
      8,
      snapshot_view.ReadOnly,
    ),
  ]
  let #(model, events) = ready(rows)
  let opened = tui.open_queue(model)
  let wide = painted(opened)
  assert string.contains(wide, "▸ urgent captured")
  assert string.contains(wide, "[STEER] [EDIT]")
  assert string.contains(wide, "visible but")
  assert string.contains(wide, "[QUEUE] [READ-ONLY]")
  assert string.contains(wide, "Captured excerpt · revision 7")
  assert string.contains(wide, "Enter fetches full text")

  let locked = opened |> key("down") |> key("enter")
  assert requests(events, []) == []
  assert locked.queue_editor.awaiting == None
  assert string.contains(painted(locked), "read-only for this attachment")
  assert string.contains(painted(locked), "full text unavailable")
}

pub fn compact_excerpt_paging_reaches_tail_and_resize_clamps_render_test() {
  let excerpt =
    "line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12-tail"
  let #(model, _) =
    ready([pending_as("A", "queue", excerpt, 3, snapshot_view.Editable)])
  let compact =
    model
    |> tui.update(backend.Resize(40, 12), _)
    |> tui.open_queue
  let first = painted_at(compact, 40, 12)
  assert string.contains(first, "line-01")
  assert !string.contains(first, "line-12-tail")

  let paged =
    list.fold(list.repeat(Nil, 20), compact, fn(current, _) {
      key(current, "pagedown")
    })
  assert paged.queue_editor.preview_scroll > 0
  let tail = painted_at(paged, 40, 12)
  assert string.contains(tail, "line-12-tail")
  assert !string.contains(tail, "line-01")

  // Width alone can reduce the wrapped row count below the retained offset.
  // Presentation clamps against the rows at the new width immediately.
  let widened = painted_at(paged, 80, 12)
  assert string.contains(widened, "line-12-tail")

  // A larger bounded card clamps the retained offset during presentation, so
  // resize alone cannot leave a blank preview waiting for another key.
  let enlarged = painted_at(paged, 80, 24)
  assert string.contains(enlarged, "line-09")
  assert string.contains(enlarged, "line-12-tail")
}

pub fn compact_single_line_paging_reaches_a_twenty_cell_suffix_test() {
  let text = string.repeat("x", 29) <> "ABCDEFGHIJKLMNOPQRST"
  let #(model, _) =
    ready([pending_as("A", "queue", text, 3, snapshot_view.Editable)])
  let compact =
    model
    |> tui.update(backend.Resize(40, 12), _)
    |> tui.open_queue
    |> key("pagedown")
  assert string.contains(painted_at(compact, 40, 12), "ABCDEFGHIJKLMNOPQRST")
}

pub fn two_row_queue_title_pages_beside_a_multiline_composer_test() {
  let excerpt =
    "line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12-tail"
  let #(model, _) =
    ready([pending_as("A", "queue", excerpt, 3, snapshot_view.Editable)])
  let compact =
    tui.Model(
      ..model,
      input: textarea.state_from_string("ordinary draft\nsecond draft line"),
    )
    |> tui.update(backend.Resize(40, 12), _)
    |> tui.open_queue
  let first = painted_at(compact, 40, 12)
  assert string.contains(first, "line-01")
  assert string.contains(first, "ordinary draft")
  assert string.contains(first, "second draft line")
  assert string.contains(first, "[pasted ~10 tokens]")

  let paged =
    list.fold(list.repeat(Nil, 20), compact, fn(current, _) {
      key(current, "pagedown")
    })
  let tail = painted_at(paged, 40, 12)
  assert string.contains(tail, "line-12-tail")
  assert string.contains(tail, "ordinary draft")
  assert string.contains(tail, "second draft line")
}

pub fn two_row_queue_title_pages_beside_an_active_status_test() {
  let excerpt =
    "line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12-tail"
  let #(model, _) =
    ready([pending_as("A", "queue", excerpt, 3, snapshot_view.Editable)])
  let compact =
    tui.Model(..model, submitting: Some("main"))
    |> tui.update(backend.Resize(40, 12), _)
    |> tui.open_queue
  let first = painted_at(compact, 40, 12)
  assert string.contains(first, "line-01")
  assert string.contains(first, "submitting")
  assert string.contains(first, "ordinary composer draft")
  assert string.contains(first, "[pasted ~10 tokens]")

  let paged =
    list.fold(list.repeat(Nil, 20), compact, fn(current, _) {
      key(current, "pagedown")
    })
  let tail = painted_at(paged, 40, 12)
  assert string.contains(tail, "line-12-tail")
  assert string.contains(tail, "submitting")
  assert string.contains(tail, "ordinary composer draft")
}

pub fn compact_capture_refresh_uses_the_reserved_queue_viewport_test() {
  let excerpt =
    "line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12-tail"
  let row = pending_as("A", "queue", excerpt, 3, snapshot_view.Editable)
  let #(model, _) = ready([row])
  let compact =
    model
    |> tui.update(backend.Resize(40, 12), _)
    |> tui.open_queue
  let paged =
    list.fold(list.repeat(Nil, 20), compact, fn(current, _) {
      key(current, "pagedown")
    })
  assert paged.queue_editor.preview_scroll == 11
  let assert Some(#(previous, _)) = paged.captured
  let assert Ok(data) = json.parse(metadata([row]))
  let cut = snapshot.Captured(..previous, metadata: data, next_seq: 11)
  let assert Ok(view) = snapshot_view.decode(cut)
  let refreshed =
    tui.apply_channel_update(
      paged,
      session_channel.Captured(cut, view, session_channel.Notified),
    )
  assert refreshed.queue_editor.preview_scroll == 11
  assert string.contains(painted_at(refreshed, 40, 12), "line-12-tail")
}

pub fn duplicate_excerpts_fetch_the_selected_identity_test() {
  let #(model, events) = ready([pending("A"), pending("B")])
  let selected = model |> tui.open_queue |> key("down")
  assert string.contains(
    painted(selected),
    "▸ same instruction · [QUEUE] [EDIT]",
  )
  let waiting = key(selected, "enter")
  let request = issued(events, "queued_input")
  let assert Some(queue_editor.Fetch(id: "B", strand: "main", ..)) =
    waiting.queue_editor.awaiting
    as "selection is carried by opaque identity, not its duplicate text"

  // Even a correlated document must answer the selected identity before it
  // can take custody of the independent editor.
  let foreign = full_reply(waiting, request, "A", 3, "wrong item")
  assert foreign.queue_editor.draft == None
  let answered = full_reply(waiting, request, "B", 3, "the second item")
  assert draft(answered).document.id == "B"
  assert textarea.value(draft(answered).input) == "the second item"
}

pub fn clean_retained_draft_allows_editing_another_item_test() {
  let #(model, events) = ready([pending("A"), pending("B")])
  let waiting = model |> tui.open_queue |> key("enter")
  let request = issued(events, "queued_input")
  let clean = full_reply(waiting, request, "A", 3, "same instruction")
  let selected = clean |> key("esc") |> key("down") |> key("enter")
  let _ = issued(events, "queued_input")
  let assert Some(queue_editor.Fetch(id: "B", ..)) =
    selected.queue_editor.awaiting
    as "an unchanged editable draft must not force a save before browsing another item"
}

pub fn resuming_a_draft_cancels_another_items_late_fetch_test() {
  let #(model, events) = ready([pending("A"), pending("B")])
  let waiting_a = model |> tui.open_queue |> key("enter")
  let request_a = issued(events, "queued_input")
  let clean_a = full_reply(waiting_a, request_a, "A", 3, "same instruction")
  let waiting_b = clean_a |> key("esc") |> key("down") |> key("enter")
  let request_b = issued(events, "queued_input")
  let resumed = waiting_b |> key("e") |> key("end") |> key("!")
  assert resumed.queue_editor.awaiting == None
  assert resumed.queue_editor.request_id == None
  assert draft(resumed).document.id == "A"

  let late = full_reply(resumed, request_b, "B", 9, "late B text")
  assert draft(late).document.id == "A"
  assert textarea.value(draft(late).input) == "same instruction!"
}

pub fn queue_mouse_hit_excludes_controls_and_scrolled_heading_test() {
  let rows =
    ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12"]
    |> list.map(pending)
  let #(model, _) = ready(rows)
  let opened =
    model
    |> tui.update(backend.Resize(120, 30), _)
    |> tui.open_queue
  let selected =
    list.fold(list.repeat(Nil, 11), opened, fn(current, _) {
      key(current, "down")
    })
  assert selected.queue_editor.selected == 11

  let controls =
    tui.update(backend.MousePress(2, 14, backend.MouseLeft), selected)
  let heading =
    tui.update(backend.MousePress(2, 17, backend.MouseLeft), selected)
  assert controls.queue_editor.selected == 11
  assert heading.queue_editor.selected == 11

  let row = tui.update(backend.MousePress(2, 18, backend.MouseLeft), selected)
  assert row.queue_editor.selected == 6
}

pub fn reopening_queue_browses_before_resuming_a_retained_draft_test() {
  let #(editor, _) = opened("original complete text")
  let closed = editor |> key("esc") |> key("esc")
  let browsing = tui.open_queue(closed)
  assert browsing.queue_editor.surface == queue_editor.Inspector
  assert textarea.value(browsing.input) == "ordinary composer draft"
  assert string.contains(painted(browsing), "e resumes editing")

  let resumed = key(browsing, "e")
  assert resumed.queue_editor.surface == queue_editor.Editor
  assert textarea.value(draft(resumed).input) == "original complete text"
  assert string.contains(painted(resumed), "ordinary composer draft")
  assert string.contains(painted(resumed), "same instruction")
}

pub fn complete_fetch_and_save_preserve_text_beyond_the_excerpt_test() {
  let content = string.repeat("x", 600) <> "\nUNIQUE_TAIL"
  let #(model, events) = opened(content)
  assert textarea.value(draft(model).input) == content
  assert draft(model).document.attachment_count == 2
  assert string.contains(painted(model), "2 image attachments retained")
  assert string.contains(painted(model), "UNIQUE_TAIL")

  let edited = model |> key("end") |> key("!")
  let complete = textarea.value(draft(edited).input)
  assert string.contains(complete, "UNIQUE_TAIL")
  let saved = key(edited, "ctrl+s")
  let request = issued(events, "edit_queued_input")
  assert draft(saved).delivery == queue_editor.Saving
  assert saved.input == model.input
  assert saved.attachments == model.attachments
  assert saved.notice == "edit_queued_input sent"
  assert string.contains(painted(saved), "Saving this revision")

  // The lane deliberately records no sensitive body. Check the encoder used
  // by Ctrl+s against the exact retained document and complete editor value.
  let assert Ok(json.Object(envelope)) =
    json.parse(protocol.edit_queued_input(
      request,
      draft(saved).document,
      complete,
    ))
    as "the queue replacement has an encoded command envelope"
  assert list.key_find(envelope, "cmd") == Ok(json.String("edit_queued_input"))
  let assert Ok(json.Object(body)) = list.key_find(envelope, "body")
    as "the replacement carries a structured body"
  assert list.key_find(body, "id") == Ok(json.String("A"))
  assert list.key_find(body, "strand") == Ok(json.String("main"))
  assert list.key_find(body, "expected_revision") == Ok(json.Int(3))
  assert list.key_find(body, "text") == Ok(json.String(complete))
}

pub fn stale_or_drained_refusal_keeps_the_unsaved_draft_test() {
  list.each(["stale_queue_revision", "queued_input_missing"], fn(code) {
    let #(model, events) = opened("original")
    let edited = model |> key("end") |> key("!")
    let value = textarea.value(draft(edited).input)
    let saving = key(edited, "ctrl+s")
    let request = issued(events, "edit_queued_input")
    let failed = refused(saving, request, code)
    assert textarea.value(draft(failed).input) == value
    assert draft(failed).document.id == "A"
    assert draft(failed).delivery == queue_editor.Editable
    assert string.contains(painted(failed), code)
    assert requests(events, []) == []
    assert failed.queued == model.queued
  })
}

pub fn uncertain_save_locks_text_and_cannot_reissue_until_reconciled_test() {
  let #(model, events) = opened("original")
  let edited = model |> key("end") |> key("!")
  let value = textarea.value(draft(edited).input)
  let saving = key(edited, "ctrl+s")
  let request = issued(events, "edit_queued_input")
  let uncertain = receive(saving, connection.NetworkFault("reply lost"))
  assert draft(uncertain).delivery == queue_editor.Unknown
  let assert Some(unconfirmed) = uncertain.unconfirmed
    as "the lost mutation reply keeps its exact request identity"
  assert unconfirmed.command == "edit_queued_input"
  assert unconfirmed.request_id == request
  let locked = uncertain |> key("x") |> key("ctrl+s")
  assert textarea.value(draft(locked).input) == value
  assert requests(events, []) == []
  assert string.contains(painted(locked), "Save outcome unknown")

  // Reattachment to the same target supplies a usable command lane, but
  // only the explicit authoritative read can unlock this retained draft.
  let #(reconnected, reads) =
    ready_as(
      [pending("A")],
      snapshot.Expected("A", "epoch", "incarnation"),
      "new-connection",
    )
  let retry =
    tui.Model(
      ..locked,
      channel: reconnected.channel,
      captured: reconnected.captured,
      peer: tui.Replaying,
    )
  let fetching = key(retry, "ctrl+r")
  let read = issued(reads, "queued_input")
  let reconciled = full_reply(fetching, read, "A", 4, value)
  assert draft(reconciled).delivery == queue_editor.Editable
  assert draft(reconciled).document.revision == 4
  assert draft(reconciled).owner != draft(locked).owner
  assert draft(reconciled).namespace == draft(locked).namespace
  assert textarea.value(draft(reconciled).input) == value
  assert requests(reads, []) == []
}

pub fn attachment_change_cannot_save_an_old_editor_test() {
  let #(model, events) = opened("original")
  let assert Some(#(cut, view)) = model.captured
    as "the editor belongs to the captured attachment"
  let attachment =
    snapshot.Attachment(..cut.attachment, connection_id: "replacement")
  let changed =
    tui.Model(
      ..model,
      captured: Some(#(snapshot.Captured(..cut, attachment:), view)),
    )
  let saved = key(changed, "ctrl+s")
  assert requests(events, []) == []
  assert draft(saved).delivery == queue_editor.Editable
  assert textarea.value(draft(saved).input) == "original"
  assert string.contains(painted(saved), "Attachment changed")
}

pub fn selecting_another_item_does_not_discard_an_uncertain_draft_test() {
  let #(model, events) = opened("A original")
  let edited = model |> key("end") |> key("!")
  let saving = key(edited, "ctrl+s")
  let _ = issued(events, "edit_queued_input")
  let uncertain = receive(saving, connection.NetworkFault("reply lost"))
  let #(reconnected, reads) = ready([pending("A"), pending("B")])
  let switched =
    tui.Model(
      ..uncertain,
      channel: reconnected.channel,
      captured: reconnected.captured,
      peer: tui.Replaying,
    )
    |> key("esc")
    |> key("down")
    |> key("enter")
  assert requests(reads, []) == []
  assert switched.queue_editor.awaiting == None
  assert draft(switched).document.id == "A"
  assert textarea.value(draft(switched).input) == "A original!"
  assert string.contains(painted(switched), "e resumes it")

  let resumed = key(switched, "e")
  assert resumed.queue_editor.surface == queue_editor.Editor
  assert textarea.value(draft(resumed).input) == "A original!"
}

pub fn explicit_refresh_after_stale_refusal_keeps_same_item_draft_test() {
  let #(model, events) = opened("original")
  let edited = model |> key("end") |> key("!")
  let value = textarea.value(draft(edited).input)
  let saving = key(edited, "ctrl+s")
  let request = issued(events, "edit_queued_input")
  let failed = refused(saving, request, "stale_queue_revision")
  let fetching = key(failed, "ctrl+r")
  let request = issued(events, "queued_input")
  let refreshed =
    full_reply(fetching, request, "A", 4, "another editor changed this")
  assert draft(refreshed).document.revision == 4
  assert textarea.value(draft(refreshed).input) == value
  assert string.contains(painted(refreshed), "draft retained")
}

pub fn full_document_decoder_bounds_encoded_bytes_and_image_counts_test() {
  let assert Ok(document) =
    queue_editor.decode(board("A", 3, string.repeat("x", 600), 2))
    as "a complete value beyond the queue excerpt remains editable"
  assert document.attachment_count == 2
  assert string.length(document.text) == 600
  let escaped = string.repeat("\u{0000}", 9000)
  assert string.byte_size(escaped) < 48_000
  let assert Error(_) = queue_editor.decode(board("A", 3, escaped, 2))
    as "JSON escaping counts toward the encoded document bound"
  let assert Error(_) = queue_editor.decode(board("A", 3, "text", -1))
    as "image counts cannot be negative"
  let assert Error(_) = queue_editor.decode(board("A", -1, "text", 0))
    as "queue revisions cannot be negative"
}

pub fn selected_identity_survives_a_fresh_cut_reordering_duplicate_excerpts_test() {
  let #(model, events) = ready([pending("A"), pending("B")])
  let selected = model |> tui.open_queue |> key("down")
  let assert Some(#(previous, _)) = selected.captured
    as "selection is tied to a completed metadata cut"
  let assert Ok(data) = json.parse(metadata([pending("B"), pending("A")]))
    as "the reordered queue is valid metadata"
  let cut = snapshot.Captured(..previous, metadata: data, next_seq: 11)
  let assert Ok(view) = snapshot_view.decode(cut)
    as "the next capture retains both distinct queue identities"
  let reordered =
    tui.apply_channel_update(
      selected,
      session_channel.Captured(cut, view, session_channel.Notified),
    )
  assert string.contains(
    painted(reordered),
    "▸ same instruction · [QUEUE] [EDIT]",
  )
  let waiting = key(reordered, "enter")
  let _ = issued(events, "queued_input")
  let assert Some(queue_editor.Fetch(id: "B", ..)) =
    waiting.queue_editor.awaiting
    as "reordering identical excerpts must not silently retarget the edit"
}

pub fn retained_draft_cannot_refresh_or_save_into_another_queue_namespace_test() {
  let alternatives = [
    snapshot.Expected("B", "epoch", "incarnation"),
    snapshot.Expected("A", "new-epoch", "incarnation"),
    snapshot.Expected("A", "epoch", "new-incarnation"),
  ]
  list.each(alternatives, fn(expected) {
    let #(original, _) = opened("draft for the original queue")
    let edited = original |> key("end") |> key("!")
    let retained = draft(edited)
    let #(other, events) = ready_as([pending("A")], expected, "new-connection")
    let switched =
      tui.Model(
        ..edited,
        channel: other.channel,
        captured: other.captured,
        peer: tui.Replaying,
      )
    let refreshed = key(switched, "ctrl+r")
    assert requests(events, []) == []
      as "explicit reconciliation cannot read a reused id in another queue namespace"
    assert refreshed.queue_editor.awaiting == None
    assert draft(refreshed) == retained
    assert painted(refreshed) != painted(switched)
      as "the refused refresh must explain the ownership boundary"
    let saved = key(refreshed, "ctrl+s")
    assert requests(events, []) == []
      as "a retained draft cannot become a replacement in another session or runtime"
    assert draft(saved) == retained
    assert string.contains(painted(saved), "draft retained")

    let browsing = switched |> key("esc") |> key("enter")
    assert requests(events, []) == []
      as "Enter cannot fetch a reused row identity from another queue namespace"
    assert browsing.queue_editor.awaiting == None
    assert draft(browsing) == retained
    assert string.contains(painted(browsing), "e resumes it")
  })
}
