//// Archiving a session from the sidebar (protocol-change/065, the addendum on
//// archiving from the sidebar), on the home and on a session page.
////
//// These tests pin that the quiet button exists only where the daemon handed the
//// page the capability and never on the row on screen, that a press asks the
//// daemon nothing until its question is confirmed, that the question names both
//// steps for a running row and the session as escaped text, that a running row
//// is stopped and archived while a saved one is archived, that a stale or forged
//// confirmation asks nothing, and that the table's Stop and Delete questions and
//// the sidebar's never answer for each other.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/actions
import web_view/component
import web_view/home
import web_view/operator_page
import web_view/sessions.{type Entry, Blocked, Entry, Live, Saved}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn entry(
  id: String,
  name: String,
  workspace: String,
  residency: sessions.Residency,
) -> Entry {
  Entry(
    id:,
    name:,
    workspace:,
    created_at: 100,
    residency:,
    subtitle: None,
    role: None,
    project: None,
  )
}

// `A` is the session a session page is on; `B` runs, `C` is saved and `X` is a
// blocked row.
fn listing() -> List(Entry) {
  [
    entry("B", "vetting lint", "/src/loom", Live),
    entry("A", "web ui", "/src/loom", Live),
    entry("C", "hex release", "/src/weft", Saved),
    entry("X", "stuck", "/src/weft", Blocked),
  ]
}

type Ask =
  fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil

