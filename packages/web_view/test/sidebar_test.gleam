//// The session sidebar: how the principal's sessions are grouped and
//// ordered, when a page reads the list, and what the sidebar draws.
////
//// The list is read-only. These tests pin that it draws every name as
//// escaped text, marks the session on screen, holds no handler of any kind,
//// and leaves the paths the observer's socket admits where they were.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/sessions.{type Entry, Entry, Live, Saved}

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn entry(
  id: String,
  name: String,
  workspace: String,
  created_at: Int,
  residency: sessions.Residency,
) -> Entry {
  Entry(id:, name:, workspace:, created_at:, residency:)
}

// Three workspaces. `A`, the session on screen, is in `/src/loom` with a
// newer sibling; `/src/weft` holds the newest session of the three.
fn listing() -> List(Entry) {
  [
    entry("B", "vetting lint", "/src/loom", 300, Live),
    entry("A", "web ui", "/src/loom", 100, Live),
    entry("C", "hex release", "/src/weft", 900, Saved),
    entry("D", "", "/src/notes", 500, Saved),
    entry("E", "older weft", "/src/weft", 50, Saved),
  ]
}

fn names(group: sessions.Group) -> List(String) {
  list.map(group.entries, fn(entry) { entry.id })
}

// The workspace of the session on screen is first, though `/src/weft` holds a
// newer session; the rest follow by their newest session. Within a workspace
// the newest session is first.
pub fn the_current_workspace_comes_first_then_the_newest_test() {
  let groups = sessions.grouped(listing(), "A")
  assert list.map(groups, fn(group) { group.workspace })
    == ["/src/loom", "/src/weft", "/src/notes"]
  let assert [loom, weft, notes] = groups
  assert names(loom) == ["B", "A"]
  assert names(weft) == ["C", "E"]
  assert names(notes) == ["D"]
}

// With another session on screen the order follows it, and a session that is
// listed nowhere leaves the recency order alone.
pub fn the_order_follows_the_session_on_screen_test() {
  let groups = sessions.grouped(listing(), "C")
  assert list.map(groups, fn(group) { group.workspace })
    == ["/src/weft", "/src/notes", "/src/loom"]
  let unlisted = sessions.grouped(listing(), "Z")
  assert list.map(unlisted, fn(group) { group.workspace })
    == ["/src/weft", "/src/notes", "/src/loom"]
}

// Two sessions created in the same millisecond are ordered by identity, and
// two workspaces whose newest sessions tie are ordered by path, so the order
// never depends on the order the daemon listed them in.
pub fn ties_are_broken_by_identity_and_by_path_test() {
  let tied = [
    entry("b", "second", "/src/b", 10, Live),
    entry("a", "first", "/src/b", 10, Live),
    entry("c", "other", "/src/a", 10, Live),
  ]
  let forward = sessions.grouped(tied, "none")
  let backward = sessions.grouped(list.reverse(tied), "none")
  assert forward == backward
  assert list.map(forward, fn(group) { group.workspace })
    == ["/src/a", "/src/b"]
  let assert [_, second] = forward
  assert names(second) == ["a", "b"]
}

pub fn no_sessions_make_no_groups_test() {
  assert sessions.grouped([], "A") == []
}

// A page reads the list when it opens: the transport's read is asked for once
// and its answer arrives as the page's own message.
pub fn a_page_reads_its_sessions_when_it_opens_test() {
  let answered = process.new_subject()
  let start = page_fixture.start()
  let asked = process.new_subject()
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, sessions: fn() {
        process.send(asked, Nil)
        listing()
      }),
    )
  let #(_, effects) =
    component.update(
      component.new(start),
      component.Opened(process.new_subject()),
    )
  effect.perform(
    effects,
    fn(message) { process.send(answered, message) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  assert process.receive(asked, 0) == Ok(Nil)
  assert process.receive(answered, 0) == Ok(component.SessionsListed(listing()))
}

// The answer is grouped for the page and does not move the lane.
pub fn the_answer_fills_the_sidebar_test() {
  let model = component.new(page_fixture.start())
  assert component.session_groups(model) == []
  let #(listed, _) =
    component.update(model, component.SessionsListed(listing()))
  assert list.map(component.session_groups(listed), fn(group) {
      group.workspace
    })
    == ["/src/loom", "/src/weft", "/src/notes"]
}

// A list past the catalogue's page is cut, not drawn whole.
pub fn a_list_past_the_limit_is_cut_test() {
  let many =
    list.repeat(Nil, sessions.listed_limit + 20)
    |> list.index_map(fn(_, n) { n })
    |> list.map(fn(n) { entry(string.inspect(n), "s", "/src/x", n, Saved) })
  let #(listed, _) =
    component.update(
      component.new(page_fixture.start()),
      component.SessionsListed(many),
    )
  let assert [group] = component.session_groups(listed)
  assert list.length(group.entries) == sessions.listed_limit
}

// One read when the page opens, and the next only after the refresh interval,
// on the tick that follows it.
pub fn the_list_is_read_again_only_after_the_interval_test() {
  let asked = process.new_subject()
  let clock = page_fixture.clock()
  let start = page_fixture.start_with(clock)
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, sessions: fn() {
        process.send(asked, Nil)
        []
      }),
    )
  let model = component.new(start)
  let wire = process.new_subject()
  let run = fn(model, message) {
    let #(model, effects) = component.update(model, message)
    effect.perform(
      effects,
      fn(_) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() { panic as "no dynamic value" },
      fn(_, _) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
    )
    model
  }
  let model = run(model, component.Opened(wire))
  assert process.receive(asked, 0) == Ok(Nil)

  page_fixture.set(clock, component.sessions_refresh_ms - 1)
  let model = run(model, component.Ticked)
  assert process.receive(asked, 0) == Error(Nil)

  page_fixture.set(clock, component.sessions_refresh_ms)
  let _ = run(model, component.Ticked)
  assert process.receive(asked, 0) == Ok(Nil)
}

