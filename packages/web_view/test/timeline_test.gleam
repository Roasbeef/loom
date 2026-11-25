//// The timeline's wire, its rule and its view. The wire round-trips, drops a
//// damaged card and keeps the rest; the rule merges pages and picks cards by
//// density; and the view draws session text as text nodes only, so a path that
//// is markup is escaped and never reaches an attribute.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import lustre/element
import session_view/timeline
import web_view/session_brief
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
    card(1, timeline.Prompted),
    card(4, timeline.Worked),
    card(7, timeline.Ran),
    timeline_feed.Card(..card(10, timeline.Ran), failed: 1),
  ]

  assert list.map(timeline_rule.shown(cards, timeline_rule.Landmarks), fn(each) {
      each.from_seq
    })
    == [1, 10]
  assert list.length(timeline_rule.shown(cards, timeline_rule.Standard)) == 4
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
      handlers: None,
    ))
    |> element.to_string
    == ""
}
