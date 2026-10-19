//// The Session pane's "Proposals" section, drawn on the daemon owner's page
//// only (protocol-change/086).
////
//// A model that notices a correction worth keeping queues a proposal for a
//// standing rule, and the daemon writes nothing until a person decides. The
//// section lists the proposals newest first. Each row says which proposal it
//// is, when it was made, where it stands and the first line of why, and opens
//// into a drawer that shows the rationale, the session it came from and the
//// edit itself through the page's one diff drawer (`view/diff`): the text an
//// approval would remove in red and the text it would add in green. A pending
//// row has Approve and Reject buttons. Approve asks its question in place
//// first, because an approval writes a rule that every later session
//// obeys; Reject sends at once. A row that is no longer pending says what
//// became of it and has no buttons, as does a row of a kind or state this
//// page does not know.
////
//// The words are plain and fixed, with no left-edge bars and no shadows: the
//// question is a tinted block with a hairline border, as the make-shareable
//// question is (`view/share`). The section is the Session pane's eighth and
//// last child, so its handlers are beneath `component.proposals_path`. An
//// observer's page and a member's draw `element.none()` there, and the
//// daemon refuses the commands to either on its own account.
////
//// Every id, rationale, rule text and session identity comes from a model.
//// Each is drawn as a text node. None is an attribute, a class, a key or a
//// handler's message: a handler carries the identity the server drew on the
//// button from its own board, and that is a value held by the page's server
//// and never read back from the browser. The classes are literals chosen from
//// a closed set.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/proposals as board_words
import web_view/proposals.{type State}
import web_view/view/diff
import web_view/view/home_table

/// The messages the section's buttons send.
pub type Presses(message) {
  Presses(
    /// An Approve button, with the identity of the proposal it was drawn on.
    /// The press opens the question and sends nothing.
    ask: fn(String) -> message,
    /// The question's confirm, which sends the approval the question armed.
    approve: message,
    /// The question's way out, which closes it and sends nothing.
    keep: message,
    /// A Reject button, with the identity of the proposal it was drawn on.
    reject: fn(String) -> message,
  )
}

/// The section for the page's board: what is proposed, that nothing is, that
/// the board has not been read, or why it could not be.
///
/// `notice` is the words of the last refusal, empty when there is none.
///
/// ## Examples
///
/// ```gleam
/// // proposals_view.view(component.proposals_kept(model), component.proposals_state(model), "", presses)
/// ```
pub fn view(
  board: Option(board_words.Board),
  state: State,
  notice: String,
  presses: Presses(message),
) -> Element(message) {
  html.section(
    [
      attribute.class("proposals"),
      attribute.id("proposals"),
      attribute.aria_label("Proposals"),
    ],
    [
      html.h3([attribute.class("session-eyebrow")], [
        html.text(heading(board)),
      ]),
      ..list.append(refusal(notice), body(board, notice, state, presses))
    ],
  )
}

// The heading carries the count, so the reader who scrolls to the section
// from the tab's badge sees the same number there.
fn heading(board: Option(board_words.Board)) -> String {
  case board_words.badge(board) {
    Some(pending) -> "Proposals · " <> int.to_string(pending) <> " pending"
    None -> "Proposals"
  }
}

// The last refusal, in the words the shared record kept. It is an alert, so a
// screen reader says it when it appears.
fn refusal(notice: String) -> List(Element(message)) {
  case notice {
    "" -> []
    words -> [
      html.p([attribute.class("proposals-notice"), attribute.role("alert")], [
        html.text(words),
      ]),
    ]
  }
}

