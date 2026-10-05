//// The Session tab's rename control, drawn on an owner's page only
//// (protocol-change/067).
////
//// The control is one small form under the Session pane's other controls: a
//// disclosure whose summary says "Rename", holding one text field and a submit
//// button. The browser owns the text as the owner types, and one submit carries
//// it to the server, where its fields are decoded totally and anything but one
//// field named `text` refuses the event (`web_view/operator_page`). Nothing
//// else about the rename is chosen on the page: not the session, not the
//// principal, and not whether the owner may. The daemon decides all three when
//// it is asked (`client/daemon/ui_socket.rename_for`).
////
//// The region is the Session pane's last child, so its handler's path is
//// beneath `component.rename_path` whichever state it is in, and the page
//// socket admits a submit there only for an owner. A page whose principal
//// cannot rename draws `element.none()` in the same place, so no other path
//// moves. The form is keyed by how many renames succeeded, so a successful
//// one is replaced by a closed empty form and a refused one stays as the owner
//// left it.
////
//// The session's current name is drawn as a text node in the region's lead,
//// and never as the field's `value` or `placeholder`, because those are
//// attributes and a name is text the page does not put in one. A field that
//// opens empty makes a one-letter fix cost the whole name, so the field sits in
//// a `<loom-rename>` element (`web_client/rename`) that copies the lead's text
//// into it in the browser, when the form is drawn. The server's markup carries
//// two fixed, valueless markers for that and nothing taken from the name:
//// `scope_marker` on the container that holds both the lead and the field, and
//// `name_marker` on the element whose text node is the name. The words of a
//// refusal are fixed (`web_view/renames`). The module takes the submit handler
//// as a value, because `web_view/operator_page` owns the message type and
//// imports this module.

import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import web_view/renames.{type Control}

/// The fixed, valueless attribute that marks the container holding both the
/// name's text node and the rename field. `<loom-rename>` looks for the name
/// inside the nearest ancestor that carries it.
///
/// ## Examples
///
/// ```gleam
/// assert rename.scope_marker == "data-loom-renames"
/// ```
pub const scope_marker = "data-loom-renames"

/// The fixed, valueless attribute that marks the element whose text node is
/// the session's current name, the text `<loom-rename>` copies.
///
/// ## Examples
///
/// ```gleam
/// assert rename.name_marker == "data-loom-name"
/// ```
pub const name_marker = "data-loom-name"

/// The rename text field in its `<loom-rename>` wrapper. The field carries no
/// `value` and no `placeholder` drawn from the name; the wrapper copies the
/// current name into it in the browser when it appears. The wrapper is the
/// field's only parent, so no sibling's position moves and the form's handler
/// paths are as they were.
///
/// ## Examples
///
/// ```gleam
/// // rename.field()
/// ```
pub fn field() -> Element(message) {
  element.element("loom-rename", [], [
    html.input([
      attribute.type_("text"),
      attribute.name("text"),
      attribute.aria_label("New name"),
      attribute.placeholder("New name"),
      attribute.attribute("maxlength", "256"),
      attribute.attribute("autocomplete", "off"),
    ]),
  ])
}

/// The control for the page's `control` state: nothing for a page that cannot
/// rename, and the form, its status line and the session's current name for any
/// other state. `current` is the display name the page last knew, if it has
/// one, and `renamed` is how many renames have succeeded, which keys the form.
///
/// ## Examples
///
/// ```gleam
/// // rename.view(renames.Ready, Some("review auth"), 0, submit)
/// ```
pub fn view(
  control: Control,
  current: Option(String),
  renamed: Int,
  submit: Attribute(message),
) -> Element(message) {
  case control {
    renames.Withheld -> element.none()
    renames.Ready | renames.Asking | renames.Done | renames.Refused(..) ->
      html.section(
        [
          attribute.class("controls"),
          attribute.aria_label("Rename this session"),
          attribute.attribute(scope_marker, ""),
        ],
        [
          lead(current),
          keyed.div([attribute.class("control-forms")], [
            #("rename-" <> int.to_string(renamed), form(control, submit)),
          ]),
          status(control),
        ],
      )
  }
}

// The lead's words. The name is a text node: a catalogue field, drawn as text
// and never as an attribute.
fn lead(current: Option(String)) -> Element(message) {
  html.p([attribute.class("control-goal-text")], case current {
    Some(name) -> [
      html.text("Name: "),
      html.span([attribute.attribute(name_marker, "")], [html.text(name)]),
    ]
    None -> [html.text("This session has no name yet.")]
  })
}

// The disclosure and its form. While a request is with the daemon the button is
// disabled, though the form keeps its handler: a submit meanwhile is ignored by
// the component, which is the layer that holds.
fn form(control: Control, submit: Attribute(message)) -> Element(message) {
  let asking = case control {
    renames.Asking -> [attribute.disabled(True)]
    renames.Withheld | renames.Ready | renames.Done | renames.Refused(..) -> []
  }
  html.details([attribute.class("control-form")], [
    html.summary([], [html.text("Rename")]),
    html.form(
      [
        attribute.class("control-input"),
        attribute.class("control-rename"),
        submit,
      ],
      [
        field(),
        html.button([attribute.type_("submit"), ..asking], [html.text("Rename")]),
      ],
    ),
  ])
}

// The status line: empty except after an answer, so the region's children keep
// their places. A refusal is in the reason's fixed words.
fn status(control: Control) -> Element(message) {
  case control {
    renames.Refused(reason:) ->
      html.p(
        [
          attribute.class("rename-status"),
          attribute.class("refused"),
          attribute.role("status"),
        ],
        [html.text(renames.reason_words(reason))],
      )
    renames.Done ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [
        html.text("Renamed."),
      ])
    renames.Withheld | renames.Ready | renames.Asking ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [])
  }
}
