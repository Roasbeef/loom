//// The Session pane's "Remembered permissions" section, drawn on an operator's
//// page only (protocol-change/073).
////
//// "Allow for this session" keeps a permission after the card that asked for
//// it is gone, so the section lists what is kept: each filesystem or network
//// permission, then each remembered command, with who allowed it, from which
//// sign-in or terminal, and when. Each row has a Forget button that asks its
//// question in place, and a "Forget all" sits under the list. A permission
//// that was allowed from a browser sign-in which has since ended says so, so
//// that someone who signed a browser out can see what it left behind.
////
//// The words are plain and fixed, with no left-edge bars and no shadows: the
//// question is a tinted block with a hairline border, as the make-shareable
//// question is (`view/share`). The section is the Session pane's sixth and
//// last child, so its handlers are beneath `component.remembered_path`, which
//// the operator socket admits and an observer's does not; an observer's page
//// draws `element.none()` there.
////
//// Every path, tool, command excerpt and name comes from the session or its
//// principals. Each is drawn as a text node. None is an attribute, a class, a
//// key or a handler's message: a handler carries the question the server
//// armed, and that is a value held by the page's server and never read back
//// from the browser.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/remembered as session
import web_view/remembered.{type Armed}
import web_view/view/home_table

/// The messages the section's buttons send.
pub type Presses(message) {
  Presses(
    /// A Forget button, with the question for its row. The question is made
    /// from the list as drawn, so the press sends nothing but the question.
    ask: fn(Armed) -> message,
    /// The question's confirm, which sends what the question armed.
    confirm: message,
    /// The question's Keep, which closes it and sends nothing.
    cancel: message,
  )
}

/// The section for the page's list: what is kept, or that the list has not
/// been read.
///
/// ## Examples
///
/// ```gleam
/// // remembered_view.view(component.remembered(model), component.remembering(model), presses)
/// ```
pub fn view(
  board: Option(session.Board),
  state: remembered.State,
  presses: Presses(message),
) -> Element(message) {
  html.section(
    [
      attribute.class("remembered"),
      attribute.aria_label("Remembered permissions"),
    ],
    [
      html.h3([attribute.class("session-eyebrow")], [
        html.text("Remembered permissions"),
      ]),
      ..body(board, state, presses)
    ],
  )
}

fn body(
  board: Option(session.Board),
  state: remembered.State,
  presses: Presses(message),
) -> List(Element(message)) {
  case board {
    None -> [
      html.p([attribute.class("session-quiet")], [html.text("not read yet")]),
    ]
    Some(board) ->
      case session.count(board) {
        0 -> [
          html.p([attribute.class("session-quiet")], [
            html.text("Nothing is remembered for this session."),
          ]),
        ]
        total -> [
          html.p([attribute.class("share-lead")], [
            html.text(
              "Allowed for the rest of this session. Forget one and the agent has to ask again.",
            ),
          ]),
          html.ul(
            [attribute.class("remembered-list")],
            list.append(
              list.map(board.grants, fn(permission) {
                permission_row(board, permission, state, presses)
              }),
              list.map(board.actions, fn(consent) {
                consent_row(consent, state, presses)
              }),
            ),
          ),
          everything(board, total, state, presses),
        ]
      }
  }
}

// One filesystem or network permission.
fn permission_row(
  board: session.Board,
  permission: session.Permission,
  state: remembered.State,
  presses: Presses(message),
) -> Element(message) {
  row(
    session.describe(permission.kind),
    permission.provenance,
    state,
    remembered.forgetting_permission(board, permission),
    "this permission",
    presses,
  )
}

// One remembered command.
fn consent_row(
  consent: session.Consent,
  state: remembered.State,
  presses: Presses(message),
) -> Element(message) {
  row(
    session.describe_consent(consent),
    consent.provenance,
    state,
    remembered.forgetting_consent(consent),
    "this command",
    presses,
  )
}

// A row: what is kept, who allowed it and when, the note when the sign-in it
// came from has ended, and its button or its question.
fn row(
  what: String,
  provenance: session.Provenance,
  state: remembered.State,
  armed: Armed,
  noun: String,
  presses: Presses(message),
) -> Element(message) {
  html.li([attribute.class("remembered-row")], [
    html.p([attribute.class("remembered-what")], [html.text(what)]),
    html.p([attribute.class("session-quiet")], [
      html.text(who(provenance)),
    ]),
    case remembered.ended(state, provenance) {
      True ->
        html.p([attribute.class("remembered-ended")], [
          html.text(remembered.ended_words),
        ])
      False -> element.none()
    },
    case state.armed {
      Some(open) if open.key == armed.key ->
        question(
          "Forget " <> noun <> "? The agent will have to ask again.",
          "Forget",
          presses,
        )
      Some(_) | None ->
        html.div([attribute.class("share-actions")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("remembered-forget"),
              event.on_click(presses.ask(armed)),
            ],
            [html.text("Forget")],
          ),
        ])
    },
  ])
}

// The button under the list, which asks about everything.
fn everything(
  board: session.Board,
  total: Int,
  state: remembered.State,
  presses: Presses(message),
) -> Element(message) {
  let armed = remembered.forgetting_everything(board)
  case state.armed {
    Some(open) if open.key == armed.key ->
      question(
        "Forget all "
          <> int.to_string(total)
          <> "? The agent will have to ask again for each.",
        "Forget all",
        presses,
      )
    Some(_) | None ->
      html.div([attribute.class("share-actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("remembered-forget"),
            event.on_click(presses.ask(armed)),
          ],
          [html.text(remembered.forget_all_label(total))],
        ),
      ])
  }
}

// The question that replaces a button in place: the sentence, the confirm that
// names the act, and the way out.
fn question(
  words: String,
  confirm: String,
  presses: Presses(message),
) -> Element(message) {
  html.div([attribute.class("share-ask")], [
    html.p([attribute.class("share-lead"), attribute.role("alert")], [
      html.text(words),
    ]),
    html.div([attribute.class("share-actions")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("share-make"),
          event.on_click(presses.confirm),
        ],
        [html.text(confirm)],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("share-cancel"),
          event.on_click(presses.cancel),
        ],
        [html.text("Keep it")],
      ),
    ]),
  ])
}

// Who allowed it and when, in one quiet line: the daemon's words for the who
// and the minute in UTC, which is all the wire carries.
fn who(provenance: session.Provenance) -> String {
  case session.when(provenance) {
    Some(at) -> {
      let #(date, clock) = home_table.utc(at)
      session.who(provenance) <> " · " <> date <> " " <> clock <> " UTC"
    }
    None -> session.who(provenance)
  }
}
