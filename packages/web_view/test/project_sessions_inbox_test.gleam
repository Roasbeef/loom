//// A project's router and workers in the home's inbox (protocol-change/106, the
//// addendum on project sessions in the inbox). The daemon's list of
//// conversations leaves them out, and the inbox reads them for what needs the
//// owner: a worker that waits on an approval is a thread named for its ticket, a
//// worker with nothing pending is not, and none of them reaches a list.

import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element
import web_view/attention_feed.{Ask, Row, Section, Stuck}
import web_view/home
import web_view/sessions.{type Entry, Entry, Live, Report}
import web_view/signins

fn entry(id: String, name: String, standing: sessions.Standing) -> Entry {
  Entry(
    id:,
    name:,
    workspace: "/src/loom",
    created_at: 100_000,
    residency: Live,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
    standing:,
  )
}

// A session the owner started, a worker that waits on an approval, a worker
// with nothing pending and the project's router.
fn listing() -> List(Entry) {
  [
    entry("O", "my own session", sessions.Ordinary),
    entry("W1", "", sessions.ProjectWorker("p1", "t-needs")),
    entry("W2", "", sessions.ProjectWorker("p1", "t-quiet")),
    entry("R", "", sessions.ProjectRouter("p1")),
  ]
}

fn reports() -> List(#(String, sessions.Report)) {
  [
    #("O", Report(sessions.Idle, Some("Done."), [], None, None, 0)),
    #("W1", Report(sessions.NeedsYou, None, [], None, None, 1)),
    #("W2", Report(sessions.Idle, Some("Waiting."), [], None, None, 0)),
    #("R", Report(sessions.Working, None, [], None, None, 0)),
  ]
}

// What the feed holds: the quiet worker W2 has an open ask, and the router R a
// stuck strand. The needing worker W1 has none.
fn feed_rows() -> List(#(String, attention_feed.Row)) {
  [
    #(
      "W2",
      Row(
        waiting_since: Some(99_000_000),
        asks: Section(count: 1, items: [
          Ask(
            id: "ask-0123456789",
            strand: "main",
            created_at: 99_000_000,
            head: "Which database?",
            questions: 1,
          ),
        ]),
        finds: Section(count: 0, items: []),
        stuck: Section(count: 0, items: []),
      ),
    ),
    #(
      "R",
      Row(
        waiting_since: None,
        asks: Section(count: 0, items: []),
        finds: Section(count: 0, items: []),
        stuck: Section(count: 1, items: [
          Stuck(
            strand: "main",
            failed_at: Some(99_000_000),
            reason: None,
            retry_after_ms: None,
            parent: None,
            operation: None,
          ),
        ]),
      ),
    ),
  ]
}

fn attention(
  rows: List(#(String, attention_feed.Row)),
) -> option.Option(home.Attention) {
  Some(
    home.Attention(
      feed: fn(_, deliver) { deliver(rows) },
      saved: fn(_, deliver) { deliver([]) },
      record: fn(_, _, _) { Nil },
      approvals: fn(_, _) { Nil },
      review: None,
      review_pause_ms: 0,
      act: None,
      brief: fn(_, _, _) { Nil },
      timeline: fn(_, _, _, _) { Nil },
      span: fn(_, _, _, _, _) { Nil },
    ),
  )
}

fn start() -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 100_000_000 },
    activity: fn(_, deliver) { deliver(reports()) },
    rename: None,
    manage: None,
    thread_send: None,
    attention: attention([]),
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
    passkeys: None,
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "box",
    placements: fn(_) { Nil },
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

fn drawn() -> String {
  drawn_with(start())
}

fn drawn_with(start: home.Start) -> String {
  home.new(start)
  |> run(home.TimerReady(process.new_subject()))
  |> home.view
  |> element.to_string
}

// A worker that waits on an approval is a thread, named for its ticket.
pub fn a_project_session_with_an_approval_is_an_inbox_thread_test() {
  let html = drawn()

  assert string.contains(html, "Worker for ticket t-needs")
}

// A worker with nothing pending, and the router while it works, are not.
pub fn a_project_session_with_nothing_pending_is_not_listed_test() {
  let html = drawn()

  assert !string.contains(html, "t-quiet")
  assert !string.contains(html, "Router of")
}

// The session the owner started is listed as it always was, and no project
// session reaches the lists of conversations.
pub fn project_sessions_stay_out_of_the_lists_test() {
  let html = drawn()

  assert string.contains(html, "my own session")
  assert !string.contains(html, "Worker for ticket t-quiet")
}

// A project session whose feed holds an ask, or a stuck strand, is a thread too,
// named for what it is to its project; the ones whose feed holds nothing are not.
pub fn a_project_session_with_an_ask_or_a_stuck_strand_is_a_thread_test() {
  let html =
    drawn_with(home.Start(..start(), attention: attention(feed_rows())))

  assert string.contains(html, "Which database?")
  assert string.contains(html, "Worker for ticket t-quiet")
  assert string.contains(html, "Router of")
}
