//// The strand panel: four panes in a fixed order as the frame's last child,
//// the badge's count, and the rule that the panel carries no decision.
////
//// The tabs and the choice between them are `<loom-shell>`'s
//// (`packages/web_client`), which runs in a browser; these tests read the
//// markup the server writes for it. What they pin is what the server owes the
//// element: every pane is drawn, always, in one order; the panel is the last
//// child of the frame so a later region cannot move an admitted path; a strand
//// waiting on a decision is counted and says so in words; and the decision
//// itself, the approval card, is in the dock and nowhere in the panel.

import gleam/list
import gleam/option.{None}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page

const panel_start = "<aside aria-label=\"Strand panel\""

// A capture in which `strand` waits on a decision while its operation `op`
// runs: the escalation's scope names the strand and the operation, which is
// the evidence `agent_view` requires before it says a strand needs input.
fn waiting_on(strand: String, op: String) {
  let escalation = lane_fixture.pending_approval(strand, op)
  let #(main, others) = case strand {
    "main" -> #(option.Some(op), [])
    _ -> #(None, [#(strand, op)])
  }
  component.new(page_fixture.start())
  |> component.apply([
    lane_fixture.captured_cells(10, main, others, [escalation]),
  ])
}

// The second working agent waits. Its approval card is not drawn, since cards
// are drawn for the strand on screen and that is `main`.
fn waiting() {
  waiting_on(lane_fixture.tester, lane_fixture.tests_op())
}

// `main` waits, so its approval card is drawn in the dock.
fn main_waiting() {
  waiting_on("main", lane_fixture.main_op())
}

fn quiet() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.captured(10, None)])
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

