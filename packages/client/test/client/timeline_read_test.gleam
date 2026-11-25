//// The resident side of `sessions.timeline` (protocol-change/134): the page of
//// cards a strand's records make, its bounds, and the control command's decoder.

import client/daemon/protocol
import client/timeline_read
import core/clock
import core/entry
import core/ids
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
