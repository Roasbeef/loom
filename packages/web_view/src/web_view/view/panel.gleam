//// The strand panel: the right-hand column, a tabbed panel of three panes,
//// the Strands, Changes and Session tabs.
////
//// The panel is the page's last child (`view/shell`). It is an `aside` whose
//// children are the three panes, always in the same order and all drawn, so
//// no pane's place depends on what another holds. The panel adds the column
//// and the Strands pane's title around the strip's list, which `view/strip`
//// draws and memoizes; the Changes and Session panes are drawn by
//// `view/changes` and `view/session_tab`, and each is a `section` of its own.
//// The tab bar is not here: the shell element draws the buttons above the
//// column (`packages/web_client`), keeps which tab is chosen, and hides the
//// panes of the others. The server draws every pane and never learns which
//// shows.
////
//// The Strands pane is the panel's first child. Its title comes first and the
//// strip's list second, and the list's `ul` is the path
//// `component.strip_path` names, so nothing may be placed between the title
//// and the list. The strip's cards are the only handlers in the panel, and
//// the panel carries no control that decides anything: a card that needs a
//// decision says so in its status line, and the approval card that answers it
//// stays in the dock, above the composer, where its rules hold
//// (docs/design-notes/web-design.md, section 6.1).
////
//// The title counts the strands the list holds, as text the component
//// computed from the strip (`strip.count`). No attribute here is built from
//// session text.

import gleam/int
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The panel around the three panes, the first of which is `strands` under a
/// title saying how many strands it lists.
///
/// With no strand listed the title is the word alone, so a page that has not
/// yet captured a session does not say "Strands · 0". `changes` and `session`
/// are whole panes, drawn by their own modules.
///
/// ## Examples
///
/// ```gleam
/// // panel.view(strip.count(strip), strip.view(strip, focus), changes.view(board), session)
/// ```
pub fn view(
  count: Int,
  strands: Element(message),
  changes: Element(message),
  session: Element(message),
) -> Element(message) {
  html.aside(
    [
      attribute.class("panel"),
      attribute.aria_label("Strand panel"),
      attribute.attribute("slot", "right"),
    ],
    [
      html.section(
        [
          attribute.class("pane"),
          attribute.class("pane-strands"),
          attribute.aria_label("Strands"),
        ],
        [
          html.h2([attribute.class("panel-title")], [html.text(title(count))]),
          strands,
        ],
      ),
      changes,
      session,
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
