//// The owner's page for making a project (protocol-change/106, the addendum on
//// creating a project from the web view).
////
//// The page is the centre while a project is being made, and it draws the step
//// `web_view/project_create` holds: a list of folders to choose from and a
//// field for another folder, then the check and setup the daemon proposes for
//// the folder with the reason beside each, in two boxes the owner may edit, and
//// last the project that was made. It decides nothing. Every button carries a
//// message the server built, and each form accepts exactly the fields it was
//// drawn with, so a browser event can name only a folder, a check and a setup.
////
//// ## What is drawn
////
//// A folder's path, a proposal's command and its reason are text nodes. A path
//// is also the text of its button and never an attribute, a class or a key. The
//// two command boxes are given the proposal as their initial value, which Lustre
//// escapes as an attribute value, and nothing in this page is built into an
//// address. The classes are fixed words from the home's stylesheet.
////
//// ## Flow
////
//// `view` → `choosing` → `reviewing` → `done`
////
//// 1. `view` draws the heading, a way back, and the step.
//// 2. `choosing` draws the folders and the field for another one.
//// 3. `reviewing` draws the proposal, the two boxes and the Create button.
//// 4. `done` says what was made and what was not stored.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/project_settings_view as settings
import web_view/creations
import web_view/project_create.{type Creation}

/// What the page is given to draw.
pub type Offer(message) {
  Offer(
    /// The step the owner is at.
    creation: Creation,
    /// The folders the page's own lists drew, as the page offers them: the
    /// owner's recent folders and the folders of the sessions it lists, without
    /// those that already hold a project.
    folders: List(String),
    /// The message a folder's button sends, given the folder.
    chose: fn(String) -> message,
    /// The message the field for another folder sends, given the typed path.
    typed: fn(String) -> message,
    /// The message the Create form sends, given the check and the setup.
    confirm: fn(String, String) -> message,
    /// The message that closes the page.
    back: message,
  )
}

/// The page.
///
/// ## Examples
///
/// ```gleam
/// // project_create_view.view(offer)
/// ```
pub fn view(offer: Offer(message)) -> Element(message) {
  html.section(
    [
      attribute.class("home-group"),
      attribute.class("home-project-create"),
      attribute.aria_label("New project"),
    ],
    [
      html.div([attribute.class("home-group-head")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("home-new"),
            event.on_click(offer.back),
          ],
          [html.text(back_words(offer.creation))],
        ),
        html.h3([attribute.class("home-workspace")], [
          html.text("New project"),
        ]),
      ]),
      ..step(offer)
    ],
  )
}

/// The back button says what it does: it leaves a finished page as "Done", and
/// abandons any other as "Cancel". Nothing has been made before the last step.
fn back_words(creation: Creation) -> String {
  case creation.step {
    project_create.Done(..) -> "Done"
    project_create.Choosing(_)
    | project_create.Reading(_)
    | project_create.Reviewing(..)
    | project_create.Creating(..) -> "Cancel"
  }
}

/// The step's body.
fn step(offer: Offer(message)) -> List(Element(message)) {
  case offer.creation.step {
    project_create.Choosing(notice:) -> choosing(offer, notice)
    project_create.Reading(workspace:) -> [
      html.p([attribute.class("home-card-fact")], [html.text(workspace)]),
      html.p([attribute.class("home-empty")], [
        html.text("Reading the folder for a proposal. Nothing is run."),
      ]),
    ]
    project_create.Reviewing(workspace:, proposed:, check:, setup:, notice:) ->
      reviewing(offer, workspace, proposed, check, setup, notice, Ready)
    project_create.Creating(workspace:, proposed:, check:, setup:) ->
      reviewing(offer, workspace, proposed, check, setup, None, Sending)
    project_create.Done(project:, workspace:, unsettled:) ->
      done(project, workspace, unsettled)
  }
}

// Whether the confirmation can be sent.
type Progress {
  Ready
  Sending
}

/// The choice of a folder: what the page offers, one button each, and a field
/// for a folder it does not list.
fn choosing(
  offer: Offer(message),
  notice: Option(String),
) -> List(Element(message)) {
  list.flatten([
    [
      html.p([attribute.class("home-card-fact")], [
        html.text(
          "A project is one long-lived router for one repository. Choose the folder it is for.",
        ),
      ]),
    ],
    refusal(notice),
    case offer.folders {
      [] -> [
        html.p([attribute.class("home-empty")], [
          html.text("No folder is listed yet. Type the path of one below."),
        ]),
      ]
      found -> [
        keyed.ul(
          [attribute.class("home-list")],
          list.index_map(found, fn(path, index) {
            #("f" <> int.to_string(index), folder_row(offer, path))
          }),
        ),
      ]
    },
    [typed_form(offer)],
  ])
}

/// One folder as a button: its whole path as text.
fn folder_row(offer: Offer(message), path: String) -> Element(message) {
  html.li([attribute.class("home-folder")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-ticket"),
        event.on_click(offer.chose(path)),
      ],
      [
        html.span([attribute.class("home-folder-name")], [
          html.text(creations.folder(path)),
        ]),
        html.span([attribute.class("home-folder-path")], [html.text(path)]),
      ],
    ),
  ])
}

