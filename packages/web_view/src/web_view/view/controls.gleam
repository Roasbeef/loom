//// The operator page's session controls: the goal's buttons and one small
//// form that forks the strand.
////
//// Each control runs a command the terminal already runs from a typed
//// draft, so this module adds no operation. The goal's buttons are
//// `/goal pause`, `/goal resume` and `/goal clear`. The fork needs words
//// from the operator, so it is a `<details>` holding a form with one text
//// field, which the component turns into `/fork <name>` and parses as a
//// typed draft is parsed. The other commands the bar once offered, Stop
//// and a Set goal form, are gone from the page: Stop remains the
//// terminal's Escape, and a goal can still be pinned by typing `/goal ...`
//// in the composer, which the page has parsed as a command since S5.
////
//// The controls live in two places. The Session tab holds all of them, as
//// the operator's one place to steer the session: the goal's buttons beside
//// its row, and the Fork form under it (`session`). The dock draws one line
//// of them, and only while a goal is running or held (`dock`): the goal's
//// words and its one steering button, since a loop that is spending tokens
//// is the thing an operator wants a hand on without opening a tab. A goal
//// that is complete or limited, and no goal at all, leave the dock to the
//// todo line and the composer.
////
//// Two things keep a click from landing on the wrong control. The goal's
//// steering button and its Clear are drawn in a keyed row that carries
//// `arming`, so when the goal's status changes the row is inserted afresh
//// and the stylesheet refuses clicks on it for 600 ms, as it does for an
//// approval card. And the form is keyed by how many have been sent, so a
//// sent form is replaced by a closed empty one.
////
//// The goal row's words are the terminal's own (`goal_view.row`), and the
//// server's, so the page words nothing about the goal itself. They and the
//// goal's objective are text nodes. Every label here is fixed, and the only
//// session content is the goal row. The bar takes the messages its buttons
//// send and the form's submit handler as values, because
//// `web_view/operator_page` owns the message type and imports this module.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/goal_view

/// Everything the bar draws and sends.
pub type Bar(message) {
  Bar(
    /// The goal as the server last rendered it, or `None` before any read.
    goal: Option(goal_view.Board),
    /// What the goal's Pause button sends.
    pause: message,
    /// What the goal's Resume button sends.
    resume: message,
    /// What the goal's Clear button sends.
    clear: message,
    /// The fork form's submit handler.
    fork: Attribute(message),
    /// How many forms have been sent, which keys the form.
    sent: Int,
  )
}

/// The Session tab's controls: the goal row with its buttons, then the Fork
/// form. It is the Session pane's last child and always drawn, so the pane's
/// other paths do not depend on whether a goal exists.
///
/// ## Examples
///
/// ```gleam
/// // controls.session(controls.Bar(goal: None, ..))
/// ```
pub fn session(bar: Bar(message)) -> Element(message) {
  html.section(
    [attribute.class("controls"), attribute.aria_label("Session controls")],
    [
      html.div([attribute.class("control-row")], [goal(bar)]),
      keyed.div([attribute.class("control-forms")], [
        #("fork-" <> int.to_string(bar.sent), fork(bar)),
      ]),
    ],
  )
}

/// The dock's one line: while a goal is active or paused, its words and the
/// button that steers it. Any other state draws an empty node, so the dock's
/// children keep their places.
///
/// ## Examples
///
/// ```gleam
/// // controls.dock(controls.Bar(goal: None, ..))
/// ```
pub fn dock(bar: Bar(message)) -> Element(message) {
  case bar.goal {
    Some(goal_view.Pinned(status: goal_view.Active, ..) as pinned) ->
      dock_line(pinned, goal_view.Active, bar)
    Some(goal_view.Pinned(status: goal_view.Paused(_) as status, ..) as pinned) ->
      dock_line(pinned, status, bar)
    Some(goal_view.Pinned(..)) | Some(goal_view.NoGoal(..)) | None ->
      element.none()
  }
}

// The line itself: the goal's first row of words and its one steering
// button, keyed by the status so a change of status arms the row afresh.
fn dock_line(
  pinned: goal_view.Board,
  status: goal_view.Status,
  bar: Bar(message),
) -> Element(message) {
  html.section([attribute.class("dock-goal"), attribute.aria_label("Goal")], [
    keyed.div([attribute.class("control-row")], [
      #(
        goal_view.status_word(status),
        html.div(
          [attribute.class("control-actions"), attribute.class("arming")],
          [
            html.span(
              [attribute.class("control-goal-text")],
              list.map(list.take(goal_view.row(pinned), 1), html.text),
            ),
            steering(status, bar),
          ],
        ),
      ),
    ]),
  ])
}

// The goal, in the terminal's row words, and the buttons its status offers:
// a goal that is running can be held, one that is held or stopped short can
// continue, and any goal can be cleared. The row is keyed by the status, so
// a change of status is a new row and arms again.
fn goal(bar: Bar(message)) -> Element(message) {
  case bar.goal {
    None -> element.none()
    Some(goal_view.NoGoal(..)) ->
      html.span([attribute.class("control-goal")], [
        html.text("No goal is pinned. Type /goal and an objective to pin one."),
      ])
    Some(goal_view.Pinned(status:, ..) as pinned) ->
      keyed.div([attribute.class("control-goal")], [
        #(
          goal_view.status_word(status),
          html.div(
            [attribute.class("control-actions"), attribute.class("arming")],
            [
              html.span(
                [attribute.class("control-goal-text")],
                list.map(list.take(goal_view.row(pinned), 1), html.text),
              ),
              steering(status, bar),
              button("control-clear", "Clear goal", bar.clear),
            ],
          ),
        ),
      ])
  }
}

// The one button that steers the goal's loop, chosen by the status.
fn steering(status: goal_view.Status, bar: Bar(message)) -> Element(message) {
  case status {
    goal_view.Active -> button("control-pause", "Pause goal", bar.pause)
    goal_view.Paused(_) | goal_view.Limited(_) ->
      button("control-resume", "Resume goal", bar.resume)
    goal_view.Complete -> element.none()
  }
}

fn button(class: String, label: String, message: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      event.on_click(message),
    ],
    [html.text(label)],
  )
}

// A disclosure holding one form. Whether it is open is the browser's, as a
// fold's is, and the form is the operator's uncontrolled input, sent by its
// own submit.
fn disclosure(
  summary: String,
  kind: Attribute(message),
  handler: Attribute(message),
  label: String,
  send: String,
) -> Element(message) {
  html.details([attribute.class("control-form")], [
    html.summary([], [html.text(summary)]),
    html.form([attribute.class("control-input"), kind, handler], [
      html.input([
        attribute.type_("text"),
        attribute.name("text"),
        attribute.aria_label(label),
        attribute.placeholder(label),
        attribute.attribute("autocomplete", "off"),
      ]),
      html.button([attribute.type_("submit")], [html.text(send)]),
    ]),
  ])
}

fn fork(bar: Bar(message)) -> Element(message) {
  disclosure(
    "Fork",
    attribute.class("control-fork"),
    bar.fork,
    "Name for the new strand",
    "Fork",
  )
}
