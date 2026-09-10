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
  json.Object([
    #("id", json.String(id)),
    #("strand", json.String("main")),
    #("kind", json.String("queue")),
    #("text", json.String("same instruction")),
    #("revision", json.Int(3)),
    #("editable", json.Bool(True)),
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
  let model = tui.update(backend.Resize(120, 30), model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, 120, 30))
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
  assert string.contains(painted(opened), "A · editable · same instruction")
  assert string.contains(painted(opened), "B · editable · same instruction")

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

pub fn duplicate_excerpts_fetch_the_selected_identity_test() {
  let #(model, events) = ready([pending("A"), pending("B")])
  let selected = model |> tui.open_queue |> key("down")
  assert string.contains(painted(selected), "> queue B · editable")
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

pub fn selecting_another_item_does_not_rebind_an_uncertain_draft_test() {
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
  let request = issued(reads, "queued_input")
  let answered = full_reply(switched, request, "B", 9, "B complete text")
  assert draft(answered).document.id == "B"
  assert textarea.value(draft(answered).input) == "B complete text"
  assert !string.contains(painted(answered), "A original")
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
  assert string.contains(painted(reordered), "> queue B · editable")
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
  })
}
