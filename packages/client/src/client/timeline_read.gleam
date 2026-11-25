//// What a running session reports of its own timeline, for Home's review and
//// update threads (protocol-change/134): the resident side of the
//// `sessions.timeline` read.
////
//// The read is computed by the session's own Agency actor, as `session_brief`
//// is, from the session's own store. It runs no tool, opens no other session
//// and writes nothing. It scans the newest `scan_cap` records of main's branch,
//// cuts them with `session_view/timeline`, and answers one bounded page of the
//// cards, newest page first, with a cursor for the older ones and the span still
//// open. A strand longer than the scan starts its cards inside a turn, and the
//// first card it can make says so by having `turn_seq` zero.
////
//// ## How a read runs
////
//// 1. `read` answers `build`'s page as the reply object.
//// 2. `window` reads main's newest records of every kind, oldest first.
//// 3. `page` takes the cards older than `before`, at most `limit` of them, and
////    the open span on the first page.
//// 4. `fit` sheds the oldest cards until the encoded reply fits
////    `timeline_feed.feed_bytes`.
////
//// ## What a card claims
////
//// Every fact comes from a record. Nothing a model wrote is in a card, and the
//// strings a card holds are marked untrusted for the page
//// (`web_view/timeline_feed`).

import core/entry.{type Entry}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import session/session
import session_view/timeline
import storage/storage
import web_view/timeline_feed.{type Feed}

/// How many of main's newest records a read cuts. Cards older than the scan are
/// not offered; a strand longer than this starts inside a turn.
pub const scan_cap = 2000

/// The main strand, which the cards are cut from.
const main_strand = "main"

/// The timeline of this session as one reply object, `{"timeline": {...}}`.
///
/// ## Examples
///
/// ```gleam
/// // timeline_read.read(runtime, None, 10)
/// ```
pub fn read(
  runtime: api.Runtime,
  before: Option(Int),
  limit: Int,
) -> Result(JsonValue, String) {
  build(runtime, before, limit) |> result.map(timeline_feed.to_json)
}

/// The timeline of this session as a typed value, before it is encoded.
///
/// ## Examples
///
/// ```gleam
/// // timeline_read.build(runtime, None, 10)
/// ```
pub fn build(
  runtime: api.Runtime,
  before: Option(Int),
  limit: Int,
) -> Result(Feed, String) {
  use records <- result.map(window(runtime))

  of_records(records, before, limit)
}

/// The page of cards a strand's oldest-first records make. A `limit` outside one
/// to `max_cards` is brought into that range.
///
/// ## Examples
///
/// ```gleam
/// assert timeline_read.of_records([], None, 10).cards == []
/// ```
pub fn of_records(
  records: List(Entry),
  before: Option(Int),
  limit: Int,
) -> Feed {
  let cut = timeline.cut(records, timeline.default_step_limit)
  let wanted = int.clamp(limit, 1, timeline_feed.max_cards)

  fit(page(cut, before, wanted))
}

/// Main's newest `scan_cap` records of every kind, oldest first, or none when
/// main has no leaf yet.
fn window(runtime: api.Runtime) -> Result(List(Entry), String) {
  use leaf <- result.try(
    session.strand_leaf(runtime.session, main_strand)
    |> result.map_error(string.inspect),
  )

  // A strand with no leaf has nothing to scan.
  case leaf {
    Some(session.Cell(value: Some(leaf), ..)) ->
      storage.scan_branch(
        runtime.session.store,
        storage.branch_scan(leaf) |> storage.branch_limit(scan_cap),
      )
      |> result.map(list.reverse)
      |> result.map_error(string.inspect)
    Some(session.Cell(value: None, ..)) | None -> Ok([])
  }
}

/// The newest `wanted` cards older than `before`, oldest first, the cursor for
/// the cards still older, and the open span when this is the first page.
fn page(cut: timeline.Cut, before: Option(Int), wanted: Int) -> Feed {
  // A cursor leaves the cards at or after it out.
  let older_cards = case before {
    Some(from_seq) ->
      list.filter(cut.cards, fn(card) { card.from_seq < from_seq })
    None -> cut.cards
  }

  let skipped = int.max(0, list.length(older_cards) - wanted)
  let cards = list.drop(older_cards, skipped)

  timeline_feed.Feed(
    cards: list.map(cards, timeline_feed.of_card),
    older: case skipped, cards {
      0, _ | _, [] -> None
      _, [first, ..] -> Some(first.from_seq)
    },
    now: case before {
      None -> option.map(cut.open, timeline_feed.of_card)
      Some(_) -> None
    },
  )
}

/// Sheds the oldest cards until the reply fits, moving the cursor to the oldest
/// card kept so the shed ones are still reachable.
fn fit(feed: Feed) -> Feed {
  let size = string.byte_size(json.to_string(timeline_feed.to_json(feed)))

  // A reply within the bound is sent whole.
  case size <= timeline_feed.feed_bytes, feed.cards {
    True, _ | _, [] -> feed
    False, [_, ..kept] ->
      fit(
        timeline_feed.Feed(..feed, cards: kept, older: case kept {
          [next, ..] -> Some(next.from_seq)
          [] -> feed.older
        }),
      )
  }
}
