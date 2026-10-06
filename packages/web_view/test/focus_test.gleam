//// Strand focus: a chip of the agent strip makes the page show and address
//// that strand (protocol-change/051, the addendum on strand focus).
////
//// A focus is the shared step's change of strand (`step.focus`) run by the
//// page. It sends no command, so an observer's page carries it; and because
//// every command the operator's page sends addresses the active strand, what
//// the operator does after a focus is done to the strand on screen. What a
//// page sends is read from the transport with every effect performed, and
//// which chips a page holds is read through Lustre's simulator, which
//// dispatches only to handlers the rendered tree carries.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/operator
import session_view/transcript_line.{type Line, Assistant, Line}
import web_view/component
import web_view/operator_page

// An observer's page holding the forked capture: `main`, the reviewer and the
// advisor each have a transcript of their own.
fn observing(running: List(#(String, String))) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(page_fixture.start()),
      component.update,
      list.flatten([
        [component.Opened(wire)],
        list.map(page_fixture.transfer("observer", []), fn(frame) {
          component.Arrived([frame])
        }),
        [component.Ticked],
      ]),
    )
    |> page_fixture.refuse_reads(component.update, wire, component.Arrived)
  let _ = page_fixture.sent(wire)
  #(component.apply(model, [lane_fixture.forked(None, running)]), wire)
}

// An operator's page holding the same capture.
fn operating(running: List(#(String, String))) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(page_fixture.start()),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer("operator", []), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> page_fixture.refuse_reads(operator_page.update, wire, fn(frames) {
      operator_page.Observed(component.Arrived(frames))
    })
  let _ = page_fixture.sent(wire)
  #(component.apply(model, [lane_fixture.forked(None, running)]), wire)
}

fn reviewer_running() {
  [#(lane_fixture.child, lane_fixture.review_op())]
}

fn focused(model, strand: String) {
  page_fixture.run(model, component.update, [component.FocusRequested(strand)])
}

// The advisor's note as the advisor's own transcript draws it. On `main`'s
// transcript the same record is the marked commentary, not the advisor's
// speech.
fn advisor_said() -> Line {
  Line(Assistant, "advisor: watch the <sweep>")
}

fn html(model) -> String {
  element.to_string(component.view(model))
}

fn texts(model) -> String {
  string.inspect(component.lines(model))
}

// A page starts on `main`, and its transcript is `main`'s.
pub fn a_page_starts_on_main_test() {
  let #(model, _) = observing([])
  assert component.strand(model) == component.primary
  assert string.contains(texts(model), "Done: two files.")
  assert !list.contains(component.lines(model), advisor_said())
}

// Focusing the advisor draws the advisor's own records where `main`'s were,
// and returning to `main` draws `main`'s again: the record parks each strand's
// window and restores it.
pub fn focusing_the_advisor_draws_its_transcript_and_back_test() {
  let #(model, _) = observing([])
  let main_rows = component.rows(model)

  let advisor = focused(model, "advisor")
  assert component.strand(advisor) == "advisor"
  assert list.contains(component.lines(advisor), advisor_said())

  let back = focused(advisor, "main")
  assert component.strand(back) == "main"
  assert component.rows(back) == main_rows
}

// A reviewer's transcript is drawn from its own branch, which forks from
// `main`'s second record, so the reviewer's rows are its question and reply
// and the first record `main` shares with it.
pub fn focusing_a_reviewer_draws_its_branch_test() {
  let #(model, _) = observing(reviewer_running())
  let reviewer = focused(model, lane_fixture.child)
  assert component.strand(reviewer) == lane_fixture.child
  assert string.contains(texts(reviewer), "check the <patch> twice")
  assert string.contains(texts(reviewer), "reviewer: <b>two</b> nits")
  assert !string.contains(texts(reviewer), "Done: two files.")
}

// The strip marks the strand on screen, and only that one, and the strand's
// name is drawn as text.
pub fn the_strip_marks_the_focused_chip_test() {
  let #(model, _) = observing(reviewer_running())
  assert string.contains(html(model), "class=\"chip following hue-main\"")

  let reviewer = focused(model, lane_fixture.child)
  let drawn = html(reviewer)
  assert string.contains(drawn, "class=\"chip following hue-2\"")
  assert !string.contains(drawn, "class=\"chip following hue-main\"")
  assert list.length(string.split(drawn, "aria-current")) == 2
  assert !string.contains(drawn, "<b>review")
  assert string.contains(drawn, "&lt;b&gt;review")
}

// The advisor's chip is a chip like the others, and focusing it marks it.
pub fn the_advisors_chip_focuses_too_test() {
  let #(model, _) = observing([])
  let advisor = focused(model, "advisor")
  assert string.contains(html(advisor), "class=\"chip following hue-advisor\"")
}

// A strand the capture does not list, and the strand already shown, are not
// focus changes.
pub fn focusing_an_unlisted_or_shown_strand_changes_nothing_test() {
  let #(model, wire) = observing([])
  let ghost = focused(model, "ghost")
  assert component.strand(ghost) == "main"
  let same = focused(model, "main")
  assert component.strand(same) == "main"
  assert component.rows(same) == component.rows(model)
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// A page that has not drawn a capture yet has no strand to move to.
pub fn a_page_with_no_capture_does_not_focus_test() {
  let model = component.new(page_fixture.start())
  let #(after, _) = component.focus(model, "advisor")
  assert component.strand(after) == "main"
}

// A page that is paged back returns to the newest rows when it focuses
// another strand, as a page's first strand starts.
pub fn a_focus_starts_the_new_strand_at_its_tail_test() {
  let model =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(301, 450)])
  let #(paged, _) = component.older(model)
  assert component.paging(paged) == component.Paged
  let #(moved, _) = component.focus(paged, "advisor")
  assert component.paging(moved) == component.Tail
}

