//// An operator's page: the observer's component, plus the two commands an
//// operator may send from a browser, a prompt and a decision.
////
//// The page socket starts this application only for an attachment whose
//// role, capped by the page's ceiling, is operator (protocol-change/051,
//// the operator addendum). An observer's page is `web_view/component`,
//// whose message type holds no command at all, so which application runs
//// is also which commands exist. The daemon's gateway refuses an
//// observer's mutation on its own; the type is the second, independent
//// layer.
////
//// The commands are messages, and the component's state stays the
//// observer's: `Observed` passes every observer message through
//// unchanged, and `Submitted` and `Decided` reach the lane through
//// `component.submit` and `component.decide`, which call the engine's
//// command arms (`session_view/operator`). This module decides nothing
//// about the session. It turns a browser event into one of those two
//// calls, and draws the composer and the approval cards.
////
//// The browser can reach only the handlers the rendered tree holds, and a
//// handler's message is fixed when the tree is drawn. So each approval
//// button carries the escalation's identity and the sequence it was drawn
//// at, and `component.decide` answers only the record that still has both.
//// The composer is an uncontrolled form: the browser owns the text as the
//// operator types, and one submit carries it to the server, where its
//// fields are decoded totally and anything unexpected refuses the event.

import core/origin
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/approval
import session_view/operator
import session_view/snapshot
import web_view/component

/// Everything an operator's page can be told.
pub type Msg(socket) {
  /// One of the observer component's own messages: the connection, the
  /// frames and the tick.
  Observed(message: component.Msg(socket))

  /// The composer was submitted with this text, as a prompt or a steer.
  Submitted(text: String, delivery: operator.Delivery)

  /// An approval card's button: the escalation's identity, the sequence
  /// the card was drawn at, and the answer.
  Decided(id: String, seq: Int, answer: component.Answer)
}

/// The Lustre application for one session's operator page.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(operator_page.app(), start)
/// ```
pub fn app() -> lustre.App(
  component.Start(socket),
  component.Model(socket),
  Msg(socket),
) {
  lustre.application(init, update, view)
}

fn init(
  start: component.Start(socket),
) -> #(component.Model(socket), Effect(Msg(socket))) {
  let #(model, effects) = component.init(start)
  #(model, effect.map(effects, Observed))
}

/// Applies one message.
///
/// ## Examples
///
/// ```gleam
/// // operator_page.update(model, operator_page.Submitted("hi", operator.Prompt))
/// ```
pub fn update(
  model: component.Model(socket),
  message: Msg(socket),
) -> #(component.Model(socket), Effect(Msg(socket))) {
  let #(model, effects) = case message {
    Observed(message:) -> component.update(model, message)
    Submitted(text:, delivery:) -> component.submit(model, text, delivery)
    Decided(id:, seq:, answer:) -> component.decide(model, id, seq, answer)
  }
  #(model, effect.map(effects, Observed))
}

/// The operator's page: the heading, the transcript, the approvals waiting
/// for a decision in a region of their own, and the composer.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(operator_page.view(model))
/// ```
pub fn view(model: component.Model(socket)) -> Element(Msg(socket)) {
  html.main([attribute.class("loom-session operator")], [
    component.heading(model),
    component.transcript_view(component.rows(model)),
    approvals(component.pending(model)),
    composer(model),
  ])
}

// The approvals region sits outside the transcript, so nothing the session
// writes can appear inside it, and it is styled unlike any transcript line.
// A card is keyed by the sequence its record was drawn at and its place,
// both the daemon's, never by text the session wrote. A card never takes
// focus and nothing here has `autofocus`.
fn approvals(pending: List(approval.Review)) -> Element(Msg(socket)) {
  case pending {
    [] -> element.none()
    [_, ..] ->
      html.section(
        [
          attribute.class("approvals"),
          attribute.aria_label("Approvals waiting"),
        ],
        [
          keyed.div(
            [attribute.class("approval-list")],
            list.index_map(pending, fn(record, index) {
              #(
                int.to_string(record.seq) <> ":" <> int.to_string(index),
                card(record),
              )
            }),
          ),
        ],
      )
  }
}

// One card, drawn from the escalation record alone. Deny comes first, so it
// is the first control the operator reaches by tabbing into the card; each
// button names the tool it answers; and Allow is offered only when the
// record's whole authority was captured, which `approval.presentation`
// decides.
fn card(record: approval.Review) -> Element(Msg(socket)) {
  let tool = case record.tool {
    "" -> "this request"
    tool -> tool
  }
  let deny =
    button(
      "approval-deny",
      "Deny " <> tool,
      Decided(record.id, record.seq, component.Deny),
    )
  case approval.presentation(record) {
    Ok(shown) ->
      html.article([attribute.class("approval-card")], [
        html.p([attribute.class("approval-head")], [
          html.text("Waits for approval · " <> tool),
        ]),
        html.p([attribute.class("approval-question")], [
          html.text(shown.question),
        ]),
        html.pre([attribute.class("approval-action")], [html.text(shown.action)]),
        html.ul(
          [attribute.class("approval-authority")],
          list.map(shown.authority, fn(line) { html.li([], [html.text(line)]) }),
        ),
        html.div([attribute.class("approval-actions")], [
          deny,
          button(
            "approval-allow",
            "Allow " <> tool <> " once",
            Decided(record.id, record.seq, component.AllowOnce),
          ),
        ]),
      ])
    Error(reason) ->
      html.article([attribute.class("approval-card")], [
        html.p([attribute.class("approval-head")], [
          html.text("Waits for approval · " <> tool),
        ]),
        html.p([attribute.class("approval-question")], [
          html.text("This request cannot be approved from the page: " <> reason),
        ]),
        html.div([attribute.class("approval-actions")], [deny]),
      ])
  }
}

