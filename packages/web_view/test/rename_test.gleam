//// Renaming from an owner's page (protocol-change/067).
////
//// What these tests read is what the page draws and asks. An owner's page has
//// the control in the Session pane, one form at a path beneath
//// `component.rename_path`; a submit sends the typed text to the transport,
//// once; the daemon's answer becomes the heading's and the sidebar's name, or a
//// refusal in fixed words; and the name appears only as a text node. A page
//// whose transport has no capability draws no control and asks nothing whatever
//// message reaches it, and the observer's page draws none even when its
//// transport has one. The pinned paths of the other controls do not move.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/renames
import web_view/sessions.{Entry, Live}

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// A page on session `A` with a capture, a label and a sidebar listing, whose
// transport answers every request to rename with `answer` and reports the text
// it was asked for. `None` is a page that has no capability.
fn page(
  capability: option.Option(renames.Answer),
  asked: Subject(String),
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    label: Some(component.Label(name: "web ui", workspace: "/src/loom")),
    transport: component.Transport(
      ..start.transport,
      sessions: fn(deliver) {
        deliver([
          Entry("A", "web ui", "/src/loom", 100, Live, None, None, None, None),
          Entry("B", "other", "/src/loom", 50, Live, None, None, None, None),
        ])
      },
      rename: option.map(capability, fn(answer) {
        fn(name, deliver) {
          process.send(asked, name)
          deliver(answer)
        }
      }),
    ),
  )
  |> component.new
  |> component.apply([lane_fixture.captured(10, None)])
}

// The owner's page, answering with the name it was asked for stored as given.
fn owner(asked: Subject(String)) -> component.Model(page_fixture.Wire) {
  page(Some(renames.Renamed("review auth")), asked)
}

