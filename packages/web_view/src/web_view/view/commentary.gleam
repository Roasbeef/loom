//// The advisor's commentary section: what the advisor said on its own
//// strand while watching the strand on screen, drawn in the strand panel
//// beside the strands it observes.
////
//// The lane keeps only a hairline per review (`view/lane`); the bodies
//// live here and in the advisor's own focused transcript. The board is
//// the same `advisor_history` projection both read, and the section asks
//// the same visibility rule the lane asks (`advisor_history.visible`): a
//// board for `main` only, because the advisor's own transcript already
//// holds the same text as its ordinary entries and drawing the section
//// there too would print it twice.
////
//// Like the pending-nudges card, the section is read-only and carries no
//// handler, because it changes nothing: the advisor's words were captured,
//// not sent, and the run that delivers them is the primary's next run
//// start, which no click here can cause. The bodies are the advisor's
//// prose, untrusted display text: each is a text node, and never an
//// attribute, a class or a key. The request labels are the projection's
//// own (`Advisor · quiet requested` and its siblings), which describe the
//// request only, never a delivery. When the captured window omits older
//// ancestry the board says so, and the section repeats it, so a reader is
//// never told this is the whole history when it is not.
////
//// The section is drawn while any strand other than the advisor is on
//// screen, and `element.none()` when there is nothing to say, so the
//// panel's child list keeps one length and no handler's path moves.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/advisor_history
import session_view/text_hygiene

/// How many of the board's items the section draws before counting the
/// rest. The panel scrolls on its own, but a long review history should
/// not push the strand cards off it: the count line keeps the section
/// honest about what it left out, the same way the nudge card's does.
pub const visible_items = 3

/// The section for `board`, or nothing when it holds no items or the strand
/// on screen is the advisor's own, where the transcript already has them.
///
/// ## Examples
///
/// ```gleam
/// // commentary.view(advisor_history.Board([], None))
/// ```
pub fn view(board: advisor_history.Board) -> Element(message) {
  use <- element.memo([element.ref(board)])
  case board.items {
    [] -> element.none()
    [_, ..] -> section(board)
  }
}

fn section(board: advisor_history.Board) -> Element(message) {
  let shown = list.take(board.items, visible_items)
  let omitted = list.length(board.items) - list.length(shown)
  html.section(
    [
      attribute.class("commentary"),
      attribute.aria_label("Advisor commentary, captured and not sent"),
    ],
    list.flatten([
      [
        html.h3([attribute.class("panel-title")], [
          html.text("Advisor commentary"),
        ]),
      ],
      list.map(shown, item),
      more(omitted),
      unloaded(board.unloaded),
    ]),
  )
}

// One captured review: the request's label as its head, the advisor's
// whole text as the body. The label is the projection's own wording, which
// names the request and never claims the primary received anything.
fn item(entry: advisor_history.Item) -> Element(message) {
  html.article([attribute.class("commentary-item")], [
    html.p([attribute.class("commentary-label")], [
      html.text(label(entry.annotation)),
    ]),
    html.p([attribute.class("commentary-body")], [
      html.text(text_hygiene.multiline(entry.text)),
    ]),
  ])
}

fn label(annotation: advisor_history.Annotation) -> String {
  case annotation {
    advisor_history.AdvisorUpdate -> "commentary"
    advisor_history.RequestedQuiet -> "quiet requested"
    advisor_history.RequestedNudge -> "nudge requested"
    advisor_history.RequestedBlock -> "block requested"
    advisor_history.RequestedContinue -> "continue requested"
    advisor_history.RequestedComplete -> "complete requested"
  }
}

fn more(omitted: Int) -> List(Element(message)) {
  case omitted > 0 {
    True -> [
      html.p([attribute.class("commentary-more")], [
        html.text("+ " <> int.to_string(omitted) <> " earlier reviews"),
      ]),
    ]
    False -> []
  }
}

// The board's own honesty about the captured window: a missing older
// parent means this is not the whole advisor history, and the section
// repeats what the board says rather than claiming completeness.
fn unloaded(edge: Option(String)) -> List(Element(message)) {
  case edge {
    Some(_) -> [
      html.p([attribute.class("commentary-unloaded")], [
        html.text("Earlier advisor commentary is not loaded"),
      ]),
    ]
    None -> []
  }
}
