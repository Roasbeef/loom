//// The asks waiting on the owner, drawn where the owner reads
//// (protocol-change/051, the addendum "the ask in the dock"): a card above the
//// operator's composer and above the observer's bar for each open owner-routed
//// ask, oldest first, with the questions drawn once and each option's note
//// under its label. An operator's card holds the form and a Send, an
//// observer's holds the questions as text, and an ask that is no longer open
//// draws nothing. The turn that called `ask` is tinted in the lane and tagged
//// `lifted · Ask`.

import core/attention
import core/clock
import core/ids
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element
import page_fixture
import web_view/attention_feed.{Ask, Row, Section}
import web_view/component
import web_view/item_pane
import web_view/operator_page

const first_id = "ask-0123456789"

const second_id = "ask-2222222222"

fn feed_ask(id: String, at: Int, strand: String) -> attention_feed.Ask {
  Ask(id:, strand:, created_at: at, head: "Fold or separate?", questions: 2)
}

fn row(asks: List(attention_feed.Ask)) -> attention_feed.Row {
  Row(
    waiting_since: None,
    asks: Section(count: list.length(asks), items: asks),
    finds: Section(count: 0, items: []),
    stuck: Section(count: 0, items: []),
  )
}

fn anchor() -> attention.Anchor {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  attention.Anchor(operation:, step_id: "step-1", source_index: 1)
}

// An ask of two questions: a choice whose options all carry a note, one of
// them recommended, and a confirm.
fn the_ask(id: String) -> attention.Ask {
  attention.Ask(
    header: attention.Header(
      id:,
      created_at: 10,
      routing: attention.ToOwner,
      anchor: anchor(),
      strand: "main",
      parents: [],
    ),
    why: None,
    questions: [
      attention.Question(
        key: "q1",
        prompt: "Fold or separate?",
        kind: attention.Choice,
        options: [
          attention.Alternative(
            label: "Fold under open",
            note: Some("Keeps context."),
            emphasis: attention.Recommended,
          ),
          attention.Alternative(
            label: "Separate list",
            note: Some("Closed work leaves."),
            emphasis: attention.Plain,
          ),
        ],
      ),
      attention.Question(
        key: "q2",
        prompt: "Keep the independent parts?",
        kind: attention.Confirm,
        options: [],
      ),
    ],
    state: attention.AskOpen,
  )
}

fn start(
  asks: List(attention_feed.Ask),
  answering: Bool,
) -> component.Start(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      attention: Some(component.Attention(
        read: fn(deliver) { deliver(Ok(row(asks))) },
        record: fn(id, deliver) {
          deliver(Ok(item_pane.AskRecord(ask: the_ask(id), revision: 7)))
        },
        answer: case answering {
          True ->
            Some(fn(_ask, _revision, _form, deliver) {
              deliver(component.AnswerSent("Answered."))
            })
          False -> None
        },
        act: None,
      )),
    ),
  )
}

// Applies a message and the messages its effects dispatch, as the runtime does.
fn step(model, message: operator_page.Msg(page_fixture.Wire)) {
  let #(model, effects) = operator_page.update(model, message)
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { dynamic.nil() },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  settle(model, dispatched)
}

fn settle(model, dispatched) {
  case process.receive(dispatched, 0) {
    Ok(next) -> settle(step(model, next), dispatched)
    Error(Nil) -> model
  }
}

