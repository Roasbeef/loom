//// An operator's page: the observer's component, plus the two inputs an
//// operator may send from a browser, a draft and a decision.
////
//// The page socket starts this application only for an attachment whose
//// role, capped by the page's ceiling, is operator (protocol-change/051,
//// the operator addendum). An observer's page is `web_view/component`,
//// whose message type holds no command at all, so which application runs
//// is also which commands exist. The daemon's gateway refuses an
//// observer's mutation on its own; the type is the second, independent
//// layer.
////
//// The inputs are messages, and the component's state stays the
//// observer's: `Observed` passes every observer message through
//// unchanged, and `Submitted`, `Decided` and `Controlled` reach the shared
//// step through `component.submit`, `component.decide` and
//// `component.control`, which wrap them as its commands
//// (`session_view/commands`). A draft is parsed as the terminal parses it,
//// so a slash command that names a session command is that command, and one
//// that opens a terminal surface is refused with a notice. The controls are
//// the same commands chosen by a button or a small form (Stop, the goal's
//// buttons, Fork, Set goal), and `Replying` puts the start of a reply to a
//// peer's message in the composer without sending anything. This module
//// decides nothing about the session. It turns a browser event into one of
//// those calls, and draws the composer, the controls and the approval
//// cards.
////
//// The lane's "Load older" button is the observer's own
//// (`component.OlderRequested`), a read, and reaches this page as an
//// `Observed` message like the rest.
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
import gleam/option.{type Option, None, Some}
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
import web_view/completion
import web_view/component
import web_view/view/controls
import web_view/view/lane
import web_view/view/nudges
import web_view/view/sidebar
import web_view/view/strip

/// Everything an operator's page can be told.
pub type Msg(socket) {
  /// One of the observer component's own messages: the connection, the
  /// frames and the tick.
  Observed(message: component.Msg(socket))

  /// The composer was submitted with this text, to be sent as a prompt or a
  /// steer, or run as the slash command it names.
  Submitted(text: String, delivery: operator.Delivery)

  /// An approval card's button: the escalation's identity, the sequence
  /// the card was drawn at, and the answer.
  Decided(id: String, seq: Int, answer: component.Answer)

  /// A session control: Stop, one of the goal's buttons, or one of the two
  /// forms, with the text it held.
  Controlled(control: component.Control)

  /// A peer message's Reply button, by the key of the piece it was drawn
  /// under. The key is the engine's, never text the peer wrote.
  Replying(key: String)
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
    Controlled(control:) -> component.control(model, control)
    Replying(key:) -> component.reply(model, key)
  }
  #(model, effect.map(effects, Observed))
}

/// The operator's page: the heading, the agent strip, the lane, and the
/// dock, which holds the todo panel, the advisor's pending nudges, the
/// session controls, the approvals waiting for a decision, in a region of
/// their own directly above the composer, and the composer.
///
/// The page is a fixed frame: the heading and the agent strip at the top,
/// the dock at the bottom, and the lane between them as the one thing that
/// scrolls (`<loom-follow>`). In the document's flow the composer moved
/// down every time a row landed or its editor grew, so a click aimed at
/// Send or Steer could land on whatever had slid under the pointer. In the
/// frame the dock stays where the operator last saw it however the
/// transcript moves.
///
/// The approvals are in the dock so that a pending card is on screen
/// wherever the operator has scrolled. They sit above the composer, and the
/// dock is pinned by its bottom edge, so a card appearing grows the dock
/// upward and leaves the composer's controls where they were: the agent
/// decides when an escalation lands and how tall its card is, and neither
/// can move Send or Steer. The region's height is capped by the stylesheet
/// and scrolls on its own, so a 16 KiB action preview cannot push the
/// composer off the screen.
///
/// The todo panel is the dock's first child, above the approvals. It is the
/// terminal's pinned board and reviewer band, drawn by `component.plan`, and
/// like the approvals it grows the dock upward, shrinks the transcript by as
/// much and is capped by the stylesheet, so the panel can neither move the
/// composer nor cover a transcript row. With no board and no reviewer it is
/// `element.none()`, as the approvals are.
///
/// The nudges card and the controls come after it. The card shows what the
/// advisor holds for the primary's next run and has no button, since the queue
/// has no accept or dismiss (`web_view/view/nudges`). The controls are the
/// operator's commands as buttons and two small forms
/// (`web_view/view/controls`), and a peer's message in the lane carries a
/// Reply button (`lane.view`). All are capped or drawn at fixed
/// places, so none can move the composer's controls.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(operator_page.view(model))
/// ```
pub fn view(model: component.Model(socket)) -> Element(Msg(socket)) {
  html.main([attribute.class("loom-session operator")], [
    component.heading(model),
    strip.view(component.strip(model), fn(strand) {
      Observed(component.FocusRequested(strand))
    }),
    lane.view(
      component.pieces(model),
      component.live(model),
      component.top(model),
      Observed(component.OlderRequested),
      lane.Replies(Replying),
    ),
    html.footer([attribute.class("dock")], [
      component.plan(model),
      nudges.view(component.pending_nudges(model)),
      controls.view(bar(model)),
      approvals(component.pending(model)),
      composer(model),
    ]),
    sidebar.view(component.session_groups(model), component.session_id(model)),
  ])
}

