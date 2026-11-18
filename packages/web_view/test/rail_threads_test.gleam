//// The live rail's asks, stuck strands and finds on a session's own page
//// (protocol-change/051, the addendum "the live rail, answered"): an ask and a
//// stuck strand pin under "Needs you", a find folds under "Insights", and an
//// operator's page answers an ask in the rail with the components and the rule
//// the inbox uses. An observer's page draws the rows and no form.

import core/attention
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/attention_feed.{Ask, Find, Row, Section, Stuck}
import web_view/component
import web_view/item_pane
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

const ask_id = "ask-0123456789"

const find_id = "find-0123456789"

fn row() -> attention_feed.Row {
  Row(
    waiting_since: Some(10),
    asks: Section(count: 1, items: [
      Ask(
        id: ask_id,
        strand: "main",
        created_at: 10,
        head: "<b>Which</b> branch?",
        questions: 1,
      ),
    ]),
    finds: Section(count: 1, items: [
      Find(
        id: find_id,
        strand: "main",
        kind: attention.Bug,
        created_at: 5,
        head: "No backoff in retry.",
        path: None,
        line: None,
      ),
    ]),
    stuck: Section(count: 1, items: [
      Stuck(strand: "sub:main/audit", failed_at: Some(3)),
    ]),
  )
}

fn anchor() -> attention.Anchor {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  attention.Anchor(operation:, step_id: "step-1", source_index: 1)
}

fn the_ask() -> attention.Ask {
  attention.Ask(
    header: attention.Header(
      id: ask_id,
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
        prompt: "Which branch?",
        kind: attention.Choice,
        options: [
          attention.Alternative(
            label: "alpha\" onclick=\"x",
            note: None,
            emphasis: attention.Recommended,
          ),
          attention.Alternative(
            label: "beta",
            note: None,
            emphasis: attention.Plain,
          ),
        ],
      ),
    ],
    state: attention.AskOpen,
  )
}

type Sent {
  Sent(ask: String, revision: Int, form: JsonValue)
}

fn start(
  sent: Subject(Sent),
  answering: Bool,
) -> component.Start(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      attention: Some(
        component.Attention(
          read: fn(deliver) { deliver(Ok(row())) },
          record: fn(_id, deliver) {
            deliver(Ok(item_pane.AskRecord(ask: the_ask(), revision: 7)))
          },
          answer: case answering {
            True ->
              Some(fn(ask, revision, form, deliver) {
                process.send(sent, Sent(ask, revision, form))
                deliver(component.AnswerSent("Answered."))
              })
            False -> None
          },
        ),
      ),
    ),
  )
}

// Applies a message and the messages its effects dispatch, as the runtime does:
// `page_fixture.run` drops what an effect dispatches, and the rail's reads
// answer by dispatching.
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

