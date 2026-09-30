//// The rendered page for a capture that holds every piece the lane draws
//// (`lane_fixture`): the strand cards and their cache rings, a strand's own
//// view for the figures a card leaves out, folded work, the spawn row and the
//// child's result card, the delivered nudge, the peer card and the
//// cache-miss row. Each test renders the component and reads
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

// The page after the reader focuses `strand`, whose own view then draws the
// figures a card does not.
fn focused(model, strand: String) {
  component.update(model, component.FocusRequested(strand)).0
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
    "<li data-lustre-key=\"card-0\" class=\"chip following hue-main\">",
    ">main<",
    "<li data-lustre-key=\"card-1\" class=\"chip hue-2\">",
    "&lt;b&gt;review",
    "<li data-lustre-key=\"card-2\" class=\"chip hue-3\">",
    ">tests<",
    "<li data-lustre-key=\"advisor\" class=\"chip hue-advisor\">",
    ">advisor<",
  ])

  // A card is a ring, a name and one status line: no clock and no figures,
  // which are a strand's own view's. The strand the lane follows is marked as
  // the current one, and each card carries its position.
  assert !string.contains(drawn, "loom-elapsed")
  assert !string.contains(drawn, "since=")
  assert string.contains(
    drawn,
    "<button aria-current=\"true\" class=\"chip-hit\" data-loom-card=\"0\" type=\"button\">",
  )
  assert in_order(drawn, [
    "data-loom-card=\"0\"",
    "data-loom-card=\"1\"",
    "data-loom-card=\"2\"",
    "data-loom-card=\"3\"",
  ])

  // Every state has a word, never a colour alone.
  assert string.contains(drawn, "<span class=\"chip-status running\">")
  assert string.contains(drawn, "Working")
  let chips =
    query.find_all(
      in: component.view(settled()),
      matching: query.element(query.class("chip")),
    )
  assert list.length(chips) == 4
}

pub fn a_settled_strand_leaves_the_live_cards_for_the_group_test() {
  // The tester is running in the first capture and idle in the next, so it
  // leaves the live cards and is listed in the settled group.
  let drawn =
    page([
      lane_fixture.captured(10, None),
      lane_fixture.captured_with(10, None, [
        #(lane_fixture.child, lane_fixture.review_op()),
      ]),
    ])
    |> html
  assert string.contains(drawn, "<li data-lustre-key=\"settled\"")
  assert string.contains(drawn, "Settled · 1")
  let assert Ok(#(live, group)) = string.split_once(drawn, "settled-group")
  assert !string.contains(live, ">tests<")
  assert string.contains(group, ">tests<")
}

// A strand's elapsed time, in its own view, is a duration the roster measured
// from the daemon's own records (the glance was written seven seconds into
// the operation), never the daemon's start instant set against the page's
// clock. A page whose clock reads the start instant, one that reads the
// Unix epoch, and one that is three years ahead all draw the same seven
// seconds, which the browser shows as the terminal would.
pub fn a_strands_view_counts_a_measured_duration_whatever_the_clock_test() {
  let offset = fn(now: Int) {
    let clock = page_fixture.clock()
    let drawn =
      component.new(page_fixture.start_with(clock))
      |> at(clock, now)
      |> component.apply([lane_fixture.captured(10, None)])
      |> focused(lane_fixture.child)
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

  // The card's ring is only a shape, hidden from a screen reader; its words
  // are a strand's own view's, so the list carries none.
  assert string.contains(
    drawn,
    "<span aria-hidden=\"true\" class=\"ring ring-card ring-tail\"></span>",
  )
  assert !string.contains(drawn, "cache tail")

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

// The advisor is always listed, so its own view is the one a test can open
// without a running strand: it says the outlook in the words the rows proved,
// in the Cache row, and no others.
pub fn a_strands_view_names_the_outlook_in_the_words_the_rows_proved_test() {
  let #(page, clock) = timed([lane_fixture.captured(10, None)])
  let warm =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("advisor", 40_000, 0, 1)])
    |> at(clock, 60_000)
    |> focused("advisor")
  let drawn = html(warm)
  assert in_order(drawn, [
    "<dt class=\"detail-term\">Cache</dt>",
    "<dd class=\"detail-value\">cache tail ≤4m</dd>",
  ])
  assert string.contains(drawn, "ring ring-detail ring-tail")
}

pub fn an_unproven_provider_shows_an_idle_age_not_a_countdown_test() {
  let #(page, clock) = timed([lane_fixture.captured(10, None)])
  let idle =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("main", 40_000, 0, 0)])
    |> at(clock, 600_000)
  let drawn = html(idle)
  assert string.contains(drawn, "ring ring-card ring-idle")

  // The words are the strand's own view's, and claim an idle age, never a
  // countdown, when the provider has not proved one.
  let opened = html(focused(idle, "main"))
  assert !string.contains(opened, "cache tail")
  let advisor =
    at(page, clock, 0)
    |> component.apply([lane_fixture.usage_push("advisor", 40_000, 0, 0)])
    |> at(clock, 600_000)
    |> focused("advisor")
    |> html
  assert string.contains(advisor, "cache idle 10m")
  assert !string.contains(advisor, "cache tail")
  assert !string.contains(advisor, "cache head")
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
    ">advisor</button> · nudge · delivered",
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
    "↳ agent_spawn · ",
    ">sub:&lt;b&gt;review</button>",
    "review &lt;the&gt; patch",
    "class=\"result-card hue-2\">",
    "from ",
    ">sub:&lt;b&gt;review</button>",
    " · result · completed",
    "looks &lt;fine&gt; &amp; tidy",
  ])
}

// The nudge's body is the advisor's prose, drawn as Markdown the way the
// terminal draws it, so its `- ` line is a list item.
pub fn a_delivered_nudge_is_an_advisor_row_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "class=\"nudge\">",
    ">advisor</button> · nudge · delivered",
    "class=\"card-body markdown\">",
    "class=\"md-list\">",
    "Confirm the &lt;sweep&gt; excludes generated SQL.",
  ])
}

pub fn a_peer_message_is_stored_never_read_and_an_observer_cannot_reply_test() {
  let drawn = html(settled())
  assert in_order(drawn, [
    "class=\"peer-card\">",
    "peer · lint-census · main",
    "<span class=\"receipt\">stored</span>",
    "R8 census is &lt;14&gt; &amp; rising",
  ])
  assert !string.contains(drawn, ">read<")

  // The observer's page has no message to send, so it draws no Reply.
  assert !string.contains(drawn, "Reply")
  assert !string.contains(drawn, "peer-reply")

  // The operator's page draws one, after the body (`page_actions_test`).
  let operator = element.to_string(operator_page.view(settled()))
  assert in_order(operator, [
    "R8 census is &lt;14&gt; &amp; rising",
    "class=\"peer-reply\"",
    "Reply to this peer",
  ])
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

  // An observer's page with every piece drawn holds no control but the
  // strand cards, one button each for the four strands listed, and the tags of
  // the strands the transcript names: the spawn's, the result's and the
  // nudge's, which carry a marker and no handler.
  let observer = html(missed)
  assert list.length(string.split(observer, "<button")) == 8
  assert list.length(string.split(observer, "class=\"chip-hit\"")) == 5
  assert list.length(string.split(observer, "class=\"tag\"")) == 4
  assert !string.contains(observer, "<form")
  assert !string.contains(observer, "\" open")
}

fn key(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block, _) | turns.Commentary(block) -> block.key
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
