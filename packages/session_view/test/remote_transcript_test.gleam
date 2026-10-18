//// A page of a remote child's transcript is cut on the orchestrator that runs
//// the child and read on the parent's side (protocol-change/090). These pin
//// the page's bounds, its cursor, its total decoder and the words a host draws,
//// including that markup in a model's text stays text.

import core/accounting
import core/clock
import core/entry.{type Entry}
import core/ids
import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/remote_transcript.{Said}
import session_view/strand_framing

const child = "sub:^main/build-turn-1-0"

// Entries with distinct identities and the sequences given, newest first as a
// branch read returns them.
fn entries(seqs: List(Int), text: fn(Int) -> String) -> List(Entry) {
  let generator = ids.generator(clock.fixed(at: 0), seed: 7)
  let #(made, _) =
    list.fold(seqs, #([], generator), fn(acc, seq) {
      let #(made, generator) = acc
      let #(id, generator) = ids.mint_entry(generator)
      let record =
        entry.MessageEntry(
          id:,
          parent: None,
          seq:,
          ts: 0,
          message: message.UserMessage(
            content: [message.UserText(text: text(seq), text_signature: None)],
            timestamp: 0,
            origin: None,
          ),
          terminate: False,
        )
      #([record, ..made], generator)
    })
  list.reverse(made)
}

fn seqs_of(page: remote_transcript.Page) -> List(Int) {
  list.map(page.entries, fn(record) { record.seq })
}

// A read that returned one more entry than the limit says older ones exist, so
// the page keeps the newest, oldest first, and names the sequence the next
// read starts below. The last page has no cursor.
pub fn a_page_keeps_the_newest_entries_and_names_where_the_next_starts_test() {
  let scanned =
    entries([9, 8, 7, 6], fn(seq) { "entry " <> int.to_string(seq) })
  let page = remote_transcript.page_of(child, scanned, 3)
  assert seqs_of(page) == [7, 8, 9]
  assert page.next == Some(7)
  assert page.omitted == 0

  let last = remote_transcript.page_of(child, entries([3, 2], fn(_) { "x" }), 3)
  assert seqs_of(last) == [2, 3]
  assert last.next == None
}

// An entry too large to send alone is counted and skipped, and the page goes
// on past it, so one large result cannot stall the paging. Entries that fit
// only some of the way stop the page, and the cursor makes the next read start
// with the one that did not fit.
pub fn a_page_omits_an_entry_over_the_bound_and_stops_at_the_bound_test() {
  let huge = string.repeat("a", remote_transcript.page_bytes_limit + 10)
  let scanned =
    entries([5, 4, 3], fn(seq) {
      case seq {
        4 -> huge
        _ -> "small"
      }
    })
  let page = remote_transcript.page_of(child, scanned, 10)
  assert seqs_of(page) == [3, 5]
  assert page.omitted == 1
  assert page.next == None

  let half = string.repeat("b", remote_transcript.page_bytes_limit / 2)
  let filling = entries([3, 2, 1], fn(_) { half })
  let cut = remote_transcript.page_of(child, filling, 10)
  assert seqs_of(cut) == [3]
  assert cut.next == Some(3)
}

// What the box encodes the laptop decodes whole, and a page over its entry
// bound, or with a cursor that is not a sequence, is refused.
pub fn a_page_round_trips_and_a_damaged_one_is_refused_test() {
  let page =
    remote_transcript.page_of(child, entries([2, 1], fn(_) { "hello" }), 5)
  assert remote_transcript.decode(remote_transcript.encode(page)) == Ok(page)

  let crowded =
    remote_transcript.Page(
      ..page,
      entries: entries(
        int.range(from: 1, to: 52, with: [], run: list.prepend),
        fn(_) { "x" },
      ),
    )
  let assert Error(_) =
    remote_transcript.decode(remote_transcript.encode(crowded))
  let assert json.Object(fields) = remote_transcript.encode(page)
  let assert Error(_) =
    remote_transcript.decode(
      json.Object(list.key_set(fields, "next", json.Int(0))),
    )
}

// A model's text is words to draw, never markup: the words a host is given
// hold the angle brackets exactly as the model wrote them, and the framing a
// host draws around the page is the harness's, not the text's.
pub fn markup_in_a_transcript_is_kept_as_text_test() {
  let page =
    remote_transcript.page_of(
      child,
      entries([1], fn(_) { "<b>bold</b><script>alert(1)</script>" }),
      5,
    )
  assert remote_transcript.said(page)
    == [
      Said(
        speaker: remote_transcript.Asked,
        text: "<b>bold</b><script>alert(1)</script>",
      ),
    ]
  assert strand_framing.transcript_head(child, "box")
    == "[transcript of sub:^main/build-turn-1-0 on box]"
}

// The provider's reasoning never leaves the box: a page keeps what the model
// said and the tools it called, and no reasoning block.
pub fn a_page_carries_no_reasoning_test() {
  let assert [entry.MessageEntry(..) as record] = entries([1], fn(_) { "x" })
  let thought =
    entry.MessageEntry(
      ..record,
      message: assistant([
        message.AssistantThinking(
          thinking: "private chain of thought",
          thinking_signature: None,
          redacted: False,
        ),
        message.AssistantText(text: "the answer", text_signature: None),
      ]),
    )
  let page = remote_transcript.page_of(child, [thought], 5)
  let encoded = json.to_string(remote_transcript.encode(page))
  assert !string.contains(encoded, "private chain of thought")
  assert string.contains(encoded, "the answer")
}

fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
    api: "",
    provider: "",
    model: "",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: accounting.zero_usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

// A peek applies only the answer to the request it was sent as, and only a
// page for its own child.
pub fn a_peek_applies_only_its_own_answer_test() {
  let page = remote_transcript.page_of(child, entries([1], fn(_) { "x" }), 5)
  let loading =
    remote_transcript.open(child, "box") |> remote_transcript.sent(7)
  assert remote_transcript.receive(loading, remote_transcript.Ready(6, page))
    == loading
  assert remote_transcript.receive(loading, remote_transcript.Ready(7, page))
    == remote_transcript.Shown(child, "box", page)
  assert remote_transcript.receive(
      loading,
      remote_transcript.Failed(7, "transcript hidden"),
    )
    == remote_transcript.Unavailable(child, "box", "transcript hidden")
}