// Delivers `message` to the operator's page and then every message its
// effects dispatch, as the runtime would, so the daemon's answer arrives.
fn deliver(
  model: component.Model(page_fixture.Wire),
  message: operator_page.Msg(page_fixture.Wire),
) -> component.Model(page_fixture.Wire) {
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

fn drawn(model: component.Model(page_fixture.Wire)) -> String {
  element.to_string(operator_page.view(model))
}

// The handlers at or beneath the rename control's path.
fn rename_handlers(keys: List(String)) -> List(String) {
  list.filter(keys, fn(key) { string.starts_with(key, component.rename_path) })
}

fn count(html: String, part: String) -> Int {
  list.length(string.split(html, part)) - 1
}

// An owner's page has the control in the Session pane, after the list of rows
// and the other controls: the session's current name as text, a disclosure and
// a form with one text field.
pub fn an_owners_page_draws_the_control_test() {
  let html = drawn(owner(process.new_subject()))
  assert string.contains(html, "Rename this session")
  assert string.contains(html, "Name: <span data-loom-name>web ui</span>")
  assert string.contains(html, "<loom-rename><input")
  assert !string.contains(html, "value=\"web ui")
  assert string.contains(html, "<summary>Rename</summary>")
  assert string.contains(html, "aria-label=\"New name\"")
  assert string.contains(html, "name=\"text\"")

  let assert Ok(#(_, session)) =
    string.split_once(html, "<section aria-label=\"Session\"")
  let assert Ok(#(before, _)) =
    string.split_once(session, "aria-label=\"Rename this session\"")
  assert string.contains(before, "Cost")
  assert string.contains(before, "Session controls")
}

// The form is the one handler beneath the path the constant names, a submit, and
// nothing else on the page is beneath it.
pub fn the_form_is_the_only_handler_beneath_the_rename_path_test() {
  let keys = handlers(operator_page.view(owner(process.new_subject())))
  let beneath = rename_handlers(keys)
  assert list.length(beneath) == 1
  let assert [key] = beneath
  assert string.ends_with(key, "\nsubmit")
  assert string.starts_with(key, component.rename_path <> "\t")
}

// The paths the socket admits for the other controls are where they were: the
// invitation control, the session controls, the sidebar and the strip. The
// rename control is a fifth child after them, so placing it moved none.
pub fn the_pinned_paths_are_where_they_were_test() {
  assert component.invite_path == "0\t3\t2\t2"
  assert component.session_controls_path == "0\t3\t2\t3"
  assert component.rename_path == "0\t3\t2\t4"
  assert component.sidebar_path == "0\t1"
  assert component.strip_path == "0\t3\t0\t1\t0"
  assert component.older_path == "0\t2\t1\t0\t0"
  assert component.home_path == "0\t0\t1"

  // Drawing the control adds handlers only beneath its own path: every other
  // handler's key is the same with it as without it.
  let with = handlers(operator_page.view(owner(process.new_subject())))
  let without = handlers(operator_page.view(page(None, process.new_subject())))
  assert list.filter(with, fn(key) {
      !string.starts_with(key, component.rename_path)
    })
    == without
}

// A member operator's page and an observer's page draw nothing: the control's
// place is an empty node, so no other path moves, and no handler is there.
pub fn a_page_without_the_capability_draws_no_control_test() {
  let member = page(None, process.new_subject())
  let html = drawn(member)
  assert !string.contains(html, "Rename this session")
  assert !string.contains(html, "New name")
  assert rename_handlers(handlers(operator_page.view(member))) == []

  // The observer's page is the component's own, which has no message that
  // renames, and its panel draws nothing at the rename control's place even
  // when its transport has the capability.
  let observer = page(Some(renames.Renamed("x")), process.new_subject())
  let observed = element.to_string(component.view(observer))
  assert !string.contains(observed, "Rename this session")
  assert rename_handlers(handlers(component.view(observer))) == []
}

// A page with no capability ignores the message whatever reaches it.
pub fn a_page_without_the_capability_asks_nothing_test() {
  let asked = process.new_subject()
  let member = page(None, asked)
  let model = deliver(member, operator_page.Renaming("sneaky"))
  assert process.receive(asked, 0) == Error(Nil)
  assert component.rename_control(model) == renames.Withheld
}

// A submit sends the typed text, once, and the answer becomes the heading's and
// the sidebar's name at once, for the session on screen and no other.
pub fn a_stored_name_replaces_the_heading_and_the_sidebar_row_test() {
  let asked = process.new_subject()
  let #(listed, _) =
    component.update(
      owner(asked),
      component.SessionsListed([
        Entry("A", "web ui", "/src/loom", 100, Live, None, None, None, None),
        Entry("B", "other", "/src/loom", 50, Live, None, None, None, None),
      ]),
    )
  assert string.contains(drawn(listed), "<span class=\"session-name\">web ui<")
  let model = deliver(listed, operator_page.Renaming("review auth"))
  assert process.receive(asked, 0) == Ok("review auth")
  assert process.receive(asked, 0) == Error(Nil)
  assert component.rename_control(model) == renames.Done
  let html = drawn(model)
  assert string.contains(html, "Name: <span data-loom-name>review auth</span>")
  assert string.contains(html, "Renamed.")
  assert string.contains(html, "<span class=\"session-name\">review auth<")
  assert !string.contains(html, "Name: <span data-loom-name>web ui</span>")
  assert !string.contains(html, "<span class=\"session-name\">web ui<")

  // The other session's row is the catalogue's still.
  assert string.contains(html, "<span class=\"session-name\">other<")
}

// While a request is out a second submit asks nothing, so one submit renames at
// most once, and the form says it is asking.
pub fn a_second_submit_while_asking_asks_nothing_test() {
  let asked = process.new_subject()
  let start = page_fixture.start()
  let model =
    component.Start(
      ..start,
      transport: component.Transport(
        ..start.transport,
        rename: Some(fn(name, _deliver) { process.send(asked, name) }),
      ),
    )
    |> component.new
    |> component.apply([lane_fixture.captured(10, None)])
  let model = deliver(model, operator_page.Renaming("first"))
  assert component.rename_control(model) == renames.Asking
  let model = deliver(model, operator_page.Renaming("second"))
  assert process.receive(asked, 0) == Ok("first")
  assert process.receive(asked, 0) == Error(Nil)
  assert component.rename_control(model) == renames.Asking
  assert string.contains(drawn(model), "disabled")
}

// A refusal is worded in the reason's fixed words and nothing the daemon wrote,
// and the form stays as the owner left it so the name can be corrected.
pub fn a_refusal_is_worded_in_fixed_words_test() {
  list.each(
    [renames.NotOwner, renames.InvalidName, renames.Unavailable],
    fn(reason) {
      let model =
        page(Some(renames.Declined(reason)), process.new_subject())
        |> deliver(operator_page.Renaming("x"))
      assert component.rename_control(model) == renames.Refused(reason)
      let html = drawn(model)
      assert string.contains(html, renames.reason_words(reason))
      assert !string.contains(html, "Renamed.")
      assert string.contains(html, "Name: <span data-loom-name>web ui</span>")
    },
  )

  // After a refusal the owner may submit again.
  let asked = process.new_subject()
  let model =
    page(Some(renames.Declined(renames.InvalidName)), asked)
    |> deliver(operator_page.Renaming("bad"))
    |> deliver(operator_page.Renaming("better"))
  assert process.receive(asked, 0) == Ok("bad")
  assert process.receive(asked, 0) == Ok("better")
  assert component.rename_control(model) == renames.Refused(renames.InvalidName)
}

// An answer nobody asked for is dropped: no daemon message can change the name
// the page draws unless a request is out.
pub fn an_unsolicited_answer_is_dropped_test() {
  let model = owner(process.new_subject())
  let #(after, _) =
    operator_page.update(
      model,
      operator_page.Observed(component.Renamed(renames.Renamed("forged"))),
    )
  assert drawn(after) == drawn(model)
  assert !string.contains(drawn(after), "forged")
}

// The name is a person's text and appears only as a text node. A hostile name
// is escaped wherever it is drawn, and nowhere is it an attribute.
pub fn the_name_is_only_ever_a_text_node_test() {
  let hostile = "\"><img src=x onerror=alert(1)>"
  let model =
    page(Some(renames.Renamed(hostile)), process.new_subject())
    |> deliver(operator_page.Renaming("anything"))
  let html = drawn(model)
  assert !string.contains(html, "<img")
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")

  // The text is drawn in the heading, the lead and the sidebar row, and in no
  // attribute: every occurrence is escaped text.
  assert count(html, "onerror=alert(1)") == count(html, "onerror=alert(1)&gt;")
  assert !string.contains(html, "value=\"" <> hostile)
  assert !string.contains(html, "placeholder=\"" <> hostile)
  assert !string.contains(html, "title=\"" <> hostile)
}

// The submit's fields are decoded totally: exactly one, named `text`. Any other
// field, a repeated one or none refuses the event.
pub fn the_forms_fields_are_decoded_totally_test() {
  assert operator_page.control_text([#("text", "review auth")])
    == Ok("review auth")
  assert operator_page.control_text([]) == Error(Nil)
  assert operator_page.control_text([#("name", "x")]) == Error(Nil)
  assert operator_page.control_text([#("text", "a"), #("text", "b")])
    == Error(Nil)
  assert operator_page.control_text([#("text", "a"), #("images", "[]")])
    == Error(Nil)
}
