//// What the home offers for creating a session: nothing, or under each
//// workspace a "New session" button that opens one small form (protocol-change/
//// 065, the fourth pull request), and a control for a folder that holds no
//// session yet (protocol-change/074).
////
//// The home's centre draws the same list for every principal, and only the
//// owner's page that was minted to operate offers this, so the rule for what is
//// drawn is written here once. The offer is the page's half of "the daemon
//// refuses anyone else": a member's or an observer's page has no handler to
//// press, and the daemon refuses a forged event from one all the same
//// (`client/daemon/ui_socket.create_for`).
////
//// The form under a workspace is one name field, one checkbox and two buttons.
//// The name is optional and the box is off, so pressing Create at once makes a
//// private session named for its folder, as the terminal does. The form submits
//// the two fields and nothing else: `fields` accepts exactly one `name` and at
//// most one `shareable`, and refuses the event for any other field or a repeat,
//// as the composer's decoder does. The workspace is not a field there. It is the
//// text the catalogue wrote, carried by the message the server drew into the
//// tree, so the browser's event names only the path it fired at.
////
//// The form for another folder is the one place a workspace is a field. It adds
//// a path to the same name and box, and its decoder (`typed_fields`) is as
//// strict: exactly one `path`, one `name`, at most one `shareable`, and nothing
//// else. The text is the browser's and nothing else is: the daemon decides
//// whether it names a folder the owner may use, and the page words only the
//// refusal, in fixed words. The typed path is never an attribute on the page.
//// The field is uncontrolled and the server never writes it back, so what the
//// owner typed is not echoed even in a refusal.
////
//// While a creation is out the form is drawn disabled with "Creating" on its
//// button, and every other workspace's button has no handler. That is the
//// page's half of "a second press asks nothing", and the component's update
//// and the daemon each refuse a second one as well.
////
//// A name and a workspace are never attributes. The workspace's folder name is
//// said in the form's quiet line as a text node, the input's placeholder is
//// fixed words, and nothing here is a class, a key or an identifier taken from
//// the catalogue.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/creations.{type Sharing, Private, Shareable}

/// Where the person is in making a session.
pub type State {
  /// No form is open.
  Idle

  /// The form under this workspace is open, waiting to be filled and sent.
  Composing(workspace: String)

  /// This workspace's creation is out. The form is drawn disabled until the
  /// answer arrives.
  Waiting(workspace: String)

  /// The form for a folder the owner types is open.
  Elsewhere

  /// The creation for a typed folder is out. The form is drawn disabled until
  /// the answer arrives.
  Sending
}

/// What a page offers for creating a session.
pub type Create(message) {
  /// The page may not create: it is not the owner's, or it was not minted to
  /// operate. Nothing is drawn.
  Never

  /// The page may ask the daemon to create a session. `choose` is the message a
  /// workspace's button sends, given the workspace the group was drawn for;
  /// `submit` is what the form sends, given that workspace, the typed name and
  /// the sharing; `cancel` closes the form; `elsewhere` opens the form for a
  /// typed folder and `submit_elsewhere` is what it sends, given the typed path,
  /// the typed name and the sharing; `state` is where the person is.
  Offered(
    choose: fn(String) -> message,
    submit: fn(String, String, Sharing) -> message,
    cancel: message,
    elsewhere: message,
    submit_elsewhere: fn(String, String, Sharing) -> message,
    state: State,
  )
}

/// The state a memoized view includes in its key, so a group changes when its
/// form opens, closes or starts waiting.
///
/// ## Examples
///
/// ```gleam
/// assert create.state(create.Never) == create.Idle
/// ```
pub fn state(create: Create(message)) -> State {
  case create {
    Never -> Idle
    Offered(state:, ..) -> state
  }
}

/// The button at the head of a workspace's group, or nothing. It has a handler
/// only while no creation is out, so a press cannot start a second.
///
/// ## Examples
///
/// ```gleam
/// // create.button(create, group.workspace)
/// ```
pub fn button(create: Create(message), workspace: String) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(choose:, state:, ..) ->
      opener("New session", state, fn() { choose(workspace) })
  }
}

/// The button that opens the form for a folder the owner types, or nothing. It
/// has a handler only while no creation is out, as a workspace's button does.
///
/// ## Examples
///
/// ```gleam
/// // create.elsewhere_button(create)
/// ```
pub fn elsewhere_button(create: Create(message)) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(elsewhere:, state:, ..) ->
      opener("New session in another folder\u{2026}", state, fn() { elsewhere })
  }
}

