//// The strand panel: the right-hand column, a tabbed panel of three panes,
//// the Strands, Changes and Session tabs, with the advisor's pending
//// nudges drawn under them.
////
//// The panel is the page's last child (`view/shell`). It is an `aside` whose
//// children are the three panes, always in the same order and all drawn, so
//// no pane's place depends on what another holds, and then the advisor's
//// pending nudges, drawn by `view/nudges` as a section of their own under
//// the panes. The nudge card is not a pane: the tab rules hide a tab's
//// siblings, and the card belongs to none of them, so it shows whichever
//// tab is chosen — the queue is the advisor's, not a view of one pane's
//// data — and it is the aside's last child, so the paths the panes hold
//// (`component.strip_path`, `component.invite_path`) do not move. Its
//// visibility is the column's: the card is on screen while the panel is
//// open, is hidden with the column when the reader closes it, and below
//// 980px the stylesheet hides it so the narrow row of cards is left alone
//// (the cost is recorded in protocol-change/051's addendum of 2026-10-02).
////
//// The Strands pane is the panel's first child. Its title comes first and the
//// strip's list second, and the list's `ul` is the path
//// `component.strip_path` names, so nothing may be placed between the title
//// and the list. While a strand other than `main` is in focus the pane's
//// third child is that strand's own view (`view/strand_detail`), and the pane
//// carries the class `detailed`, which the stylesheet reads to hide the title
//// and the list: the detail replaces them on screen and the list stays in the
//// page, because the marker relay clicks a card and the cards must exist to be
//// clicked. The strip's cards are the only handlers in the panel, and
//// the panel carries no control that decides anything: a card that needs a
//// decision says so in its status line, and the approval card that answers it
//// stays in the dock, above the composer, where its rules hold
//// (docs/design-notes/web-design.md, section 6.1).
////
//// The title counts the strands the list holds, as text the component
//// computed from the strip (`strip.count`). No attribute here is built from
//// session text.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The panel around the three panes and the advisor's pending nudges,
/// the first pane being `strands` under a title saying how many strands
/// it lists.
///
/// With no strand listed the title is the word alone, so a page that has not
/// yet captured a session does not say "Strands · 0". `detail` is the view of
/// the strand in focus, when it has one, and the pane hides its title and list
/// while it is drawn. `changes` and `session` are whole panes, drawn by their
/// own modules. `nudges` is the advisor's pending-nudge card
/// (`view/nudges`), drawn under the panes on every tab, or
/// `element.none()` when nothing is waiting — which keeps the aside's child
/// list one length, so no handler's path moves when a nudge lands.
///
/// ## Examples
///
/// ```gleam
/// // panel.view(strip.count(strip), strip.view(strip, focus), None, changes.view(board), session, nudges.view(board))
/// ```
pub fn view(
  count: Int,
  strands: Element(message),
  detail: Option(Element(message)),
  changes: Element(message),
  session: Element(message),
  nudges: Element(message),
) -> Element(message) {
  html.aside(
    [
      attribute.class("panel"),
      attribute.aria_label("Strand panel"),
      attribute.attribute("slot", "right"),
    ],
    [
      html.section(
        list.append(
          [
            attribute.class("pane"),
            attribute.class("pane-strands"),
            attribute.aria_label("Strands"),
          ],
          case detail {
            Some(_) -> [attribute.class("detailed")]
            None -> []
          },
        ),
        [
          html.h2([attribute.class("panel-title")], [html.text(title(count))]),
          strands,
          case detail {
            Some(detail) -> detail
            None -> element.none()
          },
        ],
      ),
      changes,
      session,
      nudges,
    ],
  )
}

/// The Strands pane's title for `count` strands.
///
/// ## Examples
///
/// ```gleam
/// assert panel.title(0) == "Strands"
/// assert panel.title(3) == "Strands · 3"
/// ```
pub fn title(count: Int) -> String {
  case count {
    0 -> "Strands"
    _ -> "Strands · " <> int.to_string(count)
  }
}