// Opens the page for `role` and ticks it, so the feed row is read and each ask
// read in full.
fn opened(start: component.Start(page_fixture.Wire), role: String) {
  let wire = process.new_subject()
  list.fold(
    list.flatten([
      [operator_page.Observed(component.Opened(wire))],
      list.map(page_fixture.transfer(role, []), fn(frame) {
        operator_page.Observed(component.Arrived([frame]))
      }),
      [operator_page.Observed(component.Ticked)],
    ]),
    component.new(start),
    step,
  )
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// The card's own markup: from its section to the section's end.
fn dock_of(html: String) -> String {
  let assert Ok(#(_, from)) =
    string.split_once(html, "<section aria-label=\"Asks waiting\"")
    as "the page draws the ask card"
  let assert Ok(#(card, _)) = string.split_once(from, "</section>")
  card
}

// An operator's page draws the card between the approvals and the end of the
// dock, as the dock's last child, so the composer's path does not move.
pub fn an_operators_card_is_in_the_dock_with_the_form_and_send_test() {
  let html =
    operator(opened(start([feed_ask(first_id, 10, "main")], True), "operator"))
  let card = dock_of(html)

  assert string.contains(card, "Ask")
  assert string.contains(card, "waiting since")
  assert string.contains(card, "<loom-time")
  assert string.contains(card, "· main")
  assert string.contains(card, "type=\"radio\"")
  assert string.contains(card, ">Send</button>")

  // The card is inside the dock, after the composer.
  let dock = index_of(html, "<footer class=\"dock\"")
  let composer =
    index_of(html, "<form aria-label=\"Composer\" class=\"composer")
  let ask = index_of(html, "Asks waiting")
  assert dock > 0 && dock < composer && composer < ask
}

// Each question is drawn once, and an option's note sits in the same element
// beside its label whether or not the option is recommended.
pub fn each_question_is_drawn_once_with_its_note_under_each_label_test() {
  let card =
    dock_of(
      operator(opened(start([feed_ask(first_id, 10, "main")], True), "operator")),
    )

  assert count(card, "Fold or separate?") == 1
  assert count(card, "Keep the independent parts?") == 1
  assert count(card, "inbox-note") == 2
  assert string.contains(card, "Keeps context.")
  assert string.contains(card, "Closed work leaves.")
}

// An observer's page shows the questions, and no form and no Send.
pub fn an_observers_card_shows_the_questions_and_no_form_test() {
  let card =
    dock_of(
      observer(opened(
        start([feed_ask(first_id, 10, "main")], False),
        "observer",
      )),
    )

  assert string.contains(card, "Fold or separate?")
  assert string.contains(card, "Keeps context.")
  assert string.contains(card, "recommended")
  assert !string.contains(card, "<form")
  assert !string.contains(card, "<input")
  assert !string.contains(card, "Send")
}

// Several open asks are one card each, oldest first, whatever order the feed
// listed them in.
pub fn several_asks_are_one_card_each_oldest_first_test() {
  let card =
    dock_of(
      operator(opened(
        start(
          [feed_ask(second_id, 20, "sub:a"), feed_ask(first_id, 10, "main")],
          True,
        ),
        "operator",
      )),
    )

  assert count(card, "ask-card") == 2
  assert index_of(card, "· main") < index_of(card, "· sub:a")
}

// An ask the feed row no longer holds, because it was answered or closed, is
// drawn as nothing.
pub fn an_answered_ask_is_not_drawn_test() {
  let model = opened(start([feed_ask(first_id, 10, "main")], True), "operator")
  assert string.contains(operator(model), "Asks waiting")

  let after =
    step(model, operator_page.Observed(component.RailRead(Ok(row([])))))
  assert !string.contains(operator(after), "Asks waiting")
  assert !string.contains(observer(after), "Asks waiting")
}

// The turn that called `ask` is the lane's row for the ask: tinted, tagged
// `lifted · Ask`, and the rail's press names it. An earlier turn is not.
pub fn the_turn_that_asked_is_tinted_and_tagged_in_the_lane_test() {
  let html = laned(12_500, "main")

  assert string.contains(html, "needs-you")
  assert count(html, "lifted · Ask") == 1

  // The tag is on the later row: the earlier turn's words and the asking
  // prompt come first, and the one tag follows them both.
  assert index_of(html, "Hi.") < index_of(html, "ask me")
  assert index_of(html, "ask me") < index_of(html, "lifted · Ask")
}

// An ask stamped before every row of the lane has no row to tag.
pub fn an_ask_older_than_every_row_tags_nothing_test() {
  assert count(laned(500, "main"), "lifted · Ask") == 0
}

// An ask from a strand that is not on screen is not matched to a turn of the
// strand that is.
pub fn an_ask_from_another_strand_tags_nothing_test() {
  assert count(laned(12_500, "sub:a"), "lifted · Ask") == 0
}

// The page with an earlier turn and the asking turn in its lane, and one open
// ask of `strand` recorded at `at`.
fn laned(at: Int, strand: String) -> String {
  let model =
    component.new(start([], True))
    |> component.apply([
      lane_fixture.asking_after_a_turn(first_id, "Which branch?"),
    ])
    |> lane_fixture.opened
  step(
    model,
    operator_page.Observed(
      component.RailRead(Ok(row([feed_ask(first_id, at, strand)]))),
    ),
  )
  |> operator
}

// A page that has ended draws the questions as text, because a submit there is
// dropped: no form, no input and no Send, in the card or under the rail's row.
pub fn an_ended_page_draws_questions_without_a_form_test() {
  let model =
    opened(start([feed_ask(first_id, 10, "main")], True), "operator")
    |> step(operator_page.Observed(component.Refused("gone")))
  let card = dock_of(operator(model))

  assert string.contains(card, "Fold or separate?")
  assert !string.contains(card, "<form")
  assert !string.contains(card, "<input")
  assert !string.contains(card, "Send")
}

fn index_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}
