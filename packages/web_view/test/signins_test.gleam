//// The home page's sign-ins (protocol-change/065, PR 8): the browsers signed in
//// as the page's principal, one row each, with "Sign out" and "Sign out
//// everywhere" on every home and "Sign in another device" on a fresh one.
////
//// These tests pin what a row says and which one is this browser, that every
//// handler is beneath `home.signins_path` and none moves the regions the socket
//// already admits, that a press asks the daemon for the fingerprint the server
//// drew and reads the list again, that a device link is shown once in a box that
//// copies only its own shape, that a home the bookmark resumed draws no such
//// control, and that everything the daemon wrote is drawn as text.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/ending
import web_view/home
import web_view/sessions.{type Entry, Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// The instant the page reads the clock at: two days after the oldest login was
// made.
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

fn here() -> signins.Signin {
  signins.Signin(
    fingerprint: "1111111111111111",
    issued_at_ms: 0,
    last_resumed_ms: Some(now - 3_600_000),
    expires_at_ms: Some(2_592_000_000),
    issued_by: None,
  )
}

fn elsewhere() -> signins.Signin {
  signins.Signin(
    fingerprint: "2222222222222222",
    issued_at_ms: now - 600_000,
    last_resumed_ms: None,
    expires_at_ms: Some(now + 86_400_000 * 3),
    issued_by: Some("1111111111111111"),
  )
}

fn start(read: fn() -> signins.Listing) -> home.Start {
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
    create: None,
    folders: None,
    profiles: [],
    signins: fn(deliver) { deliver(read()) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
    executors: [],
  )
}

fn listing(rows: List(signins.Signin)) -> fn() -> signins.Listing {
  fn() { signins.Listed(rows) }
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

// A page with no sign-in says so and how to make one, and draws neither a row
// nor "Sign out everywhere", which has nothing to end.
pub fn a_page_with_no_sign_in_says_how_to_make_one_test() {
  let html = drawn(opened(start(listing([]))))
  assert string.contains(html, "Sign-ins")
  assert string.contains(html, "No browser is signed in.")
  assert string.contains(html, "30 days")
  assert !string.contains(html, "Sign out")
  assert beneath_signins(handlers(home.view(opened(start(listing([])))))) == []
}

// Each row says whose it is, when it was signed in, when it last came back and
// when it ends, in words, and a login a device link made says so. Only the login
// this page belongs to is "This browser", and it leaves out the use clause: it
// is in use, so "not used yet" would be false of it.
pub fn a_row_says_when_it_was_made_last_used_and_ends_test() {
  let html =
    drawn(opened(
      home.Start(
        ..start(listing([here(), elsewhere()])),
        login: Some("1111111111111111"),
      ),
    ))
  assert string.contains(html, "This browser")
  assert string.contains(html, "Another browser")
  assert list.length(string.split(html, "This browser")) == 2
  assert string.contains(html, "signed in 2d ago · ends in 28d")
  assert !string.contains(html, "last used 1h ago")
  assert string.contains(
    html,
    "signed in 10m ago · device link · not used yet · ends in 3d",
  )
  assert !string.contains(html, "from 1111111111111111")
}

// The same row on a page that no login belongs to is another browser's, and
// says when it last came back or that it has not.
pub fn another_browsers_row_says_when_it_last_came_back_test() {
  let html = drawn(opened(start(listing([here()]))))
  assert string.contains(
    html,
    "signed in 2d ago · last used 1h ago · ends in 28d",
  )
}

// A page that no login belongs to marks no row as its own.
pub fn a_page_with_no_login_marks_no_row_as_this_browser_test() {
  let html = drawn(opened(start(listing([here(), elsewhere()]))))
  assert !string.contains(html, "This browser")
  assert list.length(string.split(html, "Another browser")) == 3
}

// The bookmark is drawn as text, once, for a page a remembered login opened, so
// the person can keep it, and not at all for any other.
pub fn the_bookmark_is_drawn_only_for_a_remembered_login_test() {
  let with =
    home.Start(
      ..start(listing([here()])),
      bookmark: Some("http://127.0.0.1:4000/ui/l/abc/home"),
    )
  let html = drawn(opened(with))
  assert string.contains(html, "Bookmark this address")
  assert string.contains(html, "http://127.0.0.1:4000/ui/l/abc/home")
  let without = drawn(opened(start(listing([here()]))))
  assert !string.contains(without, "Bookmark this address")
}

// Every handler of the region is beneath `signins_path`: a button for each row,
// and "Sign out everywhere", and nothing else. The sessions' and the sidebar's
// handlers are where they were, so the socket admits the same paths for them.
pub fn every_handler_of_the_region_is_beneath_its_path_test() {
  let model = opened(start(listing([here(), elsewhere()])))
  let keys = handlers(home.view(model))
  assert list.length(beneath_signins(keys)) == 3
  assert home.signins_path == "0\t2\t2"
  assert home.table_path == "0\t2\t1"
  assert home.sidebar_path == "0\t1"

  // A page that offers a device link has one more, in the same region.
  let with_device =
    opened(
      home.Start(
        ..start(listing([here(), elsewhere()])),
        device: Some(fn() { signins.Linked("http://127.0.0.1:1/x") }),
      ),
    )
  assert list.length(beneath_signins(handlers(home.view(with_device)))) == 4

  // None of them is a handler of the sessions' table or the sidebar.
  let others =
    list.filter(keys, fn(key) {
      string.starts_with(key, home.table_path <> "\t")
      || string.starts_with(key, home.sidebar_path <> "\t")
    })
  assert list.length(others) == 2
}

// A row's "Sign out" asks the daemon for the fingerprint the server drew, and
// the list is read again, so the ended login leaves the page.
pub fn a_sign_out_asks_for_the_drawn_fingerprint_and_reads_again_test() {
  let asked = process.new_subject()
  let rows = process.new_subject()
  process.send(rows, [here(), elsewhere()])
  let read = fn() {
    let assert Ok(current) = process.receive(rows, 0)
    process.send(rows, current)
    signins.Listed(current)
  }
  let out = fn(fingerprint) {
    process.send(asked, fingerprint)
    process.send(rows, [here()])
    let assert Ok(_) = process.receive(rows, 0)
    signins.Revoked
  }
  let model =
    opened(
      home.Start(..start(read), sign_out: out, login: Some("1111111111111111")),
    )
  assert string.contains(drawn(model), "Another browser")
  let model = run(model, home.SigningOut("2222222222222222"))
  assert process.receive(asked, 0) == Ok("2222222222222222")
  let html = drawn(model)
  assert string.contains(html, "Signed that browser out.")
  assert !string.contains(html, "Another browser")
  assert string.contains(html, "signed in 2d ago")
}

// A refusal is worded in the reason's fixed words and nothing the daemon wrote.
pub fn a_refused_sign_out_says_why_in_fixed_words_test() {
  let model =
    opened(
      home.Start(..start(listing([here()])), sign_out: fn(_) {
        signins.Declined(signins.NotFound)
      }),
    )
  let html = drawn(run(model, home.SigningOut("1111111111111111")))
  assert string.contains(html, signins.reason_words(signins.NotFound))
  assert string.contains(html, "That sign-in has already ended.")
}

// "Sign out everywhere" asks once, and the list is read again.
pub fn sign_out_everywhere_asks_the_daemon_and_says_so_test() {
  let asked = process.new_subject()
  let model =
    opened(
      home.Start(..start(listing([here(), elsewhere()])), sign_out_all: fn() {
        process.send(asked, Nil)
        signins.Revoked
      }),
    )
  let html = drawn(run(model, home.SigningOutAll))
  assert process.receive(asked, 0) == Ok(Nil)
  assert string.contains(html, "Signed every browser out.")
}

// A page that ended asks nothing: its principal's access is gone, and the daemon
// would refuse.
pub fn an_ended_page_signs_nothing_out_test() {
  let asked = process.new_subject()
  let model =
    opened(
      home.Start(
        ..start(listing([here()])),
        sign_out: fn(fingerprint) {
          process.send(asked, fingerprint)
          signins.Revoked
        },
        sign_out_all: fn() {
          process.send(asked, "all")
          signins.Revoked
        },
      ),
    )
  let ended =
    run(
      model,
      home.Answered(home.reads(model), home.Closed(ending.AccessRevoked)),
    )
  let ended = run(ended, home.SigningOut("1111111111111111"))
  let _ = run(ended, home.SigningOutAll)
  assert process.receive(asked, 0) == Error(Nil)
}

// A fresh home offers the link, shows it once in a box that copies only its own
// shape, and hides it when the person is done. A home the bookmark resumed has
// no control to press and shows none.
pub fn a_fresh_home_offers_and_shows_a_device_link_once_test() {
  let address =
    "http://127.0.0.1:4000/ui/home?ticket=" <> string.repeat("ab", 32)
  let model =
    opened(
      home.Start(
        ..start(listing([here()])),
        device: Some(fn() { signins.Linked(address) }),
      ),
    )
  let html = drawn(model)
  assert string.contains(html, "Sign in another device")
  assert !string.contains(html, "loom-copy")
  let shown = run(model, home.AddingDevice)
  let html = drawn(shown)
  assert string.contains(html, "<loom-copy")
  assert string.contains(html, "subject=\"device\"")
  assert string.contains(html, "text=\"" <> address <> "\"")
  assert string.contains(html, "within 10 minutes")
  assert string.contains(html, "Done")
  let done = run(shown, home.DeviceDone)
  assert !string.contains(drawn(done), "loom-copy")
  assert !string.contains(drawn(done), address)

  // A page with no capability draws no control and ignores the message.
  let resumed = opened(start(listing([here()])))
  assert !string.contains(drawn(resumed), "Sign in another device")
  let ignored = run(resumed, home.AddingDevice)
  assert !string.contains(drawn(ignored), "loom-copy")
}

// A refused link says why in fixed words, and a second press is ignored while
// the first is out.
pub fn a_refused_device_link_says_why_and_one_is_asked_at_a_time_test() {
  let asked = process.new_subject()
  let model =
    opened(
      home.Start(
        ..start(listing([here()])),
        device: Some(fn() {
          process.send(asked, Nil)
          signins.Declined(signins.TooMany)
        }),
      ),
    )
  let html = drawn(run(model, home.AddingDevice))
  assert string.contains(html, signins.reason_words(signins.TooMany))
  assert string.contains(html, "You have made many links this hour.")
  assert process.receive(asked, 0) == Ok(Nil)

  // A request that is out holds the button: pressed again, nothing is asked.
  let #(waiting, _) = home.update(model, home.AddingDevice)
  let #(_, again) = home.update(waiting, home.AddingDevice)
  assert again == effect.none()
  assert process.receive(asked, 0) == Error(Nil)
}

// What the daemon wrote is drawn as text: a fingerprint, a parent and a
// bookmark that carry markup are escaped, and the device link is an attribute of
// the one element that checks its shape.
pub fn everything_the_daemon_wrote_is_drawn_as_text_test() {
  let hostile = "<script>alert(1)</script>"
  let model =
    opened(
      home.Start(
        ..start(
          listing([
            signins.Signin(
              fingerprint: hostile,
              issued_at_ms: 0,
              last_resumed_ms: None,
              expires_at_ms: None,
              issued_by: Some(hostile),
            ),
          ]),
        ),
        bookmark: Some(hostile),
      ),
    )
  let html = drawn(model)
  assert !string.contains(html, hostile)
  assert string.contains(html, "&lt;script&gt;")
}

// The words are fixed, one for each reason.
pub fn the_refusal_words_are_fixed_test() {
  assert signins.reason_words(signins.NotFound)
    == "That sign-in has already ended."
  assert signins.reason_words(signins.TooMany)
    == "You have made many links this hour. Try again later."
  assert signins.reason_words(signins.Unavailable)
    == "The daemon could not do that. Try again."
  assert string.contains(signins.reason_words(signins.NotFresh), "loom ui")
}

// How long until a login ends is counted in whole units rounded up, and one
// that is not after now has ended. A sign-in made a moment ago has thirty days
// less a moment, which a person told "30 days" reads as `30d`, not `29d`.
pub fn the_time_left_is_counted_in_whole_units_test() {
  assert signins.ends_in(0, 0) == "ended"
  assert signins.ends_in(10, 5) == "ended"
  assert signins.ends_in(0, 30_000) == "under a minute"
  assert signins.ends_in(0, 60_000) == "1m"
  assert signins.ends_in(0, 90_000) == "2m"
  assert signins.ends_in(0, 7_200_000) == "2h"
  assert signins.ends_in(0, 7_200_001) == "3h"
  assert signins.ends_in(0, 3_599_000) == "1h"
  assert signins.ends_in(0, 2_591_999_000) == "30d"
  assert signins.ends_in(0, 86_399_000) == "1d"
  assert signins.ends_in(0, 2_592_000_000) == "30d"
  assert signins.ends_in(0, 5_184_000_000) == "60d"
}

// The account panel is the sign-ins region and nothing else of the home's body:
// the name in the bar is the button that opens it, wrapped in the element that
// toggles it in the browser, and the region carries the mark a press inside it
// is recognised by. The region exists once, at its pinned path, and the
// stylesheet floats it, so the centre's body is the session list.
pub fn the_names_button_opens_the_one_marked_region_test() {
  let html = drawn(opened(start(listing([here(), elsewhere()]))))
  assert string.contains(html, "<loom-popover wanted=\"closed\">")
  assert string.contains(html, "data-popover=\"toggle\"")
  assert string.contains(html, "aria-expanded=\"false\"")
  assert list.length(string.split(html, "class=\"home-signins\"")) == 2
  assert list.length(string.split(html, "data-popover=\"panel\"")) == 2
  assert string.contains(
    html,
    "<section class=\"home-signins\" data-popover=\"panel\">",
  )

  // The name is text inside the button, never an attribute.
  assert string.contains(
    html,
    "Alice<span aria-hidden=\"true\" class=\"home-who-chevron\"",
  )

  // The name's button holds no Lustre handler, so the bar has none beneath its
  // third child, and the admin button's path is where it was.
  assert home.admin_path == "0\t0\t5"
  let keys = handlers(home.view(opened(start(listing([here()])))))
  assert list.all(keys, fn(key) { !string.starts_with(key, "0\t0\t2") })
}

// The panel opens by itself while a device link is on show, so the link is on
// screen when it arrives.
pub fn a_shown_link_asks_the_panel_to_open_test() {
  let address = "http://127.0.0.1:1/ui/home?ticket=" <> string.repeat("ab", 32)
  let with_device =
    home.Start(
      ..start(listing([here()])),
      device: Some(fn() { signins.Linked(address) }),
    )
  let model = opened(with_device)
  assert string.contains(drawn(model), "<loom-popover wanted=\"closed\">")
  let shown = drawn(run(model, home.AddingDevice))
  assert string.contains(shown, "<loom-popover wanted=\"open\">")
  assert string.contains(shown, "subject=\"device\"")
  assert string.contains(shown, "class=\"home-device-head\"")
}

// The bookmark has a copy button of its own, and only a page a login opened
// draws it.
pub fn the_bookmark_is_drawn_in_a_copy_box_test() {
  let bookmark =
    "http://127.0.0.1:1/ui/l/" <> string.repeat("ab", 16) <> "/home"
  let html =
    drawn(opened(
      home.Start(
        ..start(listing([here()])),
        login: Some("1111111111111111"),
        bookmark: Some(bookmark),
      ),
    ))
  assert string.contains(html, "subject=\"bookmark\"")
  assert string.contains(html, "text=\"" <> bookmark <> "\"")
  let without = drawn(opened(start(listing([here()]))))
  assert !string.contains(without, "subject=\"bookmark\"")
}