// An ask that reports what the daemon was asked and answers at once.
fn answering(asked: Subject(#(actions.Action, String))) -> Ask {
  fn(action, session, deliver) {
    process.send(asked, #(action, session))
    deliver(actions.Done(action))
  }
}

// An ask that reports what it was asked and never answers.
fn silent(asked: Subject(#(actions.Action, String))) -> Ask {
  fn(action, session, _deliver) { process.send(asked, #(action, session)) }
}

// The sidebar's column of a page's drawing, which is where the archive buttons
// are, apart from the home's own table.
fn sidebar_of(html: String) -> String {
  let assert Ok(#(_, from)) =
    string.split_once(html, "<aside aria-label=\"Sessions\"")
  let assert Ok(#(sidebar, _)) = string.split_once(from, "</aside>")
  sidebar
}

// --- The home ---------------------------------------------------------------

fn home_start(manage: Option(Ask)) -> home.Start {
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
    manage:,
    create: None,
    folders: None,
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
  )
}

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

fn home_html(model: home.Model) -> String {
  element.to_string(home.view(model))
}

// The owner's fresh home draws the quiet button on every row: "Stop and
// archive" on a running one and "Archive" on a saved or blocked one, each in the
// sidebar. A home without the capability draws none, and the home's own table
// keeps its buttons.
pub fn the_homes_sidebar_draws_the_button_only_with_the_capability_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(answering(asked))))
  let sidebar = sidebar_of(home_html(owner))
  assert list.length(string.split(sidebar, "class=\"session-archive\"")) == 5
  assert list.length(string.split(sidebar, "aria-label=\"Stop and archive\""))
    == 3
  assert list.length(string.split(sidebar, "aria-label=\"Archive\"")) == 3
  assert string.contains(
    sidebar,
    "title=\"Stop this session, then archive it: hide it and keep its history\"",
  )

  let plain = opened(home_start(None))
  let html = home_html(plain)
  assert !string.contains(html, "session-archive")
  assert !string.contains(html, "Stop and archive")
  assert process.receive(asked, 0) == Error(Nil)
}

// A press opens the row's question and asks the daemon nothing. A running row's
// question names both steps, a saved row's names one, and the session's name is
// escaped text in either.
pub fn a_press_asks_a_question_and_sends_nothing_test() {
  let asked = process.new_subject()
  let hostile = "<img src=x onerror=alert(1)>"
  let start =
    home.Start(..home_start(Some(answering(asked))), sessions: fn(deliver) {
      deliver(
        home.Listed([
          entry("B", hostile, "/src/loom", Live),
          entry("C", "hex release", "/src/weft", Saved),
        ]),
      )
    })
  let owner = opened(start)

  let model = run(owner, home.SidebarArchiveAsked("B"))
  let html = home_html(model)
  assert string.contains(html, "Stop this session, then archive it?")
  assert string.contains(
    html,
    "<p class=\"session-confirm-name\">&lt;img src=x onerror=alert(1)&gt;</p>",
  )
  assert !string.contains(html, "<img src=x onerror")
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(model, home.SidebarArchiveAsked("C"))
  let html = home_html(model)
  assert string.contains(html, "Archive this session?")
  assert !string.contains(html, "Stop this session, then archive it?")
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(model, home.ConfirmCancelled)
  assert !string.contains(home_html(model), "session-confirm")
}

// The confirmation asks once, for the action the row's residency gave, and a
// second press while the request is out asks nothing.
pub fn the_confirmation_stops_and_archives_a_running_row_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(silent(asked))))

  let model = run(owner, home.SidebarArchiveAsked("B"))
  let model = run(model, home.SidebarArchiveConfirmed("B"))
  assert process.receive(asked, 0) == Ok(#(actions.StopArchive, "B"))
  let model = run(model, home.SidebarArchiveConfirmed("B"))
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(sidebar_of(home_html(model)), "disabled")

  let owner = opened(home_start(Some(silent(asked))))
  let model = run(owner, home.SidebarArchiveAsked("C"))
  let _ = run(model, home.SidebarArchiveConfirmed("C"))
  assert process.receive(asked, 0) == Ok(#(actions.Archive, "C"))

  let owner = opened(home_start(Some(silent(asked))))
  let model = run(owner, home.SidebarArchiveAsked("X"))
  let _ = run(model, home.SidebarArchiveConfirmed("X"))
  assert process.receive(asked, 0) == Ok(#(actions.Archive, "X"))
}

// A confirmation for no question, for another row, for a session the page does
// not list, or on a page with no capability asks nothing, and neither question
// answers for the other's: a stale click on the sidebar's confirm button cannot
// confirm the table's Delete, and the table's Delete confirm cannot confirm the
// sidebar's Archive.
pub fn a_stale_or_forged_confirmation_asks_nothing_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(silent(asked))))

  let _ = run(owner, home.SidebarArchiveConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)

  let model = run(owner, home.SidebarArchiveAsked("C"))
  let _ = run(model, home.SidebarArchiveConfirmed("B"))
  assert process.receive(asked, 0) == Error(Nil)

  assert !string.contains(
    home_html(run(owner, home.SidebarArchiveAsked("nobody"))),
    "session-confirm",
  )

  let deleting = run(owner, home.DeleteRequested("C"))
  let _ = run(deleting, home.SidebarArchiveConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)

  let archiving = run(owner, home.SidebarArchiveAsked("C"))
  let _ = run(archiving, home.DeleteConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)

  let plain = opened(home_start(None))
  let model = run(plain, home.SidebarArchiveAsked("C"))
  let _ = run(model, home.SidebarArchiveConfirmed("C"))
  assert process.receive(asked, 0) == Error(Nil)
  assert !string.contains(home_html(model), "session-confirm")
}

// The sidebar's question is drawn in the sidebar alone, and the table's own
// questions are drawn in the table alone.
pub fn each_question_is_drawn_in_its_own_place_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(silent(asked))))

  let html = home_html(run(owner, home.SidebarArchiveAsked("C")))
  assert string.contains(sidebar_of(html), "session-confirm")
  assert !string.contains(html, "home-confirm")

  let html = home_html(run(owner, home.DeleteRequested("C")))
  assert string.contains(html, "home-confirm")
  assert !string.contains(sidebar_of(html), "session-confirm")
}

// The answer is the page's notice in fixed words, and the list is read again so
// the archived row leaves the sidebar.
pub fn the_answer_is_a_note_and_the_list_is_read_again_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(answering(asked))))
  let model = run(owner, home.SidebarArchiveAsked("B"))
  let model = run(model, home.SidebarArchiveConfirmed("B"))
  assert process.receive(asked, 0) == Ok(#(actions.StopArchive, "B"))
  assert string.contains(home_html(model), "Stopped and archived.")
}

