//// An operator's page sends exactly the two commands it offers, through the
//// engine's command arms, and nothing a browser can fire decides an
//// approval except that approval's own button (protocol-change/051, the
//// operator addendum).
////
//// What the page sends is read from the transport, with every effect
//// performed (`page_fixture.run`); which handlers the page holds is read
//// through Lustre's simulator, which dispatches only to handlers the
//// rendered tree carries, as the browser runtime does.

import gleam/erlang/process
import gleam/list
import gleam/string
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/operator
import web_view/component
import web_view/operator_page

fn page(role: String, cells) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(page_fixture.start()),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire, 0))],
        list.map(page_fixture.transfer(role, cells), fn(frame) {
          operator_page.Observed(component.Arrived([frame], 0))
        }),
        [operator_page.Observed(component.Ticked(0))],
      ]),
    )

  // The lane's own snapshot requests are not what these tests are about.
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

fn pending() {
  [page_fixture.escalation("esc-1", 7, "fs_write", "write the file")]
}

fn send(model, messages) {
  page_fixture.run(model, operator_page.update, messages)
}

fn simulation(role: String, cells) {
  let #(model, _) = page(role, cells)
  simulate.application(
    init: fn(_) { #(model, effect.none()) },
    update: operator_page.update,
    view: operator_page.view,
  )
  |> simulate.start(Nil)
}

pub fn an_operator_submits_a_prompt_to_main_test() {
  let #(model, wire) = page("operator", [])
  let model =
    send(model, [operator_page.Submitted("inspect the tree", operator.Prompt)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one prompt is one command"
  assert string.contains(frame, "\"cmd\":\"prompt\"")
  assert string.contains(frame, "\"strand\":\"main\"")
  assert string.contains(frame, "\"text\":\"inspect the tree\"")
  assert component.drafts(model) == 1
}

pub fn a_steer_is_sent_as_a_steer_test() {
  let #(model, wire) = page("operator", [])
  let _ = send(model, [operator_page.Submitted("go left", operator.Steer)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one steer is one command"
  assert string.contains(frame, "\"cmd\":\"steer\"")
}

// The composer's form is the page's one submit handler, and its fields
// become the prompt.
pub fn the_composer_form_submits_its_draft_test() {
  let submitted =
    simulation("operator", [])
    |> simulate.submit(on: query.element(query.class("composer")), fields: [
      #("draft", "hello"),
      #("delivery", "prompt"),
    ])
  assert component.drafts(simulate.model(submitted)) == 1
  assert component.notice(simulate.model(submitted))
    == component.Said("prompt sent")
}

// Enter in the editor is a newline: no key handler exists for it, and a
// submitted draft with an approval pending sends the prompt and decides
// nothing.
pub fn enter_in_the_composer_never_decides_an_approval_test() {
  let keyed =
    simulation("operator", pending())
    |> simulate.event(
      on: query.element(query.tag("textarea")),
      name: "keydown",
      data: [],
    )
  let assert Ok(simulate.Problem(name: "EventHandlerNotFound", ..)) =
    list.last(simulate.history(keyed))
    as "the editor holds no key handler"

  let #(model, wire) = page("operator", pending())
  let model = send(model, [operator_page.Submitted("y", operator.Prompt)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "a submitted draft is one prompt"
  assert string.contains(frame, "\"cmd\":\"prompt\"")
  assert !string.contains(frame, "escalation_id")
  assert list.length(component.pending(model)) == 1
}

pub fn deny_sends_the_drawn_identity_and_sequence_test() {
  let #(model, wire) = page("operator", pending())
  let _ = send(model, [operator_page.Decided("esc-1", 7, component.Deny)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one decision is one command"
  assert string.contains(frame, "\"cmd\":\"deny\"")
  assert string.contains(frame, "\"escalation_id\":\"esc-1\"")
  assert string.contains(frame, "\"expected_seq\":7")
}

pub fn allow_once_sends_the_drawn_digest_and_grants_test() {
  let #(model, wire) = page("operator", pending())
  let _ = send(model, [operator_page.Decided("esc-1", 7, component.AllowOnce)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one decision is one command"
  assert string.contains(frame, "\"cmd\":\"approve\"")
  assert string.contains(frame, "\"expected_seq\":7")
  assert string.contains(frame, "\"action\":\"captured-action\"")
  assert string.contains(frame, "/shared/output")
  assert !string.contains(frame, "\"scope\"")
}

// A button drawn for one sequence answers only that sequence: a record that
// moved after the card was drawn is not decided.
pub fn a_decision_for_a_stale_sequence_sends_nothing_test() {
  let #(model, wire) = page("operator", pending())
  let model =
    send(model, [operator_page.Decided("esc-1", 6, component.AllowOnce)])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let assert component.Warned(_) = component.notice(model)
    as "the page says nothing was decided"
}

// The engine's own role check is the third layer under the component type
// and the gateway: an observer's attachment sends no command whatever
// message reaches it.
pub fn an_observer_attachment_sends_no_command_test() {
  let #(model, wire) = page("observer", pending())
  let _ =
    send(model, [
      operator_page.Submitted("hello", operator.Prompt),
      operator_page.Decided("esc-1", 7, component.Deny),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn an_empty_or_oversized_draft_is_refused_before_the_lane_test() {
  let #(model, wire) = page("operator", [])
  let _ =
    send(model, [
      operator_page.Submitted("   ", operator.Prompt),
      operator_page.Submitted(
        string.repeat("x", component.prompt_limit + 1),
        operator.Prompt,
      ),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn the_composer_refuses_any_field_it_does_not_offer_test() {
  assert operator_page.composition([#("draft", "hi")])
    == Ok(operator_page.Submitted("hi", operator.Prompt))
  assert operator_page.composition([
      #("draft", "hi"),
      #("delivery", "steer"),
    ])
    == Ok(operator_page.Submitted("hi", operator.Steer))
  list.each(
    [
      [],
      [#("draft", "a"), #("draft", "b")],
      [#("draft", "a"), #("delivery", "approve")],
      [#("draft", "a"), #("delivery", "prompt"), #("delivery", "steer")],
      [#("draft", "a"), #("escalation_id", "esc-1")],
    ],
    fn(fields) {
      let assert Error(Nil) = operator_page.composition(fields)
        as "a forged composer field refuses the event"
    },
  )
}

// A card appearing must never move the composer: the agent chooses when a
// card lands and how tall it is, so drawn above the composer it could slide
// Deny or Allow under a click on its way to the editor or to Send. The
// approvals therefore come after the composer.
pub fn the_composer_comes_before_the_approvals_test() {
  let #(model, _) = page("operator", pending())
  let html = element.to_string(operator_page.view(model))
  let assert Ok(#(before_composer, _)) =
    string.split_once(html, "class=\"composer\"")
    as "the page draws a composer"
  assert !string.contains(before_composer, "class=\"approvals\"")
  assert string.contains(html, "class=\"approvals\"")
}

// The card is drawn from the record alone, outside the transcript: Deny is
// its first control, every button names the tool, nothing takes focus, and
// the session's text is escaped.
pub fn an_approval_card_puts_deny_first_and_escapes_the_record_test() {
  let #(model, _) =
    page("operator", [
      page_fixture.escalation(
        "esc-1",
        7,
        "fs_write",
        "<script>alert(1)</script><a href=\"javascript:alert(2)\">open</a>",
      ),
    ])
  let html = element.to_string(operator_page.view(model))
  assert !string.contains(html, "<a ")
  assert string.contains(html, "&lt;a href=")
  let assert [_, after_deny] = string.split(html, "Deny fs_write")
    as "the deny button names the tool once"
  assert string.contains(after_deny, "Allow fs_write once")
  assert !string.contains(html, "autofocus")
  assert !string.contains(html, "<script>")
  assert string.contains(html, "&lt;script&gt;")
  assert string.contains(html, "class=\"approvals\"")
}

pub fn a_closed_connection_refuses_commands_test() {
  let #(model, wire) = page("operator", [])
  let _ =
    send(model, [
      operator_page.Observed(component.Arrived(
        [connection_event.Closed("access was revoked")],
        0,
      )),
      operator_page.Observed(component.Ticked(250)),
      operator_page.Submitted("hello", operator.Prompt),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}
