//// The create-session form's words (`web_view/view/create`): the Shareable
//// box is one word with a hint beneath it, and the form's fields are as they
//// were.

import gleam/option.{None, Some}
import gleam/string
import lustre/element
import web_view/creations
import web_view/view/create

fn drawn() -> String {
  drawn_with([], [])
}

fn drawn_with(profiles: List(String), models: List(String)) -> String {
  create.Offered(
    choose: fn(_) { Nil },
    submit: fn(_, _, _, _) { Nil },
    cancel: Nil,
    elsewhere: Nil,
    submit_elsewhere: fn(_, _, _, _) { Nil },
    state: create.Composing("/src/loom"),
    profiles:,
    models:,
  )
  |> create.form("/src/loom")
  |> element.to_string
}

fn drawn_elsewhere(profiles: List(String), models: List(String)) -> String {
  create.Offered(
    choose: fn(_) { Nil },
    submit: fn(_, _, _, _) { Nil },
    cancel: Nil,
    elsewhere: Nil,
    submit_elsewhere: fn(_, _, _, _) { Nil },
    state: create.Elsewhere,
    profiles:,
    models:,
  )
  |> create.elsewhere_form
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

// The select exists only when the daemon listed profiles, in both forms.
pub fn the_profile_select_is_drawn_only_when_profiles_exist_test() {
  assert !string.contains(drawn(), "<select")
  assert !string.contains(drawn_elsewhere([], []), "<select")
  assert string.contains(drawn_with(["deepseek"], []), "name=\"profile\"")
  assert string.contains(drawn_elsewhere(["deepseek"], []), "name=\"profile\"")
}

// The model select is drawn the same way: only when the daemon listed model
// keys, in both forms, and independently of the profile select.
pub fn the_model_select_is_drawn_only_when_models_exist_test() {
  assert !string.contains(drawn_with(["deepseek"], []), "name=\"model\"")
  assert !string.contains(drawn_elsewhere(["deepseek"], []), "name=\"model\"")
  assert string.contains(drawn_with([], ["fast"]), "name=\"model\"")
  assert string.contains(drawn_elsewhere([], ["fast"]), "name=\"model\"")

  // With only models there is one select and it is the model's.
  assert !string.contains(drawn_with([], ["fast"]), "name=\"profile\"")

  // With both, each has its own select and its own label.
  let both = drawn_with(["deepseek"], ["fast"])
  assert string.contains(both, "name=\"profile\"")
  assert string.contains(both, "name=\"model\"")
  assert string.contains(both, "aria-label=\"Model profile\"")
  assert string.contains(both, "aria-label=\"Main model\"")
}

// The default comes first with an empty value, and each profile's option
// carries its position as the value and its name as the label.
pub fn the_select_offers_the_default_then_each_profile_by_position_test() {
  let html = drawn_with(["deepseek", "gemini"], [])
  assert string.contains(html, "name=\"profile\"")
  assert string.contains(html, "<option value>Default</option>")
  assert string.contains(html, "<option value=\"0\">deepseek</option>")
  assert string.contains(html, "<option value=\"1\">gemini</option>")
}

pub fn the_model_select_offers_the_default_then_each_key_by_position_test() {
  let html = drawn_elsewhere([], ["fast", "slow"])
  assert string.contains(html, "<option value>Default</option>")
  assert string.contains(html, "<option value=\"0\">fast</option>")
  assert string.contains(html, "<option value=\"1\">slow</option>")
}

// A profile's name is the daemon's text and is drawn as a text node only: it is
// escaped as one and appears in no attribute.
pub fn a_profile_name_is_a_text_node_and_never_an_attribute_test() {
  let hostile = "x\" onfocus=\"alert(1)\" <b>"
  let html = drawn_with([hostile], [])
  assert !string.contains(html, "onfocus=\"alert(1)\"")
  assert string.contains(html, "&lt;b&gt;")
  assert string.contains(html, "<option value=\"0\">")
}

// A model key is the owner's configuration text and is held to the same rule.
pub fn a_model_key_is_a_text_node_and_never_an_attribute_test() {
  let hostile = "x\" onfocus=\"alert(1)\" <b>"
  let html = drawn_with([], [hostile])
  assert !string.contains(html, "onfocus=\"alert(1)\"")
  assert string.contains(html, "&lt;b&gt;")
  assert string.contains(html, "<option value=\"0\">")
  let typed = drawn_elsewhere([], [hostile])
  assert !string.contains(typed, "onfocus=\"alert(1)\"")
}

pub fn a_submitted_position_becomes_the_offered_name_test() {
  let offered = ["deepseek", "gemini"]
  assert create.fields_with_roles(
      [#("name", "x"), #("profile", "1")],
      offered,
      [],
    )
    == Ok(#("x", creations.Private, creations.Roles(Some("gemini"), None)))
  assert create.fields_with_roles(
      [#("profile", "0"), #("name", "x"), #("shareable", "on")],
      offered,
      [],
    )
    == Ok(#("x", creations.Shareable, creations.Roles(Some("deepseek"), None)))
  assert create.fields_with_roles(
      [#("name", "x"), #("profile", "")],
      offered,
      [],
    )
    == Ok(#("x", creations.Private, creations.default_roles))
  assert create.fields_with_roles([#("name", "x")], offered, [])
    == Ok(#("x", creations.Private, creations.default_roles))
  assert create.typed_fields_with_roles(
      [#("path", "~/app"), #("name", ""), #("profile", "1")],
      offered,
      [],
    )
    == Ok(#(
      "~/app",
      "",
      creations.Private,
      creations.Roles(Some("gemini"), None),
    ))
}

// A model position becomes the offered key, alone or beside a profile.
pub fn a_submitted_position_becomes_the_offered_model_key_test() {
  let models = ["fast", "slow"]
  assert create.fields_with_roles([#("name", "x"), #("model", "1")], [], models)
    == Ok(#("x", creations.Private, creations.Roles(None, Some("slow"))))
  assert create.fields_with_roles(
      [#("model", "0"), #("name", "x"), #("profile", "0")],
      ["deepseek"],
      models,
    )
    == Ok(#(
      "x",
      creations.Private,
      creations.Roles(Some("deepseek"), Some("fast")),
    ))
  assert create.fields_with_roles(
      [#("name", "x"), #("model", "")],
      ["deepseek"],
      models,
    )
    == Ok(#("x", creations.Private, creations.default_roles))
  assert create.typed_fields_with_roles(
      [#("path", "~/app"), #("model", "1"), #("name", "")],
      [],
      models,
    )
    == Ok(#("~/app", "", creations.Private, creations.Roles(None, Some("slow"))))
}

// The browser can choose among the names the page drew and name no other: a
// position past the list, a name where a position goes, a repeat and a profile
// field on a page that offered none are all refused.
pub fn a_profile_the_page_did_not_offer_is_refused_test() {
  let offered = ["deepseek"]
  assert create.fields_with_roles(
      [#("name", "x"), #("profile", "1")],
      offered,
      [],
    )
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("profile", "-1")],
      offered,
      [],
    )
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("profile", "deepseek")],
      offered,
      [],
    )
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("profile", "0"), #("profile", "0")],
      offered,
      [],
    )
    == Error(Nil)
  assert create.fields_with_roles([#("name", "x"), #("profile", "0")], [], [])
    == Error(Nil)
  assert create.typed_fields_with_roles(
      [#("path", "~/a"), #("name", ""), #("profile", "3")],
      offered,
      [],
    )
    == Error(Nil)
}

// The same holds for a model, and a position in one list is never read against
// the other: a profile offered with no models cannot be sent as a model.
pub fn a_model_the_page_did_not_offer_is_refused_test() {
  let models = ["fast"]
  assert create.fields_with_roles([#("name", "x"), #("model", "1")], [], models)
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("model", "-1")],
      [],
      models,
    )
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("model", "fast")],
      [],
      models,
    )
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("model", "0"), #("model", "0")],
      [],
      models,
    )
    == Error(Nil)
  assert create.fields_with_roles(
      [#("name", "x"), #("model", "0")],
      ["deepseek"],
      [],
    )
    == Error(Nil)
  assert create.typed_fields_with_roles(
      [#("path", "~/a"), #("name", ""), #("model", "3")],
      [],
      models,
    )
    == Error(Nil)
}

// A `profile` field of any value, the empty one included, drops the event on a
// page that offered no profiles, as 076 says, and a `model` field does on a page
// that offered no models.
pub fn an_empty_field_is_refused_when_none_were_offered_test() {
  assert create.fields_with_roles([#("name", "x"), #("profile", "")], [], [])
    == Error(Nil)
  assert create.fields_with_roles([#("name", "x"), #("model", "")], [], [])
    == Error(Nil)
  assert create.typed_fields_with_roles(
      [#("path", "~/a"), #("name", ""), #("profile", "")],
      [],
      [],
    )
    == Error(Nil)
  assert create.typed_fields_with_roles(
      [#("path", "~/a"), #("name", ""), #("model", "")],
      [],
      [],
    )
    == Error(Nil)
}
