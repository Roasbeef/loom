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
//// The bar sits in the dock, above the composer, so it is where Send and
//// Steer are and moves no more than they do. Two things keep a click from
//// landing on the wrong control. The goal's one steering button and its
//// Clear are drawn in a keyed row that carries `arming`, so when the
//// goal's status changes the row is inserted afresh and the stylesheet
//// refuses clicks on it for 600 ms, as it does for an approval card. And
//// the form is keyed by how many have been sent, so a sent form is
//// replaced by a closed empty one.
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

/// The bar: the goal row when a goal is known, then the fork form.
///
/// ## Examples
///
/// ```gleam
/// // controls.view(controls.Bar(goal: None, ..))
/// ```
pub fn view(bar: Bar(message)) -> Element(message) {
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

// The goal, in the terminal's row words, and the buttons its status offers:
// a goal that is running can be held, one that is held or stopped short can
// continue, and any goal can be cleared. The row is keyed by the status, so
// a change of status is a new row and arms again.
fn goal(bar: Bar(message)) -> Element(message) {
  case bar.goal {
    None -> element.none()
    Some(goal_view.NoGoal(..)) ->
      html.span([attribute.class("control-goal")], [
        html.text("No goal is pinned"),
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
