//// The timeline's wire, its rule and its view. The wire round-trips, drops a
//// damaged card and keeps the rest; the rule merges pages and picks cards by
//// density; and the view draws session text as text nodes only, so a path that
//// is markup is escaped and never reaches an attribute.

import core/json
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import lustre/element
import session_view/span_lines
import session_view/timeline
import web_view/session_brief
import web_view/span_feed
import web_view/timeline_feed
import web_view/timeline_rule
import web_view/view/timeline_view

fn card(from_seq: Int, kind: timeline.Kind) -> timeline_feed.Card {
  timeline_feed.Card(
    kind:,
    turn_seq: 1,
    from_seq:,
    to_seq: from_seq + 2,
    last: "entry",
    started_at: 1000,
    ended_at: 2000,
    steps: 4,
    reads: 1,
    failed: 0,
    files: [
      timeline_feed.File(session_brief.untrusted("src/a.gleam"), 3, 1),
    ],
    files_total: 1,
    command: Some(timeline_feed.Command(
      session_brief.untrusted("make check"),
      2,
    )),
    spawned: [],
    peers: 0,
    tokens_before: None,
    excerpt: Some(session_brief.untrusted("fix the replay")),
  )
}

pub fn a_feed_round_trips_test() {
  let feed =
    timeline_feed.Feed(
      cards: [card(1, timeline.Prompted), card(4, timeline.Ran)],
      older: Some(1),
      now: Some(card(7, timeline.Worked)),
    )

  assert timeline_feed.decode(timeline_feed.to_json(feed)) == Ok(feed)
}

