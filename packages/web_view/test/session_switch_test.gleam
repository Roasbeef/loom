//// Opening another session from an operator's page (protocol-change/051, the
//// addendum on switching sessions).
////
//// A switch is a navigation, so what these tests read is the request the page
//// makes and what it draws for the answer: a sidebar row that can be opened
//// is a button beneath `component.sidebar_path`, pressing it asks the
//// transport's `open` for the session the row named, a ticket becomes the
//// address the hidden `<loom-switch>` carries, and a refusal is worded in the
//// composer's notice and moves nobody. A peer message's Open button asks the
//// same way, and only for a session in the principal's own list of running
//// sessions. The observer's page has none of it.
////
//// The saved rows are buttons too (protocol-change/065, the third pull
//// request): pressing one hands the session to the transport's `resume`, which
//// starts the daemon's task and returns, the row reads "opening" until the
//// task's answer arrives as `Linked`, and a second press asks nothing.
////
//// The last group is the way back (protocol-change/065, the second pull
//// request): a page opened from a home draws a "Home" button on both pages,
//// whose press asks the transport for a home ticket and whose answer is drawn
//// on the same hidden element.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/sessions.{type Entry, Entry, Live, Saved}

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// A session that is what `start` names, `A`, and the ones listed beside it.
fn listing() -> List(Entry) {
  [
    Entry("B", "vetting lint", "/src/loom", 300, Live, None, None, None),
    Entry("A", "web ui", "/src/loom", 100, Live, None, None, None),
    Entry("C", "hex release", "/src/weft", 900, Saved, None, None, None),
    Entry("lint-census", "census", "/src/loom", 50, Live, None, None, None),
  ]
}

const ticket_path = "/ui/sessions/B?ticket=abc"

// A page on session `A` whose transport answers every request to open a
// session with `answer`, and reports the identity it was asked for.
fn started(
  answer: sessions.Answer,
  asked: Subject(String),
) -> component.Start(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    transport: component.Transport(..start.transport, open: fn(id) {
      process.send(asked, id)
      answer
    }),
  )
}

// A page holding a capture and a list, whose transport answers with `answer`.
fn page(
  answer: sessions.Answer,
  entries: List(Entry),
) -> #(component.Model(page_fixture.Wire), Subject(String)) {
  let asked = process.new_subject()
  let #(model, _) =
    component.update(
      component.new(started(answer, asked))
        |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(entries),
    )
  #(model, asked)
}

// Delivers `message` to the operator's page and then every message its
// effects dispatch, as the runtime would, so the daemon's answer arrives.
fn deliver(
  model: component.Model(page_fixture.Wire),
  message: operator_page.Msg(page_fixture.Wire),
) -> component.Model(page_fixture.Wire) {
  let #(model, effects) = operator_page.update(model, message)
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  case process.receive(dispatched, 0) {
    Ok(next) -> deliver(model, next)
    Error(Nil) -> model
  }
}

fn drawn(model: component.Model(page_fixture.Wire)) -> String {
  element.to_string(operator_page.view(model))
}

fn sidebar_clicks(keys: List(String)) -> List(String) {
  list.filter(keys, fn(key) {
    string.starts_with(key, component.sidebar_path <> "\t")
    && string.ends_with(key, "\nclick")
  })
}

