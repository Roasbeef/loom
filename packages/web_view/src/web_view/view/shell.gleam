//// The page's frame: the top bar across the full width, and beneath it
//// three columns, the sessions' sidebar on the left, the session's centre
//// and the strand panel on the right.
////
//// The frame is `<loom-shell>` (`packages/web_client`), the client element
//// that lays the regions out in its slots and draws the two buttons that
//// hide and show the side columns. The server draws each region as one of
//// its children and never renders whether a column is open, because that is
//// the reader's preference and nothing the server holds; a hidden column is
//// drawn and patched as before.
////
//// Both pages lay themselves out through this module, so the order of the
//// frame's children is written once. That order is not cosmetic. Lustre
//// names an event handler by its path in the tree, and the page socket
//// admits an observer's click only at two fixed paths
//// (`component.older_path` and `component.strip_path`), so a region that
//// moved would move an admitted path with it. The children are, in order:
////
//// 0. the top bar (`view/heading`), in the `bar` slot;
//// 1. the sidebar (`view/sidebar`), in the `left` slot, or `element.none()`
////    where a page has none, so the regions after it keep their index
////    either way;
//// 2. the centre, a `main` holding the transcript and, below it, the
////    dock or the observer's bar, in the default slot;
//// 3. the strand panel (`view/panel`), in the `right` slot and the page's
////    last child, so that a region added after it in a later change does
////    not move a path again. It holds the Strands, Changes and Session panes,
////    which the element shows one at a time.
////
//// A region names its own slot, since only it can put an attribute on its
//// element, and the slot is the same in every page that draws the region.
//// The module decides nothing about the session. Each region is drawn by its
//// own module and handed in as an element, and this one places them.
////
//// The frame has three attributes. `sidebar` is a fixed word saying whether the
//// page has a sidebar, so the element draws no button for a column that is
//// not there; it is written from the `Sidebar` type. `needing` is the number
//// of strands waiting on a decision, which the element draws as the badge on
//// the Strands tab. `workspace` is the digest of the session's workspace that
//// the daemon computed (`component.Start`), under which the element keeps the
//// reader's layout in the browser's storage; it is left out when the host has
//// none. None is ever built from session text: the first is one of two words,
//// the second an integer the component counted, and the third a hex digest
//// the daemon made from a path, which is not the path.
////
//// The element ignores a `workspace` that is not a 64-digit lower-case hex
//// string, so nothing here needs to validate it for the browser's sake.
////
//// The home page (protocol-change/065) draws the same frame with its panel
//// as `element.none()`. The frame's element still draws the panel's column
//// and its button around an empty slot, so the home's class, `loom-home`, is
//// what the stylesheet reads to leave them out. It is a class on the host and
//// no attribute the element reads, so the element is unchanged.
////
//// The module takes plain elements and imports nothing from
//// `web_view/component`, which imports it.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Who the page is drawn for. The frame's class says so, and nothing else
/// about the frame differs.
pub type Audience {
  /// The operator's page: it may send commands.
  Operator

  /// The observer's page: read-only.
  Observer

  /// The home page (protocol-change/065): the same frame with no strand
  /// panel. Its class tells the stylesheet to leave the panel's column and
  /// its button out, since the home has no panel to show.
  Home
}

/// The frame's left column: the sessions' sidebar, or the absence of one.
/// The type is how the frame learns whether to draw a button for the column.
pub type Sidebar(message) {
  /// The page draws a sidebar, which is `view/sidebar`'s element.
  Listed(Element(message))

  /// The page has no sidebar: an observer's page, or an operator's whose
  /// catalogue read listed nothing.
  Unlisted
}

