//// The resident side of `sessions.timeline` (protocol-change/134): the page of
//// cards a strand's records make, its bounds, and the control command's decoder.

import client/daemon/protocol
import client/timeline_read
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/timeline
import web_view/timeline_feed

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    usage_evidence.none(),
  )
}

// A strand of `turns` turns, each a prompt and an answer, two cards a turn.
fn strand(turns: Int) -> List(entry.Entry) {
  int.range(from: 0, to: turns, with: [], run: fn(found, n) { [n, ..found] })
  |> list.reverse
  |> list.flat_map(fn(turn) {
    let seq = turn * 2 + 1

    [
      entry.MessageEntry(
        id(seq),
        None,
        seq,
        seq * 1000,
        message.UserMessage(
          [message.UserText("task " <> int.to_string(turn), None)],
          0,
          None,
        ),
        False,
      ),
      entry.MessageEntry(
        id(seq + 1),
        None,
        seq + 1,
        { seq + 1 } * 1000,
        message.AssistantMessage(
          [message.AssistantText("done", None)],
          "t",
          "t",
          "t",
          None,
          None,
          None,
          usage(),
          message.Stop,
          None,
          None,
          None,
          None,
          0,
        ),
        False,
      ),
    ]
  })
}

pub fn the_newest_page_has_a_cursor_for_older_cards_test() {
  let feed = timeline_read.of_records(strand(30), None, 5)

  assert list.length(feed.cards) == 5
  assert feed.older
    == Some(case feed.cards {
      [first, ..] -> first.from_seq
      [] -> 0
    })
}

pub fn an_older_page_continues_where_the_cursor_says_test() {
  let first = timeline_read.of_records(strand(30), None, 5)
  let assert Some(before) = first.older
  let second = timeline_read.of_records(strand(30), Some(before), 5)

  assert list.all(second.cards, fn(card) { card.from_seq < before })
  assert second.now == None
  assert list.length(second.cards) == 5
}

pub fn the_limit_is_brought_into_bounds_test() {
  assert list.length(timeline_read.of_records(strand(30), None, 999).cards)
    == timeline_feed.max_cards
  assert list.length(timeline_read.of_records(strand(30), None, 0).cards) == 1
}

pub fn a_short_strand_has_no_cursor_test() {
  let feed = timeline_read.of_records(strand(2), None, 10)

  assert list.length(feed.cards) == 4
  assert feed.older == None
}

