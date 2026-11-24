//// The ask board: which asks are drawn, in what order, with what draft, and
//// what the daemon's feed and record documents say.

import ask_scene
import core/attention
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import tui/ask_board
import tui/ask_form
import tui/job

fn feed_row(
  session: String,
  state: String,
  ids: List(#(String, Int)),
) -> json.JsonValue {
  json.Object([
    #("session_id", json.String(session)),
    #("state", json.String(state)),
    #(
      "asks",
      json.Object([
        #("count", json.Int(list.length(ids))),
        #(
          "items",
          json.Array(
            list.map(ids, fn(entry) {
              json.Object([
                #("id", json.String(entry.0)),
                #("strand", json.String("main")),
                #("created_at", json.Int(entry.1)),
                #("head", json.String("which?")),
                #("questions", json.Int(1)),
              ])
            }),
          ),
        ),
      ]),
    ),
  ])
}

fn feed(rows: List(json.JsonValue)) -> json.JsonValue {
  json.Object([#("attention", json.Array(rows))])
}

// The reply of `attention.read` for an ask: the stored record with its content
// hoisted, no parents, and the revision and `may_answer` the daemon adds.
fn record(
  ask: attention.Ask,
  revision: Int,
  may_answer: Bool,
) -> json.JsonValue {
  let assert json.Object(stored) = attention.encode_ask(ask)
  let assert Ok(json.Object(content)) = list.key_find(stored, "content")
  let kept =
    list.filter(stored, fn(field) {
      field.0 != "content" && field.0 != "parents"
    })

  json.Object(
    list.flatten([
      kept,
      content,
      [
        #("revision", json.Int(revision)),
        #("may_answer", json.Bool(may_answer)),
      ],
    ]),
  )
}

// A read job's slot, as the board holds one while its read runs.
fn a_read() -> job.Awaiting(job.AsksReply) {
  job.awaiting(job.first())
}

fn ask(id: String, at: Int) -> attention.Ask {
  ask_scene.choice_ask(id, at)
}

pub fn the_feed_row_of_the_session_lists_its_asks_oldest_first_test() {
  let document =
    feed([
      feed_row("other", "ok", [#("ask-0000000001", 5)]),
      feed_row("s-1", "ok", [
        #("ask-0000000003", 30),
        #("ask-0000000001", 10),
        #("ask-0000000002", 20),
      ]),
    ])
  assert ask_board.decode_feed(document, "s-1")
    == Ok(
      ask_board.Feed(count: 3, ids: [
        "ask-0000000001",
        "ask-0000000002",
        "ask-0000000003",
      ]),
    )
}

pub fn a_row_that_is_not_ok_or_is_missing_says_nothing_test() {
  let unknown =
    feed([
      json.Object([
        #("session_id", json.String("s-1")),
        #("state", json.String("unknown")),
      ]),
    ])
  let assert Error(_) = ask_board.decode_feed(unknown, "s-1")
  let assert Error(_) = ask_board.decode_feed(feed([]), "s-1")
  let assert Error(_) = ask_board.decode_feed(json.Null, "s-1")
}

pub fn an_open_ask_for_the_owner_reads_back_as_the_stored_ask_test() {
  let stored = ask("ask-3f9c01a2b4", 1000)
  let assert Ok(Some(loaded)) =
    ask_board.decode_record(record(stored, 41, True))
  assert loaded.ask == stored
  assert loaded.revision == 41
  assert loaded.standing == ask_form.MayAnswer
}

pub fn an_observer_is_told_it_may_not_answer_test() {
  let assert Ok(Some(loaded)) =
    ask_board.decode_record(record(ask("ask-3f9c01a2b4", 1000), 41, False))
  assert loaded.standing == ask_form.ObserverOnly
}

pub fn an_answered_ask_or_one_for_a_strand_is_no_ask_here_test() {
  let answered =
    attention.Ask(
      ..ask("ask-3f9c01a2b4", 1000),
      state: attention.Answered(
        at: 2000,
        answer: attention.Answer(
          values: [
            #("q1", attention.Picked("Separate list")),
            #("q2", attention.Yes),
          ],
          by: "owner",
        ),
      ),
    )
  assert ask_board.decode_record(record(answered, 50, True)) == Ok(None)

  let base = ask("ask-3f9c01a2b4", 1000)
  let strand =
    attention.Ask(
      ..base,
      header: attention.Header(
        ..base.header,
        routing: attention.ToStrand("sub:audit"),
      ),
    )
  assert ask_board.decode_record(record(strand, 41, True)) == Ok(None)
}

pub fn a_damaged_record_is_an_error_not_a_crash_test() {
  let assert Error(_) = ask_board.decode_record(json.Null)
  let assert Error(_) =
    ask_board.decode_record(
      json.Object([
        #("status", json.String("open")),
        #("routing", json.String("owner")),
      ]),
    )
}

pub fn a_read_draws_two_asks_oldest_first_and_counts_the_rest_test() {
  let records =
    list.map([#("ask-0000000001", 10), #("ask-0000000002", 20)], fn(entry) {
      record(ask(entry.0, entry.1), 7, True)
    })
  let board = ask_board.loaded(ask_board.empty(), 3, records, 1000)
  assert list.map(board.forms, fn(form) { form.ask.header.id })
    == ["ask-0000000001", "ask-0000000002"]
  assert ask_board.more(board) == 1
  assert board.phase == ask_board.Resting(1000 + ask_board.rest_ms)
}

pub fn no_more_than_two_asks_are_ever_drawn_test() {
  let records =
    list.map([1, 2, 3, 4], fn(n) {
      record(ask("ask-000000000" <> int_text(n), n), 7, True)
    })
  let board = ask_board.loaded(ask_board.empty(), 4, records, 0)
  assert list.length(board.forms) == 2
  assert ask_board.more(board) == 2
}

fn int_text(n: Int) -> String {
  int.to_string(n)
}

pub fn a_new_ask_never_takes_the_keyboard_test() {
  let records = [record(ask("ask-0000000001", 10), 7, True)]
  let board = ask_board.loaded(ask_board.empty(), 1, records, 0)
  assert board.focus == ask_board.Composer
  assert ask_board.focused(board) == None
}

pub fn a_read_again_keeps_the_draft_and_drops_the_answered_ask_test() {
  let first = record(ask("ask-0000000001", 10), 7, True)
  let second = record(ask("ask-0000000002", 20), 7, True)
  let board = ask_board.loaded(ask_board.empty(), 2, [first, second], 0)
  let assert [one, ..] = board.forms
  let drafted =
    ask_form.Form(..one, drafts: [
      ask_form.Draft(picked: [1], other: None, text: ""),
      ask_form.Draft(picked: [], other: None, text: ""),
    ])
  let board = ask_board.with_form(board, 0, drafted)

  // The same two asks read again at a newer revision keep the draft.
  let again =
    ask_board.loaded(
      board,
      2,
      [record(ask("ask-0000000001", 10), 8, True), second],
      9000,
    )
  let assert [kept, _] = again.forms
  assert kept.revision == 8
  assert kept.drafts == drafted.drafts

  // The first is answered elsewhere: only the second remains.
  let gone = ask_board.loaded(again, 1, [second], 18_000)
  assert list.map(gone.forms, fn(form) { form.ask.header.id })
    == ["ask-0000000002"]
}

pub fn the_keyboard_goes_only_to_an_ask_the_owner_can_answer_test() {
  let observed = record(ask("ask-0000000001", 10), 7, False)
  let owned = record(ask("ask-0000000002", 20), 7, True)
  let board = ask_board.loaded(ask_board.empty(), 2, [observed, owned], 0)
  let focused = ask_board.focus_card(board)
  assert focused.focus == ask_board.Card("ask-0000000002")

  let only_observed = ask_board.loaded(ask_board.empty(), 1, [observed], 0)
  assert ask_board.focus_card(only_observed).focus == ask_board.Composer
}

pub fn the_keyboard_returns_to_the_composer_when_its_ask_goes_test() {
  let owned = record(ask("ask-0000000001", 10), 7, True)
  let board = ask_board.loaded(ask_board.empty(), 1, [owned], 0)
  let focused = ask_board.focus_card(board)
  assert focused.focus == ask_board.Card("ask-0000000001")
  let gone = ask_board.loaded(focused, 0, [], 9000)
  assert gone.focus == ask_board.Composer
  assert gone.forms == []
}

pub fn cycling_moves_between_answerable_asks_test() {
  let first = record(ask("ask-0000000001", 10), 7, True)
  let second = record(ask("ask-0000000002", 20), 7, True)
  let board =
    ask_board.loaded(ask_board.empty(), 2, [first, second], 0)
    |> ask_board.focus_card
  assert ask_board.cycle(board, 1).focus == ask_board.Card("ask-0000000002")
  assert ask_board.cycle(board, -1).focus == ask_board.Card("ask-0000000001")
  assert ask_board.cycle(ask_board.cycle(board, 1), 1).focus
    == ask_board.Card("ask-0000000002")
}

pub fn an_accepted_answer_removes_the_ask_and_asks_for_a_read_test() {
  let owned = record(ask("ask-0000000001", 10), 7, True)
  let board =
    ask_board.loaded(ask_board.empty(), 1, [owned], 0)
    |> ask_board.focus_card
  let done = ask_board.answered(board, "ask-0000000001")
  assert done.forms == []
  assert done.phase == ask_board.ReadDue
  assert done.focus == ask_board.Composer
}

pub fn a_refused_answer_keeps_the_draft_and_shows_words_test() {
  let owned = record(ask("ask-0000000001", 10), 7, True)
  let board = ask_board.loaded(ask_board.empty(), 1, [owned], 0)
  let refused =
    ask_board.answer_refused(board, "ask-0000000001", "The ask is gone.")
  let assert [form] = refused.forms
  assert form.refusal == Some("The ask is gone.")
  assert refused.phase == ask_board.ReadDue
}

pub fn the_poll_waits_for_its_rest_and_for_the_request_test() {
  let board = ask_board.empty()
  assert ask_board.read_due(board, 0)
  assert !ask_board.read_due(ask_board.reading(board, a_read()), 0)
  assert !ask_board.read_due(ask_board.sending(board, "ask-0000000001"), 0)
  let resting = ask_board.read_failed(board, 100)
  assert !ask_board.read_due(resting, 100 + ask_board.failure_rest_ms - 1)
  assert ask_board.read_due(resting, 100 + ask_board.failure_rest_ms)
}

pub fn another_session_starts_a_fresh_board_test() {
  let owned = record(ask("ask-0000000001", 10), 7, True)
  let board =
    ask_board.loaded(
      ask_board.Board(..ask_board.empty(), session: "s-1"),
      1,
      [owned],
      0,
    )
  assert ask_board.for_session(board, "s-1") == board
  let fresh = ask_board.for_session(board, "s-2")
  assert fresh.forms == []
  assert fresh.session == "s-2"
}

pub fn a_rest_can_be_cut_short_and_a_request_in_flight_cannot_test() {
  let resting = ask_board.read_failed(ask_board.empty(), 0)
  assert ask_board.due(resting).phase == ask_board.ReadDue

  // A read already due or in flight is left as it is.
  assert ask_board.due(ask_board.empty()).phase == ask_board.ReadDue
  let reading = ask_board.reading(resting, a_read())
  assert ask_board.due(reading).phase == reading.phase
  let sending = ask_board.sending(resting, "ask-0000000001")
  assert ask_board.due(sending).phase == ask_board.Sending("ask-0000000001")
}

// The keyboard follows an ask, not a position: when an earlier ask is answered
// elsewhere, Ctrl+s must not land on the ask that moved up into its place.
pub fn the_keyboard_stays_with_its_ask_when_an_earlier_ask_goes_test() {
  let first = record(ask("ask-0000000001", 10), 7, True)
  let second = record(ask("ask-0000000002", 20), 7, True)
  let board =
    ask_board.loaded(ask_board.empty(), 2, [first, second], 0)
    |> ask_board.focus_card
    |> ask_board.cycle(1)
  assert board.focus == ask_board.Card("ask-0000000002")

  // The first ask vanishes: the second is now at position zero and still has
  // the keyboard.
  let after = ask_board.loaded(board, 1, [second], 9000)
  let assert Some(#(0, form)) = ask_board.focused(after)
  assert form.ask.header.id == "ask-0000000002"

  // The ask that has the keyboard vanishes: the keyboard goes to the composer,
  // and not to the ask that remains.
  let on_first =
    ask_board.loaded(ask_board.empty(), 2, [first, second], 0)
    |> ask_board.focus_card
  assert on_first.focus == ask_board.Card("ask-0000000001")
  let gone = ask_board.loaded(on_first, 1, [second], 9000)
  assert gone.focus == ask_board.Composer
  assert ask_board.focused(gone) == None
}
