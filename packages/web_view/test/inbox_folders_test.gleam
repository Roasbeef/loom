//// The inbox's rail folders (`web_view/inbox_rule.Folder`, wired in
//// `web_view/home` and drawn by `web_view/view/sidebar`).
////
//// A folder narrows the list to one group and tells the daemon nothing. These
//// tests pin that a folder's count is the number of rows its band draws, that a
//// press narrows the list, that a press for a folder the page does not list
//// changes nothing, and that a folder whose group has emptied draws as
//// "Everything, by need". Every folder is a click beneath `home.sidebar_path`,
//// which the home's socket already admits.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/home
import web_view/inbox_rule
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

fn start_with(
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

fn start() -> home.Start {
  start_with(home.OperatorCeiling, reports())
}

fn count(name: String, count: String) -> String {
  "<span class=\"nm\">"
  <> name
  <> "</span><span class=\"n\">"
  <> count
  <> "</span>"
}

fn band(name: String, count: String) -> String {
  name <> "<span class=\"inbox-count\"> · " <> count <> "</span>"
}

// `B` has an approval pending, `A` finished a run and said something, and `C`
// works. So "Needs you" and "Updates" hold one thread each, and nothing else
// has a folder.
pub fn only_the_groups_that_hold_something_have_a_folder_test() {
  let html = drawn(opened(start()))

  assert string.contains(html, "<span class=\"nm\">Everything, by need</span>")
  assert string.contains(html, count("Needs you", "1"))
  assert string.contains(html, count("Updates", "1"))
  assert !string.contains(html, "<span class=\"nm\">To review</span>")
  assert !string.contains(html, "<span class=\"nm\">Finds</span>")
  assert !string.contains(html, "<span class=\"nm\">Projects</span>")
}

// A press narrows the list to the folder's group and "Everything, by need"
// clears it.
pub fn a_press_narrows_the_list_and_everything_clears_it_test() {
  let model = opened(start())
  let narrowed = run(model, home.FolderPicked(inbox_rule.Updating))
  let html = drawn(narrowed)

  assert string.contains(html, band("Updates", "1"))
  assert !string.contains(html, band("Needs you", "1"))
  assert !string.contains(html, band("Waiting", "1"))

  let cleared = drawn(run(narrowed, home.FolderPicked(inbox_rule.Everything)))
  assert string.contains(cleared, band("Needs you", "1"))
  assert string.contains(cleared, band("Updates", "1"))
}

// A press for a folder the page does not list changes nothing, so a forged
// message cannot hide the list behind a filter with no rows.
pub fn a_press_for_an_unlisted_folder_changes_nothing_test() {
  let model = opened(start())

  assert drawn(run(model, home.FolderPicked(inbox_rule.Projecting)))
    == drawn(model)
  assert drawn(run(model, home.FolderPicked(inbox_rule.Reviewing)))
    == drawn(model)
}

// A folder whose group has emptied draws as "Everything, by need", so the list
// is never blank under a filter the rail no longer offers.
pub fn an_emptied_folder_draws_as_everything_test() {
  let narrowed = run(opened(start()), home.FolderPicked(inbox_rule.Updating))
  let quiet = [#("C", Report(sessions.Idle, None, []))]
  let html = drawn(run(narrowed, home.Observed(quiet)))

  assert !string.contains(html, "<span class=\"nm\">Updates</span>")
  assert string.contains(html, "aria-pressed=\"true\"")
}

// The top bar's pill says how many threads wait on the owner, and a page with
// none draws no pill.
pub fn the_bar_counts_what_waits_on_the_owner_test() {
  assert string.contains(
    drawn(opened(start())),
    "<span class=\"need-pill\">1 need you</span>",
  )

  let calm = [#("C", Report(sessions.Working, None, []))]
  assert !string.contains(
    drawn(opened(start_with(home.OperatorCeiling, calm))),
    "need-pill",
  )
}

// Every handler beneath the sidebar's path is a click, which the socket admits.
pub fn every_folder_is_a_click_beneath_the_sidebar_test() {
  let beneath =
    handlers(home.view(opened(start())))
    |> list.filter(string.starts_with(_, home.sidebar_path <> "\t"))

  assert beneath != []
  assert list.all(beneath, fn(key) { string.ends_with(key, "\nclick") })
}

// The count note says what the counts read.
pub fn the_rail_note_says_what_the_counts_read_test() {
  assert string.contains(
    drawn(opened(start())),
    "Counts read 3 running sessions. Saved sessions are not checked.",
  )
}
