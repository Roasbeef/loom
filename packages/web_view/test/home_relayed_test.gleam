//// The relayed session page (protocol-change/094): the home component with one
//// session of another orchestrator in its centre.
////
//// These tests drive the component the way the daemon's runtime does, with a
//// `Visit` whose functions record what they were asked and answer when the test
//// says. They pin that the page reads when its timer exists and at each
//// interval, that every press is judged before the daemon is asked, that an
//// answer is followed by a read, that text from the box is drawn escaped and
//// only as text, that the only handlers lie beneath the regions the daemon's
//// socket admits, and that a page with no relayed session ignores all of it.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import session_view/remote_transcript
import web_view/ending
import web_view/home
import web_view/listing
import web_view/page
import web_view/relayed
import web_view/relayed_session
import web_view/sessions
import web_view/signins
import web_view/view/relayed_session as relayed_view

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

const identity = "0198c0de-0000-7000-8000-000000000001"

const now = 7_400_000

// What the visit's functions were asked, in order, so a test can read it back.
type Asked {
  Read
  Sent(text: String)
  Stopped
  Archived
  Decided(escalation: String, seq: Int, choice: relayed.Choice)
}

fn need(
  escalation: String,
  seq: Int,
  ability: relayed.Ability,
) -> relayed.Need {
  relayed.Need(
    escalation:,
    seq:,
    strand: "main",
    tool: "bash",
    question: "Allow this command?",
    action: "go test ./...",
    authority: ["Network access: any host"],
    outside: [],
    ability:,
    remember: relayed.Rememberable,
  )
}

fn row(needs: List(relayed.Need)) -> relayed.Row {
  relayed.Row(
    name: "build the thing",
    code: listing.Registered("exec", "loom"),
    activity: relayed.NeedsYou,
    updated_ms: 1000,
    needs:,
    more_needs: 0,
  )
}

fn page() -> relayed.History {
  relayed.Shown(remote_transcript.Page(
    child: "main",
    entries: [],
    omitted: 0,
    next: None,
  ))
}

fn heard(needs: List(relayed.Need)) -> relayed.Read {
  relayed.Heard(row: Some(row(needs)), history: page())
}

// A visit that records every call on `log` and answers each read with `read`
// and each press with `outcome`, at once.
fn visit(
  log: Subject(Asked),
  read: relayed.Read,
  outcome: relayed.Outcome,
) -> home.Visit {
  home.Visit(
    orchestrator: "box",
    session: identity,
    refresh_ms: 5,
    read: fn(deliver) {
      process.send(log, Read)
      deliver(read)
    },
    send: fn(text, deliver) {
      process.send(log, Sent(text))
      deliver(outcome)
    },
    stop: fn(deliver) {
      process.send(log, Stopped)
      deliver(outcome)
    },
    archive: fn(deliver) {
      process.send(log, Archived)
      deliver(outcome)
    },
    decide: fn(escalation, seq, choice, deliver) {
      process.send(log, Decided(escalation, seq, choice))
      deliver(outcome)
    },
  )
}

fn start(visiting: option.Option(home.Visit)) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed([])) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    create: None,
    folders: None,
    elsewhere: None,
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
    visiting:,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "laptop",
    placements: fn(_) { Nil },
  )
}

// Runs one message through the component and performs its effects the way
// Lustre's runtime would, folding every dispatched message back in, in order.
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

// A page whose relay timer exists, so its first read has been made.
fn opened(
  read: relayed.Read,
  outcome: relayed.Outcome,
) -> #(home.Model, Subject(Asked), Subject(Nil)) {
  let log = process.new_subject()
  let timer = process.new_subject()
  let model = home.new(start(Some(visit(log, read, outcome))))
  #(run(model, home.RelayTimerReady(timer)), log, timer)
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

fn asked(log: Subject(Asked)) -> List(Asked) {
  case process.receive(log, 0) {
    Ok(entry) -> [entry, ..asked(log)]
    Error(Nil) -> []
  }
}

pub fn a_visiting_page_opens_on_the_session_and_reads_nothing_yet_test() {
  let log = process.new_subject()
  let model = home.new(start(Some(visit(log, heard([]), relayed.Done))))

  let assert home.Relayed(_) = home.pane(model)
  let html = drawn(model)
  assert string.contains(html, "<h1>Session</h1>")
  assert string.contains(html, "Reading the session from box")
  assert asked(log) == []
}