/// The frame for `audience`, with each region in its place.
///
/// `centre` is the children of the centre column, in order: the transcript
/// first, so its "Load older" button keeps the path `component.older_path`
/// names. `needing` is how many strands wait on a decision, for the badge.
/// `proposals` is how many proposed standing rules wait for the owner
/// (protocol-change/086), the number on the Session tab, which is zero on every
/// page but the owner's. `evolution` is how many governed-evolution candidates
/// wait for a person (protocol-change/099), the number on the Evolution tab,
/// or `None` on a page that has no such tab, which carries no attribute and so
/// draws no tab button.
/// `workspace` is the workspace digest, or an empty string for none, in which
/// case the frame carries no `workspace` attribute.
///
/// ## Examples
///
/// ```gleam
/// // shell.view(shell.Observer, heading, shell.Unlisted, [lane], panel, 0, 0, None, "", 0)
/// ```
pub fn view(
  audience: Audience,
  bar: Element(message),
  sidebar: Sidebar(message),
  centre: List(Element(message)),
  panel: Element(message),
  needing: Int,
  proposals: Int,
  evolution: Option(Int),
  workspace: String,
  waiting: Int,
) -> Element(message) {
  element.element(
    "loom-shell",
    frame_attributes(
      audience,
      sidebar,
      needing,
      proposals,
      evolution,
      workspace,
      waiting,
    ),
    [
      bar,
      sidebar_element(sidebar),
      html.main([attribute.class("centre")], centre),
      panel,
    ],
  )
}

/// The class for the audience, the word that says whether there is a sidebar,
/// the count of strands waiting on a decision and, when the host has one, the
/// workspace digest. The operator's frame carries a second class, which the
/// observer's lacks.
fn frame_attributes(
  audience: Audience,
  sidebar: Sidebar(message),
  needing: Int,
  proposals: Int,
  evolution: Option(Int),
  workspace: String,
  waiting: Int,
) -> List(attribute.Attribute(message)) {
  // Dispatch on frame_attributes state.
  let word = case sidebar {
    Listed(_) -> "listed"
    Unlisted -> "none"
  }

  let facts = [
    attribute.attribute("sidebar", word),
    attribute.attribute("needing", int.to_string(needing)),
    ..proposals_fact(
      proposals,
      list.flatten([
        evolution_fact(evolution),
        waiting_fact(waiting),
        digest(workspace),
      ]),
    )
  ]

  // Dispatch on frame_attributes state.
  case audience {
    Operator -> [
      attribute.class("loom-session"),
      attribute.class("operator"),
      ..facts
    ]
    Observer -> [attribute.class("loom-session"), ..facts]
    Home -> [
      attribute.class("loom-session"),
      attribute.class("loom-home"),
      ..facts
    ]
  }
}

/// The `waiting` attribute, written only while a session on the list waits on
/// the person. The stylesheet draws it as the count on the sidebar's menu button,
/// so the phone shows that something needs the person while the sidebar is shut.
/// It is a number the component counted and is capped at ten, the largest the
/// stylesheet has a word for.
fn waiting_fact(waiting: Int) -> List(attribute.Attribute(message)) {
  case waiting > 0 {
    True -> [
      attribute.attribute("waiting", int.to_string(int.min(waiting, 10))),
    ]
    False -> []
  }
}

/// The `proposals` attribute, written only while a proposal waits, so a page
/// that has none, which is every page but the owner's, carries nothing.
fn proposals_fact(
  proposals: Int,
  rest: List(attribute.Attribute(message)),
) -> List(attribute.Attribute(message)) {
  case proposals > 0 {
    True -> [attribute.attribute("proposals", int.to_string(proposals)), ..rest]
    False -> rest
  }
}

/// The `evolution` attribute, written on a page that has the Evolution tab and
/// carrying how many candidates wait, even when that is none: the attribute's
/// presence is what makes the shell draw the tab, so the observer's page, which
/// never has one, draws no button and no handler beneath the pane's path.
fn evolution_fact(
  evolution: Option(Int),
) -> List(attribute.Attribute(message)) {
  case evolution {
    Some(count) -> [attribute.attribute("evolution", int.to_string(count))]
    None -> []
  }
}

// The `workspace` attribute, or none where the host has no digest.
fn digest(workspace: String) -> List(attribute.Attribute(message)) {
  case workspace {
    "" -> []
    digest -> [attribute.attribute("workspace", digest)]
  }
}

// The sidebar's place holds its element, or an empty node where the page
// has none, so the centre and the panel keep their indexes.
fn sidebar_element(sidebar: Sidebar(message)) -> Element(message) {
  case sidebar {
    Listed(element) -> element
    Unlisted -> element.none()
  }
}
