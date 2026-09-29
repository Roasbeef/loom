//// The advisor's pending nudges: what the advisor has written for the
//// primary that the primary has not yet been given, drawn in the dock on
//// both pages.
////
//// The terminal draws the same observation beside its composer, under the
//// label "Advisor · pending, not delivered" (`session_view/advisor_pending`,
//// `docs/architecture/advisor.md`, "The pending panel is a pull
//// observation"). A queued nudge waits in the advisor's guard cell until the
//// primary's next run start drains it into that run's prompt. Seeing it does
//// not deliver it, and there is no command that accepts it early or discards
//// it: the only operation the protocol has on the queue is the read-only
//// `advisor_pending`, and the run start is the drain. So the card carries no
//// button and no handler. It shows every body the observation holds, which the
//// terminal's composer band, limited to three rows, does not, and says how
//// many more the server counted and did not send.
////
//// The card is drawn from the observation alone and never enters the
//// conversation. The bodies are what the advisor wrote, untrusted display
//// text: each is a text node, after the same hygiene the terminal applies,
//// and never an attribute, a class or a key. The words that frame them are
//// fixed here. The card takes the observation as a plain value, because
//// `web_view/component` imports this module to lay the page out, and it
//// draws `element.none()` when nothing is waiting, so the dock's children keep
//// their places.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/advisor_pending
import session_view/text_hygiene

/// The card for the pending nudges, or nothing when the observation holds
/// none or has not been read.
///
/// The observation is memoized, so a render for a streaming answer leaves the
/// card's subtree alone.
///
/// ## Examples
///
/// ```gleam
/// // nudges.view(Some(advisor_pending.Board("main", 1, ["rebase first"], 1)))
/// ```
pub fn view(board: Option(advisor_pending.Board)) -> Element(message) {
  use <- element.memo([element.ref(board)])
  case board {
    Some(advisor_pending.Board(pending: [_, ..], ..) as held) -> card(held)
    Some(advisor_pending.Board(pending: [], ..)) | None -> element.none()
  }
}

// The heading names the count and the recipient, as the terminal's does, and
// the label the terminal's tail carries: these bodies are not delivered. The
// list is every body received, oldest first. A server that counted more than
// it sent is told to the reader, so the card never claims to be the whole
// queue when it is not.
fn card(board: advisor_pending.Board) -> Element(message) {
  let omitted = board.total - list.length(board.pending)
  html.section(
    [
      attribute.class("nudges"),
      attribute.aria_label("Advisor nudges pending, not delivered"),
    ],
    [
      html.p([attribute.class("nudge-head")], [
        html.text(
          "advisor · "
          <> int.to_string(board.total)
          <> " pending, not delivered · held for your next prompt to "
          <> text_hygiene.single_line(board.strand),
        ),
      ]),
      html.ul(
        [attribute.class("nudge-list")],
        list.map(board.pending, fn(body) {
          html.li([attribute.class("nudge-item")], [
            html.text(text_hygiene.multiline(body)),
          ])
        }),
      ),
      ..more(omitted)
    ],
  )
}

fn more(omitted: Int) -> List(Element(message)) {
  case omitted > 0 {
    True -> [
      html.p([attribute.class("nudge-more")], [
        html.text("+" <> int.to_string(omitted) <> " more waiting"),
      ]),
    ]
    False -> []
  }
}
