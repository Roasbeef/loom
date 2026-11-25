//// The owner's "Get started" page and the first-session hint
//// (docs/design-notes/setup-wizard.md).
////
//// The page is the centre while the rail's "Get started" entry is open. It
//// opens with one status line that has no actions, then five steps, each with a
//// state word and one sentence. Only the project step has a button, because it
//// is the only step this page can do; the others say what to do from a terminal.
//// The hint is one line above the inbox that suggests the project step after a
//// first session.
////
//// ## What is drawn
////
//// Every word is a fixed word of the page, except a folder's path and a model's
//// key, which are text nodes. Nothing is built into an attribute, a class or an
//// address from either, and the classes are fixed words from the home's
//// stylesheet. The page uses the home's tinted boxes with a hairline border,
//// with no left accent bar and no shadow.
////
//// ## Flow
////
//// `view` → `step_row`, and `hint`
////
//// 1. `view` draws the heading, the status line and a `step_row` for each step.
//// 2. `hint` draws the one-line suggestion and its two buttons.

import gleam/list
import gleam/option.{type Option, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/get_started.{type Step}

/// What the page is given to draw.
pub type Offer(message) {
  Offer(
    /// The status line's heading: whether the page's connection to the daemon
    /// stands.
    heading: String,
    /// The status line's words, from `get_started.model_words`.
    status: String,
    /// The steps, from `get_started.checklist`.
    steps: List(Step),
    /// The message the project step's button sends, or none on a page that may
    /// not make a project.
    new_project: Option(message),
    /// The message a step's "Skip" sends, given the step.
    skip: fn(get_started.Key) -> message,
    /// The message that closes the page.
    back: message,
  )
}

/// The page.
///
/// ## Examples
///
/// ```gleam
/// // get_started_view.view(offer)
/// ```
pub fn view(offer: Offer(message)) -> Element(message) {
  html.section(
    [
      attribute.class("home-group"),
      attribute.aria_label("Get started"),
    ],
    [
      html.div([attribute.class("home-group-head")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("home-new"),
            event.on_click(offer.back),
          ],
          [html.text("Done")],
        ),
        html.h3([attribute.class("home-workspace")], [
          html.text("Get started"),
        ]),
      ]),
      html.p([attribute.class("home-empty")], [
        html.text(
          "Each step shows what this daemon already has. Nothing is written from this page.",
        ),
      ]),
      html.div([attribute.class("setup-note"), attribute.role("note")], [
        html.p([attribute.class("setup-title")], [html.text(offer.heading)]),
        html.p([], [html.text(offer.status)]),
      ]),
      ..list.map(offer.steps, step_row(_, offer.new_project, offer.skip))
    ],
  )
}

/// One step: its name and state word, its sentence, and the project step's
/// button while the step is open.
fn step_row(
  step: Step,
  new_project: Option(message),
  skip: fn(get_started.Key) -> message,
) -> Element(message) {
  html.div([attribute.class("home-project")], [
    html.div([attribute.class("home-group-head")], [
      html.span([attribute.class("home-folder-name")], [html.text(step.title)]),
      html.span([attribute.class("home-empty")], [
        html.text(state_words(step.state)),
      ]),
    ]),
    html.p([attribute.class("home-empty")], [html.text(step.detail)]),
    case step.key, step.state, new_project {
      get_started.FirstProject, get_started.Open, Some(press) ->
        button("home-new", press, "New project")
      get_started.Folder, _, _
      | get_started.Worktree, _, _
      | get_started.FirstProject, _, _
      | get_started.Publish, _, _
      | get_started.Extras, _, _
      -> element.none()
    },
    case get_started.skippable(step) {
      True -> button("link-button", skip(step.key), "Skip")
      False -> element.none()
    },
  ])
}

/// A button with a fixed class and words.
fn button(class: String, press: message, words: String) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      event.on_click(press),
    ],
    [html.text(words)],
  )
}

/// The state word beside a step's name.
fn state_words(state: get_started.State) -> String {
  case state {
    get_started.Done -> "done"
    get_started.Open -> "not done"
    get_started.NotHere -> "not on this page"
    get_started.Unread -> "not read here yet"
    get_started.Skipped -> "skipped"
  }
}

/// The first-session hint: one line and the two buttons that answer it.
///
/// ## Examples
///
/// ```gleam
/// // get_started_view.hint(open, dismiss)
/// ```
pub fn hint(open: message, dismiss: message) -> Element(message) {
  html.div([attribute.class("setup-note"), attribute.role("note")], [
    html.p([], [
      html.text(
        "Loom can also route a repository's work as tickets. Set up a project.",
      ),
    ]),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("home-new"),
        event.on_click(open),
      ],
      [html.text("Get started")],
    ),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("link-button"),
        event.on_click(dismiss),
      ],
      [html.text("Not now")],
    ),
  ])
}