// A running session other than the one on screen is a button, and so is a
// saved one, which asks the daemon to resume it. The session on screen is where
// the person is, so it offers no press that would do nothing.
pub fn a_row_is_a_button_only_where_a_press_can_work_test() {
  let #(model, _) = page(operator_page_answer(), listing())
  let html = drawn(model)
  let assert Ok(#(_, from_sidebar)) =
    string.split_once(html, "<aside aria-label=\"Sessions\"")
  let assert Ok(#(sidebar, _)) = string.split_once(from_sidebar, "</aside>")

  // `B` and the peer `lint-census` are running and are not on screen, and
  // `C` is saved.
  assert list.length(string.split(sidebar, "<button")) == 5
  assert string.contains(sidebar, "class=\"session-open\"")
  assert string.contains(sidebar, "title=\"Open this session\"")
  assert string.contains(sidebar, "title=\"Resume this session\"")

  // The names are text inside the buttons, and the three buttons are the only
  // handlers beneath the sidebar's path: the current row holds none.
  assert string.contains(sidebar, "vetting lint")
  assert list.length(sidebar_clicks(handlers(operator_page.view(model)))) == 3
}

fn operator_page_answer() -> sessions.Answer {
  sessions.Ticketed(ticket_path)
}

// A press sends the row's session to the transport, which the daemon
// answers, and a ticket becomes the address the hidden element carries. The
// page's lane and record are not touched: nothing was written to its
// connection.
pub fn a_press_becomes_a_ticketed_address_on_the_switch_element_test() {
  let #(model, asked) = page(sessions.Ticketed(ticket_path), listing())
  let before = drawn(model)
  assert string.contains(before, "<loom-switch hidden></loom-switch>")
  assert !string.contains(before, "ticket=")

  let opened = deliver(model, operator_page.Opening("B"))
  assert process.receive(asked, 0) == Ok("B")
  assert process.receive(asked, 0) == Error(Nil)
  assert component.departure(opened) == option.Some(ticket_path)
  assert string.contains(
    drawn(opened),
    "<loom-switch hidden to=\"" <> ticket_path <> "\"></loom-switch>",
  )
  assert component.notice(opened) == component.Said("Opening that session.")
}

// The switch element is the centre's last child, after the dock, so no path
// an event names moves for it.
pub fn the_switch_element_is_the_centres_last_child_test() {
  let #(model, _) = page(operator_page_answer(), listing())
  let html = drawn(model)
  let assert Ok(#(_, after_dock)) = string.split_once(html, "</footer>")
  assert string.starts_with(after_dock, "<loom-switch")

  // The keyboard switcher follows it, as the last child, and holds no text and
  // no attribute.
  assert string.starts_with(
    after_dock,
    "<loom-switch hidden></loom-switch><loom-switcher></loom-switcher></main>",
  )
}

// A refusal is worded in fixed words for its reason, in the composer's
// notice, and draws no address.
pub fn a_declined_switch_is_worded_and_moves_nobody_test() {
  list.each(
    [sessions.NotHeld, sessions.NotRunning, sessions.Unavailable],
    fn(reason) {
      let #(model, asked) = page(sessions.Declined(reason), listing())
      let declined = deliver(model, operator_page.Opening("B"))
      assert process.receive(asked, 0) == Ok("B")
      assert component.departure(declined) == None
      assert component.notice(declined)
        == component.Warned(sessions.reason_words(reason))
      let html = drawn(declined)
      assert string.contains(html, sessions.reason_words(reason))
      assert !string.contains(html, " to=\"")
    },
  )
}

// The words are fixed and distinct, and say nothing of the daemon's own
// error.
pub fn the_refusal_words_are_fixed_and_distinct_test() {
  let words =
    list.map(
      [
        sessions.NotHeld,
        sessions.NotRunning,
        sessions.Unavailable,
        sessions.NoHome,
        sessions.NotOperator,
        sessions.NotOpened,
      ],
      sessions.reason_words,
    )
  assert list.length(list.unique(words)) == 6
}

// The session on screen is not a button, and a forged message naming it asks
// for nothing.
pub fn the_session_on_screen_asks_nothing_test() {
  let #(model, asked) = page(operator_page_answer(), listing())
  let same = deliver(model, operator_page.Opening("A"))
  assert process.receive(asked, 0) == Error(Nil)
  assert component.departure(same) == None
}

// A peer's message names its source session. The page offers Open only when
// that identity is one of the principal's listed, running sessions, and then
// the button is labelled with the catalogue's name for it.
pub fn a_peer_message_offers_open_for_a_running_listed_session_test() {
  let #(model, _) = page(operator_page_answer(), listing())
  let html = drawn(model)
  assert string.contains(html, "class=\"peer-card\"")
  assert string.contains(html, "class=\"peer-open\"")
  assert string.contains(html, ">Open census<")

  // Pressing it is the same request as the sidebar's.
  let clicked =
    simulate.application(
      init: fn(_) { #(model, effect.none()) },
      update: operator_page.update,
      view: operator_page.view,
    )
    |> simulate.start(Nil)
    |> simulate.click(on: query.element(query.class("peer-open")))
  assert component.notice(simulate.model(clicked))
    == component.Said("Asking to open it.")
}

pub fn a_peer_message_offers_no_open_for_any_other_session_test() {
  // Not listed at all.
  let #(unlisted, _) =
    page(
      operator_page_answer(),
      list.filter(listing(), fn(entry) { entry.id != "lint-census" }),
    )
  assert !string.contains(drawn(unlisted), "peer-open")
  assert string.contains(drawn(unlisted), "peer-reply")

  // Listed but saved.
  let #(saved, _) =
    page(
      operator_page_answer(),
      list.map(listing(), fn(entry) {
        case entry.id == "lint-census" {
          True -> Entry(..entry, residency: Saved)
          False -> entry
        }
      }),
    )
  assert !string.contains(drawn(saved), "peer-open")

  // No list at all: the peer's identity alone offers nothing.
  let #(bare, _) = page(operator_page_answer(), [])
  assert !string.contains(drawn(bare), "peer-open")
}

// The catalogue's words reach the button as text, and a name that holds markup
// is escaped.
pub fn the_open_button_escapes_the_catalogues_name_test() {
  let #(model, _) =
    page(operator_page_answer(), [
      Entry(
        "lint-census",
        "<b>census</b>",
        "/src/loom",
        50,
        Live,
        None,
        None,
        None,
      ),
    ])
  let html = drawn(model)
  assert string.contains(html, ">Open &lt;b&gt;census&lt;/b&gt;<")
  assert !string.contains(html, "<b>census")
}

// The observer's page draws no sidebar, no Open button and no switch element,
// and carries no handler beneath the sidebar's path, whatever list it holds.
pub fn an_observers_page_has_no_way_to_switch_test() {
  let #(model, _) = page(operator_page_answer(), listing())
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "session-open")
  assert !string.contains(html, "peer-open")
  assert !string.contains(html, "loom-switch")
  assert sidebar_clicks(handlers(component.view(model))) == []
}

// --- the way home (protocol-change/065, the second pull request) -------------

const home_ticket = "/ui/home?ticket=abc"

// A page on session `A` that may go home: its transport answers a request to
// go home with `answer` and reports that it was asked.
fn homed(
  answer: sessions.Answer,
  asked: Subject(Nil),
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      home: option.Some(fn() {
        process.send(asked, Nil)
        answer
      }),
    ),
  )
  |> component.new
  |> component.apply([lane_fixture.captured(10, None)])
}

// Performs `effects` and folds in the messages they dispatch, for the
// observer's component, as `deliver` does for the operator's page.
fn settle(
  model: component.Model(page_fixture.Wire),
  effects: effect.Effect(component.Msg(page_fixture.Wire)),
) -> component.Model(page_fixture.Wire) {
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  case process.receive(dispatched, 0) {
    Ok(next) -> {
      let #(model, effects) = component.update(model, next)
      settle(model, effects)
    }
    Error(Nil) -> model
  }
}

// A page that was opened from a home draws a "Home" button as the top bar's
// second child, on the operator's page and on the observer's, and a page that
// was not draws none.
pub fn only_a_page_opened_from_a_home_draws_the_home_button_test() {
  let model = homed(sessions.Ticketed(home_ticket), process.new_subject())
  list.each([element.to_string(component.view(model)), drawn(model)], fn(html) {
    assert string.contains(html, "class=\"home-link\"")
    assert string.contains(html, ">Home</button>")
  })
  let plain = page_fixture.start() |> component.new
  list.each([element.to_string(component.view(plain)), drawn(plain)], fn(html) {
    assert !string.contains(html, "home-link")
  })
}

// The press is the page's only request: nothing names where to go. The answer
// is a home ticket's address on the hidden element, the same element a switch
// uses, and the observer's page draws it too, last in its centre.
pub fn a_press_of_home_becomes_a_ticketed_address_on_both_pages_test() {
  let asked = process.new_subject()
  let model = homed(sessions.Ticketed(home_ticket), asked)
  let operator = deliver(model, operator_page.Observed(component.GoingHome))
  assert process.receive(asked, 0) == Ok(Nil)
  assert component.departure(operator) == option.Some(home_ticket)
  assert string.contains(
    drawn(operator),
    "<loom-switch hidden to=\"" <> home_ticket <> "\"></loom-switch>",
  )

  let #(observer, effects) = component.update(model, component.GoingHome)
  let observer = settle(observer, effects)
  assert process.receive(asked, 0) == Ok(Nil)
  assert component.departure(observer) == option.Some(home_ticket)
  let html = element.to_string(component.view(observer))
  assert string.contains(
    html,
    "<loom-switch hidden to=\"" <> home_ticket <> "\"></loom-switch>",
  )
  assert component.departure(model) == None
}

// A refusal to go home is worded in its own fixed words and moves nobody, in
// the composer's notice on the operator's page and in the observer's bar on the
// observer's.
pub fn a_declined_home_is_worded_and_moves_nobody_test() {
  let model = homed(sessions.Declined(sessions.NoHome), process.new_subject())
  let operator = deliver(model, operator_page.Observed(component.GoingHome))
  assert component.departure(operator) == None
  assert component.notice(operator)
    == component.Warned(sessions.reason_words(sessions.NoHome))

  let #(observer, effects) = component.update(model, component.GoingHome)
  let observer = settle(observer, effects)
  assert component.departure(observer) == None
  let html = element.to_string(component.view(observer))
  assert string.contains(html, sessions.reason_words(sessions.NoHome))
  assert !string.contains(html, " to=\"")
}

// A page with no capability ignores the message, so a frame that named the
// button's path on a page that drew none changes nothing.
pub fn a_page_with_no_way_home_ignores_the_press_test() {
  let model = page_fixture.start() |> component.new
  let #(after, _) = component.update(model, component.GoingHome)
  assert component.departure(after) == None
  assert component.notice(after) == component.Quiet
}

// --- resuming a saved session (protocol-change/065, the third pull request) --

// A page on session `A` whose transport hands every resume to `resume`.
fn resuming(
  resume: fn(String, fn(sessions.Answer) -> Nil) -> Nil,
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  let model =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, resume:),
    )
    |> component.new
    |> component.apply([lane_fixture.captured(10, None)])
  let #(model, _) = component.update(model, component.SessionsListed(listing()))
  model
}

