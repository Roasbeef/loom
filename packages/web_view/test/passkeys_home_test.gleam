//// The home page's passkeys region (protocol-change/127): the owner's passkeys,
//// one row each, a "Remove" that asks for a second press, and "Add a passkey" on
//// a fresh home.
////
//// These tests pin that a page with no capability draws no region, what a row
//// says, that every handler is beneath `home.signins_path` where the socket
//// already admits a click, that a removal needs the second press and only for the
//// row that was asked about, that a page that ended asks nothing, and that
//// everything the daemon wrote is drawn as text.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/home
import web_view/passkeys
import web_view/sessions.{type Entry, Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// The instant the page reads the clock at: two days after the oldest passkey was
// added.
const now = 172_800_000

fn entry(id: String) -> Entry {
  Entry(
    id:,
    name: "a session",
    workspace: "/src/loom",
    created_at: 1000,
    residency: Live,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn phone() -> passkeys.Passkey {
  passkeys.Passkey(
    fingerprint: "aaaaaaaaaaaaaaaa",
    label: "Phone",
    created_at_ms: 0,
    last_used_ms: Some(now - 3_600_000),
  )
}

fn laptop() -> passkeys.Passkey {
  passkeys.Passkey(
    fingerprint: "bbbbbbbbbbbbbbbb",
    label: "Laptop",
    created_at_ms: now - 600_000,
    last_used_ms: None,
  )
}

// The removals the page asked the daemon for, in order, reported to `asked`.
fn capability(
  rows: List(passkeys.Passkey),
  add: Option(String),
  asked: Subject(String),
) -> Option(home.Passkeys) {
  Some(home.Passkeys(
    read: fn(deliver) { deliver(passkeys.Listed(rows)) },
    remove: fn(fingerprint) {
      process.send(asked, fingerprint)
      passkeys.Removed
    },
    add:,
  ))
}

fn start(held: Option(home.Passkeys)) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed([entry("A")])) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    thread_send: None,
    attention: None,
    create: None,
    folders: None,
    elsewhere: None,
    projects: None,
    profiles: [],
    models: [],
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
    passkeys: held,
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "box",
    placements: fn(_) { Nil },
  )
}

// Runs one message through the component and performs its effects the way
// Lustre's runtime would, folding every dispatched message back in order.
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

fn beneath_signins(keys: List(String)) -> List(String) {
  list.filter(keys, fn(key) {
    string.starts_with(key, home.signins_path <> "\t")
  })
}

// A page the daemon handed no capability draws no region and no word of it.
pub fn a_page_with_no_capability_draws_no_passkeys_test() {
  let html = drawn(opened(start(None)))
  assert !string.contains(html, "Passkeys")
  assert !string.contains(html, "passkey")
}

// A fresh owner's home with no passkey says so and offers the link to the
// registration page, which is an address and not an event.
pub fn a_fresh_home_offers_the_registration_link_test() {
  let asked = process.new_subject()
  let model = opened(start(capability([], Some("/ui/p/key/passkey"), asked)))
  let html = drawn(model)
  assert string.contains(html, "Passkeys")
  assert string.contains(html, "No passkey is added yet.")
  assert string.contains(html, "href=\"/ui/p/key/passkey\"")
  assert string.contains(html, "Add a passkey")
  assert !string.contains(html, "Add one from a page opened with")
  assert beneath_signins(handlers(home.view(model))) == []
}

// A resumed home lists and removes, draws no link, and says where one is added.
pub fn a_resumed_home_draws_no_registration_link_test() {
  let asked = process.new_subject()
  let html = drawn(opened(start(capability([], None, asked))))
  assert !string.contains(html, "Add a passkey")
  assert string.contains(html, "Add one from a page opened with `loom ui`.")
}

// A row says its label, when it was added and when it last signed a browser in.
pub fn a_row_says_its_label_and_history_test() {
  let asked = process.new_subject()
  let html = drawn(opened(start(capability([phone(), laptop()], None, asked))))
  assert string.contains(html, "Phone")
  assert string.contains(html, "added 2d ago · last used 1h ago")
  assert string.contains(html, "Laptop")
  assert string.contains(html, "added 10m ago · not used yet")
  assert !string.contains(html, "aaaaaaaaaaaaaaaa")
}

