//// The page's frame (`web_view/view/shell`): `<loom-shell>` around the four
//// regions, each in the slot the element lays it out in, and the one
//// attribute that says whether the page has a sidebar.
////
//// The element itself runs in the browser (`packages/web_client`); these
//// tests read the markup the server writes for it. The order of the four
//// children, which decides the paths the observer's socket admits, is pinned
//// by `page_events_test`, and the words of each region by the tests of the
//// region.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/sessions.{Entry, Live, Saved}

fn listing() -> List(sessions.Entry) {
  [
    Entry("B", "vetting lint", "/src/loom", 300, Live, None, None, None, None),
    Entry("A", "web ui", "/src/loom", 100, Live, None, None, None, None),
    Entry("C", "hex release", "/src/weft", 900, Saved, None, None, None, None),
  ]
}

// A page holding a capture and a sidebar list, on `A`.
fn listed(entries: List(sessions.Entry)) {
  let #(model, _) =
    component.update(
      component.new(page_fixture.start())
        |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(entries),
    )
  model
}

// How many times `needle` occurs in `haystack`.
fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// Whether each part appears in `html` after the one before it.
fn in_order(html: String, parts: List(String)) -> Bool {
  case parts {
    [] -> True
    [part, ..rest] ->
      case string.split_once(html, part) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}

// An operator's page with a sidebar says so, and draws the top bar, the
// sidebar, the centre and the panel as the shell's children in that order,
// the three side regions each in its slot and the centre in the default one.
pub fn an_operators_frame_names_its_slots_in_order_test() {
  let html = element.to_string(operator_page.view(listed(listing())))
  assert in_order(html, [
    "<loom-shell class=\"loom-session operator\" needing=\"0\" sidebar=\"listed\">",
    "<header class=\"session-head\" slot=\"bar\">",
    "<aside aria-label=\"Sessions\" class=\"sidebar\" slot=\"left\">",
    "<main class=\"centre\">",
    "<aside aria-label=\"Strand panel\" class=\"panel\" slot=\"right\">",
    "</loom-shell>",
  ])

  // Exactly one region is in each named slot, and the centre has none.
  assert count(html, "slot=\"bar\"") == 1
  assert count(html, "slot=\"left\"") == 1
  assert count(html, "slot=\"right\"") == 1
  assert !string.contains(html, "<main class=\"centre\" slot")
}

// An observer's page draws no sidebar, so the frame says `none` and the
// left slot is empty: the element then draws no button for it.
pub fn an_observers_frame_has_no_sidebar_test() {
  let html = element.to_string(component.view(listed(listing())))
  assert string.contains(
    html,
    "<loom-shell class=\"loom-session\" needing=\"0\" sidebar=\"none\">",
  )
  assert !string.contains(html, "slot=\"left\"")
  assert string.contains(html, "slot=\"bar\"")
  assert string.contains(html, "slot=\"right\"")
}

// An operator's page whose catalogue read listed nothing has no sidebar
// either, and says so, so that the bar does not draw a button that would
// hide an empty column.
pub fn an_operator_with_no_listed_sessions_has_no_sidebar_test() {
  let html = element.to_string(operator_page.view(listed([])))
  assert string.contains(html, "sidebar=\"none\"")
  assert !string.contains(html, "slot=\"left\"")
  assert string.contains(html, "slot=\"right\"")
}

// The attribute is one of two fixed words, whatever the catalogue holds: it
// is written from the type, never from a session's or a workspace's text.
pub fn the_sidebar_attribute_is_a_fixed_word_test() {
  let hostile = [
    Entry(
      "X",
      "\" onclick=\"alert(1)",
      "/src/\"><script>",
      1,
      Live,
      None,
      None,
      None,
      None,
    ),
  ]
  let html = element.to_string(operator_page.view(listed(hostile)))
  assert string.contains(html, "sidebar=\"listed\"")
  assert count(html, "sidebar=\"") == 1
  assert !string.contains(html, "<script>")
}

const workspace_hash =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// The frame carries the workspace digest the host handed the component, on
// the operator's page and the observer's, so the element can key the
// reader's layout by it. The value written is the digest, not the label's
// path.
pub fn the_frame_carries_the_workspace_digest_test() {
  let start =
    component.Start(
      ..page_fixture.start(),
      label: Some(component.Label(
        name: "web ui",
        workspace: "/home/me/src/loom",
      )),
      workspace_digest: workspace_hash,
    )
  let model = component.new(start)

  let operator = element.to_string(operator_page.view(model))
  assert string.contains(operator, "workspace=\"" <> workspace_hash <> "\"")
  assert count(operator, "workspace=\"") == 1

  let observer = element.to_string(component.view(model))
  assert string.contains(observer, "workspace=\"" <> workspace_hash <> "\"")
  assert count(observer, "workspace=\"") == 1
}

// A host with no digest writes no attribute, so the element reads none and
// keeps nothing for the page.
pub fn a_host_without_a_digest_writes_no_workspace_attribute_test() {
  let html = element.to_string(operator_page.view(listed(listing())))
  assert !string.contains(html, "workspace=\"")
}