// A page holding a capture and a list, on `A`.
fn listed_page(entries: List(Entry)) {
  let #(model, _) =
    component.update(
      component.new(page_fixture.start())
        |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(entries),
    )
  model
}

// The operator's page, the only one that draws the sidebar.
fn observer_html(model) -> String {
  element.to_string(operator_page.view(model))
}

// The sidebar draws each workspace by its last segment, with the whole path
// as a title, and each session by name; the session on screen is marked, and
// a session with no name is named by its identity.
pub fn the_sidebar_lists_workspaces_and_sessions_test() {
  let drawn = observer_html(listed_page(listing()))
  assert string.contains(
    drawn,
    "<aside aria-label=\"Sessions\" class=\"sidebar\" slot=\"left\">",
  )
  assert string.contains(drawn, "title=\"/src/loom\"")
  assert string.contains(drawn, ">loom<")
  assert string.contains(drawn, "vetting lint")
  assert string.contains(drawn, "Session D")

  // Sessions appear in the grouped order: the newer one of the current
  // workspace before the current session itself.
  let assert Ok(#(before_web, _)) = string.split_once(drawn, "web ui")
  assert string.contains(before_web, "vetting lint")
  assert string.contains(drawn, "class=\"session current\"")

  // Only the session on screen is current.
  assert list.length(string.split(drawn, "aria-current=\"true\"")) == 3
  assert string.contains(drawn, "resident")
  assert string.contains(drawn, "saved")
}

// The catalogue's fields are drawn as text, never as markup.
pub fn the_sidebar_escapes_what_the_catalogue_holds_test() {
  let drawn =
    observer_html(
      listed_page([
        entry("A", "<b>bold</b> & co", "/src/<x>", 1, Live),
        entry("F", "<script>alert(1)</script>", "/src/<x>", 2, Saved),
      ]),
    )
  assert !string.contains(drawn, "<b>bold")
  assert !string.contains(drawn, "<script")
  assert string.contains(drawn, "&lt;b&gt;bold&lt;/b&gt; &amp; co")
  assert string.contains(drawn, "&lt;script&gt;")
}

// A page whose read found nothing draws no sidebar.
pub fn an_empty_list_draws_no_sidebar_test() {
  let drawn = observer_html(listed_page([]))
  assert !string.contains(drawn, "class=\"sidebar\"")
  assert string.contains(drawn, "sidebar=\"none\"")
  assert !string.contains(drawn, "<aside aria-label=\"Sessions\"")
}

// The sidebar is read-only: no row is a link, a button or a form, and it adds
// no handler to either page, so the paths the observer's socket admits and
// the operator's composer are exactly where they were.
pub fn the_sidebar_carries_no_handler_test() {
  let bare =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.captured(10, None)])
  let listed = listed_page(listing())
  assert handlers(component.view(listed)) == handlers(component.view(bare))
  assert handlers(operator_page.view(listed))
    == handlers(operator_page.view(bare))

  let assert Ok(sidebar) = sidebar_of(observer_html(listed))
  assert !string.contains(sidebar, "<a ")
  assert !string.contains(sidebar, "<button")
  assert !string.contains(sidebar, "<form")
  assert !string.contains(sidebar, "href")
  assert !string.contains(sidebar, "onclick")
}

// The markup of the sidebar alone: from its opening tag to the first closing
// `</aside>`, which is its own, since the sidebar holds no other aside.
fn sidebar_of(drawn: String) -> Result(String, Nil) {
  use #(_, from) <- result.try(string.split_once(
    drawn,
    "<aside aria-label=\"Sessions\"",
  ))
  use #(sidebar, _) <- result.try(string.split_once(from, "</aside>"))
  Ok(sidebar)
}

// The operator's page draws the sidebar in the frame's second place: after
// the top bar and before the centre, whose composer and dock it precedes, and
// the strand panel, which is the last child.
pub fn the_operators_page_draws_the_sidebar_second_test() {
  let drawn = element.to_string(operator_page.view(listed_page(listing())))
  let assert Ok(#(before, after)) =
    string.split_once(drawn, "<aside aria-label=\"Sessions\"")
  assert string.contains(before, "class=\"session-head\"")
  assert !string.contains(before, "class=\"composer\"")
  assert string.contains(after, "class=\"composer\"")
  assert string.contains(after, "<aside aria-label=\"Strand panel\"")
}

// Focusing another strand leaves the sidebar as it was: it lists sessions,
// not strands.
pub fn focusing_a_strand_leaves_the_sidebar_alone_test() {
  let listed = listed_page(listing())
  let #(moved, _) = component.focus(listed, "advisor")
  assert component.session_groups(moved) == component.session_groups(listed)
}

// An observer's page draws no sidebar, whatever list it holds: the daemon
// supplies it none, and the view has nowhere to draw one.
pub fn an_observers_page_draws_no_sidebar_test() {
  let drawn = element.to_string(component.view(listed_page(listing())))
  assert !string.contains(drawn, "<aside aria-label=\"Sessions\"")
  assert !string.contains(drawn, "vetting lint")
  assert !string.contains(drawn, "/src/loom")
}
