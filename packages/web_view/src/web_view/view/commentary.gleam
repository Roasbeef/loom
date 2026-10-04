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
//// The section is one native `details`, closed, so a short session's panel is
//// not pushed to the fold by bodies nobody asked for. Its summary is one line:
//// `Advisor · 3 reviews · last: Nothing to correct.`, which names the count
//// and the first line of the newest review. Opening it is the browser's and
//// the server never learns which it is, so it draws no handler and keeps no
//// state, as the settled group does (`view/strip`). Inside, each review is a
//// label line and its body, drawn through the lane's Markdown drawer so
//// backticked names read as code (`web_view/markdown_view`, which keeps 051's
//// rules: text nodes only, no link followed). The closed `details` is
//// recorded in protocol-change/051's addendum of 2026-10-03 on the right
//// panel, which amends the sentence of 2026-10-02 that says the section is
//// drawn open.
////
//// The section is drawn while `main` is on screen, and `element.none()`
//// otherwise or when there is nothing to say, so the panel's child list
//// keeps one length and no handler's path moves.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/advisor_history
import session_view/markdown
import session_view/text_hygiene
import web_view/markdown_view

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
  // The board is oldest-first, so the newest reviews are its tail. Keeping
  // the tail in board order leaves the newest review last, as in the lane.
  let omitted = int.max(0, list.length(board.items) - visible_items)
  let shown = list.drop(board.items, omitted)
  html.section(
    [
      attribute.class("commentary"),
      attribute.aria_label("Advisor commentary, captured and not sent"),
    ],
    [
      html.details([], [
        html.summary([attribute.class("commentary-summary")], [
          html.text(summary(board)),
        ]),
        html.div(
          [attribute.class("commentary-items")],
          list.flatten([
            list.map(shown, item),
            more(omitted),
            unloaded(board.unloaded),
          ]),
        ),
      ]),
    ],
  )
}

/// The section's one summary line: the count of reviews and the first line of
/// the newest, cut to `summary_limit` characters. The words are fixed and the
/// quoted line is the advisor's, so a host draws it as a text node.
///
/// ## Examples
///
/// ```gleam
/// // commentary.summary(board) == "Advisor · 2 reviews · last: Nothing to correct."
/// ```
pub fn summary(board: advisor_history.Board) -> String {
  let count = list.length(board.items)
  let head =
    "Advisor · "
    <> int.to_string(count)
    <> case count {
      1 -> " review"
      _ -> " reviews"
    }

  case list.last(board.items) {
    Ok(newest) ->
      case first_line(newest.text) {
        "" -> head
        line -> head <> " · last: " <> line
      }
    Error(Nil) -> head
  }
}

/// The most characters of the newest review the summary quotes.
pub const summary_limit = 72

// The first line of a review that has any words, without the backticks and
// emphasis marks the body's Markdown carries, since a summary is plain text,
// and cut to `summary_limit` with an ellipsis.
fn first_line(text: String) -> String {
  let line =
    text_hygiene.multiline(text)
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.find(fn(line) { line != "" })
    |> result.unwrap("")
    |> string.replace("`", "")
    |> string.replace("**", "")

  case string.length(line) > summary_limit {
    True -> string.slice(line, 0, summary_limit - 1) <> "…"
    False -> line
  }
}

// One captured review: the request's label as its head, the advisor's
// whole text as the body. The label is the projection's own wording, which
// names the request and never claims the primary received anything.
fn item(entry: advisor_history.Item) -> Element(message) {
  html.article([attribute.class("commentary-item")], [
    html.p([attribute.class("commentary-label")], [
      html.text(label(entry.annotation)),
    ]),
    html.div(
      [attribute.class("commentary-body"), attribute.class("markdown")],
      markdown_view.blocks(markdown.parse(text_hygiene.multiline(entry.text))),
    ),
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