pub fn a_damaged_card_is_dropped_and_the_rest_kept_test() {
  let good =
    timeline_feed.to_json(timeline_feed.Feed(
      [card(1, timeline.Prompted)],
      None,
      None,
    ))
  let assert json.Object([#("timeline", json.Object(fields))]) = good
  let damaged =
    json.Object([
      #(
        "timeline",
        json.Object([
          #(
            "cards",
            json.Array([
              json.Object([#("kind", json.String("nonsense"))]),
              ..case list.key_find(fields, "cards") {
                Ok(json.Array(cards)) -> cards
                _ -> []
              }
            ]),
          ),
        ]),
      ),
    ])
  let assert Ok(feed) = timeline_feed.decode(damaged)

  assert list.length(feed.cards) == 1
  assert timeline_feed.decode(json.Null) == Error(Nil)
}

pub fn pages_merge_and_a_refusal_keeps_the_cards_test() {
  let newest = timeline_feed.Feed([card(10, timeline.Answered)], Some(10), None)
  let older = timeline_feed.Feed([card(1, timeline.Prompted)], None, None)
  let first = timeline_rule.merged(None, None, Ok(newest))
  let both = timeline_rule.merged(Some(first), Some(10), Ok(older))

  assert list.map(both.cards, fn(each) { each.from_seq }) == [1, 10]
  assert both.older == None
  assert timeline_rule.merged(Some(both), None, Error("busy")) == both
  assert timeline_rule.merged(None, None, Error("busy")).words == Some("busy")
}

pub fn landmarks_leave_out_plain_work_test() {
  let cards = [
    timeline_feed.Card(
      ..card(1, timeline.Prompted),
      turn_seq: 1,
      files: [],
      files_total: 0,
      failed: 0,
    ),
    timeline_feed.Card(..card(4, timeline.Worked), turn_seq: 1, files_total: 1),
    timeline_feed.Card(
      ..card(7, timeline.Ran),
      turn_seq: 1,
      command: Some(timeline_feed.Command(session_brief.untrusted("make"), 0)),
      failed: 1,
    ),
    timeline_feed.Card(
      ..card(10, timeline.Ran),
      turn_seq: 1,
      failed: 0,
      files_total: 0,
    ),
  ]

  assert list.map(timeline_rule.shown(cards, timeline_rule.Landmarks), fn(each) {
      each.from_seq
    })
    == [1, 10]
  assert list.length(timeline_rule.shown(cards, timeline_rule.Standard)) == 4
}

// A turn where nothing happened is left out of the landmarks unless it is the
// newest turn, and a turn that wrote a file or failed a call keeps its landmark
// cards.
pub fn landmarks_keep_eventful_turns_and_the_newest_test() {
  let chatter = fn(seq, turn) {
    [
      timeline_feed.Card(
        ..card(seq, timeline.Prompted),
        turn_seq: turn,
        files_total: 0,
        failed: 0,
      ),
      timeline_feed.Card(
        ..card(seq + 1, timeline.Answered),
        turn_seq: turn,
        files_total: 0,
        failed: 0,
      ),
    ]
  }
  let wrote = [
    timeline_feed.Card(
      ..card(10, timeline.Prompted),
      turn_seq: 10,
      files_total: 0,
      failed: 0,
    ),
    timeline_feed.Card(
      ..card(11, timeline.Worked),
      turn_seq: 10,
      files_total: 2,
      failed: 0,
    ),
    timeline_feed.Card(
      ..card(12, timeline.Answered),
      turn_seq: 10,
      files_total: 0,
      failed: 0,
    ),
  ]
  let cards = list.flatten([chatter(1, 1), wrote, chatter(20, 20)])
  let seqs =
    list.map(timeline_rule.shown(cards, timeline_rule.Landmarks), fn(each) {
      each.from_seq
    })

  assert seqs == [10, 12, 20, 21]
}

fn drawn(path: String) -> String {
  let hostile =
    timeline_feed.Card(
      ..card(1, timeline.Ran),
      files: [timeline_feed.File(session_brief.untrusted(path), 1, 0)],
      excerpt: Some(session_brief.untrusted(path)),
    )

  timeline_view.pane(timeline_view.Offer(
    held: Some(timeline_rule.Held([hostile], None, None, None)),
    density: timeline_rule.Detailed,
    opened: set.new(),
    now: 5000,
    spans: dict.new(),
    handlers: None,
  ))
  |> element.to_string
}

pub fn session_text_is_escaped_and_never_an_attribute_test() {
  let html = drawn("\"><script>alert(1)</script>")

  assert !string.contains(html, "<script>")
  assert string.contains(html, "&lt;script&gt;")
  assert !string.contains(html, "href=")
}

pub fn a_page_with_no_cards_draws_nothing_test() {
  assert timeline_view.pane(timeline_view.Offer(
      held: Some(timeline_rule.Held([], None, None, None)),
      density: timeline_rule.Standard,
      opened: set.new(),
      now: 0,
      spans: dict.new(),
      handlers: None,
    ))
    |> element.to_string
    == ""
}

fn band(now_steps: Int, ended_at: Int) -> String {
  timeline_view.pane(timeline_view.Offer(
    held: Some(timeline_rule.Held(
      [card(1, timeline.Prompted)],
      None,
      Some(
        timeline_feed.Card(
          ..card(2, timeline.Worked),
          steps: now_steps,
          ended_at:,
        ),
      ),
      None,
    )),
    density: timeline_rule.Standard,
    opened: set.new(),
    now: 500_000,
    spans: dict.new(),
    handlers: None,
  ))
  |> element.to_string
}

// "Where it is" says how many steps ran since the last card and how long ago, in
// words that read after "ago", and says nothing for a span of no step.
pub fn the_open_span_band_is_plain_and_absent_when_empty_test() {
  assert string.contains(
    band(3, 499_000),
    "3 steps since the last card, last record just now",
  )
  assert string.contains(
    band(1, 100_000),
    "1 step since the last card, last record 6m ago",
  )
  assert !string.contains(band(0, 499_000), "Where it is")
}

// A refresh that overlaps the held cards keeps the older ones, and one that does
// not replaces them.
pub fn a_refresh_overlap_decides_what_is_kept_test() {
  let held =
    timeline_rule.Held(
      [
        card(1, timeline.Prompted),
        card(4, timeline.Answered),
        card(7, timeline.Prompted),
      ],
      Some(1),
      None,
      None,
    )
  let overlapping =
    timeline_feed.Feed(
      [
        card(4, timeline.Answered),
        card(7, timeline.Prompted),
        card(10, timeline.Answered),
      ],
      Some(4),
      None,
    )
  let moved = timeline_feed.Feed([card(20, timeline.Prompted)], Some(20), None)

  let kept = timeline_rule.merged(Some(held), None, Ok(overlapping))
  let replaced = timeline_rule.merged(Some(held), None, Ok(moved))

  assert list.map(kept.cards, fn(each) { each.from_seq }) == [1, 4, 7, 10]
  assert kept.older == Some(1)
  assert list.map(replaced.cards, fn(each) { each.from_seq }) == [20]
  assert replaced.older == Some(20)
}

fn a_span() -> span_feed.Feed {
  span_feed.Feed(
    lines: [
      span_feed.Line(
        1,
        1000,
        span_lines.Prompted,
        session_brief.untrusted("fix it"),
        span_lines.NoOutcome,
      ),
      span_feed.Line(
        2,
        2000,
        span_lines.Step,
        session_brief.untrusted("Ran \"><script>x</script>"),
        span_lines.Failed,
      ),
    ],
    omitted: 3,
  )
}

pub fn a_span_round_trips_and_drops_a_damaged_line_test() {
  assert span_feed.decode(span_feed.to_json(a_span())) == Ok(a_span())
  assert span_feed.decode(json.Null) == Error(Nil)

  let damaged =
    json.Object([
      #(
        "span",
        json.Object([
          #("lines", json.Array([json.Object([#("seq", json.Int(1))])])),
        ]),
      ),
    ])

  assert span_feed.decode(damaged) == Ok(span_feed.Feed([], 0))
}

// An opened card draws its span's lines as text, tints a failure, says what was
// left out, and says it is reading before the answer.
pub fn an_opened_card_draws_its_span_as_text_test() {
  let drawn = fn(seen) {
    timeline_view.pane(timeline_view.Offer(
      held: Some(timeline_rule.Held([card(1, timeline.Ran)], None, None, None)),
      density: timeline_rule.Detailed,
      opened: set.new(),
      now: 5000,
      spans: dict.from_list([#(1, seen)]),
      handlers: None,
    ))
    |> element.to_string
  }
  let html = drawn(span_feed.Read(a_span()))

  assert string.contains(html, "timeline-line-failed")
  assert string.contains(html, "&lt;script&gt;x&lt;/script&gt;")
  assert !string.contains(html, "<script>")
  assert string.contains(html, "3 earlier lines not shown")
  assert string.contains(drawn(span_feed.Loading), "Reading the span")
  assert string.contains(drawn(span_feed.Refused("busy")), "busy")
}

// At Landmarks the page says how many loaded cards it leaves out and offers every
// card, and at the other densities it says nothing.
pub fn landmarks_says_how_many_cards_are_hidden_test() {
  let drawn = fn(density) {
    timeline_view.pane(timeline_view.Offer(
      held: Some(timeline_rule.Held(
        [
          card(1, timeline.Prompted),
          timeline_feed.Card(
            ..card(4, timeline.Worked),
            files_total: 0,
            failed: 0,
          ),
        ],
        None,
        None,
        None,
      )),
      density:,
      opened: set.new(),
      now: 5000,
      spans: dict.new(),
      handlers: Some(timeline_view.Handlers(
        density: fn(_) { Nil },
        toggle: fn(_) { Nil },
        older: Nil,
        open: Nil,
      )),
    ))
    |> element.to_string
  }

  assert string.contains(
    drawn(timeline_rule.Landmarks),
    "1 card hidden at Landmarks · show all",
  )
  assert !string.contains(drawn(timeline_rule.Standard), "hidden at Landmarks")
}
