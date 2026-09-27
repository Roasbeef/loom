//// The rendered page for a capture that holds every piece the lane draws
//// (`lane_fixture`): folded work, the spawn row and the child's result
//// card, the delivered nudge and the peer card. Each test renders the component and reads
//// the HTML the browser would receive, so a class, a text or an escape that
//// goes missing fails here rather than only on a screenshot.
////
//// Every string in the fixture that the session could have written holds
//// markup, and the escaping test checks each arrives only as text
//// (protocol-change/051, "Nothing from the session becomes markup").

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/transcript_lines
import session_view/turns
import web_view/component
import web_view/operator_page

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

fn html(model) -> String {
  element.to_string(component.view(model))
}

fn settled() {
  page([lane_fixture.captured(10, None)])
}

// Whether every needle occurs in `haystack`, each after the one before.
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

pub fn settled_work_folds_under_one_closed_divider_test() {
  let drawn = html(settled())
  assert string.contains(
    drawn,
    "class=\"work\"><span class=\"work-divider\" slot=\"summary\">worked 48s · 3 steps · 2 files</span>",
  )

  // The fold's state is the browser's: the server renders no attribute for
  // it, so a later patch cannot close what the reader opened.
  assert !string.contains(drawn, "\" open")
  assert !string.contains(drawn, "aria-expanded")

  // The divider stands between the prompt and the answer, and the answer
  // stays outside it.
  assert in_order(drawn, [
    "review the &lt;patch&gt; &amp; report",
    "worked 48s",
    "</loom-fold>",
    "Done: two files.",
  ])
}

pub fn a_running_turn_is_drawn_open_test() {
  let drawn =
    html(page([lane_fixture.captured(7, Some(lane_fixture.main_op()))]))
  assert string.contains(drawn, "class=\"work open\">")
  assert !string.contains(drawn, "<loom-fold")
}

pub fn a_spawn_and_its_result_wear_the_childs_hue_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "class=\"spawn hue-2\">",
    "↳ agent_spawn · sub:&lt;b&gt;review",
    "review &lt;the&gt; patch",
    "class=\"result-card hue-2\">",
    "from sub:&lt;b&gt;review · result · completed",
    "looks &lt;fine&gt; &amp; tidy",
  ])
}

pub fn a_delivered_nudge_is_an_advisor_row_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "class=\"nudge\">",
    "advisor · nudge · delivered",
    "- Confirm the &lt;sweep&gt; excludes generated SQL.",
  ])
}

pub fn a_peer_message_is_stored_never_read_and_has_no_reply_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "class=\"peer-card\">",
    "peer · lint-census · main",
    "<span class=\"receipt\">stored</span>",
    "R8 census is &lt;14&gt; &amp; rising",
  ])
  assert !string.contains(drawn, ">read<")

  // The operator's page offers no reply: that is the extracted step's.
  let operator = element.to_string(operator_page.view(settled()))
  assert !string.contains(operator, "Reply")
  assert !string.contains(operator, "reply")
}

// Nothing the session wrote reaches the page as markup: each string arrives
// escaped, and no element it names exists.
pub fn session_markup_arrives_only_as_text_test() {
  let missed = settled()
  let pages = [
    html(missed),
    element.to_string(operator_page.view(missed)),
  ]
  list.each(pages, fn(drawn) {
    assert !string.contains(drawn, "<b>")
    assert !string.contains(drawn, "<patch>")
    assert !string.contains(drawn, "<the>")
    assert !string.contains(drawn, "<fine>")
    assert !string.contains(drawn, "<14>")
    assert !string.contains(drawn, "<sweep>")
    assert !string.contains(drawn, "<a>")
    assert string.contains(drawn, "&lt;b&gt;review")
    assert string.contains(drawn, "src/&lt;a&gt;.gleam")
  })

  // An observer's page with every piece drawn still holds no control.
  let observer = html(missed)
  assert !string.contains(observer, "<button")
  assert !string.contains(observer, "<form")
  assert !string.contains(observer, "\" open")
}

fn key(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block) -> block.key
    turns.Work(key:, ..)
    | turns.Spawned(key:, ..)
    | turns.Returned(key:, ..)
    | turns.Nudged(key:, ..)
    | turns.Peer(key:, ..)
    | turns.Missed(key:, ..) -> key
  }
}

// A later arrival keeps every earlier piece's key, so the keyed lane moves
// nothing it already drew; and no key holds a path separator.
pub fn keys_hold_across_arrivals_test() {
  let early = page([lane_fixture.captured(8, None)])
  let later = component.apply(early, [lane_fixture.captured(10, None)])
  let before = list.map(component.pieces(early), key)
  let after = list.map(component.pieces(later), key)
  assert list.take(after, list.length(before)) == before
  assert list.all(after, fn(key) {
    !string.contains(key, "\t")
    && !string.contains(key, "\n")
    && !string.contains(key, "\r")
  })
  assert list.length(after) > list.length(before)
}

// The lines under the lane are the transcript's own: the parity test's
// claim holds for the richer capture too.
pub fn the_lane_keeps_the_transcripts_lines_test() {
  let model = settled()
  let from_pieces =
    component.rows(model)
    |> list.map(fn(row) { row.line })
  assert from_pieces == component.lines(model)
  assert list.any(component.lines(model), fn(line) {
    string.contains(line.text, transcript_lines.nudges_header)
    || string.contains(line.text, "Confirm the <sweep>")
  })
}
