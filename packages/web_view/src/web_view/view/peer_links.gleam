//// The Session pane's "Peer links" section, drawn on an owner's page only
//// (protocol-change/077).
////
//// It lists the focused strand's links as `this › target` rows for the links
//// that strand may send along and `source › this` rows for the links that
//// reach it. A link that may wake its target carries the mark `may wake`, and
//// a link the daemon's `[peers] default_links` setting supplies carries the
//// mark `default`. Under the list the owner may Link a session: choose one of
//// the sessions the page's sidebar lists, say what the link allows, choose
//// whether the opposite link is granted too, type the other strand (it starts
//// as `main`) and submit. Each row has an Unlink button. For a pair that links
//// both ways it asks which direction to remove, or both.
////
//// The words are plain and fixed, with no left-edge bars and no shadows: a
//// question is a tinted block with a hairline border, as the make-shareable
//// question is (`view/share`). The section is the Session pane's seventh and
//// last child, so its handlers are beneath `component.peers_path`, which only
//// an owner's socket admits. A member's or an observer's page draws
//// `element.none()` there.
////
//// Every session name, session identity and strand is text from the catalogue
//// or from a session. Each is drawn as a text node and none is an attribute,
//// a class, a key or a handler's message: a button carries the row the server
//// drew and the component checks it against its board again when the button
//// is pressed. The one field the browser fills is the target strand, in a form
//// whose submit the page decodes as exactly one field named `text`.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/peer_links.{
  type Control, type Press, type Row, BothWays, BusyOnly, Choosing, Configuring,
  Default, Idle, Incoming, MayWake, OneWay, Outgoing, Removing, Resting, Waiting,
}

/// What the section sends.
pub type Presses(message) {
  Presses(
    /// Wraps a button's `Press` as the page's message.
    press: fn(Press) -> message,
    /// The Link form's submit, which carries the target strand as one text
    /// field.
    submit: Attribute(message),
  )
}

/// The section for the page's controls, or nothing for a page that has none.
/// `strand` is the strand on screen, and `sessions` is the sessions the page's
/// sidebar lists as running, other than this one, as identity and name.
///
/// ## Examples
///
/// ```gleam
/// // peer_links_view.view(control, "main", [#("id", "review auth")], presses)
/// ```
pub fn view(
  control: Control,
  strand: String,
  sessions: List(#(String, String)),
  presses: Presses(message),
) -> Element(message) {
  case control {
    peer_links.Withheld -> element.none()
    peer_links.Offered(board:, asking:, step:, note:) ->
      html.section(
        [
          attribute.class("peer-links"),
          attribute.aria_label("Peer links"),
        ],
        [
          html.h3([attribute.class("session-eyebrow")], [
            html.text("Peer links"),
          ]),
          listing(board, step, presses),
          controls(strand, sessions, step, asking, presses),
          status(note),
        ],
      )
  }
}

fn listing(
  board: option.Option(peer_links.Board),
  step: peer_links.Step,
  presses: Presses(message),
) -> Element(message) {
  case board {
    None ->
      html.p([attribute.class("session-quiet")], [html.text("not read yet")])
    Some(board) ->
      case board.rows {
        [] ->
          html.p([attribute.class("session-quiet")], [
            html.text("No links from or to this strand."),
          ])
        rows ->
          html.div([], [
            html.ul(
              [attribute.class("peer-link-list")],
              list.map(rows, fn(row) { item(board, row, step, presses) }),
            ),
            case board.omitted {
              0 -> element.none()
              left ->
                html.p([attribute.class("session-quiet")], [
                  html.text(
                    "+" <> int.to_string(left) <> " more links not shown",
                  ),
                ])
            },
          ])
      }
  }
}

// One row: the sentence with its marks, and its Unlink button or its question.
fn item(
  board: peer_links.Board,
  row: Row,
  step: peer_links.Step,
  presses: Presses(message),
) -> Element(message) {
  let strand = board.strand
  html.li([attribute.class("peer-link")], [
    html.p([attribute.class("peer-link-text")], [
      html.text(sentence(row, strand)),
      marks(row),
    ]),
    case step {
      Removing(open) if open == row ->
        unlink_question(board, row, board.strand, presses)
      Removing(_) | Resting | Choosing | Configuring(..) ->
        html.div([attribute.class("share-actions")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("peer-unlink"),
              event.on_click(presses.press(peer_links.AskUnlink(row))),
            ],
            [html.text("Unlink")],
          ),
        ])
    },
  ])
}

// `this › target` for a link the strand sends along, `source › this` for one
// that reaches it. The other session is its name, or the start of its identity
// when the daemon could not read a name.
fn sentence(row: Row, strand: String) -> String {
  let other = named(row) <> " / " <> row.strand
  case row.direction {
    Outgoing -> strand <> " › " <> other
    Incoming -> other <> " › " <> strand
  }
}

fn named(row: Row) -> String {
  case row.name {
    "" -> string.slice(row.session, 0, 8)
    name -> name
  }
}

fn marks(row: Row) -> Element(message) {
  let words =
    list.flatten([
      case peer_links.wake_mark(row.wake) {
        Some(mark) -> [mark]
        None -> []
      },
      case row.basis {
        Default -> ["default"]
        peer_links.Granted -> []
      },
    ])
  case words {
    [] -> element.none()
    _ ->
      html.span([attribute.class("session-quiet")], [
        html.text(" · " <> string.join(words, " · ")),
      ])
  }
}