pub fn the_command_decodes_with_its_bounds_test() {
  let envelope = fn(body: String) {
    "{\"v\":2,\"id\":1,\"cmd\":\"sessions.timeline\",\"body\":" <> body <> "}"
  }
  let minted = ids.mint_session(ids.generator(clock.fixed(1000), 7)).0
  let session =
    "\"session\":\"" <> ids.session_id_to_string(minted) <> "\",\"epoch\":\"e\""

  assert protocol.decode(envelope("{" <> session <> "}")) |> is_ok
  assert protocol.decode(envelope("{" <> session <> ",\"limit\":20}")) |> is_ok
  assert protocol.decode(envelope("{" <> session <> ",\"limit\":21}"))
    |> is_ok
    == False
  assert protocol.decode(envelope("{" <> session <> ",\"before\":-1}"))
    |> is_ok
    == False
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn call_entry(
  seq: Int,
  name: String,
  call_id: String,
  arguments: json.JsonValue,
) -> entry.Entry {
  entry.MessageEntry(
    id(seq),
    None,
    seq,
    seq * 1000,
    message.AssistantMessage(
      [
        message.AssistantToolCall(message.ToolCall(
          call_id,
          name,
          arguments,
          None,
          None,
        )),
      ],
      "t",
      "t",
      "t",
      None,
      None,
      None,
      usage(),
      message.Stop,
      None,
      None,
      None,
      None,
      0,
    ),
    False,
  )
}

fn result_entry(
  seq: Int,
  name: String,
  call_id: String,
  details: json.JsonValue,
  is_error: Bool,
) -> entry.Entry {
  entry.MessageEntry(
    id(seq),
    None,
    seq,
    seq * 1000,
    message.ToolResultMessage(
      call_id,
      name,
      [message.ToolResultText("ok", None)],
      Some(details),
      None,
      None,
      is_error,
      0,
    ),
    False,
  )
}

fn prompt_entry(seq: Int) -> entry.Entry {
  entry.MessageEntry(
    id(seq),
    None,
    seq,
    seq * 1000,
    message.UserMessage([message.UserText("task", None)], 0, None),
    False,
  )
}

// A failed command after three reads: a command card, which is not a hard
// boundary.
fn command_run(first_seq: Int) -> List(entry.Entry) {
  let tag = int.to_string(first_seq)

  [
    call_entry(first_seq, "fs_read", "a" <> tag, json.Object([])),
    result_entry(first_seq + 1, "fs_read", "a" <> tag, json.Object([]), False),
    call_entry(first_seq + 2, "fs_read", "b" <> tag, json.Object([])),
    result_entry(first_seq + 3, "fs_read", "b" <> tag, json.Object([]), False),
    call_entry(
      first_seq + 4,
      "bash",
      "c" <> tag,
      json.Object([#("command", json.String("make"))]),
    ),
    result_entry(
      first_seq + 5,
      "bash",
      "c" <> tag,
      json.Object([#("exit_code", json.Int(2))]),
      True,
    ),
  ]
}

// A window that ended at the scan's cap offers no card before its first hard
// boundary, because a command card there depends on where the window began; a
// strand that fits is offered whole.
pub fn a_cut_window_offers_nothing_before_its_first_hard_boundary_test() {
  let lead = command_run(1)
  let cut_short = list.append(lead, list.map(strand(997), shift(_, 6)))
  let whole = list.take(cut_short, 20)

  assert list.length(cut_short) == timeline_read.scan_cap
  assert oldest_offered(cut_short) == Some(timeline.Prompted)
  assert oldest_offered(whole) == Some(timeline.Ran)
}

// The kind of the oldest card the pages reach, following each cursor.
fn oldest_offered(records: List(entry.Entry)) -> option.Option(timeline.Kind) {
  walk(records, timeline_read.of_records(records, None, 20))
}

fn walk(
  records: List(entry.Entry),
  feed: timeline_feed.Feed,
) -> option.Option(timeline.Kind) {
  // The last page's first card is the oldest one offered.
  case feed.older {
    Some(before) ->
      walk(records, timeline_read.of_records(records, Some(before), 20))
    None ->
      case feed.cards {
        [first, ..] -> Some(first.kind)
        [] -> None
      }
  }
}

fn shift(record: entry.Entry, by: Int) -> entry.Entry {
  case record {
    entry.MessageEntry(seq:, ..) ->
      entry.MessageEntry(
        ..record,
        id: id(seq + by),
        seq: seq + by,
        ts: { seq + by } * 1000,
      )
    entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> record
  }
}

// Pages tile the strand: each page ends just before the cursor that asked for
// it, no card is offered twice and none is skipped.
pub fn pages_are_contiguous_and_cover_every_card_test() {
  let records = strand(30)
  let all = timeline_read.of_records(records, None, 20)
  let newest = timeline_read.of_records(records, None, 7)
  let assert Some(c1) = newest.older
  let second = timeline_read.of_records(records, Some(c1), 7)
  let assert Some(c2) = second.older
  let third = timeline_read.of_records(records, Some(c2), 7)
  let seqs = fn(feed: timeline_feed.Feed) {
    list.map(feed.cards, fn(card) { card.from_seq })
  }
  let stitched = list.flatten([seqs(third), seqs(second), seqs(newest)])

  assert list.length(stitched) == 21
  assert stitched == list.sort(stitched, int.compare)
  assert list.unique(stitched) == stitched
  assert list.drop(stitched, 1)
    |> list.zip(stitched, _)
    |> list.all(fn(pair) { pair.0 < pair.1 })
  assert list.length(all.cards) == 20
}

// The open span comes back on the newest page only.
pub fn the_open_span_is_on_the_newest_page_only_test() {
  let records =
    list.append(
      strand(3),
      list.append(command_run(100), [
        call_entry(200, "fs_read", "zz", json.Object([])),
      ]),
    )
  let newest = timeline_read.of_records(records, None, 20)
  let older = timeline_read.of_records(records, Some(5), 20)

  assert newest.now != None
  assert older.now == None
}

// A reply that would exceed the byte bound sheds its oldest cards, keeps at least
// the newest, and points the cursor at the oldest it kept.
pub fn an_oversized_reply_sheds_oldest_cards_and_keeps_the_newest_test() {
  let long = string.repeat("d/", 190) <> "x.gleam"
  let heavy = fn(turn: Int) {
    let base = turn * 100
    let tag = int.to_string(turn)

    list.flatten([
      [prompt_entry(base)],
      list.flat_map([1, 2, 3, 4, 5, 6], fn(n) {
        let call_id = "e" <> tag <> int.to_string(n)
        let path = long <> int.to_string(n)

        [
          call_entry(
            base + n * 2,
            "fs_write",
            call_id,
            json.Object([#("path", json.String(path))]),
          ),
          result_entry(
            base + n * 2 + 1,
            "fs_write",
            call_id,
            json.Object([#("path", json.String(path))]),
            False,
          ),
        ]
      }),
    ])
  }
  let records = list.flat_map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], heavy)
  let feed = timeline_read.of_records(records, None, 20)
  let size = string.byte_size(json.to_string(timeline_feed.to_json(feed)))

  assert size <= timeline_feed.feed_bytes
  assert feed.cards != []
  assert case feed.cards, feed.older {
    [first, ..], Some(older) -> older == first.from_seq
    [_, ..], None | [], _ -> False
  }
}

// The command decoder refuses a limit of zero and a mistyped cursor, and takes
// the bounds as they are.
pub fn the_decoder_refuses_a_zero_limit_and_a_mistyped_cursor_test() {
  let minted = ids.mint_session(ids.generator(clock.fixed(1000), 7)).0
  let body = fn(extra: String) {
    "{\"v\":2,\"id\":1,\"cmd\":\"sessions.timeline\",\"body\":{\"session\":\""
    <> ids.session_id_to_string(minted)
    <> "\",\"epoch\":\"e\""
    <> extra
    <> "}}"
  }

  assert protocol.decode(body(",\"limit\":0")) |> is_ok == False
  assert protocol.decode(body(",\"limit\":1")) |> is_ok
  assert protocol.decode(body(",\"before\":\"7\"")) |> is_ok == False
  assert protocol.decode(body(",\"before\":0")) |> is_ok
}
