//// The placement revamp on a session's page and on the admin page: the sidebar's
//// pills and the header's placement strip.
////
//// These tests pin that a pill narrows the session page's list and a name no pill
//// carries does not, that the session on screen stays listed under any filter,
//// that the header says where the agent runs and where its commands run (and says
//// only what it knows), that the page's "New session" goes to the home page, and
//// that the admin page's sidebar is text with pills that narrow it in place.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/listing
import web_view/operator_page
import web_view/sessions.{type Entry, Entry, Live, Saved}

fn entry(
  id: String,
  name: String,
  workspace: String,
  created_at: Int,
  residency: sessions.Residency,
) -> Entry {
  Entry(
    id:,
    name:,
    workspace:,
    created_at:,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn on(entry: Entry, executor: String) -> Entry {
  Entry(..entry, executor: Some(executor))
}

fn rows() -> List(Entry) {
  [
    on(entry("R", "remote work", "repo", 900, Live), "exec"),
    entry("B", "vetting lint", "/src/loom", 300, Live),
    entry("A", "web ui", "/src/loom", 100, Live),
    entry("C", "hex release", "/src/weft", 50, Saved),
  ]
}

fn start() -> component.Start(process.Subject(String)) {
  component.Start(
    ..page_fixture.start(),
    standing: component.Standing(..component.unplaced, machine: "laptop"),
  )
}

fn page(entries: List(Entry)) {
  let #(model, _) =
    component.update(
      component.new(start())
        |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(entries),
    )
  model
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

fn update(model, message) {
  operator_page.update(model, message).0
}

// The pills of the session page are the machines the list uses, and a press
// narrows the list to the rows that touch the machine. The session on screen stays
// listed under any filter.
pub fn a_pill_narrows_the_session_pages_list_test() {
  let model = page(rows())
  let html = drawn(model)
  assert string.contains(html, "Show sessions on")
  assert string.contains(html, ">exec<span class=\"fp-count\">1</span>")
  assert string.contains(html, "remote work")
  assert string.contains(html, "vetting lint")

  let narrowed = update(model, operator_page.Narrowing("exec"))
  let html = drawn(narrowed)
  assert component.session_filter(narrowed) == listing.On("exec")
  assert string.contains(html, "remote work")
  assert !string.contains(html, "vetting lint")

  // The session on screen is listed whatever the filter says.
  assert string.contains(html, "web ui")
  assert string.contains(html, "aria-current=\"true\"")

  let widened = update(narrowed, operator_page.Widening)
  assert component.session_filter(widened) == listing.Everywhere
  assert string.contains(drawn(widened), "vetting lint")
}

// A press that names no pill, as a forged one does, leaves the list as it was.
pub fn a_name_no_pill_carries_leaves_the_list_alone_test() {
  let model = page(rows())
  let before = drawn(model)

  assert drawn(update(model, operator_page.Narrowing("gpu"))) == before
  assert drawn(update(model, operator_page.Narrowing(""))) == before
  assert drawn(update(model, operator_page.Narrowing("laptop"))) == before
}

// The header says where the agent runs and where its commands run, once the page
// has read the row of its own session, and says only the agent before.
pub fn the_header_says_where_the_agent_and_commands_run_test() {
  let before = drawn(page([]))
  assert string.contains(before, "class=\"placement-strip\"")
  assert string.contains(before, "Agent on")
  assert string.contains(before, ">laptop<")
  assert !string.contains(before, "Commands on")

  let html = drawn(page(rows()))
  assert string.contains(html, "Commands on")
  assert string.contains(html, "laptop · /src/loom")
  assert string.contains(html, "title=\"/src/loom\"")
}

// A page whose own session runs on an executor says the executor and the
// workspace, not a directory.
pub fn an_executor_sessions_header_names_the_executor_test() {
  let remote = [on(entry("A", "web ui", "repo", 100, Live), "exec")]
  let html = drawn(page(remote))
  assert string.contains(html, "exec · repo")
  assert !string.contains(html, "laptop · repo")
}

// A page that can go home draws a "New session" button, which asks for the home
// page where a session is started, and counts the sessions that wait on the
// person on the frame.
pub fn new_session_goes_to_the_home_page_test() {
  // A page with no way home has no button.
  assert !string.contains(drawn(page(rows())), "New session</button>")

  let base = start()
  let homed =
    component.Start(
      ..base,
      transport: component.Transport(
        ..base.transport,
        home: Some(fn() { sessions.Declined(sessions.NoHome) }),
      ),
    )
  let #(model, _) =
    component.update(
      component.new(homed)
        |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(rows()),
    )
  let html = drawn(model)
  assert string.contains(html, "New session</button>")
  assert string.contains(html, "<p class=\"brand\"><span>Loom</span>")
  assert !string.contains(html, "waiting=")
}

// The tag of every row names the machine that runs the agent, and a row on an
// executor says the executor and its workspace.
pub fn every_row_is_tagged_with_its_placement_test() {
  let html = drawn(page(rows()))
  assert list.length(string.split(
      html,
      "<span class=\"tag-agent\">laptop</span>",
    ))
    == 5
  assert string.contains(html, "<span class=\"tag-code\">exec · repo</span>")
}
