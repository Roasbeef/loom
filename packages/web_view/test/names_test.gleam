//// The home page's "Your name" control (protocol-change/065, the tenth pull
//// request): a form in the account panel that renames the page's own principal.
////
//// These tests pin that the form is drawn only for a page the daemon handed the
//// capability, that the current name is a text node and never an attribute, that
//// its one handler is a submit beneath `home.signins_path` and no other path
//// moves, that a submit asks the daemon once with the typed text, that the
//// bar and the form show the name the daemon stored, that a refusal is worded in
//// fixed words and leaves the form open, that a read of the name replaces the
//// page's and a read the registry did not answer leaves it, and that a page
//// which cannot rename ignores the message.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/home
import web_view/names
import web_view/sessions.{type Entry, Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn listing() -> List(Entry) {
  [
    Entry(
      id: "A",
      name: "web ui",
      workspace: "/src/loom",
      created_at: 100_000,
      residency: Live,
      subtitle: None,
      role: None,
      project: None,
    ),
  ]
}

fn start(
  rename_self: Option(fn(String, fn(names.Answer) -> Nil) -> Nil),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    create: None,
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self:,
  )
}

// Runs one message through the component and performs its effects the way
// Lustre's runtime would: a dispatched message is applied in its turn.
fn run(model: home.Model, message: home.Msg) -> home.Model {
  let #(model, effects) = home.update(model, message)
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
  settle(model, dispatched)
}

fn settle(model: home.Model, dispatched: Subject(home.Msg)) -> home.Model {
  case process.receive(dispatched, 0) {
    Ok(next) -> settle(run(model, next), dispatched)
    Error(Nil) -> model
  }
}