fn button(
  class: String,
  label: String,
  message: Msg(socket),
) -> Element(Msg(socket)) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      event.on_click(message),
    ],
    [html.text(label)],
  )
}

// The composer: who the page acts as and whom it addresses, the editor, and
// the actions. The editor is uncontrolled and keyed by how many drafts have
// been sent, so a sent draft is replaced by an empty editor and a refused
// one stays as the operator left it. The only handler is the form's submit;
// Enter in the editor is a newline, never a submission and never a
// decision.
fn composer(model: component.Model(socket)) -> Element(Msg(socket)) {
  html.form(
    [
      attribute.class("composer"),
      attribute.aria_label("Composer"),
      event.on("submit", composed()) |> event.prevent_default,
    ],
    [
      identity(model),
      keyed.div([attribute.class("editor")], [
        #(
          "draft-" <> int.to_string(component.drafts(model)),
          html.textarea(
            [
              attribute.name("draft"),
              attribute.rows(3),
              attribute.aria_label("Message to " <> component.strand),
              attribute.placeholder("Message " <> component.strand),
            ],
            "",
          ),
        ),
      ]),
      html.div([attribute.class("composer-actions")], [
        notice(component.notice(model)),
        ..actions(component.activity(model))
      ]),
    ],
  )
}

// Who the page acts as, from the attachment the last capture was taken
// for, and the strand the composer addresses.
fn identity(model: component.Model(socket)) -> Element(Msg(socket)) {
  let who = case component.attachment(model) {
    None -> [html.span([attribute.class("identity-name")], [html.text("…")])]
    Some(attachment) -> [
      html.span([attribute.class("identity-name")], [
        html.text(origin.display_label(attachment.origin)),
      ]),
      html.span([attribute.class("role-badge")], [
        html.text(role_text(attachment.role)),
      ]),
    ]
  }
  html.div(
    [attribute.class("identity")],
    list.append(who, [
      html.span([attribute.class("addressed")], [
        html.text("→ " <> component.strand),
      ]),
    ]),
  )
}

fn role_text(role: snapshot.Role) -> String {
  case role {
    snapshot.Owner -> "Owner"
    snapshot.Operator -> "Operator"
    snapshot.Observer -> "Observer"
  }
}

// An idle strand takes one Send; a busy one takes a Queue, which the daemon
// holds and runs after the current operation, or a Steer, which folds into
// it. Each is a submit button naming its delivery, so the one pressed
// travels with the form.
fn actions(activity: component.Activity) -> List(Element(Msg(socket))) {
  case activity {
    component.Idle -> [submit_button("prompt", "Send", "send")]
    component.Busy -> [
      submit_button("prompt", "Queue", "queue"),
      submit_button("steer", "Steer", "steer"),
    ]
  }
}

fn submit_button(
  delivery: String,
  label: String,
  class: String,
) -> Element(Msg(socket)) {
  html.button(
    [
      attribute.type_("submit"),
      attribute.name("delivery"),
      attribute.value(delivery),
      attribute.class(class),
    ],
    [html.text(label)],
  )
}

fn notice(notice: component.Notice) -> Element(Msg(socket)) {
  case notice {
    component.Quiet ->
      html.p([attribute.class("notice"), attribute.role("status")], [])
    component.Said(text:) ->
      html.p([attribute.class("notice"), attribute.role("status")], [
        html.text(text),
      ])
    component.Warned(text:) ->
      html.p([attribute.class("notice warned"), attribute.role("status")], [
        html.text(text),
      ])
  }
}

// The composer's submit, decoded totally from the form's fields: exactly
// one draft, and at most one delivery, which is `prompt` or `steer`. Any
// other field, a repeated one or an unknown delivery refuses the event, so
// a forged submit cannot smuggle in a command the form does not offer.
fn composed() -> decode.Decoder(Msg(socket)) {
  use fields <- decode.subfield(["detail", "formData"], decode.list(field()))
  case composition(fields) {
    Ok(message) -> decode.success(message)
    Error(Nil) ->
      decode.failure(Submitted("", operator.Prompt), "composer form")
  }
}

fn field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The message a submitted composer form's fields stand for, or a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert operator_page.composition([#("draft", "hi")])
///   == Ok(operator_page.Submitted("hi", operator.Prompt))
/// ```
pub fn composition(
  fields: List(#(String, String)),
) -> Result(Msg(socket), Nil) {
  let drafts = list.filter(fields, fn(field) { field.0 == "draft" })
  let deliveries = list.filter(fields, fn(field) { field.0 == "delivery" })
  let others =
    list.filter(fields, fn(field) {
      field.0 != "draft" && field.0 != "delivery"
    })
  case drafts, deliveries, others {
    [#(_, text)], [], [] -> Ok(Submitted(text, operator.Prompt))
    [#(_, text)], [#(_, "prompt")], [] -> Ok(Submitted(text, operator.Prompt))
    [#(_, text)], [#(_, "steer")], [] -> Ok(Submitted(text, operator.Steer))
    _, _, _ -> Error(Nil)
  }
}
