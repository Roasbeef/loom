//// A page holds one session's text and no other's
//// (`docs/design-notes/web-design.md`, section 3.4; protocol-change/051, the
//// addendum on switching sessions).
////
//// Switching sessions is a navigation to a new page, which runs a new
//// component over a new lane, so every region is drawn from that component's
//// model alone and none can keep the page that was left. The invariant is
//// tested rather than argued: two pages are built one after the other in one
//// process, each from a capture whose every region holds its own marker
//// (`lane_fixture.marked`), and the second page's markup, on both pages, holds
//// nothing of the first's. The regions are the note's table: the top bar,
//// the transcript, the strands, the Changes, Trace and Session tabs, the todo
//// line, the approval cards, and the composer.
////
//// The sidebar is the one place another session's words belong: it lists the
//// principal's sessions by the catalogue's names, which is how a person
//// returns. The catalogue names here hold no marker, so the sidebar cannot
//// hide a leak or cause a false one.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/sessions.{Entry, Live}

// The catalogue: two running sessions, named without either marker.
fn listing() -> List(sessions.Entry) {
  [
    Entry("first", "first project", "/src/one", 100, Live, None, None, None),
    Entry("second", "second project", "/src/two", 200, Live, None, None, None),
  ]
}

// The page of session `id`, opened after the host read its label and drawn
// from one capture that holds `marker` in every region, with `running`
// strands working.
fn page_of(
  id: String,
  marker: String,
  running: List(#(String, String)),
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  let start =
    component.Start(
      ..start,
      session_id: id,
      label: Some(component.Label(
        name: marker <> " name",
        workspace: "/work/" <> marker,
      )),
    )
  let #(model, _) =
    component.update(
      component.new(start)
        |> component.apply([lane_fixture.marked(marker, running)])
        |> lane_fixture.opened,
      component.SessionsListed(listing()),
    )
  model
}

fn operator_html(model: component.Model(page_fixture.Wire)) -> String {
  element.to_string(operator_page.view(model))
}

fn observer_html(model: component.Model(page_fixture.Wire)) -> String {
  element.to_string(component.view(model))
}

// What each region of session `marker` says, as text a page draws: one entry
// for each row of the note's table, so a region that drew nothing of the
// session would fail its own assertion below.
fn regions(marker: String) -> List(#(String, String)) {
  [
    #("top bar", marker <> " name"),
    #("transcript", marker <> " prompt"),
    #("transcript", marker <> " answer"),
    #("peer message", marker <> " peer says"),
    #("todo line", marker <> " task"),
    #("changes tab", marker <> "/edited.gleam"),
    #("trace tab", marker <> "_program"),
  ]
}

// What only the operator's page draws of a session.
fn operator_regions(marker: String) -> List(#(String, String)) {
  [
    #("approval card", "tool-" <> marker),
    #("session tab viewers", marker <> " viewer"),
  ]
}

// Each region of the first page says what it holds, and the second page,
// built afterwards in the same process, holds none of it and all of its own.
pub fn a_page_for_one_session_holds_no_text_of_another_test() {
  let reviewer = [#(lane_fixture.child, lane_fixture.review_op())]
  let first = page_of("first", "alpha", reviewer)
  let second = page_of("second", "beta", [])

  let first_operator = operator_html(first)
  let first_observer = observer_html(first)
  let second_operator = operator_html(second)
  let second_observer = observer_html(second)

  // The check has teeth: each region of the first session draws the first
  // session's words, on the operator's page, and on the observer's for the
  // regions it draws.
  list.each(regions("alpha"), fn(region) {
    let #(name, text) = region
    assert string.contains(first_operator, text) as name
    assert string.contains(first_observer, text) as name
  })
  list.each(operator_regions("alpha"), fn(region) {
    let #(name, text) = region
    assert string.contains(first_operator, text) as name
  })
  assert string.contains(first_operator, "Reading &lt;manager&gt;.go")

  // Every marker is "alpha", and the catalogue's names hold none, so the
  // second session's pages hold nothing of the first: not in the top bar, the
  // transcript, the strands and their glances, the tabs, the todo line, the
  // approval cards or the composer.
  assert !string.contains(second_operator, "alpha")
  assert !string.contains(second_observer, "alpha")
  assert !string.contains(second_operator, "Reading &lt;manager&gt;.go")
  assert !string.contains(second_observer, "Reading &lt;manager&gt;.go")

  // And the second page draws its own, so it is not merely empty.
  list.each(regions("beta"), fn(region) {
    let #(name, text) = region
    assert string.contains(second_operator, text) as name
    assert string.contains(second_observer, text) as name
  })
  list.each(operator_regions("beta"), fn(region) {
    let #(name, text) = region
    assert string.contains(second_operator, text) as name
  })
}

// The sidebar is the one shared region: the second page lists the first
// session by the catalogue's name, marks itself, and draws the first's words
// nowhere else.
pub fn the_sidebar_names_the_other_session_and_marks_this_one_test() {
  let second = page_of("second", "beta", [])
  let drawn = operator_html(second)
  assert string.contains(drawn, "first project")

  // The strand cards mark their own current strand, so the session marker is
  // counted inside the sidebar alone.
  let assert Ok(#(_, from_sidebar)) =
    string.split_once(drawn, "<aside aria-label=\"Sessions\"")
  let assert Ok(#(sidebar, _)) = string.split_once(from_sidebar, "</aside>")
  assert list.length(string.split(sidebar, "aria-current=\"true\"")) == 2
  assert string.contains(sidebar, "second project")
  assert component.session_id(second) == "second"
  assert component.departure(second) == None
}
