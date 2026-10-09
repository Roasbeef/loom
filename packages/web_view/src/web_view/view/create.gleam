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
//// When the daemon's configuration defines model profiles (protocol-change/076),
//// each form also carries a select of them, with the default roles first. The
//// profile names are the daemon's text and are never an attribute: an option's
//// `value` is its position in the list the page was given, and its label is the
//// name as a text node. The decoder turns the submitted position back into the
//// name from that same list (`fields_with_roles`), so the browser can choose
//// among the names the page drew and name nothing else.
////
//// The same forms carry a second select, of the daemon's `[models.<key>]` keys
//// (protocol-change/080), which pins the session's main model. It is drawn the
//// same way and decoded the same way, from its own list, and it is independent
//// of the profile select: a form may draw either, both or neither. A model key
//// is the owner's text from the configuration and is a text node and a position
//// like a profile name; nothing else about a model is given to the page.
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
//// When the daemon has executors (protocol-change/078), a third form creates a
//// session in a workspace registered on one of them. It is the other place a
//// workspace is a field, and the only one where it is a name and not a path: an
//// executor chosen from a select, the registered name typed into a text field,
//// and the optional session name. There is no Shareable box, because the daemon
//// makes a session on an executor session-only whatever the form says. The
//// executor follows the profile's rule: an option's `value` is its position in
//// the list the page was given, its label is the name as a text node, and the
//// decoder (`remote_fields`) turns the position back into the name from that
//// same list, so the browser can choose among the executors the page drew and
//// name no other. It accepts exactly one `executor`, one `workspace` and one
//// `name`. Without executors the button, the form and the decoder's only
//// possible answer do not exist: a list of none refuses every event.
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
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/creations.{type Roles, type Sharing, Private, Shareable}

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

  /// The form for a workspace registered on an executor is open
  /// (protocol-change/078).
  Remote

  /// The creation for a registered workspace is out. The form is drawn disabled
  /// until the answer arrives.
  Dispatching
}

/// What a page offers for creating a session.
pub type Create(message) {
  /// The page may not create: it is not the owner's, or it was not minted to
  /// operate. Nothing is drawn.
  Never

  /// The page may ask the daemon to create a session. `choose` is the message a
  /// workspace's button sends, given the workspace the group was drawn for;
  /// `submit` is what the form sends, given that workspace, the typed name, the
  /// sharing and the chosen roles; `cancel` closes the
  /// form; `elsewhere` opens the form for a typed folder and `submit_elsewhere`
  /// is what it sends, given the typed path, the typed name, the sharing and the
  /// chosen roles; `state` is where the person is; `profiles` is the profile
  /// names the forms offer beside the default roles, which may be none, and
  /// `models` is the model keys they offer beside the default model, which may
  /// be none. A profile or a model a submit carries is always one of them.
  /// `remote` opens the form for a workspace registered on an executor and
  /// `submit_remote` is what it sends, given the executor, the typed workspace
  /// name and the typed session name; `executors` is the executor names the
  /// daemon gave the page, which may be none, and then the page offers no such
  /// form. The executor a submit carries is always one of them. That form draws
  /// no profile or model select, so a registered session takes the
  /// configuration's roles.
  Offered(
    choose: fn(String) -> message,
    submit: fn(String, String, Sharing, Roles) -> message,
    cancel: message,
    elsewhere: message,
    submit_elsewhere: fn(String, String, Sharing, Roles) -> message,
    state: State,
    profiles: List(String),
    models: List(String),
    remote: message,
    submit_remote: fn(String, String, String) -> message,
    executors: List(String),
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
      Waiting(_) | Sending | Dispatching -> [
        attribute.disabled(True),
        ..attributes
      ]
      Idle | Composing(_) | Elsewhere | Remote -> [
        event.on_click(press()),
        ..attributes
      ]
    },
    [html.text(words)],
  )
}

/// The button that opens the form for a workspace registered on an executor, or
/// nothing when the page may not create or the daemon has no executors to offer.
/// It has a handler only while no creation is out, as the other buttons do.
///
/// ## Examples
///
/// ```gleam
/// // create.remote_button(create)
/// ```
pub fn remote_button(create: Create(message)) -> Element(message) {
  case create {
    Offered(remote:, state:, executors: [_, ..], ..) ->
      opener("New session on an executor\u{2026}", state, fn() { remote })
    Offered(executors: [], ..) | Never -> element.none()
  }
}