// A board that has not been read says so, unless a refusal has said why it
// has not, since "reading" beside "forbidden" would contradict itself.
fn body(
  board: Option(board_words.Board),
  notice: String,
  state: State,
  presses: Presses(message),
) -> List(Element(message)) {
  case board, notice {
    None, "" -> [
      html.p([attribute.class("session-quiet")], [
        html.text(board_words.loading_words),
      ]),
    ]
    None, _ -> []
    Some(board), _ ->
      case board.proposals {
        [] -> [
          html.p([attribute.class("session-quiet")], [
            html.text(board_words.empty_words),
          ]),
        ]
        rows -> [
          html.p([attribute.class("share-lead")], [
            html.text(board_words.applies_words),
          ]),
          html.ul(
            [attribute.class("proposals-list")],
            list.map(rows, fn(row) { row_view(row, state, presses) }),
          ),
          ..omitted(board.omitted)
        ]
      }
  }
}

// The one line that says the daemon left older rows out of the board, or no
// line when it left none.
fn omitted(count: Int) -> List(Element(message)) {
  case board_words.omitted_words(count) {
    Some(words) -> [
      html.p([attribute.class("session-quiet")], [html.text(words)]),
    ]
    None -> []
  }
}

// One proposal: its facts, the drawer that opens onto the edit, and what the
// reader can do about it.
fn row_view(
  row: board_words.Proposal,
  state: State,
  presses: Presses(message),
) -> Element(message) {
  html.li([attribute.class("proposal-row"), state_class(row.state)], [
    html.p([attribute.class("proposal-head")], [
      html.span([attribute.class("proposal-id")], [html.text(row.id)]),
      html.span([attribute.class("proposal-state")], [
        html.text(board_words.state_words(row.state)),
      ]),
      html.span([attribute.class("session-quiet")], [html.text(made(row))]),
    ]),
    html.p([attribute.class("proposal-why")], [
      html.text(board_words.headline(row.rationale, 140)),
    ]),
    drawer(row),
    ending(row, state, presses),
  ])
}

// The closed set of classes a state may give its row, each a literal, so no
// state the daemon names can choose one.
fn state_class(state: board_words.State) -> attribute.Attribute(message) {
  case state {
    board_words.Pending -> attribute.class("proposal-pending")
    board_words.Approved -> attribute.class("proposal-approved")
    board_words.Rejected -> attribute.class("proposal-rejected")
    board_words.Stale -> attribute.class("proposal-stale")
    board_words.Other(_) -> attribute.class("proposal-unknown")
  }
}

// When it was proposed, in UTC, which is all the wire carries.
fn made(row: board_words.Proposal) -> String {
  let #(date, clock) = home_table.utc(row.created_ms)
  date <> " " <> clock <> " UTC"
}

// The native drawer that opens onto the whole rationale, where it came from
// and the edit, so the list stays one line a row and nothing about the drawer
// needs the server.
fn drawer(row: board_words.Proposal) -> Element(message) {
  let entry = case row.source.entry {
    Some(entry) -> [
      html.text(" · entry "),
      html.span([attribute.class("proposal-ref")], [html.text(entry)]),
    ]
    None -> []
  }
  html.details([attribute.class("proposal-drawer")], [
    html.summary([], [html.text("Review the change")]),
    html.p([attribute.class("proposal-source session-quiet")], [
      html.text("From session "),
      html.span([attribute.class("proposal-ref")], [
        html.text(row.source.session),
      ]),
      ..entry
    ]),
    html.p([attribute.class("proposal-rationale")], [html.text(row.rationale)]),
    html.p([attribute.class("session-quiet")], [html.text(edit_words(row))]),
    diff.view(board_words.diff_lines(row), 0),
  ])
}

fn edit_words(row: board_words.Proposal) -> String {
  case row.old {
    "" -> "Adds a " <> board_words.kind_words(row.kind) <> " to " <> row.target
    _ -> "Replaces text in " <> row.target
  }
}

