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
import gleam/option.{Some}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/operator
import session_view/session_channel
import web_view/component
import web_view/ending
import web_view/operator_page

fn page(role: String, cells) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(page_fixture.start()),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer(role, cells), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> page_fixture.refuse_reads(operator_page.update, wire, fn(frames) {
      operator_page.Observed(component.Arrived(frames))
    })

  // The lane's own snapshot requests, and the reads the first capture
  // started, are not what these tests are about, so they are answered and
  // off the wire.
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

// A page whose strand is running an operation, as the last capture says.
fn running(role: String) {
  let #(model, wire) = page(role, [])
  #(
    component.apply(model, [
      lane_fixture.captured(10, Some(lane_fixture.main_op())),
    ]),
    wire,
  )
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

// A steer is folded into the operation that is running, so the page offers
// it only while one is, and the engine sends one only then: on an idle
// strand the same words are an ordinary prompt.
pub fn a_steer_is_sent_as_a_steer_test() {
  let #(model, wire) = running("operator")
  let _ = send(model, [operator_page.Submitted("go left", operator.Steer)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one steer is one command"
  assert string.contains(frame, "\"cmd\":\"steer\"")
}

// A draft that parses as a session command is that command, as it is in the
// terminal. The page used to send every draft to the model as a prompt, so
// `/compact` was an instruction to the model rather than a compaction.
pub fn a_slash_command_is_the_command_and_not_a_prompt_test() {
  let #(model, wire) = page("operator", [])
  let _ = send(model, [operator_page.Submitted("/compact", operator.Prompt)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one command is one frame"
  assert string.contains(frame, "\"cmd\":\"compact\"")
  assert !string.contains(frame, "\"cmd\":\"prompt\"")
  assert !string.contains(frame, "/compact")
}

// An unknown slash command is refused by the shared step, as the terminal
// refuses it, and is never sent to the model as a prompt.
pub fn an_unknown_slash_command_is_refused_not_sent_test() {
  let #(model, wire) = page("operator", [])
  let model =
    send(model, [operator_page.Submitted("/frobnicate now", operator.Prompt)])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert component.notice(model)
    == component.Said("unknown command /frobnicate")
}

// A command that opens a terminal surface has no surface here. The page says
// so and sends nothing, and the draft stays where the operator left it.
pub fn a_terminal_surface_command_is_refused_with_a_notice_test() {
  let #(model, wire) = page("operator", [])
  let drafts = component.drafts(model)
  let model =
    send(model, [
      operator_page.Submitted("/models", operator.Prompt),
      operator_page.Submitted("/sessions", operator.Prompt),
      operator_page.Submitted("/details", operator.Prompt),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let assert component.Warned(text) = component.notice(model)
    as "the page says it does not carry the command out"
  assert string.contains(text, "terminal surface")
  assert component.drafts(model) == drafts
}

// Adding a directory names a path on the daemon's host, which a browser
// reader cannot see or pick, and it is the one command that widens the
// session's filesystem scope. The page refuses each spelling with a notice,
// sends nothing, and keeps the draft where the operator left it.
pub fn adding_a_directory_is_refused_with_a_notice_test() {
  let #(model, wire) = page("operator", [])
  let drafts = component.drafts(model)
  let model =
    send(model, [
      operator_page.Submitted("/add-dir /tmp/x", operator.Prompt),
      operator_page.Submitted("/add-write-dir /tmp/x", operator.Prompt),
      operator_page.Submitted("/add-dir --write /tmp/x", operator.Prompt),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let assert component.Warned(text) = component.notice(model)
    as "the page says it does not carry the command out"
  assert string.contains(text, "terminal on the daemon's host")
  assert component.drafts(model) == drafts
}

// A command the session consumes at dispatch, rather than sends, takes the
// draft with it: `/clear` sends nothing and the composer is replaced.
pub fn a_command_that_sends_nothing_still_takes_the_draft_test() {
  let #(model, wire) = page("operator", [])
  let drafts = component.drafts(model)
  let model = send(model, [operator_page.Submitted("/clear", operator.Prompt)])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert component.drafts(model) == drafts + 1
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

// The notice states the outcome of the latest command. A refusal the page
// made itself is replaced by the next command that is sent, and that
// "sent" by the daemon's acknowledgement of it.
pub fn a_later_outcome_replaces_the_notice_test() {
  let #(model, wire) = page("operator", [])
  let model = send(model, [operator_page.Submitted("   ", operator.Prompt)])
  assert component.notice(model) == component.Warned("Nothing to send.")

  let model = send(model, [operator_page.Submitted("hi", operator.Prompt)])
  assert component.notice(model) == component.Said("prompt sent")

  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one prompt is one command"
  let model =
    send(model, [
      reply(frame, "\"mutation_outcome\",\"body\":{\"status\":\"admitted\"}"),
    ])
  assert component.notice(model) == component.Said("prompt admitted")
}

// A command the daemon refuses replaces the "sent" notice with the refusal,
// which the shared step words as the code and the daemon's message. The
// message is the daemon's own text, and the page draws it as text only.
pub fn a_refusal_replaces_the_sent_notice_test() {
  let #(model, wire) = running("operator")
  let model = send(model, [operator_page.Submitted("go left", operator.Steer)])
  assert component.notice(model) == component.Said("steer sent")

  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one steer is one command"
  let model =
    send(model, [
      reply(
        frame,
        "\"error\",\"body\":{\"code\":\"conflict\",\"message\":\"<b>busy</b>\"}",
      ),
    ])
  assert component.notice(model) == component.Said("conflict: <b>busy</b>")
  let html = element.to_string(operator_page.view(model))
  assert string.contains(html, "conflict: &lt;b&gt;busy&lt;/b&gt;")
  assert !string.contains(html, "<b>")
}

// The daemon's correlated reply to `frame`, a command the page sent: the
// event and the body after `"event":`.
fn reply(
  frame: String,
  event: String,
) -> operator_page.Msg(process.Subject(String)) {
  let assert Ok(#(_, after)) = string.split_once(frame, "\"id\":")
    as "a command carries its request identity"
  let assert Ok(#(id, _)) = string.split_once(after, ",")
    as "the identity is followed by the command"
  operator_page.Observed(
    component.Arrived([
      connection_event.Incoming(
        "{\"v\":2,\"reply_to\":" <> id <> ",\"event\":" <> event <> "}",
      ),
    ]),
  )
}

// The notice is the outcome of the operator's own commands. A page that has
// only loaded, whose lane sent the reads a first capture starts, says nothing:
// each read leaves "<name> sent" in the shared notice, which the page used to
// draw as if the operator had asked for it.
pub fn a_page_that_has_only_loaded_says_nothing_test() {
  let #(model, _) = page("operator", [])
  assert component.notice(model) == component.Quiet
}

// What the session says afterwards, a stream or a read the lane sends on its
// own, does not replace the words of the command the operator ran.
pub fn background_events_do_not_speak_over_a_command_test() {
  let #(model, _) = page("operator", [])
  let model = send(model, [operator_page.Submitted("hi", operator.Prompt)])
  let model =
    component.apply(model, [
      session_channel.Streamed("main", "op-1", "gen-1", "text", "hello"),
    ])
  assert component.notice(model) == component.Said("prompt sent")
}

// A command that says nothing leaves the page quiet rather than repeating
// what the session said before it.
pub fn a_silent_command_does_not_repeat_an_older_notice_test() {
  let #(model, _) = page("operator", [])
  let model =
    component.apply(model, [
      session_channel.Streamed("main", "op-1", "gen-1", "text", "hello"),
    ])
  let model = send(model, [operator_page.Submitted("/clear", operator.Prompt)])
  assert component.notice(model) == component.Said("local view cleared")
}

// A refused automatic read is nobody's command outcome. A refused command is.
pub fn only_a_commands_refusal_is_drawn_test() {
  let #(model, wire) = page("operator", [])
  let model = send(model, [operator_page.Submitted("hi", operator.Prompt)])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one prompt is one command"
  let model =
    send(model, [
      reply(
        frame,
        "\"error\",\"body\":{\"code\":\"conflict\",\"message\":\"busy\"}",
      ),
    ])
  assert component.notice(model) == component.Said("conflict: busy")

  // The reads the host issues itself are refused without a word: the
  // automatic ones, the pending-decisions lookup, and the history read the
  // "Load older" button asks for.
  list.each(["advisor_pending", "escalations_get", "history"], fn(name) {
    let model =
      component.apply(model, [
        session_channel.RequestRefused(name, 9, "unsupported", "no"),
      ])
    assert component.notice(model) == component.Said("conflict: busy")
  })
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

// The composer is drawn inside the dock, the footer the stylesheet pins to
// the viewport's bottom edge, so rows landing above it never move Send or
// Steer out from under a click.
pub fn the_composer_is_drawn_in_the_dock_test() {
  let #(model, _) = page("operator", [])
  let html = element.to_string(operator_page.view(model))
  let assert Ok(#(_, from_dock)) =
    string.split_once(html, "<footer class=\"dock\">")
    as "the page draws a dock"
  let assert Ok(#(dock, _)) = string.split_once(from_dock, "</footer>")
    as "the dock is closed"
  assert string.contains(dock, "class=\"composer\"")
}

// A pending card is drawn in the dock, directly above the composer, so it
// is on screen wherever the operator has scrolled. The dock is pinned by
// its bottom edge, so a card appearing grows it upward and never moves the
// composer's controls. Nothing from the transcript is inside the dock.
pub fn the_approvals_sit_above_the_composer_in_the_dock_test() {
  let #(model, _) = page("operator", pending())
  let html = element.to_string(operator_page.view(model))
  let assert Ok(#(before_dock, from_dock)) =
    string.split_once(html, "<footer class=\"dock\">")
    as "the page draws a dock"
  let assert Ok(#(dock, _)) = string.split_once(from_dock, "</footer>")
    as "the dock is closed"
  assert !string.contains(before_dock, "class=\"approvals\"")
  let assert Ok(#(above_composer, _)) =
    string.split_once(dock, "class=\"composer\"")
    as "the dock holds the composer"
  assert string.contains(above_composer, "class=\"approvals\"")
  assert !string.contains(dock, "class=\"transcript lane\"")
}

// A card's action row carries the arming class, which the stylesheet uses
// to refuse clicks on Deny and Allow for 600 ms after the card is inserted,
// so a click already on its way to the transcript cannot land on Allow.
pub fn an_approval_cards_buttons_are_armed_test() {
  let #(model, _) = page("operator", pending())
  let html = element.to_string(operator_page.view(model))
  let assert Ok(#(_, actions)) =
    string.split_once(html, "<div class=\"approval-actions arming\">")
    as "the card's action row carries the arming class"
  assert string.contains(actions, "Allow fs_write once")
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
      operator_page.Observed(
        component.Arrived([connection_event.Closed("access was revoked")]),
      ),
      operator_page.Observed(component.Ticked),
      operator_page.Submitted("hello", operator.Prompt),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// An operator's page that ended says so in its heading, as the observer's
// does, and the regions after the heading keep the paths they had, so a
// submit already in flight still names the form it meant.
pub fn an_ended_operator_page_says_so_and_keeps_its_paths_test() {
  let #(model, _) = page("operator", [])
  let live = element.to_string(operator_page.view(model))
  assert !string.contains(live, "ended-notice")
  let closed =
    send(model, [
      operator_page.Observed(
        component.Arrived([
          connection_event.Closed(ending.reason(ending.PageEnded)),
        ]),
      ),
    ])
  let html = element.to_string(operator_page.view(closed))
  assert string.contains(html, "class=\"ended-notice\"")
  assert string.contains(html, ending.headline(ending.PageEnded))

  // The notice is inside the heading, before the strip, so it is the
  // heading's last child and nothing else moved.
  assert in_order(html, [
    "class=\"session-head\"",
    "class=\"ended-notice\"",
    "</header>",
    "class=\"agent-strip\"",
  ])
}

// The page's frame is pinned: the heading and the agent strip above the
// transcript, the dock below it, in that order among `main`'s children. The
// stylesheet gives the transcript (`<loom-follow>`) the height between
// them and scrolls only it, so the order here is what pins the header at
// the top and the composer and approvals at the bottom.
pub fn the_frame_is_heading_strip_transcript_dock_test() {
  let #(model, _) = page("operator", pending())
  let html = element.to_string(operator_page.view(model))
  assert in_order(html, [
    "class=\"session-head\"",
    "class=\"agent-strip\"",
    "<loom-follow class=\"follow\">",
    "<footer class=\"dock\">",
  ])
}

// Whether each part appears in `html` after the one before it.
fn in_order(html: String, parts: List(String)) -> Bool {
  case parts {
    [] -> True
    [part, ..rest] ->
      case string.split_once(html, part) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}