// --- A session page ---------------------------------------------------------

type Page =
  component.Model(page_fixture.Wire)

// A page on session `A` holding a capture and the list, whose transport is
// handed `manage`, and whose list read answers with `remaining`.
fn session_page(manage: Option(Ask), remaining: List(Entry)) -> Page {
  let start = page_fixture.start()
  let start =
    component.Start(
      ..start,
      transport: component.Transport(
        ..start.transport,
        manage:,
        sessions: fn(deliver) { deliver(remaining) },
      ),
    )
  let #(model, _) =
    component.update(
      component.new(start) |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(listing()),
    )
  model
}

fn deliver(model: Page, message: operator_page.Msg(page_fixture.Wire)) -> Page {
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

fn page_html(model: Page) -> String {
  element.to_string(operator_page.view(model))
}

// A page the daemon handed the capability draws the button on every row but the
// one on screen, which says in its title why it has none. A page without the
// capability, which is what a bookmark's page and a page of one session are,
// draws neither, and its sidebar is as it was.
pub fn a_session_page_draws_the_button_only_with_the_capability_test() {
  let asked = process.new_subject()
  let owner = session_page(Some(answering(asked)), [])
  let sidebar = sidebar_of(page_html(owner))
  assert list.length(string.split(sidebar, "class=\"session-archive\"")) == 4
  assert list.length(string.split(sidebar, "aria-label=\"Stop and archive\""))
    == 2
  assert string.contains(
    sidebar,
    "title=\"This session is on screen. Open the home page or another session to archive it.\"",
  )

  let plain = sidebar_of(page_html(session_page(None, [])))
  assert !string.contains(plain, "session-archive")
  assert !string.contains(plain, "This session is on screen")
}

// A press on a session page asks nothing until the question is confirmed, the
// confirmation stops and archives a running row, and the answer is the page's
// notice and a fresh read of the list.
pub fn a_session_page_asks_then_stops_and_archives_test() {
  let asked = process.new_subject()
  let remaining = list.filter(listing(), fn(row) { row.id != "B" })
  let owner = session_page(Some(answering(asked)), remaining)

  let model = deliver(owner, operator_page.AskingArchive("B"))
  assert string.contains(
    page_html(model),
    "Stop this session, then archive it?",
  )
  assert process.receive(asked, 0) == Error(Nil)

  let model = deliver(model, operator_page.ConfirmingArchive("B"))
  assert process.receive(asked, 0) == Ok(#(actions.StopArchive, "B"))
  let html = page_html(model)
  assert string.contains(html, "Stopped and archived.")
  assert !string.contains(sidebar_of(html), "vetting lint")

  let model = deliver(owner, operator_page.AskingArchive("C"))
  let _ = deliver(model, operator_page.ConfirmingArchive("C"))
  assert process.receive(asked, 0) == Ok(#(actions.Archive, "C"))
}

// The session on screen, a session the list does not show and a page with no
// capability open no question, and a confirmation with no question asks nothing.
pub fn a_session_page_refuses_what_it_did_not_offer_test() {
  let asked = process.new_subject()
  let owner = session_page(Some(answering(asked)), [])

  let model = deliver(owner, operator_page.AskingArchive("A"))
  assert !string.contains(page_html(model), "session-confirm")
  let model = deliver(owner, operator_page.AskingArchive("nobody"))
  assert !string.contains(page_html(model), "session-confirm")
  let _ = deliver(owner, operator_page.ConfirmingArchive("B"))
  assert process.receive(asked, 0) == Error(Nil)

  let plain = session_page(None, [])
  let model = deliver(plain, operator_page.AskingArchive("B"))
  let _ = deliver(model, operator_page.ConfirmingArchive("B"))
  assert !string.contains(page_html(model), "session-confirm")
}

// A refusal is worded in the notice in the reason's fixed words, and the
// buttons are not stuck: the row is archivable again.
pub fn a_refusal_is_worded_in_the_notice_test() {
  let declined = fn(_action, _session, deliver) {
    deliver(actions.Declined(actions.Running))
  }
  let owner = session_page(Some(declined), listing())
  let model = deliver(owner, operator_page.AskingArchive("B"))
  let model = deliver(model, operator_page.ConfirmingArchive("B"))
  assert string.contains(
    page_html(model),
    "That session is still running. Stop it first.",
  )
  assert component.archive_stage(model) == actions.Calm
}

// Every handler the buttons add is a click beneath the sidebar's path, which
// the observer's socket never admits.
pub fn the_buttons_add_only_clicks_beneath_the_sidebar_test() {
  let asked = process.new_subject()
  let owner = session_page(Some(answering(asked)), [])
  let plain = session_page(None, [])
  let with = handlers(operator_page.view(owner))
  let without = handlers(operator_page.view(plain))
  assert list.length(with) == list.length(without) + 3
  assert list.all(without, fn(key) { list.contains(with, key) })
  assert list.all(with, fn(key) {
    list.contains(without, key)
    || string.starts_with(key, component.sidebar_path <> "\t")
  })
}

// F140: the button is a glyph in a 24px square whose words are its label and
// title, so it can sit at the row's right edge and cover nothing: it holds no
// text of its own to overlap the dot or the activity word.
pub fn the_button_is_one_glyph_with_its_words_in_the_label_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(answering(asked))))
  let sidebar = sidebar_of(home_html(owner))
  assert string.contains(sidebar, "class=\"session-archive\"")
  assert string.contains(sidebar, ">×</button>")
  assert !string.contains(sidebar, ">Stop and archive</button>")
  assert !string.contains(sidebar, ">Archive</button>")
}

