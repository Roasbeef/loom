//// Which asks hold a strand and what the reminder says about them
//// (protocol-change/119, the 2026-11-23 addendum): only an open ask of this
//// strand routed to the owner holds it, the answer's own prompt releases it,
//// and the reminder names each ask and no more than the bound.

import core/attention.{
  type Ask, Alternative, Anchor, Ask, AskOpen, Confirm, Header, Plain, Question,
}
import core/attention_answer
import core/attention_hold
import core/clock
import core/ids
import core/json
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

fn operation() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn ask(
  id: String,
  strand: String,
  routing: attention.Routing,
  state: attention.AskState,
  at: Int,
) -> Ask {
  Ask(
    header: Header(
      id:,
      created_at: at,
      routing:,
      anchor: Anchor(operation: operation(), step_id: "s", source_index: 0),
      strand:,
      parents: [],
    ),
    why: None,
    questions: [
      Question("q1", "Retry the migration?", Confirm, []),
      Question("q2", "Which branch?", attention.Choice, [
        Alternative("a", None, Plain),
        Alternative("b", None, Plain),
      ]),
    ],
    state:,
  )
}

fn cell(ask: Ask) -> #(String, json.JsonValue) {
  #(attention.ask_key(ask.header.id), attention.encode_ask(ask))
}

fn open(id: String, at: Int) -> Ask {
  ask(id, "main", attention.ToOwner, AskOpen, at)
}

pub fn only_an_open_owner_ask_of_this_strand_holds_test() {
  let answered =
    ask(
      "ask-0000000003",
      "main",
      attention.ToOwner,
      attention.Answered(at: 9, answer: attention.Answer(values: [], by: "o")),
      3,
    )
  let cells = [
    cell(open("ask-0000000001", 1)),
    cell(answered),
    cell(ask("ask-0000000004", "main", attention.ToStrand("sub:1"), AskOpen, 4)),
    cell(ask("ask-0000000005", "sub:1", attention.ToOwner, AskOpen, 5)),
    #(attention.guard_key(attention.ask_prefix), json.Int(7)),
    #("attention/ask/ask-0000000006", json.String("damaged")),
  ]

  let held = attention_hold.holding(cells, "main")
  assert list.map(held, fn(a) { a.header.id }) == ["ask-0000000001"]
  assert list.map(attention_hold.holding(cells, "sub:1"), fn(a) { a.header.id })
    == ["ask-0000000005"]
  assert attention_hold.holding(cells, "advisor") == []
}

pub fn holding_orders_oldest_first_test() {
  let cells = [
    cell(open("ask-0000000002", 20)),
    cell(open("ask-0000000001", 20)),
    cell(open("ask-0000000009", 10)),
  ]
  assert list.map(attention_hold.holding(cells, "main"), fn(a) { a.header.id })
    == ["ask-0000000009", "ask-0000000001", "ask-0000000002"]
}

pub fn the_answers_own_prompt_releases_its_ask_test() {
  let first = open("ask-0000000001", 1)
  let second = open("ask-0000000002", 2)
  let answer =
    attention_answer.prompt_text(first, [
      #("q1", attention.Yes),
      #("q2", attention.Picked("a")),
    ])

  assert attention_hold.unanswered([first, second], [answer, "continue"])
    == [second]
  assert attention_hold.unanswered([first, second], ["continue"])
    == [first, second]
}

pub fn no_open_ask_means_no_reminder_test() {
  assert attention_hold.reminder([]) == Error(Nil)
}

pub fn the_reminder_names_each_ask_by_id_and_first_question_test() {
  let assert Ok(text) =
    attention_hold.reminder([
      open("ask-0000000001", 1),
      open("ask-0000000002", 2),
    ])

  assert string.starts_with(text, attention_hold.lead)
  assert string.ends_with(text, attention_hold.trail)
  assert string.contains(
    text,
    "- ask-0000000001: Retry the migration? (and 1 more question)",
  )
  assert string.contains(text, "- ask-0000000002: Retry the migration?")
  assert string.contains(text, "has not answered")
  assert string.contains(text, "Do not do what the answer decides")
}

pub fn the_reminder_is_bounded_however_many_asks_are_open_test() {
  let asks =
    list.map([1, 2, 3, 4, 5, 6, 7, 8, 9], fn(n) {
      open("ask-000000000" <> int.to_string(n), n)
    })
  let assert Ok(text) = attention_hold.reminder(asks)

  assert string.contains(text, "- and 5 more open asks")
  assert !string.contains(text, "ask-0000000005")
  assert string.byte_size(text) < 1500
}

pub fn a_long_first_question_is_clipped_test() {
  let long = string.repeat("word ", 100)
  let base = open("ask-0000000001", 1)
  let asked = Ask(..base, questions: [Question("q1", long, Confirm, [])])
  let assert Ok(text) = attention_hold.reminder([asked])

  assert string.contains(text, "…")
  assert !string.contains(text, string.repeat("word ", 30))
}