/// The form for a registered workspace when it is open, and nothing otherwise.
/// It says in words that the workspace is a name registered on the executor and
/// not a folder on this machine, and what a blank session name gets.
///
/// ## Examples
///
/// ```gleam
/// // create.remote_form(create)
/// ```
pub fn remote_form(create: Create(message)) -> Element(message) {
  case create {
    Never -> element.none()
    Offered(submit_remote:, cancel:, state:, executors:, ..) ->
      case state, executors {
        Remote, [_, ..] ->
          registered(submit_remote, cancel, Editable, executors)
        Dispatching, [_, ..] ->
          registered(submit_remote, cancel, Locked, executors)
        Idle, _
        | Composing(_), _
        | Waiting(_), _
        | Elsewhere, _
        | Sending, _
        | Remote, []
        | Dispatching, []
        -> element.none()
      }
  }
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
    Offered(submit:, cancel:, state:, profiles:, models:, ..) ->
      case state {
        Composing(open) if open == workspace ->
          drawn(workspace, submit, cancel, Editable, profiles, models)
        Waiting(open) if open == workspace ->
          drawn(workspace, submit, cancel, Locked, profiles, models)
        Idle
        | Composing(_)
        | Waiting(_)
        | Elsewhere
        | Sending
        | Remote
        | Dispatching -> element.none()
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
    Offered(submit_elsewhere:, cancel:, state:, profiles:, models:, ..) ->
      case state {
        Elsewhere -> typed(submit_elsewhere, cancel, Editable, profiles, models)
        Sending -> typed(submit_elsewhere, cancel, Locked, profiles, models)
        Idle | Composing(_) | Waiting(_) | Remote | Dispatching ->
          element.none()
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
  submit: fn(String, String, Sharing, Roles) -> message,
  cancel: message,
  fields: Fields,
  profiles: List(String),
  models: List(String),
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session"),
      event.on("submit", submitted(workspace, submit, profiles, models))
        |> event.prevent_default,
    ],
    [
      name_field(fields),
      share_field(fields),
      profile_field(fields, profiles),
      model_field(fields, models),

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
  submit: fn(String, String, Sharing, Roles) -> message,
  cancel: message,
  fields: Fields,
  profiles: List(String),
  models: List(String),
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session in another folder"),
      event.on("submit", typed_submitted(submit, profiles, models))
        |> event.prevent_default,
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
      profile_field(fields, profiles),
      model_field(fields, models),
      html.p([attribute.class("home-create-hint")], [
        html.text("Left blank, the session is named for the folder."),
      ]),
      actions(fields, cancel),
    ],
  )
}

