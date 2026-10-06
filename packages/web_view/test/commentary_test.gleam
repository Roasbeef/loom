//// The advisor's commentary on the web page: no row in the lane, the bodies
//// in the strand panel's Strands pane, and none of it a handler. What crossed
//// into the lane before the panel existed, the full blocks and then a
//// hairline per review, is gone.
////
//// The fixture holds the forked capture: `main`, the reviewer and the
//// advisor each have a transcript, and the advisor's one note (``advisor:
//// watch the <sweep>``) is commentary on `main` — captured, never sent.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import page_fixture
import session_view/advisor_history
import web_view/component
import web_view/operator_page
import web_view/view/commentary

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

fn html(model) -> String {
  element.to_string(component.view(model))
}

fn focused(model, strand: String) {
  component.update(model, component.FocusRequested(strand)).0
}

fn in_order(haystack: String, needles: List(String)) -> Bool {
  case needles {
    [] -> True
    [needle, ..rest] ->
      case string.split_once(haystack, needle) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}

pub fn the_lane_draws_no_row_for_a_review_test() {
  let drawn = html(page([lane_fixture.forked(None, [])]))

  // Neither the hairline nor the full body and heading are in the lane:
  // everything before the panel holds none of them, and the panel's section
  // holds the body.
  assert !string.contains(drawn, "commentary-mark")
  let assert Ok(#(centre, _)) = string.split_once(drawn, "pane pane-strands")
    as "the page draws the panel"
  assert !string.contains(centre, "class=\"block commentary\"")
  assert !string.contains(centre, "Advisor transcript · captured")
  assert !string.contains(centre, "watch the &lt;sweep&gt;")
}

pub fn the_commentary_adds_no_handler_test() {
  let model = page([lane_fixture.forked(None, [])])

  // An observer's page still holds only the strand cards' clicks.
  let keys = lane_fixture.beyond_dividers(handlers(component.view(model)))
  let clicks = list.filter(keys, fn(key) { string.ends_with(key, "\nclick") })
  assert list.length(clicks) == 4
    as "main, the reviewer, the tester and the advisor"
}

pub fn the_panel_holds_the_review_bodies_test() {
  let model = page([lane_fixture.forked(None, [])])
  let drawn = html(model)

  // The section sits in the Strands pane, under the strand cards, with
  // the advisor's whole text as a text node.
  assert in_order(drawn, [
    "pane pane-strands",
    "class=\"agent-strip\"",
    "class=\"commentary\"",
    "Advisor · 1 review",
    "commentary",
    "watch the &lt;sweep&gt;",
  ])
  assert !string.contains(drawn, "watch the <sweep>")
}

// The section is one native `details`, closed: its summary is the line a
// reader sees, and the bodies are inside it. No `open` attribute is drawn, and
// no handler, so the server never learns whether it is opened.
pub fn the_section_is_one_closed_summary_line_test() {
  let board =
    advisor_history.Board(
      [
        advisor_history.Item(
          "a",
          1,
          0,
          "Nothing to correct.\nSecond line.",
          advisor_history.AdvisorUpdate,
        ),
        advisor_history.Item(
          "b",
          2,
          0,
          "Check `writable_roots` first.\nMore.",
          advisor_history.RequestedNudge,
        ),
      ],
      None,
    )
  let drawn = element.to_string(commentary.view(board))

  assert string.contains(drawn, "<details>")
  assert !string.contains(drawn, "open")
  assert in_order(drawn, [
    "<summary",
    "Advisor · 2 reviews · last: ",
    "</summary>",
  ])

  // The summary quotes the newest review's first line, without Markdown marks.
  assert commentary.summary(board)
    == "Advisor · 2 reviews · last: Check writable_roots first."
  let one =
    advisor_history.Item(
      "a",
      1,
      0,
      "Nothing to correct.\nSecond line.",
      advisor_history.AdvisorUpdate,
    )
  assert commentary.summary(advisor_history.Board([one], None))
    == "Advisor · 1 review · last: Nothing to correct."
}

// A heading or list marker is Markdown's and is not quoted.
pub fn a_leading_marker_is_not_quoted_in_the_summary_test() {
  let quoted = fn(text) {
    commentary.summary(advisor_history.Board(
      [advisor_history.Item("a", 1, 0, text, advisor_history.AdvisorUpdate)],
      None,
    ))
  }

  assert quoted("# Nothing to fix")
    == "Advisor · 1 review · last: Nothing to fix"
  assert quoted("- one thing") == "Advisor · 1 review · last: one thing"
  assert quoted("* another") == "Advisor · 1 review · last: another"
}

// A long first line is cut with an ellipsis at the limit.
pub fn a_long_first_line_is_cut_in_the_summary_test() {
  let board =
    advisor_history.Board(
      [
        advisor_history.Item(
          "a",
          1,
          0,
          string.repeat("word ", 40),
          advisor_history.AdvisorUpdate,
        ),
      ],
      None,
    )

  assert string.ends_with(commentary.summary(board), "…")
  assert string.length(commentary.summary(board))
    == string.length("Advisor · 1 review · last: ") + commentary.summary_limit
}

// The body goes through the lane's Markdown drawer, as the nudge in the lane
// does: a backticked name is code and not a pair of backticks, and markup
// stays text.
pub fn the_bodies_are_markdown_and_markup_stays_text_test() {
  let board =
    advisor_history.Board(
      [
        advisor_history.Item(
          "a",
          1,
          0,
          "Use `writable_roots` here <script>x</script>",
          advisor_history.AdvisorUpdate,
        ),
      ],
      None,
    )
  let drawn = element.to_string(commentary.view(board))

  assert string.contains(drawn, "commentary-body markdown")
  assert string.contains(
    drawn,
    "<code class=\"md-code-span\">writable_roots</code>",
  )
  assert !string.contains(drawn, "`writable_roots`")
  assert string.contains(drawn, "&lt;script&gt;x&lt;/script&gt;")
  assert !string.contains(drawn, "<script")
}

pub fn the_section_hides_when_the_advisor_is_on_screen_test() {
  let model = page([lane_fixture.forked(None, [])])
  let advisor = focused(model, "advisor")

  // The advisor's own transcript holds the note as its ordinary entries,
  // so the section draws nothing while it is on screen — the board the
  // getter hands the panel is empty for every strand but `main`.
  assert component.advisor_commentary(advisor).items == []
  assert string.contains(html(advisor), "advisor: watch the &lt;sweep&gt;")
  assert !string.contains(html(advisor), "class=\"commentary\"")
}

pub fn a_page_without_commentary_draws_no_section_test() {
  let drawn = html(page([lane_fixture.captured(10, None)]))
  assert !string.contains(drawn, "class=\"commentary\"")
  assert !string.contains(drawn, "commentary-mark")
}

pub fn the_count_and_the_missing_edge_are_worded_test() {
  let many =
    advisor_history.Board(
      [
        advisor_history.Item("a", 1, 0, "first", advisor_history.AdvisorUpdate),
        advisor_history.Item("b", 2, 0, "second", advisor_history.AdvisorUpdate),
        advisor_history.Item("c", 3, 0, "third", advisor_history.AdvisorUpdate),
        advisor_history.Item("d", 4, 0, "fourth", advisor_history.AdvisorUpdate),
      ],
      Some("an older parent"),
    )
  let drawn = element.to_string(commentary.view(many))

  // The board is oldest-first: the newest three are drawn, newest last,
  // and the oldest is the one the count stands for.
  assert !string.contains(drawn, "first")
  assert in_order(drawn, ["second", "third", "fourth"])
  assert string.contains(drawn, "+ 1 earlier reviews")
  assert string.contains(drawn, "Earlier advisor commentary is not loaded")
}

pub fn the_section_holds_no_control_test() {
  let model = page([lane_fixture.forked(None, [])])
  let assert Ok(#(_, from_section)) =
    string.split_once(html(model), "class=\"commentary\"")
    as "the section is drawn"
  let assert Ok(#(section, _)) = string.split_once(from_section, "</section>")
    as "the section is closed"
  assert !string.contains(section, "<button")
  assert !string.contains(section, "<form")
}

pub fn an_operators_page_draws_the_same_commentary_test() {
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
    |> fn(model) {
      page_fixture.refuse_reads(model, operator_page.update, wire, fn(frames) {
        operator_page.Observed(component.Arrived(frames))
      })
    }
    |> component.apply([lane_fixture.forked(None, [])])
  let drawn = element.to_string(operator_page.view(model))
  assert !string.contains(drawn, "commentary-mark")
  assert string.contains(drawn, "class=\"commentary\"")
}