// F148: the button of a running row is a filled square, the sign for stop,
// since its press stops the turn before it archives; a row at rest keeps the
// cross. Each keeps its words in its label and title.
pub fn a_running_rows_button_is_a_stop_square_test() {
  let asked = process.new_subject()
  let owner = opened(home_start(Some(answering(asked))))
  let sidebar = sidebar_of(home_html(owner))
  assert string.contains(
    sidebar,
    "aria-label=\"Stop and archive\" class=\"session-archive\"",
  )
  let assert Ok(#(_, from_running)) =
    string.split_once(sidebar, "aria-label=\"Stop and archive\"")
  let assert Ok(#(running, _)) = string.split_once(from_running, "</button>")
  assert string.ends_with(running, ">■")
  assert !string.contains(running, "×")
  let assert Ok(#(_, from_saved)) =
    string.split_once(sidebar, "aria-label=\"Archive\"")
  let assert Ok(#(saved, _)) = string.split_once(from_saved, "</button>")
  assert string.ends_with(saved, ">×")
}

// F141: a running row whose activity is working or needs-you says the turn is
// in flight and will be stopped, as the home's Stop does. An idle row, or one
// the activity read has not named, keeps the plain sentence, and a saved row's
// is the archive question.
pub fn a_busy_rows_question_says_it_is_mid_turn_test() {
  let asked = process.new_subject()
  let busy =
    run(
      opened(home_start(Some(answering(asked)))),
      home.Observed([#("B", sessions.Working)]),
    )
  let html = home_html(run(busy, home.SidebarArchiveAsked("B")))
  assert string.contains(html, "Stop this session mid-turn, then archive it?")

  let waiting =
    run(
      opened(home_start(Some(answering(asked)))),
      home.Observed([#("B", sessions.NeedsYou)]),
    )
  let html = home_html(run(waiting, home.SidebarArchiveAsked("B")))
  assert string.contains(html, "Stop this session mid-turn, then archive it?")

  let idle =
    run(
      opened(home_start(Some(answering(asked)))),
      home.Observed([#("B", sessions.Idle)]),
    )
  let html = home_html(run(idle, home.SidebarArchiveAsked("B")))
  assert string.contains(html, "Stop this session, then archive it?")
  assert !string.contains(html, "mid-turn")
}