// The controls, with what each sends. Stop is offered while the strand runs
// an operation, and the two forms send their text as one field. The bar is
// drawn in the dock for an operator only: an observer's page has no message
// for any of it.
fn bar(model: component.Model(socket)) -> controls.Bar(Msg(socket)) {
  controls.Bar(
    strand: component.strand,
    stop: case component.activity(model) {
      component.Busy -> Some(Controlled(component.Stop))
      component.Idle -> None
    },
    goal: component.goal(model),
    pause: Controlled(component.PauseGoal),
    resume: Controlled(component.ResumeGoal),
    clear: Controlled(component.ClearGoal),
    fork: form_submit(component.Fork),
    pin: form_submit(component.PinGoal),
    sent: component.sent_forms(model),
  )
}

// A control form's submit, carrying the one field it has. Anything else in
// the form refuses the event, as the composer's decoder refuses an unknown
// field.
fn form_submit(
  control: fn(String) -> component.Control,
) -> attribute.Attribute(Msg(socket)) {
  event.on("submit", written(control)) |> event.prevent_default
}

fn written(
  control: fn(String) -> component.Control,
) -> decode.Decoder(Msg(socket)) {
  use fields <- decode.subfield(["detail", "formData"], decode.list(field()))
  case control_text(fields) {
    Ok(text) -> decode.success(Controlled(control(text)))
    Error(Nil) -> decode.failure(Controlled(control("")), "control form")
  }
}