// The form for a workspace registered on an executor: which executor, the name
// the workspace is registered under there, and the optional session name. There
// is no Shareable box, because the daemon makes a session on an executor
// session-only (its workspace aggregate is keyed by a path on the daemon's
// host), which is what Shareable asks for. The executor is a select whose option
// values are positions in the list the page was given and whose labels are the
// names as text nodes, so no executor name is ever an attribute, and the
// decoder turns the position back into the name from that same list.
fn registered(
  submit: fn(String, String, String) -> message,
  cancel: message,
  fields: Fields,
  executors: List(String),
) -> Element(message) {
  html.form(
    [
      attribute.class("home-create"),
      attribute.aria_label("New session on an executor"),
      event.on("submit", remote_submitted(submit, executors))
        |> event.prevent_default,
    ],
    [
      html.label([attribute.class("home-create-profile")], [
        html.span([attribute.class("home-create-profile-name")], [
          html.text("Executor"),
        ]),
        html.select(
          [
            attribute.name("executor"),
            attribute.class("home-create-profile-select"),
            attribute.aria_label("Executor"),
            ..locks(fields)
          ],
          list.index_map(executors, fn(name, position) {
            html.option([attribute.value(int.to_string(position))], name)
          }),
        ),
      ]),
      html.input([
        attribute.type_("text"),
        attribute.name("workspace"),
        attribute.class("home-create-path"),
        attribute.placeholder("Registered workspace name, for example app"),
        attribute.aria_label("Workspace name"),
        attribute.attribute("maxlength", "128"),
        attribute.autocomplete("off"),
        attribute.autofocus(True),
        ..locks(fields)
      ]),
      html.p([attribute.class("home-create-hint")], [
        html.text(
          "The name the workspace is registered under on that executor. It is a name, not a folder: the daemon does not look for it on this machine.",
        ),
      ]),
      name_field(fields),
      html.p([attribute.class("home-create-hint")], [
        html.text("Left blank, the session is named for the workspace."),
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

// The select of model profiles, or nothing when the configuration defines none.
fn profile_field(fields: Fields, profiles: List(String)) -> Element(message) {
  chooser(fields, "profile", "Model profile", profiles)
}

// The select of the daemon's model keys, or nothing when there are none. It
// pins the session's main model (protocol-change/080).
fn model_field(fields: Fields, models: List(String)) -> Element(message) {
  chooser(fields, "model", "Main model", models)
}

// A labelled select of text the daemon supplied, or nothing when it supplied
// none. The first option is the default and has the empty value. Each other
// option's value is its position in `offered`, and its label is the text as a
// text node, so no name or key is ever an attribute. The profile and model rows
// share the stylesheet's `home-create-profile` classes, which style any labelled
// select in this form.
fn chooser(
  fields: Fields,
  field_name: String,
  label: String,
  offered: List(String),
) -> Element(message) {
  case offered {
    [] -> element.none()
    _ ->
      html.label([attribute.class("home-create-profile")], [
        html.span([attribute.class("home-create-profile-name")], [
          html.text(label),
        ]),
        html.select(
          [
            attribute.name(field_name),
            attribute.class("home-create-profile-select"),
            attribute.aria_label(label),
            ..locks(fields)
          ],
          [
            html.option([attribute.value("")], "Default"),
            ..list.index_map(offered, fn(text, position) {
              html.option([attribute.value(int.to_string(position))], text)
            })
          ],
        ),
      ])
  }
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
// unless `fields_with_roles` accepts them. A refused event is dropped by Lustre
// with no message.
fn submitted(
  workspace: String,
  submit: fn(String, String, Sharing, Roles) -> message,
  profiles: List(String),
  models: List(String),
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))
  case fields_with_roles(listed, profiles, models) {
    Ok(#(name, sharing, roles)) ->
      decode.success(submit(workspace, name, sharing, roles))
    Error(Nil) ->
      decode.failure(
        submit(workspace, "", Private, creations.default_roles),
        "creation form",
      )
  }
}

// The typed form's decoder, refused unless `typed_fields_with_roles` accepts
// the list.
fn typed_submitted(
  submit: fn(String, String, Sharing, Roles) -> message,
  profiles: List(String),
  models: List(String),
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))
  case typed_fields_with_roles(listed, profiles, models) {
    Ok(#(path, name, sharing, roles)) ->
      decode.success(submit(path, name, sharing, roles))
    Error(Nil) ->
      decode.failure(
        submit("", "", Private, creations.default_roles),
        "folder form",
      )
  }
}

// The registered-workspace form's decoder, refused unless `remote_fields`
// accepts the list.
fn remote_submitted(
  submit: fn(String, String, String) -> message,
  executors: List(String),
) -> decode.Decoder(message) {
  use listed <- decode.subfield(["detail", "formData"], decode.list(field()))
  case remote_fields(listed, executors) {
    Ok(#(executor, workspace, name)) ->
      decode.success(submit(executor, workspace, name))
    Error(Nil) -> decode.failure(submit("", "", ""), "executor form")
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

/// The name, sharing and roles a submitted form's fields stand for, given the
/// profile names and model keys the form offered: `fields`, plus at most one
/// `profile` and at most one `model`, each of whose value is the empty string
/// (the default) or the position of one of the matching list, which is turned
/// back into the name or key here. A `profile` field when no profiles were
/// offered (likewise `model`), a position outside its list and any other text
/// refuse the event, so the browser can pick among the texts the page drew and
/// name no other.
///
/// ## Examples
///
/// ```gleam
/// assert create.fields_with_roles(
///     [#("name", "x"), #("profile", "1"), #("model", "0")],
///     ["a", "b"],
///     ["fast"],
///   )
///   == Ok(#("x", creations.Private, creations.Roles(Some("b"), Some("fast"))))
/// assert create.fields_with_roles([#("name", "x"), #("profile", "")], ["a"], [])
///   == Ok(#("x", creations.Private, creations.default_roles))
/// assert create.fields_with_roles([#("name", "x"), #("model", "2")], [], ["a"])
///   == Error(Nil)
/// ```
pub fn fields_with_roles(
  listed: List(#(String, String)),
  profiles: List(String),
  models: List(String),
) -> Result(#(String, Sharing, Roles), Nil) {
  use #(rest, roles) <- result.try(chosen_roles(listed, profiles, models))
  use #(name, sharing) <- result.map(fields(rest))
  #(name, sharing, roles)
}

/// The path, name, sharing and roles a submitted folder form's fields stand
/// for: `typed_fields` with the roles `fields_with_roles` reads.
///
/// ## Examples
///
/// ```gleam
/// assert create.typed_fields_with_roles(
///     [#("path", "~/app"), #("name", ""), #("profile", "0")],
///     ["a"],
///     [],
///   )
///   == Ok(#("~/app", "", creations.Private, creations.Roles(Some("a"), None)))
/// ```
pub fn typed_fields_with_roles(
  listed: List(#(String, String)),
  profiles: List(String),
  models: List(String),
) -> Result(#(String, String, Sharing, Roles), Nil) {
  use #(rest, roles) <- result.try(chosen_roles(listed, profiles, models))
  use #(path, name, sharing) <- result.map(typed_fields(rest))
  #(path, name, sharing, roles)
}

// Splits the `profile` and `model` entries from a form's fields and reads each
// against its own offered list. What remains is the fields the older decoders
// judge, so they stay as strict as they were.
fn chosen_roles(
  listed: List(#(String, String)),
  profiles: List(String),
  models: List(String),
) -> Result(#(List(#(String, String)), Roles), Nil) {
  let rest =
    list.filter(listed, fn(field) { field.0 != "profile" && field.0 != "model" })
  use profile <- result.try(chosen(
    list.filter(listed, fn(field) { field.0 == "profile" }),
    profiles,
  ))
  use model <- result.map(chosen(
    list.filter(listed, fn(field) { field.0 == "model" }),
    models,
  ))
  #(rest, creations.Roles(profile:, model:))
}

// The text a form's entries for one select choose: none sent is the default, one
// with an empty value is the default, and one whose value is the position of an
// offered text is that text. Two entries, or any other value, is a refusal, and
// so is any entry at all when nothing was offered.
fn chosen(
  entries: List(#(String, String)),
  offered: List(String),
) -> Result(Option(String), Nil) {
  case entries {
    [] -> Ok(None)
    [#(_, "")] if offered != [] -> Ok(None)
    [#(_, position)] ->
      case int.parse(position) {
        Ok(index) if index >= 0 ->
          list.drop(offered, index)
          |> list.first
          |> result.map(Some)
        Ok(_) | Error(Nil) -> Error(Nil)
      }
    [_, _, ..] -> Error(Nil)
  }
}

/// The executor, workspace name and session name a submitted registered-
/// workspace form's fields stand for, given the executor names the form offered:
/// exactly one `executor` whose value is the position of one of `executors`,
/// which is turned back into the name here, exactly one `workspace`, exactly one
/// `name`, and no other field. A position past the list, a negative or
/// non-numeric one, a name where a position goes, a repeat and a missing field
/// all refuse the event, so the browser can choose among the executors the page
/// drew and name no other. The workspace and the session name are the browser's
/// text and nothing else is: the daemon judges both again.
///
/// ## Examples
///
/// ```gleam
/// assert create.remote_fields(
///     [#("executor", "1"), #("workspace", "app"), #("name", "")],
///     ["a", "b"],
///   )
///   == Ok(#("b", "app", ""))
/// assert create.remote_fields(
///     [#("executor", "2"), #("workspace", "app"), #("name", "")],
///     ["a", "b"],
///   )
///   == Error(Nil)
/// ```
pub fn remote_fields(
  listed: List(#(String, String)),
  executors: List(String),
) -> Result(#(String, String, String), Nil) {
  let chosen = list.filter(listed, fn(field) { field.0 == "executor" })
  let workspaces = list.filter(listed, fn(field) { field.0 == "workspace" })
  let names = list.filter(listed, fn(field) { field.0 == "name" })
  case chosen, workspaces, names, list.length(listed) {
    [#(_, position)], [#(_, workspace)], [#(_, name)], 3 ->
      case int.parse(position) {
        Ok(index) if index >= 0 ->
          list.drop(executors, index)
          |> list.first
          |> result.map(fn(executor) { #(executor, workspace, name) })
        Ok(_) | Error(Nil) -> Error(Nil)
      }
    _, _, _, _ -> Error(Nil)
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
    Idle | Elsewhere | Sending | Remote | Dispatching -> None
    Composing(workspace:) | Waiting(workspace:) -> Some(workspace)
  }
}
