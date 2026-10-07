//// The create-session form's words (`web_view/view/create`): the Shareable
//// box is one word with a hint beneath it, and the form's fields are as they
//// were.

import gleam/string
import lustre/element
import web_view/creations
import web_view/view/create

fn drawn() -> String {
  create.Offered(
    choose: fn(_) { Nil },
    submit: fn(_, _, _) { Nil },
    cancel: Nil,
    elsewhere: Nil,
    submit_elsewhere: fn(_, _, _) { Nil },
    state: create.Composing("/src/loom"),
  )
  |> create.form("/src/loom")
  |> element.to_string
}

// The label is the word "Shareable" and nothing else; the explanation is a
// separate, quieter line inside the same label, so pressing it still ticks the
// box.
pub fn the_shareable_label_is_one_word_with_a_hint_test() {
  let html = drawn()
  assert string.contains(
    html,
    "<span class=\"home-create-share-name\">Shareable</span>",
  )
  assert string.contains(
    html,
    "<span class=\"home-create-share-hint\">Keeps its own notes and history, so you can invite people to it.</span>",
  )
  assert !string.contains(html, "Shareable.")
  assert string.contains(html, "name=\"shareable\"")
}

// The words changed and the fields did not.
pub fn the_forms_fields_are_unchanged_test() {
  assert create.fields([#("name", "x"), #("shareable", "on")])
    == Ok(#("x", creations.Shareable))
  assert create.fields([#("name", "x")]) == Ok(#("x", creations.Private))
}