// Each row's "Remove" is a handler beneath the account panel, where the home's
// socket already admits a click.
pub fn every_passkey_handler_is_beneath_the_account_panel_test() {
  let asked = process.new_subject()
  let model = opened(start(capability([phone(), laptop()], Some("/x"), asked)))
  let keys = beneath_signins(handlers(home.view(model)))
  assert list.length(keys) >= 2
  let asked_model = run(model, home.PasskeyAsked("aaaaaaaaaaaaaaaa"))
  let confirming = beneath_signins(handlers(home.view(asked_model)))
  assert list.length(confirming) == list.length(keys) + 1
}

// The first press asks nothing: the row offers "Confirm" and "Cancel".
pub fn the_first_press_only_asks_for_a_second_test() {
  let asked = process.new_subject()
  let model = opened(start(capability([phone(), laptop()], None, asked)))
  let model = run(model, home.PasskeyAsked("aaaaaaaaaaaaaaaa"))
  let html = drawn(model)
  assert string.contains(html, "Confirm")
  assert string.contains(html, "Cancel")
  assert process.receive(asked, 0) == Error(Nil)
  let model = run(model, home.PasskeyKept)
  assert !string.contains(drawn(model), "Confirm")
  assert process.receive(asked, 0) == Error(Nil)
}

// The second press asks the daemon for the row that was asked about, reads the
// list again and says so; a "Confirm" for another row does nothing.
pub fn the_second_press_removes_only_the_asked_row_test() {
  let asked = process.new_subject()
  let model = opened(start(capability([phone(), laptop()], None, asked)))
  let model = run(model, home.PasskeyAsked("aaaaaaaaaaaaaaaa"))
  let model = run(model, home.PasskeyConfirmed("bbbbbbbbbbbbbbbb"))
  assert process.receive(asked, 0) == Error(Nil)
  let model = run(model, home.PasskeyConfirmed("aaaaaaaaaaaaaaaa"))
  assert process.receive(asked, 0) == Ok("aaaaaaaaaaaaaaaa")
  assert string.contains(
    drawn(model),
    "Removed that passkey. Browsers it signed in stay signed in until you sign them out.",
  )
  assert !string.contains(drawn(model), "Confirm")

  // A confirmation with no first press asks nothing.
  let again = run(model, home.PasskeyConfirmed("aaaaaaaaaaaaaaaa"))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(drawn(again), "Confirm")
}

// A refusal is the reason's fixed words, never the daemon's own.
pub fn a_refused_removal_is_worded_by_the_page_test() {
  let model =
    opened(
      start(
        Some(home.Passkeys(
          read: fn(deliver) { deliver(passkeys.Listed([phone()])) },
          remove: fn(_) { passkeys.Declined(passkeys.NotFound) },
          add: None,
        )),
      ),
    )
  let model = run(model, home.PasskeyAsked("aaaaaaaaaaaaaaaa"))
  let model = run(model, home.PasskeyConfirmed("aaaaaaaaaaaaaaaa"))
  assert string.contains(drawn(model), "That passkey has already been removed.")
}

// A page that has no capability ignores the messages, as the daemon would
// refuse the request.
pub fn a_page_with_no_capability_ignores_the_messages_test() {
  let model = opened(start(None))
  let model = run(model, home.PasskeyAsked("aaaaaaaaaaaaaaaa"))
  assert !string.contains(drawn(model), "Confirm")
}

// A label is text, whatever it holds.
pub fn a_label_is_only_ever_text_test() {
  let asked = process.new_subject()
  let hostile = passkeys.Passkey(..phone(), label: "<script>alert(1)</script>")
  let html = drawn(opened(start(capability([hostile], None, asked))))
  assert !string.contains(html, "<script>alert")
  assert string.contains(html, "&lt;script&gt;")
}

// A listing that did not answer leaves the rows the page has.
pub fn an_unread_listing_leaves_the_rows_test() {
  let asked = process.new_subject()
  let model = opened(start(capability([phone()], None, asked)))
  let model = run(model, home.PasskeysRead(passkeys.Unread))
  assert string.contains(drawn(model), "Phone")
}