// What follows the drawer: the buttons or the question for a pending row, and
// for any other row the sentence about what became of it.
fn ending(
  row: board_words.Proposal,
  state: State,
  presses: Presses(message),
) -> Element(message) {
  case board_words.decidable(row), proposals.asking(state, row.id) {
    True, True -> question(row, presses)
    True, False ->
      html.div([attribute.class("share-actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("proposal-approve"),
            event.on_click(presses.ask(row.id)),
          ],
          [html.text(proposals.ask_label)],
        ),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("proposal-reject"),
            event.on_click(presses.reject(row.id)),
          ],
          [html.text(proposals.reject_label)],
        ),
      ])
    False, _ ->
      html.p([attribute.class("proposal-settled session-quiet")], [
        html.text(board_words.settled_words(row)),
      ])
  }
}

// The question that replaces the buttons in place: the sentence, the confirm
// that names the act, and the way out.
fn question(
  row: board_words.Proposal,
  presses: Presses(message),
) -> Element(message) {
  html.div([attribute.class("share-ask")], [
    html.p([attribute.class("share-lead"), attribute.role("alert")], [
      html.text(
        "Approve this "
        <> board_words.kind_words(row.kind)
        <> "? "
        <> board_words.approve_words(row),
      ),
    ]),
    html.div([attribute.class("share-actions")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("share-make"),
          event.on_click(presses.approve),
        ],
        [html.text("Approve " <> board_words.kind_words(row.kind))],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("share-cancel"),
          event.on_click(presses.keep),
        ],
        [html.text(proposals.keep_label)],
      ),
    ]),
  ])
}

/// Pending, decidable proposals from `board` rendered as inline approval-style
/// cards for the dock above the composer. Each card is keyed by its index in
/// the pending list so no model-authored text is ever a key or attribute.
/// A board with no pending proposals returns `[]`.
///
/// ## Examples
///
/// ```gleam
/// assert proposals_view.dock_cards(None, proposals.new(), presses) == []
/// ```
pub fn dock_cards(
  board: Option(board_words.Board),
  state: State,
  presses: Presses(message),
) -> List(#(String, Element(message))) {
  case board {
    None -> []
    Some(board) -> {
      let pending_rows = list.filter(board.proposals, board_words.decidable)
      list.index_map(pending_rows, fn(row, index) {
        #(int.to_string(index), dock_card(row, state, presses))
      })
    }
  }
}

fn dock_card(
  row: board_words.Proposal,
  state: State,
  presses: Presses(message),
) -> Element(message) {
  html.article([attribute.class("approval-card proposal-card")], [
    html.p([attribute.class("approval-head")], [
      html.b([attribute.class("approval-strand")], [html.text(row.id)]),
      html.text(" proposes a " <> board_words.kind_words(row.kind) <> " for "),
      html.span([attribute.class("proposal-ref")], [html.text(row.target)]),
    ]),
    html.p([attribute.class("approval-question")], [html.text(row.rationale)]),
    diff.view(board_words.diff_lines(row), 0),
    dock_ending(row, state, presses),
  ])
}

fn dock_ending(
  row: board_words.Proposal,
  state: State,
  presses: Presses(message),
) -> Element(message) {
  case proposals.asking(state, row.id) {
    True -> question(row, presses)
    False ->
      html.div(
        [attribute.class("approval-actions"), attribute.class("arming")],
        [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("approval-deny proposal-reject"),
              event.on_click(presses.reject(row.id)),
            ],
            [html.text("Reject " <> board_words.kind_words(row.kind))],
          ),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("approval-allow proposal-approve"),
              event.on_click(presses.ask(row.id)),
            ],
            [html.text("Approve " <> board_words.kind_words(row.kind) <> "…")],
          ),
          html.span([attribute.class("arm-note")], [html.text("Arming…")]),
        ],
      )
  }
}

/// The badge a heading or a tab may show for the board: nothing when none are
/// pending.
///
/// ## Examples
///
/// ```gleam
/// assert proposals_view.pending(None) == 0
/// ```
pub fn pending(board: Option(board_words.Board)) -> Int {
  case board_words.badge(board) {
    Some(count) -> count
    None -> 0
  }
}
