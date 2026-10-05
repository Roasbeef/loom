//// The home page's "Your name" control: one small form in the account panel
//// that changes the page's principal's display name (protocol-change/065, the
//// tenth pull request).
////
//// The person's name in the bar opens the account panel, and the control is the
//// panel's first region, above the sign-ins. It is a lead that says what the
//// name is for and shows the current one, one text field and a submit button.
//// The browser owns the text as the person types, and one submit carries it to
//// the server, where its fields are decoded totally and anything but one field
//// named `text` refuses the event (`web_view/home`). Nothing else about the
//// rename is chosen on the page: not the principal, and not whether the page
//// may. The daemon decides both when it is asked
//// (`client/daemon/ui_socket.rename_self_for`).
////
//// The current name is drawn as a text node in the lead, and never as the
//// field's `value` or `placeholder`, because those are attributes and a name is
//// peer text the page does not put in one. A field that opens empty makes a
//// one-letter fix cost the whole name, so the field sits in a `<loom-rename>`
//// element (`web_client/rename`) that copies the lead's text into it in the
//// browser, when the form is drawn. The server's markup carries two fixed,
//// valueless markers for that and nothing taken from the name
//// (`view/rename.scope_marker` and `view/rename.name_marker`, the ones the
//// session rename and the home's row rename use). The form is keyed by how many
//// renames succeeded, so a successful one is replaced by a form that opens on
//// the new name and a refused one stays as the person left it.
////
//// The control is drawn only for a page the daemon handed the capability, which
//// is every page minted to operate; a read-only link draws nothing in its
//// place. The words of a refusal are fixed (`web_view/names`). The module takes
//// the submit handler as a value, because `web_view/home` owns the message type
//// and imports this module.

import gleam/int
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import web_view/names.{type Control}
import web_view/view/rename

/// What the page offers for renaming its principal.
pub type Offer(message) {
  /// No control is drawn: the page is a read-only link, or the daemon handed it
  /// no capability. The daemon refuses a forged submit too.
  Withheld

  /// The control is drawn. `control` says where it stands, `named` is how many
  /// renames have succeeded, which keys the form, and `submit` is the form's
  /// handler.
  Offered(control: Control, named: Int, submit: Attribute(message))
}

/// The control: nothing for a page that cannot rename, and the lead, the form
/// and the status line for any other. `name` is the display name the page last
/// knew.
///
/// ## Examples
///
/// ```gleam
/// // your_name.view("Alex", your_name.Offered(names.Ready, 0, submit))
/// ```
pub fn view(name: String, offer: Offer(message)) -> Element(message) {
  case offer {
    Withheld -> element.none()
    Offered(control:, named:, submit:) ->
      html.div(
        [
          attribute.class("yourname"),
          attribute.attribute(rename.scope_marker, ""),
        ],
        [
          html.h2([attribute.class("home-heading")], [html.text("Your name")]),
          html.p([attribute.class("yourname-lead")], [
            html.text("Shown to the people you share sessions with. Now: "),
            html.span([attribute.attribute(rename.name_marker, "")], [
              html.text(name),
            ]),
          ]),
          keyed.div([attribute.class("yourname-forms")], [
            #("name-" <> int.to_string(named), form(control, submit)),
          ]),
          status(control),
        ],
      )
  }
}

// The form: the field in its `<loom-rename>` wrapper and the submit button.
// While a request is with the daemon the button is disabled, though the form
// keeps its handler: a submit meanwhile is ignored by the component, which is
// the layer that holds.
fn form(control: Control, submit: Attribute(message)) -> Element(message) {
  let asking = case control {
    names.Asking -> [attribute.disabled(True)]
    names.Ready | names.Done | names.Refused(..) -> []
  }
  html.form(
    [
      attribute.class("yourname-form"),
      attribute.aria_label("Your name"),
      submit,
    ],
    [
      rename.field(),
      html.button([attribute.type_("submit"), ..asking], [html.text("Rename")]),
    ],
  )
}

// The status line: empty except after an answer, so the region's children keep
// their places. A refusal is in the reason's fixed words.
fn status(control: Control) -> Element(message) {
  case control {
    names.Refused(reason:) ->
      html.p(
        [
          attribute.class("rename-status"),
          attribute.class("refused"),
          attribute.role("status"),
        ],
        [html.text(names.reason_words(reason))],
      )
    names.Done ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [
        html.text("Renamed."),
      ])
    names.Ready | names.Asking ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [])
  }
}