// A strand the reader paged back keeps the older rows it loaded while they
// look at another strand. The window parks under the strand's name, and so
// does the row limit; restoring only the window would trim it back to the
// newest `live_rows` on the next projection.
pub fn a_strands_loaded_history_survives_a_round_trip_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
  let page =
    page_fixture.run(page, component.update, [component.OlderRequested])
  let assert [read] =
    page_fixture.sent(wire)
    |> list.filter(fn(frame) { string.contains(frame, "\"cmd\":\"history\"") })
  let page =
    page_fixture.run(page, component.update, [
      component.Arrived(page_fixture.history(
        page_fixture.request_id(read),
        "operator",
        lane_fixture.older_page(201, 300),
        301,
      )),
    ])
  let loaded = list.length(component.rows(page))
  assert loaded > component.live_rows

  let away = focused(page, "advisor")
  assert component.paging(away) == component.Tail

  let back = focused(away, "main")
  assert component.paging(back) == component.Paged
  assert list.length(component.rows(back)) == loaded
}

// The key `<loom-follow>` keeps the reader's place under is a number the page
// assigned, never the strand's name, which a peer may have chosen. A strand
// keeps its number when the reader comes back to it, and two strands never
// share one.
pub fn the_lane_draws_a_numeric_strand_key_and_not_the_name_test() {
  let #(model, _) = observing([])
  let key = fn(model, number) {
    string.contains(
      html(model),
      "data-strand-key=\"" <> int.to_string(number) <> "\"",
    )
  }
  assert key(model, 1)
  let advisor = focused(model, "advisor")
  assert key(advisor, 2)
  assert key(focused(advisor, "main"), 1)
  assert component.marks(focused(advisor, "main")).key == 1
  assert !string.contains(html(advisor), "data-strand-key=\"advisor\"")
  assert !string.contains(html(advisor), "data-strand-key=\"main\"")
}

