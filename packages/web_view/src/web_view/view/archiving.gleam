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
//// running row the sentence names both steps. Which action a press means is
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

/// The quiet button of a row, or nothing. It reads "Stop and archive" on a
/// running row and "Archive" otherwise, with a title that says what it does.
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
      let #(label, title) = case entry.residency {
        Live -> #(
          "Stop and archive",
          "Stop this session, then archive it: hide it and keep its history",
        )
        Saved | Blocked -> #(
          "Archive",
          "Archive this session: hide it and keep its history",
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
            event.on_click(ask(entry.id)),
            ..working
          ],
          [html.text(label)],
        ),
      ]
    }
  }
}

/// The question that replaces `entry`'s row while it is asking, or nothing when
/// the page is not asking about it. A running row's sentence names both steps.
///
/// ## Examples
///
/// ```gleam
/// // archiving.question(archiving, entry)
/// ```
pub fn question(
  archiving: Archiving(message),
  entry: Entry,
) -> Option(Element(message)) {
  case archiving {
    Offered(confirm:, cancel:, stage: actions.Confirming(session:, action:), ..)
      if session == entry.id
    ->
      case confirms(action) {
        True -> Some(asking(entry, action, confirm(entry.id), cancel))
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
  confirm: message,
  cancel: message,
) -> Element(message) {
  let #(label, lead, go) = case action {
    actions.StopArchive -> #(
      "Stop and archive this session",
      "Stop this session, then archive it?",
      "Stop and archive",
    )
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
