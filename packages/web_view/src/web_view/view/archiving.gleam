//// The archive action of a sidebar row: a quiet button, and the one question
//// that follows it (protocol-change/065, the addendum on archiving from the
//// sidebar).
////
//// The owner's fresh home has Stop, Archive and Delete beside each row of its
//// table (`view/home_table`). The sidebar is the column the owner keeps in
//// sight, so it offers the one action that tidies it: Archive on a saved or
//// blocked row, and "Stop and archive" on a running one. The button is drawn
//// after the row's own button, so the row's own path is where it was, and the
//// stylesheet shows it on hover and on keyboard focus. It is a real button in
//// the tab order the whole time, so the keyboard reaches it without a pointer.
////
//// A press asks nothing of the daemon. It opens the row's question, which
//// replaces the row's words with one sentence in fixed words, the session's
//// name beneath it as a text node, a button that asks and a Cancel. For a
//// running row the sentence names both steps, and says the turn is running when
//// the activity read has the session working or waiting on its operator. Which action a press means is
//// the server's: `action` reads it from the row's residency when the page asks,
//// and the confirm message carries only the session, so a browser can never
//// choose between Archive and Stop-and-archive, nor confirm a Delete the home's
//// table opened (`confirms`).
////
//// The page the sidebar is on decides whether the action exists. The home and
//// a session page draw it only when the daemon handed the page the capability
//// that the home's Archive button has (`ui_socket.home_manage_capability`):
//// an owner's operating page that a fresh `loom ui` exchange opened. A bookmark
//// page, a member's page and a read-only link draw nothing, and the daemon
//// checks all of it again when the request runs.
////
//// The session on screen has no archive action, and says why in a `title`:
//// stopping it ends the page that asked, which would take the task and the
//// confirmation with it.
////
//// Every name is a text node. The module takes the entry the catalogue
//// supplied and a page's own messages, and imports nothing from the pages.

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/actions.{type Action, type Stage}
import web_view/sessions.{type Entry, Blocked, Live, Saved}

/// What a page offers for archiving a sidebar row.
pub type Archiving(message) {
  /// Nothing is drawn: the page was not handed the capability.
  Never

  /// Each other row has the button. `ask` is the message the button sends given
  /// the row's identity, `confirm` the question's own button, and `cancel` its
  /// Cancel. `stage` is where the page stands: the one row that is asking or
  /// waiting on the daemon. The identities are the catalogue's, drawn into the
  /// tree by the server, so a browser's event never names a session.
  Offered(
    ask: fn(String) -> message,
    confirm: fn(String) -> message,
    cancel: message,
    stage: Stage,
  )
}

/// Whether a running row's session is between turns or inside one, as the
/// activity read last said. It decides only which sentence the question uses:
/// stopping a session that is working, or waiting on its operator, cuts its
/// turn short, and the sentence says so as the home's Stop does. A row the read
/// has not named is `AtRest`, because the page then has no claim to make.
pub type Turn {
  /// A turn is running or waiting on its operator, and stopping ends it.
  MidTurn

  /// Nothing is known to be running, so stopping interrupts nothing the page
  /// knows of.
  AtRest
}

/// The action a press on `entry`'s button means: a running row is stopped and
/// archived, and a saved or blocked one is archived. It is read from the
/// catalogue's entry when the page asks, and never from the browser.
///
/// ## Examples
///
/// ```gleam
/// assert archiving.action(entry) == actions.Archive
/// ```
pub fn action(entry: Entry) -> Action {
  case entry.residency {
    Live -> actions.StopArchive
    Saved | Blocked -> actions.Archive
  }
}

/// Whether `action` is one the sidebar's question asks, which is what its
/// confirm message may confirm. The table's Stop and Delete are not, so a
/// stale click on the sidebar's confirm button cannot answer their questions.
///
/// ## Examples
///
/// ```gleam
/// assert archiving.confirms(actions.Delete) == False
/// ```
pub fn confirms(action: Action) -> Bool {
  case action {
    actions.Archive | actions.StopArchive -> True
    actions.Stop | actions.Delete -> False
  }
}

/// The action the sidebar's open question is for, when `stage` is that question
/// for `session`. It is what a confirm message may act on: any other stage, for
/// any other row or for the table's Stop or Delete question, gives none.
///
/// ## Examples
///
/// ```gleam
/// assert archiving.confirmed(actions.Calm, "a") == Error(Nil)
/// ```
pub fn confirmed(stage: Stage, session: String) -> Result(Action, Nil) {
  case stage {
    actions.Confirming(session: open, action:) if open == session ->
      case confirms(action) {
        True -> Ok(action)
        False -> Error(Nil)
      }
    actions.Confirming(..) | actions.Calm | actions.Working(..) -> Error(Nil)
  }
}