// The question for one row. A pair that links both ways asks which direction,
// and a single link asks to confirm.
fn unlink_question(
  board: peer_links.Board,
  row: Row,
  strand: String,
  presses: Presses(message),
) -> Element(message) {
  let button = fn(class, words, press) {
    html.button(
      [
        attribute.type_("button"),
        attribute.class(class),
        event.on_click(presses.press(press)),
      ],
      [html.text(words)],
    )
  }
  let keep = button("share-cancel", "Keep it", peer_links.Cancel)
  case peer_links.partner(board, row) {
    None ->
      question("Remove " <> sentence(row, strand) <> "?", [
        button(
          "share-make",
          "Remove",
          peer_links.ConfirmUnlink(peer_links.ThisWay),
        ),
        keep,
      ])
    Some(other) ->
      question("These two strands link both ways. Which do you remove?", [
        button(
          "share-make",
          sentence(row, strand),
          peer_links.ConfirmUnlink(peer_links.ThisWay),
        ),
        button(
          "share-make",
          sentence(other, strand),
          peer_links.ConfirmUnlink(peer_links.OtherWay),
        ),
        button(
          "share-make",
          "Both directions",
          peer_links.ConfirmUnlink(peer_links.EitherWay),
        ),
        keep,
      ])
  }
}

fn question(
  words: String,
  buttons: List(Element(message)),
) -> Element(message) {
  html.div([attribute.class("share-ask")], [
    html.p([attribute.class("share-lead"), attribute.role("alert")], [
      html.text(words),
    ]),
    html.div([attribute.class("share-actions")], buttons),
  ])
}

// The Link control under the list: a button, the session picker, or the form.
fn controls(
  strand: String,
  sessions: List(#(String, String)),
  step: peer_links.Step,
  asking: peer_links.Asking,
  presses: Presses(message),
) -> Element(message) {
  case step {
    Resting | Removing(_) ->
      html.div([attribute.class("share-actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("peer-link-open"),
            event.on_click(presses.press(peer_links.OpenLink)),
          ],
          [html.text("Link a session")],
        ),
      ])
    Choosing -> picker(sessions, presses)
    Configuring(name:, wake:, reverse:, ..) ->
      html.div([attribute.class("share-ask")], [
        html.p([attribute.class("share-lead")], [
          html.text("Link " <> strand <> " to " <> name),
        ]),
        toggle(
          "Deliver only while it is busy",
          wake == BusyOnly,
          presses.press(peer_links.ChooseWake(BusyOnly)),
        ),
        toggle(
          "May wake it when it is idle",
          wake == MayWake,
          presses.press(peer_links.ChooseWake(MayWake)),
        ),
        toggle(
          "Both directions",
          reverse == BothWays,
          presses.press(
            peer_links.ChooseReverse(case reverse {
              BothWays -> OneWay
              OneWay -> BothWays
            }),
          ),
        ),
        html.form([attribute.class("control-input"), presses.submit], [
          html.input([
            attribute.type_("text"),
            attribute.name("text"),
            attribute.value("main"),
            attribute.aria_label("Strand in the other session"),
            attribute.attribute("maxlength", "128"),
            attribute.attribute("autocomplete", "off"),
          ]),
          html.button(
            [
              attribute.type_("submit"),
              attribute.class("share-make"),
              ..case asking {
                Waiting -> [attribute.disabled(True)]
                Idle -> []
              }
            ],
            [html.text("Link")],
          ),
        ]),
        html.div([attribute.class("share-actions")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("share-cancel"),
              event.on_click(presses.press(peer_links.Cancel)),
            ],
            [html.text("Cancel")],
          ),
        ]),
      ])
  }
}

fn picker(
  sessions: List(#(String, String)),
  presses: Presses(message),
) -> Element(message) {
  html.div([attribute.class("share-ask")], [
    html.p([attribute.class("share-lead")], [
      case sessions {
        [] -> html.text("No other session is running.")
        _ -> html.text("Link to which session?")
      },
    ]),
    html.ul(
      [attribute.class("peer-pick-list")],
      list.map(sessions, fn(entry) {
        let #(session, name) = entry
        html.li([], [
          html.button(
            [
              attribute.type_("button"),
              event.on_click(
                presses.press(peer_links.PickSession(session, name)),
              ),
            ],
            [html.text(name)],
          ),
        ])
      }),
    ),
    html.div([attribute.class("share-actions")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("share-cancel"),
          event.on_click(presses.press(peer_links.Cancel)),
        ],
        [html.text("Cancel")],
      ),
    ]),
  ])
}

// A choice that stays on screen: pressed or not, said both in the label's
// state attribute and by the button being the selected one.
fn toggle(words: String, on: Bool, press: message) -> Element(message) {
  html.div([attribute.class("share-actions")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.attribute("aria-pressed", case on {
          True -> "true"
          False -> "false"
        }),
        event.on_click(press),
      ],
      [html.text(words)],
    ),
  ])
}

fn status(note: peer_links.Note) -> Element(message) {
  case note {
    peer_links.Silent ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [])
    peer_links.Said(outcome:) ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [
        html.text(peer_links.outcome_words(outcome)),
      ])
    peer_links.Refused(reason:) ->
      html.p(
        [
          attribute.class("rename-status"),
          attribute.class("refused"),
          attribute.role("status"),
        ],
        [html.text(peer_links.reason_words(reason))],
      )
  }
}
