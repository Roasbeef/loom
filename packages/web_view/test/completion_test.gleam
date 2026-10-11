//// The slash commands the composer offers are the terminal's, less the ones
//// the page refuses, and nothing in the table is session text.
////
//// The table is what `<loom-composer>` narrows as the draft grows, so what
//// these tests hold to is its content: the names and hints are the ones
//// `session_view/command.suggestions` gives the terminal's completer, and a
//// row is left out exactly when the page would refuse the command it names.

import core/json
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import lustre/element
import page_fixture
import session_view/command
import web_view/completion
import web_view/component
import web_view/operator_page

// Every row the terminal's completer can offer: the one-word commands, and
// the rows that complete an argument once its space is typed.
fn terminal() -> List(command.Suggestion) {
  list.flatten([
    command.suggestions("/"),
    command.suggestions("/effort "),
    command.suggestions("/goal "),
    command.suggestions("/profile "),
    command.suggestions("/model-profile "),
  ])
}

fn commands(rows: List(command.Suggestion)) -> List(String) {
  list.map(rows, fn(row) { row.command })
}

pub fn every_row_is_one_the_terminal_offers_with_its_name_and_hint_test() {
  list.each(completion.rows(), fn(row) {
    assert list.any(terminal(), fn(shown) {
      shown.command == row.command && shown.description == row.description
    })
  })
}

// The terminal's `/goal` shows the goal's status, which the page does not
// run, so the table once held no row to find `/goal check` from. The head is
// offered with the terminal's own hint and marked as taking an argument, so
// choosing it leaves `/goal ` in the editor.
pub fn the_goal_head_is_offered_and_continues_test() {
  let assert Ok(head) =
    list.find(completion.rows(), fn(row) { row.command == "/goal" })
  assert head.takes_argument
  assert head.description == "show status; add a space for goal actions"
  assert string.contains(completion.table(), "\"c\":\"/goal\"")
}

pub fn a_command_the_page_runs_is_offered_test() {
  let offered = commands(completion.rows())
  list.each(
    ["/compact", "/fork", "/steer", "/abort", "/effort", "/clear"],
    fn(name) {
      assert list.contains(offered, name)
    },
  )
}

// A command whose argument has a closed vocabulary is offered again, row by
// row, for once its space is typed.
pub fn the_argument_rows_are_offered_test() {
  let offered = commands(completion.rows())
  assert list.contains(offered, "/effort low")
  assert list.contains(offered, "/effort max")
  assert list.contains(offered, "/goal check")
  assert list.contains(offered, "/goal --budget")
}

// `/profile` is a session command, so the page runs it exactly as the terminal
// does, under both spellings, and offers the one argument it can know, `default`.
// The profile names are the daemon's text and the table is an attribute, so they
// are never rows (the page prints them when `/profile` is answered).
pub fn the_profile_commands_are_offered_under_both_spellings_test() {
  let rows = completion.rows()
  let offered = commands(rows)
  list.each(
    ["/profile", "/model-profile", "/profile default", "/model-profile default"],
    fn(name) {
      assert list.contains(offered, name)
    },
  )
  let assert Ok(head) = list.find(rows, fn(row) { row.command == "/profile" })
  assert head.takes_argument
}

pub fn the_page_carries_the_profile_commands_as_session_commands_test() {
  assert component.page_command(command.parse("/profile"))
    == Ok(command.ProfileShow)
  assert component.page_command(command.parse("/model-profile codex"))
    == Ok(command.ProfileSelect(option.Some("codex")))
  assert component.page_command(command.parse("/profile default"))
    == Ok(command.ProfileSelect(option.None))
}

// The page refuses a terminal surface and adding a directory, and does not
// offer what it would refuse. What is missing from the table is exactly what
// `component.page_command` refuses, checked against the command each missing
// row names.
pub fn a_command_the_page_refuses_is_not_offered_test() {
  let offered = commands(completion.rows())
  list.each(
    ["/help", "/model", "/sessions", "/access", "/add-dir", "/add-write-dir"],
    fn(name) {
      assert !list.contains(offered, name)
    },
  )

  let missing =
    list.filter(terminal(), fn(row) { !list.contains(offered, row.command) })
  assert missing != []
  list.each(missing, fn(row) {
    let draft = case row.takes_argument {
      True -> row.command <> " x"
      False -> row.command
    }
    let assert Error(_) = component.page_command(command.parse(draft))
      as row.command
  })
}

// Owner administration stays in the terminal. The page refuses `/access`
// itself, so a page an agent took has no path to the owner's overlay.
pub fn the_page_refuses_the_owner_access_overlay_test() {
  let assert Error(reason) = component.page_command(command.parse("/access"))
  assert string.contains(reason, "terminal surface")
  assert string.contains(reason, "Nothing was sent")
}

pub fn the_table_is_json_the_element_can_read_test() {
  let assert Ok(json.Array(items)) = json.parse(completion.table())
    as "the table is an array"
  assert list.length(items) == list.length(completion.rows())
  let assert [json.Object([#("c", json.String(_)), #("d", _), #("a", _)]), ..] =
    items
    as "each row names its command, its hint and whether an argument follows"
}

// The table rides on the editor's element as an attribute and is the same on
// every render, and the editor stays the plain textarea inside it.
pub fn the_composer_carries_the_table_on_its_editor_test() {
  let model = page_fixture.ready(process.new_subject(), "operator")
  let html = element.to_string(operator_page.view(model))
  assert string.contains(html, "<loom-composer")
  assert string.contains(html, "commands=\"")
  assert string.contains(html, "&quot;c&quot;:&quot;/compact&quot;")
  let assert Ok(#(_, editor)) = string.split_once(html, "<loom-composer")
    as "the editor is inside the element"
  assert string.contains(editor, "<textarea")
}