// The panel's markup: from its opening tag to its closing one, which no other
// `aside` is nested in.
fn panel_of(html: String) -> String {
  let assert Ok(#(_, from)) = string.split_once(html, panel_start)
    as "the page draws the panel"
  let assert Ok(#(panel, _)) = string.split_once(from, "</aside>")
    as "the panel is closed"
  panel
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
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

// Every pane is drawn on every page, in one order, so that no pane's place
// depends on what another holds and the element's choice between them is
// only a matter of which it shows.
pub fn every_pane_is_drawn_in_a_fixed_order_on_both_pages_test() {
  list.each([operator(quiet()), observer(quiet())], fn(html) {
    let panel = panel_of(html)
    assert in_order(panel, [
      "pane pane-strands",
      "pane pane-changes",
      "pane pane-session",
      "pane pane-trace",
    ])
  })

  // The operator's Session pane also holds its controls, a section of their
  // own after the invitation control's place.
  assert count(panel_of(operator(quiet())), "<section") == 5
  assert count(panel_of(observer(quiet())), "<section") == 4
}

// The panel is the last child of the frame: nothing is drawn after it, so a
// region added later cannot move a path the observer's socket admits.
pub fn the_panel_is_the_last_child_of_the_frame_test() {
  list.each([operator(quiet()), observer(quiet())], fn(html) {
    let assert Ok(#(_, from)) = string.split_once(html, panel_start)
    let assert Ok(#(_, after)) = string.split_once(from, "</aside>")
    assert after == "</loom-shell>"
  })
}

// The shell's badge is the number of strands waiting on a decision, and a
// page with none writes zero.
pub fn the_frame_carries_the_number_of_strands_waiting_test() {
  assert component.needing(quiet()) == 0
  assert string.contains(observer(quiet()), "needing=\"0\"")
  assert string.contains(operator(quiet()), "needing=\"0\"")

  assert component.needing(waiting()) == 1
  assert string.contains(observer(waiting()), "needing=\"1\"")
  assert string.contains(operator(waiting()), "needing=\"1\"")
}

// A strand that needs a decision says so in fixed words on its card, on both
// pages, and no other card does.
pub fn a_waiting_strand_says_needs_approval_test() {
  list.each([operator(waiting()), observer(waiting())], fn(html) {
    let panel = panel_of(html)
    assert count(panel, "Needs approval") == 1
    assert !string.contains(panel, "Needs input")
  })
  assert !string.contains(panel_of(observer(quiet())), "Needs approval")
}

// The approval card is the decision, and it stays in the dock, above the
// composer. The panel points to it with the strand's status and holds no
// control that decides: no card, no Allow, no Deny, no form and no field.
// Its only buttons are the strand cards, each of which only focuses a strand.
pub fn the_panel_carries_no_decision_control_test() {
  let html = operator(main_waiting())

  // The card is in the dock, which is before the panel.
  let assert Ok(#(before, _)) = string.split_once(html, panel_start)
  assert string.contains(before, "<footer class=\"dock\">")
  assert string.contains(before, "approval-card")
  assert string.contains(before, "approval-deny")

  let panel = panel_of(html)
  assert string.contains(panel, "Needs approval")
  assert !string.contains(panel, "approval-")
  assert !string.contains(panel, "Allow")
  assert !string.contains(panel, "Deny")
  assert !string.contains(panel, "<textarea")

  // The Session pane's Fork form is the one other control, and it decides
  // nothing: its submit is the only button that is not a strand's card.
  assert count(panel, "<button") == count(panel, "chip-hit") + 1
  assert count(panel, "<form") == 1
}

// An observer has no dock and no card, and its panel still names the strand
// that waits, without a control that could answer it.
pub fn an_observers_panel_names_the_wait_and_holds_no_card_test() {
  let html = observer(waiting())
  assert !string.contains(html, "approval-card")
  let panel = panel_of(html)
  assert string.contains(panel, "Needs approval")
  assert count(panel, "<button") == count(panel, "chip-hit")
}

// --- keys and the approval cards ----------------------------------------------

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: element.Element(message)) -> List(String)

// The shell's key listener drops every key pressed inside the region of
// approval cards, and finds the region by this marker. It is drawn on that
// region alone, on the operator's page and only while a card is pending, so
// the words the shell looks for exist exactly where the rule needs them.
pub fn the_approval_region_carries_the_marker_the_shell_drops_keys_by_test() {
  let html = operator(main_waiting())
  assert string.contains(
    html,
    "<section aria-label=\"Approvals waiting\" class=\"approvals\" data-loom-approvals>",
  )
  assert count(html, "data-loom-approvals") == 1

  // No card pending, no region, no marker; and the observer has none.
  assert !string.contains(operator(quiet()), "data-loom-approvals")
  assert !string.contains(observer(main_waiting()), "data-loom-approvals")
}

// No approval card carries a strand marker, so the shell's relay, which reads
// one property of a click's own target, cannot be aimed at a control inside a
// card, and the card holds nothing the shell would press.
pub fn no_approval_card_carries_a_strand_marker_test() {
  let html = operator(main_waiting())
  let assert Ok(#(_, from)) = string.split_once(html, "data-loom-approvals>")
    as "the region is drawn"
  let assert Ok(#(region, _)) = string.split_once(from, "</section>")
    as "the region is closed"
  assert string.contains(region, "approval-card")
  assert !string.contains(region, "data-loom-focus")
  assert !string.contains(region, "data-loom-card")
  assert !string.contains(region, "data-loom-crumb")
}

// The composer is the tag the shell's key rule reads as the editor, and the
// approval region is not inside it or it inside the region, so `Escape` in a
// draft is the composer's and a key in a card is nobody's.
pub fn the_composer_and_the_approvals_are_separate_places_test() {
  let html = operator(main_waiting())
  assert string.contains(html, "<loom-composer")
  let assert Ok(#(_, from)) = string.split_once(html, "data-loom-approvals>")
  let assert Ok(#(region, after)) = string.split_once(from, "</section>")
  assert !string.contains(region, "loom-composer")
  assert string.contains(after, "<loom-composer")
}

// A page with an approval pending registers no handler for a key, of any
// kind: the operator's tree holds clicks and submits only, and the key
// listener is the shell's, in the browser, which sends the server nothing. So
// no keystroke reaches the server as a decision, or as anything.
pub fn no_key_handler_exists_on_a_page_with_an_approval_pending_test() {
  let names =
    handlers(operator_page.view(main_waiting()))
    |> list.map(fn(key) {
      let assert Ok(name) = list.last(string.split(key, "\n"))
        as "a handler key ends in its event name"
      name
    })
    |> list.unique
    |> list.sort(string.compare)
  assert names == ["click", "submit"]
  assert list.all(handlers(component.view(main_waiting())), fn(key) {
    string.ends_with(key, "\nclick")
  })
}