/// The text of a submitted control form's fields, or a refusal: exactly one
/// field, named `text`, and nothing else.
///
/// ## Examples
///
/// ```gleam
/// assert operator_page.control_text([#("text", "try-a-cache")])
///   == Ok("try-a-cache")
/// ```
pub fn control_text(fields: List(#(String, String))) -> Result(String, Nil) {
  case fields {
    [#("text", text)] -> Ok(text)
    _ -> Error(Nil)
  }
}

// The approvals region sits outside the transcript, so nothing the session
// writes can appear inside it, and it is styled unlike any transcript line.
// A card is keyed by the sequence its record was drawn at, which is the
// daemon's and never text the session wrote. Every storage write takes its
// own sequence, so no two pending records share one, and a card keeps its
// key when a sibling leaves. A card never takes focus and nothing here has
// `autofocus`.
//
// With nothing pending the region is `element.none()`, an empty text node,
// rather than nothing at all. The composer therefore stays the dock's
// last child, after the places of the todo panel, the nudges, the controls
// and this one, whether or not a card is drawn, so the path a browser event
// names for the composer's form is the same before and after a card
// appears, and a submit in flight still reaches the form.
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
            list.map(pending, fn(record) {
              #(int.to_string(record.seq), card(record))
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
//
// The action row carries `arming`, which the stylesheet uses to refuse
// clicks on the row for 600 ms after the card is inserted, with the buttons
// drawn dimmed meanwhile. A card appears above the composer when the agent
// decides, so a click already on its way to the bottom of the transcript
// could otherwise land on Allow. The delay is a CSS animation, so it needs
// no script and no timer here, and it runs once per inserted card: cards
// are keyed by sequence, so a later patch updates the same node rather
// than inserting a new one, and the animation does not start again.
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
        html.div(
          [attribute.class("approval-actions"), attribute.class("arming")],
          [
            deny,
            button(
              "approval-allow",
              "Allow " <> tool <> " once",
              Decided(record.id, record.seq, component.AllowOnce),
            ),
          ],
        ),
      ])
    Error(reason) ->
      html.article([attribute.class("approval-card")], [
        html.p([attribute.class("approval-head")], [
          html.text("Waits for approval · " <> tool),
        ]),
        html.p([attribute.class("approval-question")], [
          html.text("This request cannot be approved from the page: " <> reason),
        ]),
        html.div(
          [attribute.class("approval-actions"), attribute.class("arming")],
          [deny],
        ),
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
        #("draft-" <> int.to_string(component.drafts(model)), editor(model)),
      ]),
      html.div([attribute.class("composer-actions")], [
        notice(component.notice(model)),
        ..actions(component.activity(model))
      ]),
    ],
  )
}

// The editor, inside `<loom-composer>` (`packages/web_client`), which lists
// the slash commands as the draft grows and sends it on Command or Control
// with Enter. The textarea is still the uncontrolled editor it was, and the
// element only listens to it: the browser owns the text, the form's submit is
// the one event the server hears, and Enter in the editor is a newline. The
// element's `commands` attribute is the static table of completions, which
// holds no session text (`web_view/completion`).
//
// A prompt the daemon handed back is put in the editor by the element, which
// alone knows whether the operator has typed there since. The server tells it
// with the count in `returned`, which rises with each return, and with the
// prompts themselves as text-node children in the slot named `returned`,
// each numbered by a `data-n`. The element's shadow root has no such slot,
// so the browser never draws them; they are only read. They come after the
// textarea, so the textarea keeps its place in the tree.
fn editor(model: component.Model(socket)) -> Element(Msg(socket)) {
  element.element(
    "loom-composer",
    [
      attribute.attribute("commands", completion.table()),
      attribute.attribute("returned", int.to_string(component.returns(model))),
    ],
    [
      html.textarea(
        [
          attribute.name("draft"),
          attribute.rows(3),
          attribute.aria_label("Message to " <> component.strand(model)),
          attribute.placeholder("Message " <> component.strand(model)),
        ],
        "",
      ),
      ..list.map(component.returned(model), fn(returned) {
        html.span(
          [
            attribute.attribute("slot", "returned"),
            attribute.attribute("data-n", int.to_string(returned.number)),
          ],
          [html.text(returned.text)],
        )
      })
    ],
  )
}

// Who the page acts as, from the attachment the last capture was taken
// for, the strand the composer addresses, and what may be said about that
// strand's prompt cache, where the operator decides to send now or later.
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
        html.text("→ " <> component.strand(model)),
      ]),
      outlook(component.addressed(model)),
    ]),
  )
}

// The addressed strand's cache outlook, drawn as the chip's ring is and
// worded by `cache_miss.outlook_label`. A tail about to lapse is the one
// reading worth the signal colour; nothing else here nags.
fn outlook(chip: Option(strip.Chip)) -> Element(Msg(socket)) {
  case chip {
    Some(strip.Chip(cache: Some(#(held, label)), ..)) ->
      html.span(
        [
          attribute.class("outlook"),
          strip.ring_class(held),
          attribute.role("status"),
        ],
        [html.text(label)],
      )
    Some(strip.Chip(cache: None, ..)) | None -> element.none()
  }
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