fn opened(start: home.Start) -> home.Model {
  run(home.new(start), home.TimerReady(process.new_subject()))
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

fn count(html: String, needle: String) -> Int {
  list.length(string.split(html, needle)) - 1
}

// A page the daemon handed no capability draws no control and asks nothing.
pub fn a_page_without_the_capability_draws_no_name_form_test() {
  let model = opened(start(None))
  let html = drawn(model)
  assert !string.contains(html, "Your name")
  assert !string.contains(html, "<form")
  let model = run(model, home.NameSubmitted("Alicia"))
  assert drawn(model) == html
}

// The control is the panel's first region. The current name is a text node in
// the lead, the field carries none of it, and the form's one handler is a submit
// beneath the region the socket admits. No path the socket already admits moves.
pub fn the_form_draws_the_name_as_text_and_submits_beneath_the_panel_test() {
  let ask = fn(_name, _deliver) { Nil }
  let with = opened(start(Some(ask)))
  let html = drawn(with)
  assert string.contains(html, "Your name")
  assert string.contains(html, "Now: <span data-loom-name>Alice</span>")
  assert string.contains(html, "data-loom-renames")
  assert string.contains(html, "<loom-rename><input")
  assert string.contains(html, "name=\"text\"")
  assert !string.contains(html, " value=")
  assert !string.contains(html, "placeholder=\"Alice")
  assert count(html, "<form") == 1

  let keys = handlers(home.view(with))
  let without = handlers(home.view(opened(start(None))))
  let added = list.filter(keys, fn(key) { !list.contains(without, key) })
  assert added != []
  assert list.all(added, fn(key) {
    string.starts_with(key, home.signins_path <> "\t")
    && string.ends_with(key, "\nsubmit")
  })
  assert list.length(added) == 1
  assert home.signins_path == "0\t2\t2"
  assert home.table_path == "0\t2\t1"
  assert home.sidebar_path == "0\t1"

  // The sign-ins' own handlers and the table's keep the paths they had on a page
  // with no form: nothing outside the panel moved, and inside it the form is
  // ahead of the rows, which are matched by their handlers' kind and count.
  let outside = fn(key) { !string.starts_with(key, home.signins_path <> "\t") }
  assert list.filter(keys, outside) == list.filter(without, outside)
}

// A name a peer chose is only ever escaped text: a name carrying markup draws as
// text in the lead and the bar, and no attribute holds it.
pub fn a_name_with_markup_is_escaped_text_test() {
  let ask = fn(_name, _deliver) { Nil }
  let hostile = "<img src=x onerror=alert(1)>"
  let model = opened(home.Start(..start(Some(ask)), name: hostile))
  let html = drawn(model)
  assert !string.contains(html, hostile)
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")
  assert !string.contains(html, "=\"&lt;img")
}

// A submit asks the daemon once with the typed text. The answer is the name the
// catalogue stored, which the bar and the lead then draw, and the form is
// replaced by one that opens on it.
pub fn a_submit_asks_once_and_the_answer_names_the_page_test() {
  let asked = process.new_subject()
  let ask = fn(name, deliver) {
    process.send(asked, name)
    deliver(names.Renamed("Alicia"))
  }
  let model = opened(start(Some(ask)))
  let before = drawn(model)
  assert string.contains(before, "name-0")
  let model = run(model, home.NameSubmitted("  Alicia "))
  assert process.receive(asked, 0) == Ok("  Alicia ")
  assert process.receive(asked, 0) == Error(Nil)
  let html = drawn(model)
  assert count(html, "Alicia") == 2
  assert !string.contains(html, "Alice<")
  assert string.contains(html, "Renamed.")
  assert string.contains(html, "name-1")
}

// While a request is out a second submit asks nothing, and the button is
// disabled.
pub fn a_second_submit_while_one_is_out_asks_nothing_test() {
  let asked = process.new_subject()
  let ask = fn(name, _deliver) { process.send(asked, name) }
  let model = opened(start(Some(ask)))
  let model = run(model, home.NameSubmitted("first"))
  let model = run(model, home.NameSubmitted("second"))
  assert process.receive(asked, 0) == Ok("first")
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(drawn(model), "disabled")

  // The answer that was asked for ends the wait; one that was not is dropped.
  let model = run(model, home.NameAnswered(names.Renamed("first")))
  assert string.contains(drawn(model), "Renamed.")
  let after = drawn(model)
  let model = run(model, home.NameAnswered(names.Renamed("forged")))
  assert drawn(model) == after
}

// A refusal is worded in the reason's fixed words and nothing the daemon wrote,
// and leaves the form drawn so the name can be corrected and sent again.
pub fn a_refusal_says_why_in_fixed_words_and_the_form_stays_test() {
  let asked = process.new_subject()
  let ask = fn(name, deliver) {
    process.send(asked, name)
    deliver(names.Declined(names.InvalidName))
  }
  let model = opened(start(Some(ask)))
  let model = run(model, home.NameSubmitted(""))
  let html = drawn(model)
  assert string.contains(html, names.reason_words(names.InvalidName))
  assert string.contains(
    html,
    "A name needs 1 to 256 bytes, with no control or invisible characters.",
  )
  assert string.contains(html, "Now: <span data-loom-name>Alice</span>")
  assert count(html, "<form") == 1
  let _ = run(model, home.NameSubmitted("Al"))
  assert process.receive(asked, 0) == Ok("")
  assert process.receive(asked, 0) == Ok("Al")
}

// A page that has not read yet is not connected, and asks nothing.
pub fn a_page_that_is_not_connected_asks_nothing_test() {
  let asked = process.new_subject()
  let ask = fn(name, _deliver) { process.send(asked, name) }
  let model = home.new(start(Some(ask)))
  let _ = run(model, home.NameSubmitted("early"))
  assert process.receive(asked, 0) == Error(Nil)
}

// A read of the name replaces the page's, so a name the owner changed from the
// admin page reaches an open home, and a read that did not answer leaves it.
pub fn a_read_replaces_the_name_and_an_unread_one_leaves_it_test() {
  let ask = fn(_name, _deliver) { Nil }
  let model = opened(start(Some(ask)))
  let model = run(model, home.NameRead(Some("Zed")))
  let html = drawn(model)
  assert string.contains(html, "Now: <span data-loom-name>Zed</span>")
  assert !string.contains(html, "Alice")
  assert string.contains(html, "name-1")

  let model = run(model, home.NameRead(None))
  assert drawn(model) == html

  // The same name again changes nothing, so the form is not rebuilt under a
  // person who is typing.
  let model = run(model, home.NameRead(Some("Zed")))
  assert drawn(model) == html
}

// The page asks `Start.who` with each list it reads.
pub fn each_list_also_reads_the_name_test() {
  let ask = fn(_name, _deliver) { Nil }
  let model =
    opened(
      home.Start(..start(Some(ask)), who: fn(deliver) {
        deliver(Some("From the daemon"))
      }),
    )
  assert string.contains(drawn(model), "From the daemon")
}
