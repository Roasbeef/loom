//// Held-message controls use complete documents and exact server identities.
//// These tests drive real lane outputs as well as the page's form decoder.

import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/queue_request
import session_view/queued_input
import session_view/snapshot_view
import web_view/component
import web_view/operator_page
import web_view/view/queue_input

fn row() {
  snapshot_view.PendingInput(
    "held-1",
    "main",
    snapshot_view.Queue,
    "excerpt",
    3,
    snapshot_view.Editable,
  )
}

fn page() {
  let wire = process.new_subject()
  let model =
    page_fixture.ready(wire, "operator")
    |> component.apply([
      lane_fixture.holding(
        lane_fixture.captured(10, Some(lane_fixture.main_op())),
        [row()],
      ),
    ])
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

fn send(model, action) {
  page_fixture.run(model, component.update, [component.QueueAction(action)])
}

fn document() {
  queued_input.Document(
    "held-1",
    "main",
    3,
    queued_input.Queue,
    "complete\n<b>message</b>",
    2,
  )
}

fn opened(model, wire) {
  let loading = send(model, queue_input.Open(row()))
  let assert [read] = page_fixture.commands(page_fixture.sent(wire))
    as "one complete read"
  let board =
    json.Object([
      #("id", json.String("held-1")),
      #("strand", json.String("main")),
      #("revision", json.Int(3)),
      #("kind", json.String("queue")),
      #("text", json.String(document().text)),
      #("attachment_count", json.Int(2)),
    ])
  let reply =
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(page_fixture.request_id(read))
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"queued_input\",\"board\":"
    <> json.to_string(board)
    <> "}}"
  #(
    page_fixture.run(loading, component.update, [
      component.Arrived([connection_event.Incoming(reply)]),
    ]),
    read,
  )
}