// A failed first read is no longer in flight: show its failure without also
// claiming the page is still reading.
pub fn a_failed_first_read_does_not_say_it_is_still_reading_test() {
  let #(model, _, _) = opened(relayed.Unreached("timed out"), relayed.Done)
  let html = drawn(model)
  assert string.contains(html, "Could not read from box: timed out")
  assert !string.contains(html, "Reading the session from box")
}

// Both listing and transcript failures retain the same last complete page,
// and the view reports its age rather than the failed refresh's time.
pub fn failed_refreshes_draw_the_last_complete_page_and_its_age_test() {
  let prior =
    relayed_session.heard(
      relayed_session.open("box", identity),
      heard([]),
      1000,
    )
  let presses =
    relayed_view.Presses(
      replied: fn(_) { Nil },
      stopped: Nil,
      archive_asked: Nil,
      archive_confirmed: Nil,
      archive_cancelled: Nil,
      decided: fn(_, _, _) { Nil },
    )
  let lost =
    relayed_session.heard(prior, relayed.Unreached("list timeout"), 121_000)
  let listing = element.to_string(relayed_view.view(lost, presses))
  assert string.contains(listing, "build the thing")
  assert string.contains(listing, "No entries yet.")
  assert string.contains(listing, "This is what it said 2m ago")
  assert string.contains(listing, "list timeout")

  let changed = relayed.Row(..row([]), name: "new incomplete row")
  let partial =
    relayed_session.heard(
      lost,
      relayed.Heard(
        row: Some(changed),
        history: relayed.Unreadable("history timeout"),
      ),
      181_000,
    )
  let history = element.to_string(relayed_view.view(partial, presses))
  assert string.contains(history, "build the thing")
  assert !string.contains(history, "new incomplete row")
  assert string.contains(history, "No entries yet.")
  assert string.contains(history, "This is what it said 3m ago")
  assert string.contains(history, "history timeout")
}

pub fn a_page_with_no_visit_has_no_relayed_centre_test() {
  let model = home.new(start(None))

  assert home.pane(model) == home.SessionList
  assert !string.contains(drawn(model), "relayed-pane")
}

pub fn the_timer_starts_the_first_read_and_each_answer_arms_the_next_test() {
  let #(model, log, timer) = opened(heard([]), relayed.Done)

  assert asked(log) == [Read]
  assert string.contains(drawn(model), "build the thing")

  // The answer armed the timer, so the interval passes and the page reads again.
  assert process.receive(timer, 1000) == Ok(Nil)
  let model = run(model, home.RelayTicked)
  assert asked(log) == [Read]
  assert string.contains(drawn(model), "build the thing")
}

pub fn the_page_says_where_the_session_lives_and_what_it_is_doing_test() {
  let #(model, _, _) = opened(heard([]), relayed.Done)
  let html = drawn(model)

  assert string.contains(html, "<h1>build the thing</h1>")
  assert string.contains(html, "Agent on")
  assert string.contains(html, "exec · loom")
  assert string.contains(html, "needs you")
  assert string.contains(
    html,
    "This session lives on box. This page relays replies and approvals.",
  )
}

// Everything the box wrote is a text node. A name, a request's words and a line
// of the transcript that carry markup reach the page as the characters they are.
pub fn text_from_the_box_is_drawn_escaped_test() {
  let marked = "<b>x</b> & \"q\""
  let flagged =
    relayed.Need(
      ..need("ask-1", 4, relayed.Decidable),
      strand: marked,
      tool: marked,
      question: marked,
      action: marked,
      authority: [marked],
      outside: [marked],
    )
  let read =
    relayed.Heard(
      row: Some(relayed.Row(..row([flagged]), name: marked)),
      history: page(),
    )
  let #(model, _, _) = opened(read, relayed.Done)
  let html = drawn(model)

  assert string.contains(html, "&lt;b&gt;x&lt;/b&gt; &amp; ")
  assert !string.contains(html, "<b>x</b>")
}

// Every handler lies beneath a region the daemon's socket admits.
pub fn every_handler_is_beneath_an_admitted_region_test() {
  let #(model, _, _) =
    opened(heard([need("ask-1", 4, relayed.Decidable)]), relayed.Done)
  let keys = handlers(home.view(model))

  assert keys != []
  list.each(keys, fn(key) {
    assert string.starts_with(key, home.table_path <> "\t")
      || string.starts_with(key, home.sidebar_path <> "\t")
      || string.starts_with(key, home.signins_path <> "\t")
  })
}