// A press hands the saved row's session to the task and marks the row. Nothing
// is minted by the press, the row's residency reads "opening", and no saved row
// has a handler until the answer arrives.
pub fn a_saved_press_starts_the_task_and_marks_the_row_test() {
  let asked = process.new_subject()
  let model = resuming(fn(id, _) { process.send(asked, id) })
  let before = sidebar_clicks(handlers(operator_page.view(model)))
  let pressed = deliver(model, operator_page.Resuming("C"))
  assert process.receive(asked, 0) == Ok("C")
  assert component.resuming_session(pressed) == option.Some("C")
  assert component.departure(pressed) == None
  assert string.contains(drawn(pressed), "opening")
  assert list.length(sidebar_clicks(handlers(operator_page.view(pressed))))
    == list.length(before) - 1
}

// A second press while one is out asks nothing, whichever saved row it names.
pub fn a_second_resume_press_asks_nothing_test() {
  let asked = process.new_subject()
  let model = resuming(fn(id, _) { process.send(asked, id) })
  let pressed = deliver(model, operator_page.Resuming("C"))
  let _ = process.receive(asked, 0)
  let again = deliver(pressed, operator_page.Resuming("C"))
  let other = deliver(again, operator_page.Resuming("B"))
  assert process.receive(asked, 0) == Error(Nil)
  assert component.resuming_session(other) == option.Some("C")
}