// Opens the page and ticks it, so the rail's read is asked and answered.
fn opened(start: component.Start(page_fixture.Wire)) {
  let wire = process.new_subject()
  list.fold(
    list.flatten([
      [operator_page.Observed(component.Opened(wire))],
      list.map(page_fixture.transfer("operator", []), fn(frame) {
        operator_page.Observed(component.Arrived([frame]))
      }),
      [operator_page.Observed(component.Ticked)],
    ]),
    component.new(start),
    step,
  )
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

fn second(model, message: component.Msg(page_fixture.Wire)) {
  step(model, operator_page.Observed(message))
}

fn received(sent: Subject(Sent)) -> List(Sent) {
  case process.receive(sent, 0) {
    Ok(one) -> [one, ..received(sent)]
    Error(Nil) -> []
  }
}

// An ask and a stuck strand are pinned under "Needs you", and a find is an
// insight. The ask's own words are escaped text and never an attribute.
pub fn the_rail_pins_an_ask_and_a_stuck_strand_and_folds_a_find_test() {
  let sent = process.new_subject()
  let html = drawn(opened(start(sent, True)))

  let needs = index_of(html, "Needs you")
  let insights = index_of(html, "Insights")
  let ask = index_of(html, "&lt;b&gt;Which&lt;/b&gt; branch?")
  let stuck = index_of(html, "Stopped on a failed run")
  let find = index_of(html, "No backoff in retry.")
  assert needs > 0 && needs < ask && ask < insights
  assert stuck > needs && stuck < insights
  assert find > insights

  // The form is the inbox's: fixed controls named by key, valued by position.
  assert string.contains(html, "name=\"q1\"")
  assert string.contains(html, "type=\"radio\"")
  assert string.contains(html, "value=\"0\"")
  assert string.contains(html, "Send the answer")
  assert !string.contains(html, "<b>")
  assert !string.contains(html, "value=\"alpha")
  assert !string.contains(html, "\" onclick=\"")
}

// A submit is checked by the daemon's own rule and sent at the revision the
// ask was read at, and the word that comes back is said in the rail.
pub fn an_answer_is_sent_at_its_revision_and_its_word_is_said_test() {
  let sent = process.new_subject()
  let model = opened(start(sent, True))
  let answered = second(model, component.RailAnswered(ask_id, [#("q1", "1")]))

  let assert [Sent(ask: asked, revision: 7, form:)] = received(sent)
  assert asked == ask_id
  let assert json.Object([#("answers", json.Object(answers)), ..]) = form
  assert list.key_find(answers, "q1") == Ok(json.String("beta"))
  assert string.contains(drawn(answered), "Answered.")
}

// A form the rule would refuse is not sent, and says why beside the ask.
pub fn an_invalid_form_is_not_sent_test() {
  let sent = process.new_subject()
  let model = opened(start(sent, True))
  let html = drawn(second(model, component.RailAnswered(ask_id, [])))

  assert received(sent) == []
  assert string.contains(html, "Question 1: missing")

  // A forged field is refused by name too.
  let forged =
    drawn(second(model, component.RailAnswered(ask_id, [#("by", "me")])))
  assert string.contains(forged, "The form: no such field")
  assert received(sent) == []
}

// A page that may not answer draws the same rows and no form, and ignores a
// submit that reaches it.
pub fn an_observers_rail_has_no_form_and_sends_nothing_test() {
  let sent = process.new_subject()
  let model = opened(start(sent, False))
  let html = drawn(model)

  assert string.contains(html, "&lt;b&gt;Which&lt;/b&gt; branch?")
  assert !string.contains(html, "name=\"q1\"")
  assert !string.contains(html, "type=\"radio\"")
  assert !string.contains(html, "Send the answer")

  let _ = second(model, component.RailAnswered(ask_id, [#("q1", "1")]))
  assert received(sent) == []
}

// An ask the page has not read in full, or that the row no longer holds, is not
// answered.
pub fn an_unknown_ask_is_not_answered_test() {
  let sent = process.new_subject()
  let model = opened(start(sent, True))
  let _ =
    second(model, component.RailAnswered("ask-ffffffffff", [#("q1", "1")]))
  assert received(sent) == []
}

// The form's submit is at the exact path `component.rail_submit` names, which is
// the one place an operator's page sends a submit beneath the rail.
pub fn the_rails_submit_is_at_its_exact_path_test() {
  let sent = process.new_subject()
  let model = opened(start(sent, True))
  let submits =
    every_handler(operator_page.view(model))
    |> list.filter(string.starts_with(_, component.rail_path <> "\t"))
    |> list.filter(string.ends_with(_, "\nsubmit"))

  assert list.length(submits) == 1
  let assert [path] = submits
  assert component.rail_submit(string.drop_end(path, 7))

  // Nothing else beneath the rail submits, and the click's shape is not one.
  assert !component.rail_submit("0\t3\t0\t4\t1\t1\t1\t0\t1")
  assert !component.rail_submit("0\t3\t0\t4\t1\t0\t1\tx\t1")
  assert !component.rail_submit("0\t3\t0\t4\t1\t0\t1\t0\t0")
  assert !component.rail_submit("0\t3\t0\t5\t1\t0\t1\t0\t1")
}

// The phone's sheet carries the same ask.
pub fn the_phone_sheet_shows_the_same_ask_test() {
  let sent = process.new_subject()
  let html = drawn(opened(start(sent, True)))

  assert string.contains(html, "lift-sheet")
  assert string.contains(html, "2 need you")
  assert list.length(string.split(html, "Send the answer")) == 3
}

fn index_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}