pub fn a_reply_is_judged_then_asked_then_followed_by_a_read_test() {
  let #(model, log, _) = opened(heard([]), relayed.Done)
  let _ = asked(log)

  let model = run(model, home.Relaying(relayed_session.Replied("  hello ")))
  assert asked(log) == [Sent("hello"), Read]

  // An empty reply asks nothing.
  let _ = run(model, home.Relaying(relayed_session.Replied("  ")))
  assert asked(log) == []
}

pub fn a_decision_names_only_a_request_the_row_lists_test() {
  let #(model, log, _) =
    opened(heard([need("ask-1", 4, relayed.Decidable)]), relayed.Done)
  let _ = asked(log)

  let model =
    run(
      model,
      home.Relaying(relayed_session.Decided("ask-9", 4, relayed.Allow)),
    )
  let model =
    run(
      model,
      home.Relaying(relayed_session.Decided("ask-1", 5, relayed.Allow)),
    )
  assert asked(log) == []

  let _ =
    run(model, home.Relaying(relayed_session.Decided("ask-1", 4, relayed.Deny)))
  assert asked(log) == [Decided("ask-1", 4, relayed.Deny), Read]
}

pub fn a_stop_and_an_archive_ask_the_daemon_test() {
  let #(model, log, _) = opened(heard([]), relayed.Done)
  let _ = asked(log)

  let model = run(model, home.Relaying(relayed_session.Stopped))
  assert asked(log) == [Stopped, Read]

  let model = run(model, home.Relaying(relayed_session.ArchiveAsked))
  assert asked(log) == []
  let _ = run(model, home.Relaying(relayed_session.ArchiveConfirmed))
  assert asked(log) == [Archived, Read]
}

pub fn an_unreachable_box_keeps_the_last_page_and_says_so_test() {
  let #(model, _, _) = opened(heard([]), relayed.Done)
  let model =
    run(
      model,
      home.RelayAnswered(home.relay_reads(model), relayed.Unreached("no route")),
    )
  let html = drawn(model)

  assert string.contains(html, "Could not refresh from box: no route")
  assert string.contains(html, "build the thing")
}

pub fn a_page_with_no_visit_ignores_relayed_messages_test() {
  let model = home.new(start(None))
  let model = run(model, home.Relaying(relayed_session.Stopped))
  let model = run(model, home.RelayTicked)

  assert home.pane(model) == home.SessionList
}

pub fn an_ended_page_asks_nothing_test() {
  let #(model, log, _) = opened(heard([]), relayed.Done)
  let _ = asked(log)
  let model =
    run(model, home.Refreshed(home.reads(model), home.Closed(ending.PageEnded)))
  let _ = asked(log)

  let _ = run(model, home.Relaying(relayed_session.Stopped))
  assert asked(log) == []
}

pub fn the_relayed_page_has_its_own_address_and_shell_test() {
  assert page.relayed_path("abc", "box", identity)
    == "/ui/p/abc/orchestrators/box/sessions/" <> identity

  let shell = page.relayed_shell()
  assert string.contains(shell, "Session — Loom")
  assert !string.contains(shell, identity)
  assert string.contains(shell, "<lustre-server-component>")
}

// The reply form carries exactly one field, `message`.
pub fn the_reply_form_decodes_one_field_only_test() {
  assert relayed_view.reply_fields([#("message", "hi")]) == Ok("hi")
  assert relayed_view.reply_fields([]) == Error(Nil)
  assert relayed_view.reply_fields([#("other", "hi")]) == Error(Nil)
  assert relayed_view.reply_fields([#("message", "a"), #("message", "b")])
    == Error(Nil)
  assert relayed_view.reply_fields([#("message", "a"), #("extra", "b")])
    == Error(Nil)
}

// The chain of reads stops with the page: a tick after the page ended, or after
// the person left the session for another pane, asks the box nothing.
pub fn a_tick_after_the_page_ended_or_was_left_asks_nothing_test() {
  let #(model, log, _) = opened(heard([]), relayed.Done)
  let _ = asked(log)
  let left = run(model, home.ShowingList)
  let _ = run(left, home.RelayTicked)
  assert asked(log) == []

  let ended =
    run(model, home.Refreshed(home.reads(model), home.Closed(ending.PageEnded)))
  let _ = run(ended, home.RelayTicked)
  assert asked(log) == []
}
