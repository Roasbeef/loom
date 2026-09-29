//// The strand panel: the right-hand column, which holds the strand cards
//// the agent strip held before the redesign.
////
//// The panel is the page's last child (`view/shell`). It draws a title and
//// the strip's list, which `view/strip` draws and memoizes; the panel adds
//// the column and its title around it and decides nothing about the
//// session. The strip's list is the panel's second child, which is the path
//// `component.strip_path` names and the observer's socket admits clicks
//// beneath, so nothing may be placed between the title and the list.
////
//// The title counts the strands the list holds, as text the component
//// computed from the strip (`strip.count`). No attribute here is built from
//// session text.

import gleam/int
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The panel around `strands`, titled with how many strands it lists.
///
/// With no strand listed the title is the word alone, so a page that has not
/// yet captured a session does not say "Strands · 0".
///
/// ## Examples
///
/// ```gleam
/// // panel.view(strip.count(strip), strip.view(strip, focus))
/// ```
pub fn view(count: Int, strands: Element(message)) -> Element(message) {
  html.aside([attribute.class("panel"), attribute.aria_label("Strand panel")], [
    html.h2([attribute.class("panel-title")], [html.text(title(count))]),
    strands,
  ])
}

/// The panel's title for `count` strands.
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