// A parked depth is used only over a window that still holds rows. The record
// empties a retired strand's parked window, so a strand that returns under
// the same name opens at its tail: restoring `Paged` over the empty window
// would draw no Load older, and the reader could not page.
pub fn a_returning_strand_does_not_get_a_depth_over_an_emptied_window_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
  let page =
    page_fixture.run(page, component.update, [component.OlderRequested])
  let assert [read] =
    page_fixture.sent(wire)
    |> list.filter(fn(frame) { string.contains(frame, "\"cmd\":\"history\"") })
  let page =
    page_fixture.run(page, component.update, [
      component.Arrived(page_fixture.history(
        page_fixture.request_id(read),
        "operator",
        lane_fixture.older_page(201, 300),
        301,
      )),
    ])
  assert component.paging(page) == component.Paged

  // Main is left, retires from the capture, and is listed again.
  let away = focused(page, "advisor")
  let retired =
    component.apply(away, [
      lane_fixture.without_strand(lane_fixture.conversation(301, 451), "main"),
    ])
  let listed = component.apply(retired, [lane_fixture.conversation(301, 452)])
  let back = focused(listed, "main")
  assert component.paging(back) == component.Tail
}

// An observer's focus writes no command. It may ask for a read, the strand's
// configuration, and the gateway admits reads from an observer's binding.
pub fn an_observers_focus_sends_no_command_test() {
  let #(model, wire) = observing([])
  let _ = focused(model, "advisor")
  let sent = page_fixture.commands(page_fixture.sent(wire))
  list.each(
    ["prompt", "steer", "queue", "interrupt", "decide", "approve", "fork"],
    fn(name) {
      assert list.all(sent, fn(frame) {
        !string.contains(frame, "\"cmd\":\"" <> name <> "\"")
      })
    },
  )
}

// An observer who has focused a strand still has no composer and no control
// but the chips and the marker controls, which carry no handler: the
// breadcrumb's link, the strand view's back link and the transcript's tags.
pub fn an_observer_can_focus_but_not_act_test() {
  let #(model, _) = observing(reviewer_running())
  let drawn = html(focused(model, lane_fixture.child))
  assert !string.contains(drawn, "<textarea")
  assert !string.contains(drawn, "<form")
  assert string.contains(drawn, "Observer · read-only")
  let buttons = list.length(string.split(drawn, "<button")) - 1
  let chips = list.length(string.split(drawn, "class=\"chip-hit\"")) - 1
  let markers = marker_buttons(drawn)
  assert markers >= 2
  let dividers = list.length(string.split(drawn, "data-loom-fold")) - 1
  assert dividers >= 1
  assert buttons == chips + markers + dividers
}

