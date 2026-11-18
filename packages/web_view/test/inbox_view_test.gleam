//// The home page's attention inbox as a page draws it (`web_view/view/inbox`,
//// wired in `web_view/home`).
////
//// These tests pin what the daemon's reports become on screen: the groups and
//// their counts, the headline's words, the selected thread's last message as
//// escaped text under a label that says whose words it is, an approval that is
//// named and never drawn, and the one way to open a session. They also pin the
//// socket's side of the bargain: every handler the inbox registers is a click
//// beneath `home.table_path`, so no new admission is needed.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/home
import web_view/sessions.{
  type Entry, type Report, Entry, Glance, Live, Report, Saved,
}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn entry(id: String, name: String, residency: sessions.Residency) -> Entry {
  Entry(
    id:,
    name:,
    workspace: "/src/loom",
    created_at: 100_000,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn listing() -> List(Entry) {
  [
    entry("A", "web ui", Live),
    entry("B", "vetting lint", Live),
    entry("C", "docs sweep", Live),
    entry("D", "hex release", Saved),
  ]
}

// `B` has an approval pending, `A` finished a run and said something, `C`
// works with a strand reporting, and `D` is saved and so has no report.
fn reports() -> List(#(String, Report)) {
  [
    #(
      "B",
      Report(sessions.NeedsYou, Some("Approve the push?\nIt is ready."), []),
    ),
    #(
      "A",
      Report(sessions.Idle, Some("<script>alert(1)</script> finished"), [
        Glance("s1", "Lint", "all green"),
      ]),
    ),
    #(
      "C",
      Report(sessions.Working, None, [
        Glance("s2", "", "reading the spec"),
        Glance("s3", "Tests", "waiting on CI"),
      ]),
    ),
  ]
}

fn start(
  ceiling: home.Ceiling,
  answered: List(#(String, Report)),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling:,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, deliver) { deliver(answered) },
    rename: None,
    manage: None,
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
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "box",
    placements: fn(_) { Nil },
  )
}

// Applies a message and the messages its effects dispatch, as the runtime does.
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

// The page lands on the inbox: the groups in their order with their counts, the
// headline saying what it read, and no age anywhere.
pub fn the_inbox_groups_the_threads_and_counts_what_it_read_test() {
  let html = drawn(opened(start(home.OperatorCeiling, reports())))

  assert string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(
    html,
    "1 needs you · in 3 running sessions; saved sessions not checked",
  )
  assert string.contains(html, "Needs you<span class=\"inbox-count\">1</span>")
  assert string.contains(html, "Waiting<span class=\"inbox-count\">1</span>")
  assert string.contains(html, "Updates<span class=\"inbox-count\">1</span>")

  let needs = index_of(html, "Needs you<span")
  let waiting = index_of(html, "Waiting<span")
  let updates = index_of(html, "Updates<span")
  assert needs < waiting && waiting < updates

  // A thread's row says its kind, its session and one line of what was said.
  assert string.contains(html, "Approval · vetting lint")
  assert string.contains(html, "Approve the push?")
  assert string.contains(html, "Update · docs sweep")
  assert string.contains(html, "reading the spec")
  assert !string.contains(html, "ago")
}

// The default selection is the first thread of the first group, and its reading
// pane carries the labels that say whose words are on screen.
pub fn the_reading_pane_shows_the_first_thread_and_labels_its_words_test() {
  let html = drawn(opened(start(home.OperatorCeiling, reports())))

  assert string.contains(html, "inbox-reading-default")
  assert string.contains(html, "Approval · vetting lint · /src/loom</p>")
  assert string.contains(
    html,
    "The agent&#39;s last finished turn, untrusted text",
  )
  assert string.contains(html, "It is ready.")
  assert string.contains(html, "Open session ›")
}

// A press on a thread selects it, and its message is drawn as escaped text, so
// model text never becomes markup.
pub fn a_press_selects_a_thread_and_its_words_are_text_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let html = drawn(run(model, home.InboxOpened("A")))

  assert string.contains(html, "inbox-reading-pressed")
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt; finished")
  assert !string.contains(html, "<script>")
  assert string.contains(html, "What its strands are doing")
  assert string.contains(html, "Lint: all green")
}

// A glance with no title is named by its strand.
pub fn a_glance_without_a_title_is_named_by_its_strand_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let html = drawn(run(model, home.InboxOpened("C")))

  assert string.contains(html, "s2: reading the spec")
  assert string.contains(html, "Tests: waiting on CI")
}

// An approval is named and the owner is sent to the session's own page. Nothing
// of the approval is drawn on Home, and no deciding control is.
pub fn an_approval_is_named_and_never_decided_here_test() {
  let html = drawn(opened(start(home.OperatorCeiling, reports())))

  assert string.contains(html, "An approval is pending.")
  assert string.contains(html, "Decide on the session&#39;s page ›")

  assert !string.contains(html, "Allow")
  assert !string.contains(html, "Deny")
  assert !string.contains(html, "<textarea")
  assert !string.contains(html, "<form")
  assert !string.contains(html, "<input")
}

// A failed run is named as failed, and nothing is offered but the session.
pub fn a_failed_run_is_named_test() {
  let failed = [#("A", Report(sessions.Failed, Some("It broke."), []))]
  let html = drawn(opened(start(home.OperatorCeiling, failed)))

  assert string.contains(html, "Failed · web ui")
  assert string.contains(html, "Its last run failed, and nothing is running.")
  assert !string.contains(html, "An approval is pending.")
}

// The quiet sessions are one line of names and are not rows.
pub fn quiet_sessions_fold_to_one_line_test() {
  let quiet = [
    #("A", Report(sessions.Idle, None, [])),
    #("B", Report(sessions.Idle, None, [])),
    #("C", Report(sessions.Working, None, [])),
  ]
  let html = drawn(opened(start(home.OperatorCeiling, quiet)))

  assert string.contains(html, "Quiet: vetting lint, web ui")
  assert !string.contains(html, "Quiet · web ui")
  assert !string.contains(html, "Quiet<span")
}

// With nothing waiting or running the page keeps the list, and an owner
// with no capability to create sees the old page.
pub fn nothing_to_read_leaves_the_list_test() {
  let quiet = [#("A", Report(sessions.Idle, None, []))]
  let html = drawn(opened(start(home.OperatorCeiling, quiet)))

  assert !string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(html, "<h1>Sessions</h1>")
}

// An observer's page lands on the same list and may read it. Choosing the full
// list shows the older page.
pub fn an_observers_page_lands_on_the_inbox_and_can_leave_it_test() {
  let model = opened(start(home.ObserverCeiling, reports()))
  assert string.contains(drawn(model), "<h1>Inbox</h1>")

  let listed = run(model, home.ShowingList)
  assert !string.contains(drawn(listed), "<h1>Inbox</h1>")
  assert string.contains(drawn(listed), "<h1>Sessions</h1>")

  // A later read does not take the person back to the inbox.
  let read = run(listed, home.Observed(reports()))
  assert string.contains(drawn(read), "<h1>Sessions</h1>")
}

// The handlers are clicks beneath the table's region, which the socket admits
// already, and a session the page does not list cannot be selected into view.
pub fn every_handler_is_a_click_beneath_the_table_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let keys =
    handlers(home.view(model))
    |> list.filter(string.starts_with(_, home.table_path <> "\t"))

  assert keys != []
  assert list.all(keys, string.ends_with(_, "\nclick"))

  let stale = run(model, home.InboxOpened("gone"))
  assert string.contains(drawn(stale), "inbox-reading-default")
}

fn index_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}
