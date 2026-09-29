//// The page's frame: the top bar across the full width, and beneath it
//// three columns, the sessions' sidebar on the left, the session's centre
//// and the strand panel on the right.
////
//// Both pages lay themselves out through this module, so the order of the
//// frame's children is written once. That order is not cosmetic. Lustre
//// names an event handler by its path in the tree, and the page socket
//// admits an observer's click only at two fixed paths
//// (`component.older_path` and `component.strip_path`), so a region that
//// moved would move an admitted path with it. The children are, in order:
////
//// 0. the top bar (`view/heading`);
//// 1. the sidebar (`view/sidebar`), or `element.none()` where a page has
////    none, so the regions after it keep their index either way;
//// 2. the centre, a `main` holding the transcript and, below it, the
////    dock or the observer's bar;
//// 3. the strand panel (`view/panel`), the page's last child, so that a
////    region added after it in a later change does not move a path again.
////
//// The module decides nothing about the session. Each region is drawn by its
//// own module and handed in as an element, and this one places them. The
//// stylesheet turns the four children into the grid; nothing here depends on
//// the browser's width.
////
//// The module takes plain elements and imports nothing from
//// `web_view/component`, which imports it.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Who the page is drawn for. The frame's class says so, and nothing else
/// about the frame differs: the observer's page has an empty place where the
/// operator's sidebar is.
pub type Audience {
  /// The operator's page: it may send commands.
  Operator

  /// The observer's page: read-only, and it draws no sidebar.
  Observer
}

/// The frame for `audience`, with each region in its place.
///
/// `sidebar` is `element.none()` on a page that draws none. `centre` is the
/// children of the centre column, in order: the transcript first, so its
/// "Load older" button keeps the path `component.older_path` names.
///
/// ## Examples
///
/// ```gleam
/// // shell.view(shell.Observer, heading, element.none(), [lane], panel)
/// ```
pub fn view(
  audience: Audience,
  bar: Element(message),
  sidebar: Element(message),
  centre: List(Element(message)),
  panel: Element(message),
) -> Element(message) {
  html.div(frame_attributes(audience), [
    bar,
    sidebar,
    html.main([attribute.class("centre")], centre),
    panel,
  ])
}

// The operator's frame carries a second class, which the observer's lacks.
fn frame_attributes(audience: Audience) -> List(attribute.Attribute(message)) {
  case audience {
    Operator -> [attribute.class("loom-session"), attribute.class("operator")]
    Observer -> [attribute.class("loom-session")]
  }
}
