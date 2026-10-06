//// An operator's page sends exactly the two commands it offers, through the
//// engine's command arms, and nothing a browser can fire decides an
//// approval except that approval's own button (protocol-change/051, the
//// operator addendum).
////
//// What the page sends is read from the transport, with every effect
//// performed (`page_fixture.run`); which handlers the page holds is read
//// through Lustre's simulator, which dispatches only to handlers the
//// rendered tree carries, as the browser runtime does.

import core/message
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/approval
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
    send(model, [
      operator_page.Submitted("inspect the tree", operator.Prompt, []),
    ])
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
  let _ = send(model, [operator_page.Submitted("go left", operator.Steer, [])])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one steer is one command"
  assert string.contains(frame, "\"cmd\":\"steer\"")
}

// A draft that parses as a session command is that command, as it is in the
// terminal. The page used to send every draft to the model as a prompt, so
// `/compact` was an instruction to the model rather than a compaction.
pub fn a_slash_command_is_the_command_and_not_a_prompt_test() {
  let #(model, wire) = page("operator", [])
  let _ =
    send(model, [operator_page.Submitted("/compact", operator.Prompt, [])])
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
    send(model, [
      operator_page.Submitted("/frobnicate now", operator.Prompt, []),
    ])
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
      operator_page.Submitted("/models", operator.Prompt, []),
      operator_page.Submitted("/sessions", operator.Prompt, []),
      operator_page.Submitted("/details", operator.Prompt, []),
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
      operator_page.Submitted("/add-dir /tmp/x", operator.Prompt, []),
      operator_page.Submitted("/add-write-dir /tmp/x", operator.Prompt, []),
      operator_page.Submitted("/add-dir --write /tmp/x", operator.Prompt, []),
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
  let model =
    send(model, [operator_page.Submitted("/clear", operator.Prompt, [])])
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
    == component.Said("Sending")
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
  let model = send(model, [operator_page.Submitted("y", operator.Prompt, [])])
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
      operator_page.Submitted("hello", operator.Prompt, []),
      operator_page.Decided("esc-1", 7, component.Deny),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn an_empty_or_oversized_draft_is_refused_before_the_lane_test() {
  let #(model, wire) = page("operator", [])
  let _ =
    send(model, [
      operator_page.Submitted("   ", operator.Prompt, []),
      operator_page.Submitted(
        string.repeat("x", component.prompt_limit + 1),
        operator.Prompt,
        [],
      ),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// The composer's element shows a pressed draft as a pending line until the
// server takes it, which replaces the editor, or refuses it, which the
// `refused` attribute says (`web_client/pending_rule`). The count rises for
// a refusal the page makes itself and for one the lane's admission check
// makes, both of which keep the draft, and not for a draft the lane takes.
pub fn the_refused_count_rises_only_when_the_draft_is_kept_test() {
  let #(model, wire) = page("operator", [])
  assert component.refusals(model) == 0
  assert string.contains(
    element.to_string(operator_page.view(model)),
    "refused=\"0\"",
  )

  // The page's own refusal, before the lane.
  let model = send(model, [operator_page.Submitted("   ", operator.Prompt, [])])
  assert component.refusals(model) == 1

  // A draft the lane takes.
  let model = send(model, [operator_page.Submitted("hi", operator.Prompt, [])])
  assert component.refusals(model) == 1
  assert component.drafts(model) == 1
  let _ = page_fixture.sent(wire)

  // A refusal that is not the composer's leaves the count alone: a stale
  // approval card and a reply to a message no longer on the page are told
  // in the notice, and a steer the lane holds must stay in flight.
  let other =
    send(model, [
      operator_page.Decided("esc-gone", 1, component.Deny),
      operator_page.Replying("no-such-key"),
    ])
  assert component.refusals(other) == 1
  assert component.notice(other)
    == component.Warned(
      "That message is no longer on the page, so no reply was started.",
    )

  // The lane's admission check: a mutation on a closed connection keeps the
  // draft, and the count says so.
  let closed =
    send(other, [
      operator_page.Observed(
        component.Arrived([connection_event.Closed("access was revoked")]),
      ),
      operator_page.Observed(component.Ticked),
      operator_page.Submitted("again", operator.Prompt, []),
    ])
  assert component.refusals(closed) == 2
  assert component.drafts(closed) == 1
  assert string.contains(
    element.to_string(operator_page.view(closed)),
    "refused=\"2\"",
  )
}

// The notice states the outcome of the latest command. A refusal the page
// made itself is replaced by the next command that is sent, and that
// "sent" by the daemon's acknowledgement of it.
pub fn a_later_outcome_replaces_the_notice_test() {
  let #(model, wire) = page("operator", [])
  let model = send(model, [operator_page.Submitted("   ", operator.Prompt, [])])
  assert component.notice(model) == component.Warned("Nothing to send.")

  let model = send(model, [operator_page.Submitted("hi", operator.Prompt, [])])
  assert component.notice(model) == component.Said("Sending")

  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one prompt is one command"
  let model =
    send(model, [
      reply(frame, "\"mutation_outcome\",\"body\":{\"status\":\"admitted\"}"),
    ])
  assert component.notice(model) == component.Said("Sent")
}

// A command the daemon refuses replaces the "sent" notice with the refusal,
// which the shared step words as the code and the daemon's message. The
// message is the daemon's own text, and the page draws it as text only.
pub fn a_refusal_replaces_the_sent_notice_test() {
  let #(model, wire) = running("operator")
  let model =
    send(model, [operator_page.Submitted("go left", operator.Steer, [])])
  assert component.notice(model) == component.Said("Sending")

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
  let model = send(model, [operator_page.Submitted("hi", operator.Prompt, [])])
  let model =
    component.apply(model, [
      session_channel.Streamed("main", "op-1", "gen-1", "text", "hello"),
    ])
  assert component.notice(model) == component.Said("Sending")
}

// A command that says nothing leaves the page quiet rather than repeating
// what the session said before it.
pub fn a_silent_command_does_not_repeat_an_older_notice_test() {
  let #(model, _) = page("operator", [])
  let model =
    component.apply(model, [
      session_channel.Streamed("main", "op-1", "gen-1", "text", "hello"),
    ])
  let model =
    send(model, [operator_page.Submitted("/clear", operator.Prompt, [])])
  assert component.notice(model) == component.Said("local view cleared")
}

// A refused automatic read is nobody's command outcome. A refused command is.
pub fn only_a_commands_refusal_is_drawn_test() {
  let #(model, wire) = page("operator", [])
  let model = send(model, [operator_page.Submitted("hi", operator.Prompt, [])])
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
    == Ok(operator_page.Submitted("hi", operator.Prompt, []))
  assert operator_page.composition([
      #("draft", "hi"),
      #("delivery", "steer"),
    ])
    == Ok(operator_page.Submitted("hi", operator.Steer, []))
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
      operator_page.Submitted("hello", operator.Prompt, []),
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

  // The notice is inside the top bar, before the centre and the panel, so
  // it is the bar's last child and nothing else moved.
  assert in_order(html, [
    "class=\"session-head\"",
    "class=\"ended-notice\"",
    "</header>",
    "<main class=\"centre\">",
    "class=\"agent-strip\"",
  ])
}

// The page's frame is pinned: the top bar above the centre, whose transcript
// is above its dock, and the strand panel last, in that order among the
// frame's children. The stylesheet gives the transcript (`<loom-follow>`) the
// height between the bar and the dock and scrolls only it, so the order here
// is what pins the bar at the top and the composer and approvals at the
// bottom of the centre.
pub fn the_frame_is_bar_centre_panel_test() {
  let #(model, _) = page("operator", pending())
  let html = element.to_string(operator_page.view(model))
  assert in_order(html, [
    "<loom-shell class=\"loom-session operator\"",
    "class=\"session-head\"",
    "<main class=\"centre\">",
    "<loom-follow class=\"follow\">",
    "<footer class=\"dock\">",
    "</main>",
    "<aside aria-label=\"Strand panel\" class=\"panel\" slot=\"right\">",
    "pane pane-strands",
    "class=\"agent-strip\"",
    "pane pane-changes",
    "pane pane-session",
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

// --- images from the composer (protocol-change/051, the addendum on images) --

// The bytes of a PNG as `<loom-attach>` submits them: base64 text.
fn attached_png() -> String {
  lane_fixture.png
}

pub fn an_image_prompt_is_sent_as_one_ordered_turn_test() {
  let #(model, wire) = page("operator", [])
  let model =
    send(model, [
      operator_page.Submitted("what is this", operator.Prompt, [attached_png()]),
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one image prompt is one command"
  assert string.contains(frame, "\"cmd\":\"prompt_content\"")
  assert string.contains(frame, "\"strand\":\"main\"")
  assert string.contains(frame, "what is this")
  assert string.contains(frame, "\"type\":\"image\"")
  assert string.contains(frame, "\"mimeType\":\"image/png\"")
  assert string.contains(frame, attached_png())
  assert component.drafts(model) == 1
}

pub fn an_image_alone_is_a_prompt_test() {
  let #(model, wire) = page("operator", [])
  let _ =
    send(model, [operator_page.Submitted("", operator.Prompt, [attached_png()])])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "an image with no words is still a prompt"
  assert string.contains(frame, "\"cmd\":\"prompt_content\"")
}

// The type is the bytes' own. A browser that says `image/png` of a page of
// HTML is refused, and the notice says what is allowed.
pub fn a_file_that_is_not_an_image_is_refused_with_a_notice_test() {
  let #(model, wire) = page("operator", [])
  let html = bit_array.base64_encode(<<"<html><script/></html>":utf8>>, True)
  let model =
    send(model, [operator_page.Submitted("look", operator.Prompt, [html])])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert component.notice(model)
    == component.Warned(
      "Only PNG, JPEG, GIF and WebP images can be attached. Nothing was sent.",
    )
  assert component.drafts(model) == 0
}

pub fn text_that_is_not_base64_is_refused_with_a_notice_test() {
  let #(model, wire) = page("operator", [])
  let model =
    send(model, [operator_page.Submitted("look", operator.Prompt, ["!!"])])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert component.notice(model)
    == component.Warned(
      "An attached image is not valid base64. Nothing was sent.",
    )
}

pub fn a_fifth_image_refuses_the_whole_prompt_test() {
  let #(model, wire) = page("operator", [])
  let five = list.repeat(attached_png(), 5)
  let model =
    send(model, [operator_page.Submitted("look", operator.Prompt, five)])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert component.notice(model)
    == component.Warned("A prompt carries at most 4 images. Nothing was sent.")
}

pub fn a_steer_carries_no_images_test() {
  let #(model, wire) = running("operator")
  let model =
    send(model, [
      operator_page.Submitted("look", operator.Steer, [attached_png()]),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert component.notice(model)
    == component.Warned(
      "Images go with Send or Queue, not Steer. Nothing was sent.",
    )
}

// An image is new prompt content. A session command has nowhere to put one,
// and the shared step refuses it rather than dropping the image.
pub fn a_slash_command_with_an_image_is_refused_test() {
  let #(model, wire) = page("operator", [])
  let _ =
    send(model, [
      operator_page.Submitted("/compact", operator.Prompt, [attached_png()]),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// The page keeps no attachments between submits. A refused submit whose
// element still holds its images sends them once, with the next submit.
pub fn a_refused_submit_leaves_no_attachment_behind_test() {
  let #(model, wire) = page("operator", [])
  let model =
    send(model, [
      operator_page.Submitted("/frobnicate", operator.Prompt, [attached_png()]),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let _ =
    send(model, [operator_page.Submitted("plain words", operator.Prompt, [])])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "the later prompt is text alone"
  assert string.contains(frame, "\"cmd\":\"prompt\"")
  assert !string.contains(frame, "image")
}

pub fn the_composer_form_accepts_an_images_field_test() {
  assert operator_page.composition([
      #("draft", "hi"),
      #("images", "[\"QUFB\",\"QkJC\"]"),
    ])
    == Ok(operator_page.Submitted("hi", operator.Prompt, ["QUFB", "QkJC"]))
  assert operator_page.composition([
      #("draft", "hi"),
      #("delivery", "steer"),
      #("images", "[]"),
    ])
    == Ok(operator_page.Submitted("hi", operator.Steer, []))
}

pub fn the_composer_form_refuses_a_malformed_images_field_test() {
  list.each(
    [
      [#("draft", "a"), #("images", "not json")],
      [#("draft", "a"), #("images", "{\"a\":1}")],
      [#("draft", "a"), #("images", "[1,2]")],
      [#("draft", "a"), #("images", "[\"a\",null]")],
      [#("draft", "a"), #("images", "\"QUFB\"")],
      [#("draft", "a"), #("images", "[]"), #("images", "[]")],
      [#("draft", "a"), #("images", "[]"), #("image", "x")],
      [#("images", "[]")],
    ],
    fn(fields) {
      let assert Error(Nil) = operator_page.composition(fields)
        as "a forged images field refuses the event"
    },
  )
}

// The operator's composer draws the element that attaches images, inside its
// form and keyed with its draft, and an observer's page has neither.
pub fn only_the_operators_composer_draws_the_attach_element_test() {
  let #(model, _) = page("operator", [])
  let html = element.to_string(operator_page.view(model))
  let assert Ok(#(_, from_form)) =
    string.split_once(html, "aria-label=\"Composer\"")
    as "the page draws a composer form"
  let assert Ok(#(form, _)) = string.split_once(from_form, "</form>")
    as "the form is closed"
  assert string.contains(form, "<loom-attach")
  assert string.contains(form, "name=\"images\"")
  assert string.contains(form, "limits=\"")
  assert string.contains(form, "&quot;count&quot;:4")
  assert string.contains(form, "image/webp")

  let observer = element.to_string(component.view(model))
  assert !string.contains(observer, "loom-attach")
  assert !string.contains(observer, "images")
}

// --- the composer as a card -----------------------------------------------------

fn composer_of(html: String) -> String {
  let assert Ok(#(_, from_form)) =
    string.split_once(html, "<form aria-label=\"Composer\"")
    as "the page draws the composer"
  let assert Ok(#(form, _)) = string.split_once(from_form, "</form>")
    as "the form is closed"
  form
}

// The composer is three rows: a `To` line with the strand's tag, the editor,
// and a footer holding the hint, the attach element, who the page acts as and
// the actions. The tag is a label with no handler.
pub fn the_composer_is_a_to_line_an_editor_and_a_footer_test() {
  let #(model, _) = page("operator", [])
  let form = composer_of(element.to_string(operator_page.view(model)))
  assert in_order(form, [
    "class=\"to\"",
    "To",
    "class=\"to-tag hue-main\"",
    "main",
    "class=\"editor\"",
    "<textarea",
    "placeholder=\"Message the agent\"",
    "class=\"composer-actions\"",
    "<loom-attach",
    "class=\"hint\"",
    "Cmd+Enter to send",
    "class=\"who\"",
    "class=\"send\"",
  ])
  assert !string.contains(form, "identity")
  assert !string.contains(form, "role-badge")
  assert !string.contains(form, "Turn is busy")
}

pub fn a_busy_turn_says_so_in_the_footer_and_offers_queue_and_steer_test() {
  let #(model, _) = running("operator")
  let form = composer_of(element.to_string(operator_page.view(model)))
  assert string.contains(form, "Turn is busy · Cmd+Enter to send")
  assert in_order(form, ["class=\"queue\"", "class=\"steer\""])
  assert !string.contains(form, "class=\"send\"")
}

// A notice is keyed by how many times it changed, so a new one is a new
// element and the stylesheet's fade starts for it; a refused input stays
// until the next, as a warning is not faded.
pub fn each_new_notice_is_a_new_element_and_a_warning_is_not_faded_test() {
  let #(model, _) = page("operator", [])
  let before = component.notice_serial(model)
  let model = send(model, [operator_page.Submitted("hi", operator.Prompt, [])])
  assert component.notice_serial(model) == before + 1
  let html = element.to_string(operator_page.view(model))
  assert string.contains(html, "class=\"notice\"")
  assert string.contains(html, "Sending")
  assert !string.contains(html, "prompt sent")

  let model = send(model, [operator_page.Submitted("   ", operator.Prompt, [])])
  assert component.notice_serial(model) == before + 2
  assert string.contains(
    element.to_string(operator_page.view(model)),
    "notice warned",
  )

  // A message that leaves the words alone leaves the key alone.
  let same = send(model, [operator_page.Observed(component.Ticked)])
  assert component.notice_serial(same) == before + 2
}

// The card says who waits and what for, in a sentence a reader would write,
// and shows its arming delay as words while the row refuses clicks.
pub fn an_approval_card_is_worded_for_a_reader_test() {
  let #(model, _) =
    page("operator", [page_fixture.waiting("esc-1", 7, "bash", "sub:tests")])
  let html = element.to_string(operator_page.view(model))
  assert in_order(html, [
    "class=\"approval-head\"",
    "<b class=\"approval-strand\">sub:tests</b>",
    " wants to run a command",
    "class=\"approval-question\"",
    "Deny bash",
    "Allow bash once",
    "class=\"arm-note\"",
    "Arming…",
  ])
  assert !string.contains(html, "Waits for approval")
}

// A decided approval leaves a line in the lane: who answered, what, and for
// which tool. The page saw each request pending, which told it the strand that
// raised it, and the host's lookup of the decision put the author in the
// ledger. The line belongs to the strand that raised the request.
pub fn a_denied_approval_leaves_a_who_line_in_the_lane_test() {
  let #(model, _) = page("operator", [])
  let model =
    component.apply(model, [
      lane_fixture.captured_cells(10, None, [], [
        page_fixture.pending_cell("esc-9", 12, "bash", "main"),
        page_fixture.pending_cell("esc-10", 14, "fs_write", "main"),
        page_fixture.pending_cell("esc-11", 15, "bash", "sub:x"),
      ]),
    ])
  let owner = Some(message.Origin("principal-owner", "Owner"))
  let resolved = fn(id, seq, status, tool) {
    approval.Review(
      id,
      seq,
      status,
      tool,
      "printf hi",
      owner,
      approval.Unavailable("this decision is already resolved"),
      strand: None,
    )
  }
  let model =
    component.apply(model, [
      lane_fixture.captured_cells(10, None, [], []),
      session_channel.LookedUp(
        [
          resolved("esc-9", 20, approval.Rejected, "bash"),
          resolved("esc-10", 22, approval.Approved, "fs_write"),
          resolved("esc-11", 23, approval.Rejected, "bash"),
        ],
        [],
      ),
    ])
  let html = element.to_string(operator_page.view(model))
  assert in_order(html, [
    "class=\"decided decided-denied\"",
    "<span class=\"decided-who\">Owner</span>",
    " denied ",
    "<span class=\"decided-tool\">bash</span>",
    "class=\"decided decided-allowed\"",
    " allowed ",
    "fs_write",
  ])
  assert count(html, "class=\"decided ") == 2
}

fn count(html: String, part: String) -> Int {
  list.length(string.split(html, part)) - 1
}