pub fn queue_input_loads_complete_text_and_saves_exact_revision_test() {
  let #(model, wire) = page()
  let #(editing, read) = opened(model, wire)
  assert string.contains(read, "\"cmd\":\"queued_input\"")
  assert string.contains(read, "\"id\":\"held-1\"")
  let html = operator_page.view(editing) |> element.to_string
  assert string.contains(html, "complete\n&lt;b&gt;message&lt;/b&gt;")
  assert string.contains(html, "Edit queued message")
  assert string.contains(html, "Attached images")
  let saving = send(editing, queue_input.Save("replacement\ntext"))
  let assert [save] = page_fixture.commands(page_fixture.sent(wire))
    as "one replacement, not a new prompt"
  assert string.contains(save, "\"cmd\":\"edit_queued_input\"")
  assert string.contains(save, "\"expected_revision\":3")
  assert string.contains(save, "replacement\\ntext")
  let html = operator_page.view(saving) |> element.to_string
  assert string.contains(html, "Saving")
  let _ = send(saving, queue_input.Save("twice"))
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn queue_input_remove_is_exact_and_readonly_rows_have_no_controls_test() {
  let #(model, wire) = page()
  let _ = send(model, queue_input.Remove(row()))
  let assert [remove] = page_fixture.commands(page_fixture.sent(wire))
    as "one withdrawal"
  assert string.contains(remove, "\"cmd\":\"remove_queued_input\"")
  assert string.contains(remove, "\"expected_revision\":3")
  let readonly =
    snapshot_view.PendingInput(..row(), editing: snapshot_view.ReadOnly)
  let model =
    component.apply(model, [
      lane_fixture.holding(lane_fixture.captured(11, None), [readonly]),
    ])
  let _ = send(model, queue_input.Remove(row()))
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let html = operator_page.view(model) |> element.to_string
  assert !string.contains(html, ">Remove<")
  assert !string.contains(html, ">Edit<")
  assert !string.contains(
    component.view(model) |> element.to_string,
    ">Remove<",
  )
}

pub fn queue_input_refusal_and_unknown_outcome_retain_draft_test() {
  let state =
    queue_input.Editing(
      row(),
      "owner",
      "namespace",
      document(),
      "retained",
      queue_input.Saving,
      "",
    )
  let refused = queue_input.notice(state, queue_request.Refused("conflict"))
  let assert queue_input.Editing(
    text: "retained",
    delivery: queue_input.Ready,
    message: "conflict",
    ..,
  ) = refused
    as "refusal preserves text"
  let unknown = queue_input.notice(state, queue_request.Unknown)
  let assert queue_input.Editing(
    text: "retained",
    delivery: queue_input.Unknown,
    ..,
  ) = unknown
    as "uncertain saves cannot be repeated"
  assert list.length(queue_input.retain(unknown, [])) == 1
  assert queue_input.notice(unknown, queue_request.Refused("unrelated"))
    == unknown
  assert queue_input.notice(state, queue_request.Saved) == queue_input.Closed
}

pub fn queue_input_form_accepts_one_text_field_and_cancel_sends_nothing_test() {
  let #(model, wire) = page()
  let #(editing, _) = opened(model, wire)
  let _ = page_fixture.sent(wire)
  let sim =
    simulate.application(
      init: fn(_) { #(editing, effect.none()) },
      update: operator_page.update,
      view: operator_page.view,
    )
    |> simulate.start(Nil)
  let form = query.element(query.class("queue-editor"))
  let submitted =
    simulate.submit(sim, on: form, fields: [#("text", "from the browser")])
  assert string.contains(
    operator_page.view(simulate.model(submitted)) |> element.to_string,
    "Saving",
  )
  let rejected =
    simulate.submit(sim, on: form, fields: [
      #("text", "valid"),
      #("unexpected", "text"),
    ])

  // A malformed event never becomes a queue action.
  assert simulate.model(rejected) == simulate.model(sim)
  let _ = send(editing, queue_input.Cancel)
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn queue_input_remove_then_edit_waits_for_the_removal_reply_test() {
  let #(model, wire) = page()
  let removing = send(model, queue_input.Remove(row()))
  let _ = page_fixture.sent(wire)
  let after = send(removing, queue_input.Open(row()))
  assert !string.contains(
    operator_page.view(after) |> element.to_string,
    "Loading complete",
  )
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn queue_input_history_browsing_keeps_the_editor_mounted_test() {
  let #(model, wire) = page()
  let #(editing, _) = opened(model, wire)
  let large =
    component.apply(editing, [
      lane_fixture.holding(
        lane_fixture.long_running(1001, 1600, Some(lane_fixture.main_op())),
        [row()],
      ),
    ])
  let browsing =
    page_fixture.run(large, component.update, [component.OlderRequested])
  assert component.browsing(browsing)
  let html = operator_page.view(browsing) |> element.to_string
  assert string.contains(html, "queue-editor")
  assert string.contains(html, "complete\n&lt;b&gt;message&lt;/b&gt;")
}

pub fn queue_input_wire_refusal_retains_text_and_acknowledgement_closes_test() {
  let #(model, wire) = page()
  let #(editing, _) = opened(model, wire)
  let saving = send(editing, queue_input.Save("my replacement"))
  let assert [save] = page_fixture.commands(page_fixture.sent(wire))
    as "one replacement"
  let refused =
    page_fixture.run(saving, component.update, [
      component.Arrived([page_fixture.refusal(page_fixture.request_id(save))]),
    ])
  let html = operator_page.view(refused) |> element.to_string
  assert string.contains(html, "queue-editor")
  assert string.contains(html, "my replacement")
  assert string.contains(html, "unavailable: busy")
  let saving = send(refused, queue_input.Save("my replacement"))
  let assert [save] = page_fixture.commands(page_fixture.sent(wire))
    as "the rejected revision can be retried"
  let acknowledged =
    page_fixture.run(saving, component.update, [
      component.Arrived([
        connection_event.Incoming(
          "{\"v\":2,\"reply_to\":"
          <> int.to_string(page_fixture.request_id(save))
          <> ",\"event\":\"mutation_outcome\",\"body\":{\"status\":\"queued\"}}",
        ),
      ]),
    ])
  assert !string.contains(
    operator_page.view(acknowledged) |> element.to_string,
    "queue-editor",
  )
}
