//// The rendered page for a capture that holds every piece the lane draws
//// (`lane_fixture`): the agent strip and its cache rings, folded work, the
//// spawn row and the child's result card, the delivered nudge, the peer
//// card and the cache-miss row. Each test renders the component and reads
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
import lustre/dev/query
import lustre/element
import page_fixture
import session_view/agent_roster
import session_view/transcript_lines
import session_view/turns
import web_view/component
import web_view/operator_page

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

// A page whose transport reads a clock the test sets, and the clock.
fn timed(updates) {
  let clock = page_fixture.clock()
  #(
    component.new(page_fixture.start_with(clock)) |> component.apply(updates),
    clock,
  )
}

// The page after a tick that the transport's clock reads `now` at.
fn at(model, clock: page_fixture.Clock, now: Int) {
  page_fixture.set(clock, now)
  component.update(model, component.Ticked).0
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

pub fn the_strip_lists_main_then_working_agents_then_the_advisor_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "<nav aria-label=\"Agents\" class=\"agent-strip\">",
    "<li aria-current=\"true\" class=\"chip following hue-main\">",
    ">main<",
    "<li class=\"chip hue-2\">",
    "&lt;b&gt;review",
    "<li class=\"chip hue-3\">",
    ">tests<",
    "<li class=\"chip hue-advisor\">",
    ">advisor<",
  ])

  // A working agent's elapsed time is counted in the browser on from a
  // duration the roster measured, never from a daemon instant; the strand
  // the lane follows is marked as the current one.
  assert string.contains(
    drawn,
    "<loom-elapsed class=\"elapsed\" offset=\"7000\"></loom-elapsed>",
  )
  assert !string.contains(drawn, "since=")
  assert string.contains(
    drawn,
    "<li aria-current=\"true\" class=\"chip following hue-main\">",
  )

  // Every state has a glyph and a word, never a colour alone.
  assert string.contains(drawn, "<span class=\"state running\">")
  assert string.contains(drawn, "Working")
  let chips =
    query.find_all(
      in: component.view(settled()),
      matching: query.element(query.class("chip")),
    )
  assert list.length(chips) == 4
}

pub fn a_settled_strand_folds_into_a_count_test() {
  // The tester is running in the first capture and idle in the next, so it
  // leaves the strip and is counted.
  let drawn =
    page([
      lane_fixture.captured(10, None),
      lane_fixture.captured_with(10, None, [
        #(lane_fixture.child, lane_fixture.review_op()),
      ]),
    ])
    |> html
  assert string.contains(drawn, "<li class=\"chip settled\">")
  assert string.contains(drawn, "+1 settled")
  assert !string.contains(drawn, ">tests<")
}

// A chip's elapsed time is a duration the roster measured from the
// daemon's own records (the glance was written seven seconds into the
// operation), never the daemon's start instant set against the page's
// clock. A page whose clock reads the start instant, one that reads the
// Unix epoch, and one that is three years ahead all draw the same seven
// seconds, which the browser shows as the terminal would.
pub fn a_chip_counts_a_measured_duration_whatever_the_clock_test() {
  let offset = fn(now: Int) {
    let clock = page_fixture.clock()
    let drawn =
      component.new(page_fixture.start_with(clock))
      |> at(clock, now)
      |> component.apply([lane_fixture.captured(10, None)])
      |> html
    let assert Ok(#(_, after)) =
      string.split_once(drawn, "<loom-elapsed class=\"elapsed\" offset=\"")
    let assert Ok(#(value, _)) = string.split_once(after, "\"")
    value
  }
  let three_years = 3 * 365 * 24 * 3_600_000
  assert offset(lane_fixture.started_at + 7000) == "7000"
  assert offset(0) == "7000"
  assert offset(lane_fixture.started_at + three_years) == "7000"
  assert agent_roster.duration(7) == "7s"
}

pub fn the_ring_and_the_outlook_say_only_what_the_rows_proved_test() {
  // One request that read a 40k prefix and wrote to the one-hour head.
  let #(page, clock) = timed([lane_fixture.captured(10, None)])
  let warm =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("main", 40_000, 0, 1)])
    |> at(clock, 60_000)
  let drawn = html(warm)

  // The ring carries its words beside it on the figures row, so an idle
  // chip with no elapsed time or context size does not show a bare glyph.
  assert string.contains(
    drawn,
    "<span class=\"cache\"><span aria-hidden=\"true\" class=\"ring ring-tail\"></span>cache tail ≤4m</span>",
  )

  // The operator's composer names the same outlook for the strand it
  // addresses.
  let composer = element.to_string(operator_page.view(warm))
  assert string.contains(
    composer,
    "<span class=\"outlook ring-tail\" role=\"status\">cache tail ≤4m</span>",
  )

  // A running strand shows no outlook at all: the request in flight is
  // about to rewrite the prefix.
  let running =
    warm
    |> component.apply([lane_fixture.captured(10, Some(lane_fixture.main_op()))])
  assert !string.contains(html(running), "ring-tail")
}

pub fn an_unproven_provider_shows_an_idle_age_not_a_countdown_test() {
  let #(page, clock) = timed([lane_fixture.captured(10, None)])
  let idle =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("main", 40_000, 0, 0)])
    |> at(clock, 600_000)
  let drawn = html(idle)
  assert string.contains(drawn, "ring ring-idle")
  assert string.contains(drawn, "cache idle 10m")
  assert !string.contains(drawn, "cache tail")
  assert !string.contains(drawn, "cache head")
}

pub fn a_cache_miss_is_a_row_after_the_turn_that_paid_for_it_test() {
  let #(page, clock) = timed([lane_fixture.captured(10, None)])
  let missed =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("main", 40_000, 0, 0)])
    |> at(clock, 600_000)
    |> component.apply([lane_fixture.usage_push("main", 0, 40_000, 0)])
  let drawn = html(missed)
  assert in_order(drawn, [
    "advisor · nudge · delivered",
    "class=\"cache-miss\">Cache miss after 10m idle: 40k tokens re-billed (~$0.14)</p>",
  ])
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

// The nudge's body is the advisor's prose, drawn as Markdown the way the
// terminal draws it, so its `- ` line is a list item.
pub fn a_delivered_nudge_is_an_advisor_row_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "class=\"nudge\">",
    "advisor · nudge · delivered",
    "class=\"card-body markdown\">",
    "class=\"md-list\">",
    "Confirm the &lt;sweep&gt; excludes generated SQL.",
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
  let #(page, clock) = timed([lane_fixture.captured(10, None)])
  let missed =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("main", 40_000, 0, 0)])
    |> at(clock, 600_000)
    |> component.apply([lane_fixture.usage_push("main", 0, 40_000, 0)])
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
    turns.Plain(block) | turns.Commentary(block) -> block.key
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