// How many buttons carry the marker that the shell relays, read from the
// text of each button's opening tag.
fn marker_buttons(html: String) -> Int {
  string.split(html, "<button")
  |> list.drop(1)
  |> list.count(fn(rest) {
    case string.split_once(rest, ">") {
      Ok(#(opening, _)) -> string.contains(opening, "data-loom-focus")
      Error(Nil) -> False
    }
  })
}

// A press on a chip reaches the page as the focus, through the handler the
// rendered tree carries, on the observer's page.
pub fn a_press_on_the_advisors_chip_focuses_it_on_an_observers_page_test() {
  let #(model, _) = observing([])
  let pressed =
    simulate.application(
      init: fn(_) { #(model, effect.none()) },
      update: component.update,
      view: component.view,
    )
    |> simulate.start(Nil)
    |> simulate.click(on: query.descendant(
      // The lane's own rows and cards carry hue classes too, and the centre
      // comes before the panel, so the chip is named by its own class as well.
      of: query.element(query.and(
        query.class("chip"),
        query.class("hue-advisor"),
      )),
      matching: query.class("chip-hit"),
    ))
  assert component.strand(simulate.model(pressed)) == "advisor"
}

// The operator's page carries the same chips.
pub fn a_press_on_a_chip_focuses_it_on_an_operators_page_test() {
  let #(model, _) = operating(reviewer_running())
  let pressed =
    simulate.application(
      init: fn(_) { #(model, effect.none()) },
      update: operator_page.update,
      view: operator_page.view,
    )
    |> simulate.start(Nil)
    |> simulate.click(on: query.descendant(
      // The lane's own cards carry hue classes too, and the centre comes
      // before the panel, so the chip is named by its own class as well.
      of: query.element(query.and(query.class("chip"), query.class("hue-2"))),
      matching: query.class("chip-hit"),
    ))
  assert component.strand(simulate.model(pressed)) == lane_fixture.child
}

// The operator's prompt goes to the strand on screen: the advisor after its
// chip is pressed, and `main` again after `main`'s chip is pressed back. The
// lane takes one command at a time, so each prompt is sent from its own page.
pub fn an_operators_prompt_goes_to_the_focused_strand_test() {
  let #(model, wire) = operating([])
  let model =
    page_fixture.run(model, operator_page.update, [
      operator_page.Observed(component.FocusRequested("advisor")),
    ])
  let _ = page_fixture.sent(wire)
  let model =
    page_fixture.run(model, operator_page.update, [
      operator_page.Submitted("second", operator.Prompt, []),
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one prompt is one frame"
  assert string.contains(frame, "\"cmd\":\"prompt\"")
  assert string.contains(frame, "\"strand\":\"advisor\"")
  assert string.contains(frame, "second")

  // The composer names the strand it addresses.
  let drawn = element.to_string(operator_page.view(model))
  assert string.contains(drawn, "to-tag")
  assert string.contains(drawn, "Message the agent")
}

pub fn a_prompt_after_focusing_back_goes_to_main_test() {
  let #(model, wire) = operating([])
  let model =
    page_fixture.run(model, operator_page.update, [
      operator_page.Observed(component.FocusRequested("advisor")),
      operator_page.Observed(component.FocusRequested("main")),
    ])
  let _ = page_fixture.sent(wire)
  let _ =
    page_fixture.run(model, operator_page.update, [
      operator_page.Submitted("third", operator.Prompt, []),
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one prompt is one frame"
  assert string.contains(frame, "\"strand\":\"main\"")
  assert string.contains(frame, "third")
}

// A running strand is queued behind or steered, and both go to the strand on
// screen, not to `main`: the composer's Queue and Steer follow the focused
// strand's activity.
pub fn an_operators_queue_and_steer_go_to_the_focused_strand_test() {
  let #(model, wire) = operating(reviewer_running())
  let model =
    page_fixture.run(model, operator_page.update, [
      operator_page.Observed(component.FocusRequested(lane_fixture.child)),
    ])
  let _ = page_fixture.sent(wire)
  assert component.activity(model) == component.Busy
  let drawn = element.to_string(operator_page.view(model))
  assert string.contains(drawn, "Steer")
  assert string.contains(drawn, "Queue")

  let named = "\"strand\":\"" <> lane_fixture.child <> "\""
  let _ =
    page_fixture.run(model, operator_page.update, [
      operator_page.Submitted("look again", operator.Steer, []),
    ])
  let assert [steer] = page_fixture.commands(page_fixture.sent(wire))
    as "one steer is one frame"
  assert string.contains(steer, "\"cmd\":\"steer\"")
  assert string.contains(steer, named)
}

// The strand the operator is not addressing does not decide the composer's
// activity: `main` is idle while the reviewer runs, so focused on `main` the
// composer offers one Send.
pub fn the_composer_follows_the_focused_strands_activity_test() {
  let #(model, _) = operating(reviewer_running())
  assert component.activity(model) == component.Idle
  let #(reviewer, _) = component.focus(model, lane_fixture.child)
  assert component.activity(reviewer) == component.Busy
  let #(back, _) = component.focus(reviewer, "main")
  assert component.activity(back) == component.Idle
}

// A sub-agent's name is chosen by the model, so it is session text: the
// composer shows it only as the tag's text node, and no attribute (a title, the
// field's label or its placeholder) holds it. The fixture's child name carries
// markup characters, which must arrive escaped and only as text.
pub fn the_composer_names_a_sub_agent_only_as_text_test() {
  let #(model, _) = operating(reviewer_running())
  let #(model, _) = component.focus(model, lane_fixture.child)
  let drawn = element.to_string(operator_page.view(model))
  assert string.contains(drawn, ">&lt;b&gt;review</span>")
  assert string.contains(drawn, "placeholder=\"Message the agent\"")
  assert string.contains(drawn, "aria-label=\"Message the agent\"")

  // Nothing inside an opening tag holds the name.
  assert list.all(string.split(drawn, "<"), fn(tag) {
    case string.split_once(tag, ">") {
      Ok(#(inside, _)) -> !string.contains(inside, "b&gt;review")
      Error(Nil) -> True
    }
  })
  assert !string.contains(drawn, "<script")
}
