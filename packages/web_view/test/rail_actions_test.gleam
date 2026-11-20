//// The live rail's actions on a session's own page (protocol-change/051, the
//// addendum "the live rail's actions"): "Retry the last step" on a stuck
//// strand's card, and "File issue" and "Dismiss" on a find's card. An
//// operator's page draws them and its presses send the daemon what the home's
//// threads send. A page that may not act draws no button, and a message that
//// reaches it sends nothing.

import core/attention
import core/clock
import core/ids
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/attention_feed.{Find, Row, Section, Stuck}
import web_view/component
import web_view/item_pane
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

const find_id = "find-0123456789"

const strand = "sub:main/audit"

// What the page asked the daemon to do, in the order it asked.
type Acted {
  Closed(find: String, revision: Int, closure: attention.Closure)
  Retried(strand: String)
}

// One stuck strand and one find, which is all these tests need of the feed.
fn row() -> attention_feed.Row {
  Row(
    waiting_since: Some(10),
    asks: Section(count: 0, items: []),
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
      Stuck(
        strand:,
        failed_at: Some(3),
        reason: None,
        retry_after_ms: None,
        parent: None,
      ),
    ]),
  )
}

// The find read in full, at revision 7, as the daemon's record read gives it.
fn the_find() -> attention.Find {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))

  attention.Find(
    header: attention.Header(
      id: find_id,
      created_at: 5,
      routing: attention.ToOwner,
      anchor: attention.Anchor(operation:, step_id: "step-1", source_index: 1),
      strand: "main",
      parents: [],
    ),
    kind: attention.Bug,
    text: "No backoff in retry.",
    path: None,
    line: None,
    state: attention.FindOpen,
  )
}

// How the daemon answers a press: at once, or never, which keeps the action
// out for as long as a test looks at it.
type Answering {
  Promptly
  Never
}