/// The field for a folder the page does not list. The daemon judges the path as
/// it judges a new session's, and an uncontrolled box is never written back.
fn typed_form(offer: Offer(message)) -> Element(message) {
  html.form(
    [
      attribute.class("place-composer"),
      event.on("submit", one_field("folder", offer.typed))
        |> event.prevent_default,
    ],
    [
      html.input([
        attribute.type_("text"),
        attribute.name("folder"),
        attribute.class("composer-typed"),
        attribute.aria_label("Another folder"),
        attribute.placeholder("Another folder, such as ~/src/app"),
        attribute.attribute("maxlength", "4096"),
        attribute.autocomplete("off"),
      ]),
      html.div([attribute.class("cbar")], [
        html.button([attribute.type_("submit"), attribute.class("place-send")], [
          html.text("Use this folder"),
        ]),
      ]),
    ],
  )
}

/// The proposal and the form that confirms it. The two boxes start as the
/// daemon's commands, each with its reason beneath, and a blank box stores
/// nothing for that key. While the daemon is making the project the form is
/// disabled and keeps what was sent.
fn reviewing(
  offer: Offer(message),
  workspace: String,
  proposed: settings.Proposed,
  check: String,
  setup: String,
  notice: Option(String),
  standing: Progress,
) -> List(Element(message)) {
  let out = standing == Sending

  list.flatten([
    [
      html.p([attribute.class("home-folder-path")], [html.text("FOLDER")]),
      html.p([attribute.class("home-card-fact")], [html.text(workspace)]),
      html.p([attribute.class("home-card-fact")], [
        html.text(
          "These are proposals read from the folder's own files. Nothing has been run and nothing is stored until you create the project.",
        ),
      ]),
    ],
    refusal(notice),
    [
      keyed.div([], [
        #(
          "confirm",
          html.form(
            [
              attribute.class("place-composer"),
              event.on("submit", two_fields(offer.confirm))
                |> event.prevent_default,
            ],
            [
              command_box("check", "Check", check, proposed.check),
              command_box("setup", "Setup", setup, proposed.setup),
              html.div([attribute.class("cbar")], [
                html.button(
                  [
                    attribute.type_("submit"),
                    attribute.class("place-send"),
                    attribute.disabled(out),
                  ],
                  [
                    html.text(case standing {
                      Sending -> "Creating"
                      Ready -> "Create project"
                    }),
                  ],
                ),
              ]),
            ],
          ),
        ),
      ]),
    ],
    notes(proposed.notes),
  ])
}

/// One command's label, its box and the reason the daemon gave for it. A key the
/// daemon had no proposal for says so, and its box is empty.
fn command_box(
  name: String,
  label: String,
  value: String,
  found: Option(settings.Suggestion),
) -> Element(message) {
  html.div([], [
    html.p([attribute.class("home-folder-path")], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.name(name),
      attribute.class("composer-typed"),
      attribute.aria_label(label),
      attribute.value(value),
      attribute.placeholder("None"),
      attribute.attribute(
        "maxlength",
        int.to_string(project_create.command_limit),
      ),
      attribute.autocomplete("off"),
    ]),
    html.p([attribute.class("home-empty")], [
      html.text(case found {
        Some(suggestion) -> "Proposed because " <> suggestion.because
        None ->
          "Nothing in the folder suggests one. Leave it blank to set none."
      }),
    ]),
  ])
}

/// The files the daemon saw and did not read, each as a line.
fn notes(found: List(String)) -> List(Element(message)) {
  list.map(found, fn(each) {
    html.p([attribute.class("home-empty home-source-note")], [html.text(each)])
  })
}

/// A refusal, in the danger colour and kept until the next step.
fn refusal(notice: Option(String)) -> List(Element(message)) {
  case notice {
    None -> []
    Some(words) -> [
      html.p([attribute.class("home-note"), attribute.class("refused")], [
        html.text(words),
      ]),
    ]
  }
}

/// What was made. A project that was made while its settings were refused is
/// drawn as made, with the refusal under it.
fn done(
  project: String,
  workspace: String,
  unsettled: Option(String),
) -> List(Element(message)) {
  list.flatten([
    [
      html.p([attribute.class("home-note")], [
        html.text("Project created for " <> workspace <> "."),
      ]),
      html.p([attribute.class("home-folder-path")], [html.text(project)]),
    ],
    case unsettled {
      Some(words) -> [
        html.p([attribute.class("home-note"), attribute.class("refused")], [
          html.text("The settings were not stored: " <> words),
        ]),
      ]
      None -> []
    },
  ])
}

/// A submit as the message that carries its one field. Any other field, a
/// repeated one or a missing one refuses the event.
fn one_field(
  name: String,
  make: fn(String) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The form has exactly one field, so anything else is a forged event.
  case fields {
    [#(found, text)] if found == name -> decode.success(make(text))
    _ -> decode.failure(make(""), "folder form")
  }
}

/// The confirmation's submit: the check, then the setup, and nothing else.
fn two_fields(make: fn(String, String) -> message) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The form has exactly these two fields, in this order.
  case fields {
    [#("check", check), #("setup", setup)] -> decode.success(make(check, setup))
    _ -> decode.failure(make("", ""), "project form")
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}