/// Where the page stands, for a memo's key. A page that draws nothing is calm.
///
/// ## Examples
///
/// ```gleam
/// assert archiving.stage(archiving.Never) == actions.Calm
/// ```
pub fn stage(archiving: Archiving(message)) -> Stage {
  case archiving {
    Never -> actions.Calm
    Offered(stage:, ..) -> stage
  }
}

/// The quiet button of a row, or nothing. It is a 24px square holding one
/// glyph, so it can sit at the row's right edge and never lie over the name,
/// the dot or the activity word. Its `aria-label` and `title` say what it does:
/// "Stop and archive" on a running row and "Archive" otherwise. The glyph
/// differs too, so the two read differently before they are read: a cross for
/// archiving a row at rest, and a filled square, the sign for stop, on a row
/// that is running, whose press ends its turn first.
/// While a request for the row is out it is disabled, though the handler stays,
/// because the page is the layer that ignores a second press.
///
/// ## Examples
///
/// ```gleam
/// // archiving.button(archiving, entry)
/// ```
pub fn button(
  archiving: Archiving(message),
  entry: Entry,
) -> List(Element(message)) {
  case archiving {
    Never -> []
    Offered(ask:, stage:, ..) -> {
      let #(label, title, glyph) = case entry.residency {
        Live -> #(
          "Stop and archive",
          "Stop this session, then archive it: hide it and keep its history",
          "■",
        )
        Saved | Blocked -> #(
          "Archive",
          "Archive this session: hide it and keep its history",
          "×",
        )
      }
      let working = case stage {
        actions.Working(session:, ..) if session == entry.id -> [
          attribute.disabled(True),
        ]
        actions.Working(..) | actions.Calm | actions.Confirming(..) -> []
      }
      [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("session-archive"),
            attribute.title(title),
            attribute.aria_label(label),
            event.on_click(ask(entry.id)),
            ..working
          ],
          [html.text(glyph)],
        ),
      ]
    }
  }
}

/// The question that replaces `entry`'s row while it is asking, or nothing when
/// the page is not asking about it. A running row's sentence names both steps,
/// and says the turn is running when `turn` is `MidTurn`.
///
/// ## Examples
///
/// ```gleam
/// // archiving.question(archiving, entry, archiving.AtRest)
/// ```
pub fn question(
  archiving: Archiving(message),
  entry: Entry,
  turn: Turn,
) -> Option(Element(message)) {
  case archiving {
    Offered(confirm:, cancel:, stage: actions.Confirming(session:, action:), ..)
      if session == entry.id
    ->
      case confirms(action) {
        True -> Some(asking(entry, action, turn, confirm(entry.id), cancel))
        False -> None
      }
    Offered(..) | Never -> None
  }
}

/// The attribute that says why the session on screen has no archive action, or
/// none on a page that offers no action at all.
///
/// ## Examples
///
/// ```gleam
/// assert archiving.current_title(archiving.Never) == []
/// ```
pub fn current_title(
  archiving: Archiving(message),
) -> List(attribute.Attribute(message)) {
  case archiving {
    Never -> []
    Offered(..) -> [
      attribute.title(
        "This session is on screen. Open the home page or another session to archive it.",
      ),
    ]
  }
}

fn asking(
  entry: Entry,
  action: Action,
  turn: Turn,
  confirm: message,
  cancel: message,
) -> Element(message) {
  let #(label, lead, go) = case action {
    actions.StopArchive -> #(
      "Stop and archive this session",
      case turn {
        MidTurn -> "Stop this session mid-turn, then archive it?"
        AtRest -> "Stop this session, then archive it?"
      },
      "Stop and archive",
    )

    // `Stop` and `Delete` are unreachable here: `confirms` filters them first.
    actions.Archive | actions.Stop | actions.Delete -> #(
      "Archive this session",
      "Archive this session?",
      "Archive",
    )
  }
  html.div(
    [
      attribute.class("session-confirm"),
      attribute.role("alertdialog"),
      attribute.aria_label(label),
    ],
    [
      html.p([attribute.class("session-confirm-lead")], [html.text(lead)]),
      html.p([attribute.class("session-confirm-name")], [
        html.text(sessions.label(entry)),
      ]),
      html.div([attribute.class("session-confirm-actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("session-confirm-go"),
            event.on_click(confirm),
          ],
          [html.text(go)],
        ),
        html.button([attribute.type_("button"), event.on_click(cancel)], [
          html.text("Cancel"),
        ]),
      ]),
    ],
  )
}