// A press for the session on screen, a running session or an identity the page
// never listed asks nothing: only a listed saved row can be resumed.
pub fn only_a_listed_saved_row_can_be_resumed_test() {
  let asked = process.new_subject()
  let model = resuming(fn(id, _) { process.send(asked, id) })
  list.each(["A", "B", "no-such-session", ""], fn(target) {
    let pressed = deliver(model, operator_page.Resuming(target))
    assert component.resuming_session(pressed) == None
  })
  assert process.receive(asked, 0) == Error(Nil)
}

// The task's answer departs on a ticket and clears the mark, and a refusal is
// worded in the fixed words, moves nobody and gives the presses back.
pub fn the_resume_answer_departs_or_words_the_refusal_test() {
  let model = resuming(fn(_, answer) { answer(sessions.Ticketed(ticket_path)) })
  let departed = deliver(model, operator_page.Resuming("C"))
  assert component.departure(departed) == option.Some(ticket_path)
  assert component.resuming_session(departed) == None

  list.each([sessions.NotOpened, sessions.NotOperator], fn(reason) {
    let model = resuming(fn(_, answer) { answer(sessions.Declined(reason)) })
    let refused = deliver(model, operator_page.Resuming("C"))
    assert component.departure(refused) == None
    assert component.resuming_session(refused) == None
    assert component.notice(refused)
      == component.Warned(sessions.reason_words(reason))
    assert list.length(sidebar_clicks(handlers(operator_page.view(refused))))
      == 3
  })
}

// A session the daemon would not resume from a page is text.
pub fn a_blocked_row_is_text_test() {
  let model = resuming(fn(_, _) { Nil })
  let #(model, _) =
    component.update(
      model,
      component.SessionsListed([
        Entry("B", "vetting lint", "/src/loom", 300, Live, None, None, None),
        Entry("A", "web ui", "/src/loom", 100, Live, None, None, None),
        Entry("Z", "stuck", "/src/loom", 50, sessions.Blocked, None, None, None),
      ]),
    )
  assert list.length(sidebar_clicks(handlers(operator_page.view(model)))) == 1
  assert string.contains(drawn(model), "stuck")
}