// One "New session" button: disabled while a creation is out, otherwise it
// sends the message the page chose.
fn opener(
  words: String,
  state: State,
  press: fn() -> message,
) -> Element(message) {
  let attributes = [
    attribute.type_("button"),
    attribute.class("home-new"),
  ]
  html.button(
    case state {
      Waiting(_) | Sending -> [attribute.disabled(True), ..attributes]
      Idle | Composing(_) | Elsewhere -> [event.on_click(press()), ..attributes]
    },
    [html.text(words)],
  )
}

/// The form under a workspace's heading when it is the one open, and nothing
/// otherwise. The form says in words the name a blank field gets.
///
/// ## Examples
///
/// ```gleam
/// // create.form(create, group.workspace)
/// ```
pub fn form(create: Create(message), workspace: String) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(submit:, cancel:, state:, ..) ->
      case state {
        Composing(open) if open == workspace ->
          drawn(workspace, submit, cancel, Editable)
        Waiting(open) if open == workspace ->
          drawn(workspace, submit, cancel, Locked)
        Idle | Composing(_) | Waiting(_) | Elsewhere | Sending -> element.none()
      }
  }
}

/// The form for a typed folder when it is open, and nothing otherwise. It says
/// in words where a folder may be and what a blank name gets.
///
/// ## Examples
///
/// ```gleam
/// // create.elsewhere_form(create)
/// ```
pub fn elsewhere_form(create: Create(message)) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(submit_elsewhere:, cancel:, state:, ..) ->
      case state {
        Elsewhere -> typed(submit_elsewhere, cancel, Editable)
        Sending -> typed(submit_elsewhere, cancel, Locked)
        Idle | Composing(_) | Waiting(_) -> element.none()
      }
  }
}

// Whether the fields take input: a form whose creation is out is locked.
type Fields {
  Editable
  Locked
}

fn locks(fields: Fields) -> List(attribute.Attribute(message)) {
  case fields {
    Editable -> []
    Locked -> [attribute.disabled(True)]
  }
}

fn drawn(
  workspace: String,
  submit: fn(String, String, Sharing) -> message,
  cancel: message,
  fields: Fields,
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session"),
      event.on("submit", submitted(workspace, submit)) |> event.prevent_default,
    ],
    [
      name_field(fields),
      share_field(fields),

      // The hint names what a blank field gets, so the stylesheet hides it once
      // the field holds a name (`:placeholder-shown`): the field is uncontrolled,
      // and the server never sees what is typed until it is submitted.
      html.p([attribute.class("home-create-hint")], [
        html.text("Left blank, the session is named "),
        html.b([], [html.text(creations.folder(workspace))]),
        html.text("."),
      ]),
      actions(fields, cancel),
    ],
  )
}

// The form for a typed folder: the path first, then the same name and box. The
// name's hint follows the name input, as the stylesheet's sibling rule needs.
fn typed(
  submit: fn(String, String, Sharing) -> message,
  cancel: message,
  fields: Fields,
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session in another folder"),
      event.on("submit", typed_submitted(submit)) |> event.prevent_default,
    ],
    [
      html.input([
        attribute.type_("text"),
        attribute.name("path"),
        attribute.class("home-create-path"),
        attribute.placeholder("Folder path, for example ~/code/app"),
        attribute.aria_label("Folder path"),
        attribute.attribute("maxlength", "4096"),
        attribute.autocomplete("off"),
        attribute.autofocus(True),
        ..locks(fields)
      ]),
      html.p([attribute.class("home-create-hint")], [
        html.text(
          "The folder must already exist inside your home directory. A new session starts there.",
        ),
      ]),
      name_field(fields),
      share_field(fields),
      html.p([attribute.class("home-create-hint")], [
        html.text("Left blank, the session is named for the folder."),
      ]),
      actions(fields, cancel),
    ],
  )
}

fn name_field(fields: Fields) -> Element(message) {
  html.input([
    attribute.type_("text"),
    attribute.name("name"),
    attribute.class("home-create-name"),
    attribute.placeholder("Session name (optional)"),
    attribute.aria_label("Session name"),
    attribute.attribute("maxlength", "256"),
    attribute.autocomplete("off"),
    ..locks(fields)
  ])
}