fn start(
  acted: Subject(Acted),
  acting: Bool,
  answering: Answering,
) -> component.Start(page_fixture.Wire) {
  let start = page_fixture.start()
  let settle = fn(deliver, words) {
    case answering {
      Promptly -> deliver(component.AnswerSent(words))
      Never -> Nil
    }
  }

  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      attention: Some(
        component.Attention(
          read: fn(deliver) { deliver(Ok(row())) },
          record: fn(_id, deliver) {
            deliver(Ok(item_pane.FindRecord(find: the_find(), revision: 7)))
          },
          answer: None,
          act: case acting {
            True ->
              Some(
                component.Act(
                  close: fn(find, revision, closure, deliver) {
                    process.send(acted, Closed(find, revision, closure))
                    settle(deliver, "Closed.")
                  },
                  retry: fn(strand, deliver) {
                    process.send(acted, Retried(strand))
                    settle(deliver, "Delivered to the strand · admitted")
                  },
                ),
              )
            False -> None
          },
        ),
      ),
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

// Opens the page and ticks it, so the rail's read and the find's record read
// are asked and answered.
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

fn received(acted: Subject(Acted)) -> List(Acted) {
  case process.receive(acted, 0) {
    Ok(one) -> [one, ..received(acted)]
    Error(Nil) -> []
  }
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// The paths of every handler beneath the rail, with the event each one takes.
fn rail_handlers(view: Element(message)) -> List(String) {
  every_handler(view)
  |> list.filter(string.starts_with(_, component.rail_path <> "\t"))
}

fn paths(handlers: List(String), event: String) -> List(String) {
  list.filter_map(handlers, fn(handler) {
    case string.split_once(handler, "\n") {
      Ok(#(path, name)) if name == event -> Ok(path)
      _ -> Error(Nil)
    }
  })
}

// An operator's page draws the three buttons in the rail, and the same three
// in the phone's sheet.
pub fn an_operators_rail_draws_retry_file_issue_and_dismiss_test() {
  let html = drawn(opened(start(process.new_subject(), True, Promptly)))

  assert count(html, "Retry the last step") == 2
  assert count(html, "File issue") == 2
  assert count(html, "Dismiss") == 2
}

// The buttons are at the exact paths the socket's tests pin, and they are the
// only handlers the rail gains: the find's insight press stays where it was.
pub fn the_buttons_are_at_their_exact_paths_test() {
  let model = opened(start(process.new_subject(), True, Promptly))
  let clicks = paths(rail_handlers(operator_page.view(model)), "click")

  assert list.length(clicks) == 4
  assert list.count(clicks, component.rail_click) == 1
  assert list.count(clicks, component.rail_retry) == 1
  assert list.count(clicks, component.rail_close) == 2

  // No path is two things, so a socket that admitted one shape would not have
  // admitted another by accident.
  assert list.all(clicks, fn(path) {
    list.count(
      [
        component.rail_click(path),
        component.rail_retry(path),
        component.rail_close(path),
      ],
      fn(is) { is },
    )
    == 1
  })
}

pub fn the_predicates_refuse_every_neighbouring_path_test() {
  let retry = "0\t3\t0\t4\t1\t0\t1\t1\t2\t0"
  let close = "0\t3\t0\t4\t1\t1\t1\t0\t2\t1"

  assert component.rail_retry(retry)
  assert component.rail_close(close)

  // A pinned group's card closes nothing, and an insight's retries nothing.
  assert !component.rail_close(retry)
  assert !component.rail_retry(close)

  // A third button, a deeper path, a shorter one, another region and a
  // position that is not a counter are none of them an action.
  assert !component.rail_close("0\t3\t0\t4\t1\t1\t1\t0\t2\t2")
  assert !component.rail_retry("0\t3\t0\t4\t1\t0\t1\t1\t2\t1")
  assert !component.rail_close(close <> "\t0")
  assert !component.rail_close("0\t3\t0\t4\t1\t1\t1\t0\t2")
  assert !component.rail_retry("0\t3\t0\t5\t1\t0\t1\t1\t2\t0")
  assert !component.rail_close("0\t3\t0\t4\t1\t1\t1\tx\t2\t0")
  assert !component.rail_close("0\t3\t0\t4\t1\t1\t1\t-1\t2\t0")
}

// Retry sends the strand the one fixed prompt through the daemon, and the
// daemon's word is said in the rail.
pub fn retry_asks_the_stuck_strand_and_says_the_daemons_word_test() {
  let acted = process.new_subject()
  let model = opened(start(acted, True, Promptly))
  let retried = second(model, component.RailRetried(strand))

  assert received(acted) == [Retried(strand)]
  assert string.contains(drawn(retried), "Delivered to the strand")
}

// File issue and Dismiss close the find at the revision the page read, in the
// way the button says.
pub fn the_close_buttons_name_the_revision_and_the_way_test() {
  let acted = process.new_subject()
  let model = opened(start(acted, True, Promptly))
  let key = "find:" <> find_id

  let filed = second(model, component.RailClosed(key, attention.Filed))
  assert received(acted) == [Closed(find_id, 7, attention.Filed)]
  assert string.contains(drawn(filed), "Closed.")

  let _ = second(model, component.RailClosed(key, attention.Dismissed))
  assert received(acted) == [Closed(find_id, 7, attention.Dismissed)]
}

// A key or a strand the feed row does not hold is not acted on.
pub fn an_unknown_find_or_strand_is_not_acted_on_test() {
  let acted = process.new_subject()
  let model = opened(start(acted, True, Promptly))

  let _ =
    second(model, component.RailClosed("find:find-ffffffffff", attention.Filed))
  let _ =
    second(model, component.RailClosed("ask:ask-0123456789", attention.Filed))
  let _ = second(model, component.RailRetried("main"))

  assert received(acted) == []
}

// While one action is out its card says so and offers nothing, and a second
// press, on either card, sends nothing.
pub fn only_one_action_is_out_at_a_time_test() {
  let acted = process.new_subject()
  let model = opened(start(acted, True, Never))
  let pressed = second(model, component.RailRetried(strand))

  assert received(acted) == [Retried(strand)]
  assert string.contains(drawn(pressed), "Sending…")

  let again = second(pressed, component.RailRetried(strand))
  let other =
    second(again, component.RailClosed("find:" <> find_id, attention.Filed))

  assert received(acted) == []
  assert count(drawn(other), "Retry the last step") == 0
  assert count(drawn(other), "File issue") == 2
}

// A page that may not act draws no button and sends nothing for a message that
// reaches it, so its handler count is the one it had.
pub fn a_page_that_may_not_act_draws_no_button_and_sends_nothing_test() {
  let acted = process.new_subject()
  let model = opened(start(acted, False, Promptly))
  let html = drawn(model)

  assert !string.contains(html, "Retry the last step")
  assert !string.contains(html, "File issue")
  assert !string.contains(html, "Dismiss")
  assert !string.contains(html, "lift-acts")

  let clicks = paths(rail_handlers(operator_page.view(model)), "click")
  assert list.length(clicks) == 1
  assert list.all(clicks, component.rail_click)

  let _ = second(model, component.RailRetried(strand))
  let _ =
    second(model, component.RailClosed("find:" <> find_id, attention.Filed))
  assert received(acted) == []
}

// The observer's own view is the page without the capability, so its tree has
// the one handler the rail always had.
pub fn an_observers_view_has_only_the_insight_press_test() {
  let model = opened(start(process.new_subject(), False, Promptly))
  let html = element.to_string(component.view(model))
  let clicks = paths(rail_handlers(component.view(model)), "click")

  assert !string.contains(html, "Retry the last step")
  assert !string.contains(html, "File issue")
  assert list.all(clicks, component.rail_click)
}

// The two buttons of a find's card are drawn after the card's own button, as
// its last child, so the insight's press keeps the place it had.
pub fn the_actions_follow_the_cards_button_test() {
  let html = drawn(opened(start(process.new_subject(), True, Promptly)))
  let assert Ok(#(_, card)) = string.split_once(html, "lift-find")
  let assert Ok(#(press, _)) = string.split_once(card, "lift-acts")

  assert string.contains(press, "lift-press")
  assert !string.contains(press, "File issue")
}