fn share_field(fields: Fields) -> Element(message) {
  html.label([attribute.class("home-create-share")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.name("shareable"),
      ..locks(fields)
    ]),
    html.span([attribute.class("home-create-share-text")], [
      html.span([attribute.class("home-create-share-name")], [
        html.text("Shareable"),
      ]),
      html.span([attribute.class("home-create-share-hint")], [
        html.text(
          "Keeps its own notes and history, so you can invite people to it.",
        ),
      ]),
    ]),
  ])
}

fn actions(fields: Fields, cancel: message) -> Element(message) {
  html.div([attribute.class("home-create-actions")], [
    html.button(
      [
        attribute.type_("submit"),
        attribute.class("home-create-go"),
        ..locks(fields)
      ],
      [
        html.text(case fields {
          Editable -> "Create session"
          Locked -> "Creating"
        }),
      ],
    ),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-create-cancel"),
        event.on_click(cancel),
        ..locks(fields)
      ],
      [html.text("Cancel")],
    ),
  ])
}

// The event's decoder: the form's fields as the browser lists them, refused
// unless `fields` accepts them. A refused event is dropped by Lustre with no
// message.
fn submitted(
  workspace: String,
  submit: fn(String, String, Sharing) -> message,
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))
  case fields(listed) {
    Ok(#(name, sharing)) -> decode.success(submit(workspace, name, sharing))
    Error(Nil) ->
      decode.failure(submit(workspace, "", Private), "creation form")
  }
}

// The typed form's decoder, refused unless `typed_fields` accepts the list.
fn typed_submitted(
  submit: fn(String, String, Sharing) -> message,
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))
  case typed_fields(listed) {
    Ok(#(path, name, sharing)) -> decode.success(submit(path, name, sharing))
    Error(Nil) -> decode.failure(submit("", "", Private), "folder form")
  }
}

fn field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The name and sharing a submitted form's fields stand for, or a refusal:
/// exactly one `name`, at most one `shareable` whose value is the browser's
/// `on`, and no other field. An unticked box is not sent, so its absence is
/// `Private`.
///
/// ## Examples
///
/// ```gleam
/// assert create.fields([#("name", "review")]) == Ok(#("review", creations.Private))
/// assert create.fields([#("name", ""), #("shareable", "on")])
///   == Ok(#("", creations.Shareable))
/// ```
pub fn fields(
  listed: List(#(String, String)),
) -> Result(#(String, Sharing), Nil) {
  let names = list.filter(listed, fn(field) { field.0 == "name" })
  let boxes = list.filter(listed, fn(field) { field.0 == "shareable" })
  case names, boxes, list.length(listed) {
    [#(_, name)], [], 1 -> Ok(#(name, Private))
    [#(_, name)], [#(_, "on")], 2 -> Ok(#(name, Shareable))
    _, _, _ -> Error(Nil)
  }
}

/// The path, name and sharing a submitted folder form's fields stand for, or a
/// refusal: exactly one `path`, exactly one `name`, at most one `shareable`
/// whose value is the browser's `on`, and no other field. It is `fields` with
/// the path the form adds, and as strict, so the workspace becomes a field in
/// this one form and in no other.
///
/// ## Examples
///
/// ```gleam
/// assert create.typed_fields([#("path", "~/app"), #("name", "")])
///   == Ok(#("~/app", "", creations.Private))
/// assert create.typed_fields([#("path", "~/a"), #("path", "~/b"), #("name", "")])
///   == Error(Nil)
/// ```
pub fn typed_fields(
  listed: List(#(String, String)),
) -> Result(#(String, String, Sharing), Nil) {
  let paths = list.filter(listed, fn(field) { field.0 == "path" })
  let rest = list.filter(listed, fn(field) { field.0 != "path" })
  case paths, fields(rest) {
    [#(_, path)], Ok(#(name, sharing)) -> Ok(#(path, name, sharing))
    _, _ -> Error(Nil)
  }
}

/// The workspace a form is open for, if one is, which the component's update
/// uses to refuse a submit for a form that is not the open one. The typed
/// folder's form is open for no workspace.
///
/// ## Examples
///
/// ```gleam
/// assert create.open_for(create.Composing("/w")) == Some("/w")
/// assert create.open_for(create.Elsewhere) == None
/// ```
pub fn open_for(state: State) -> Option(String) {
  case state {
    Idle | Elsewhere | Sending -> None
    Composing(workspace:) | Waiting(workspace:) -> Some(workspace)
  }
}
