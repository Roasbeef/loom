//// What `<loom-shell>` decides: which of the page's two side columns are
//// open, which tab the strand panel shows, what each toggle and tab says,
//// whether a column can be reached by the keyboard, and whether the page has
//// a sidebar at all.
////
//// The element (`web_client/shell`) draws the page's frame around the
//// server's regions: the top bar, the sessions sidebar on the left, the
//// centre, and the strand panel on the right. The server writes what is in
//// each region and knows nothing of whether a column is shown. Which columns
//// are shown is a preference of the reader's browser that changes with
//// nothing the server holds, so it lives in the element, and the two
//// buttons that change it are most of its behaviour. The strand panel has
//// tabs, and which one shows is the same kind of preference: the server
//// draws every tab's pane, and the shell shows one. This module holds the
//// rules over plain values and imports neither Lustre nor the DOM binding,
//// so the tests load it under Node (`scripts/web_client_test.sh` checks
//// that).
////
//// Nothing here is remembered: a reload opens both columns on the Strands
//// tab (docs/design-notes/web-design.md, section 4, puts persistence in a
//// later change). Nothing here handles a key.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One of the two side columns.
pub type Region {
  /// The sessions sidebar, on the left.
  Sidebar

  /// The strand panel, on the right.
  Panel
}

/// One of the strand panel's tabs. The server draws a pane for each, always,
/// and the shell shows the chosen one, so a tab needs no round trip and the
/// server never learns which is showing.
pub type Tab {
  /// The strand cards, and the detail of the strand in focus.
  Strands

  /// The files the session's own edits changed.
  Changes

  /// The session's goal and cost and, where the page shows them, its jobs
  /// and viewers.
  Session
}

/// Whether a column is shown.
pub type State {
  /// The column takes its width and its content is reachable.
  Open

  /// The column takes no width and its content is not reachable.
  Closed
}

/// Which columns are shown, and which tab the panel shows.
pub type Layout {
  Layout(
    /// The sessions sidebar's state.
    sidebar: State,
    /// The strand panel's state.
    panel: State,
    /// The tab the strand panel shows, whether or not the panel is open.
    tab: Tab,
  )
}

/// Whether the page draws a sidebar. An observer's page draws none, so its
/// bar has no button for it.
pub type Presence {
  /// The server drew a sidebar.
  Listed

  /// The page has no sidebar.
  Unlisted
}

/// Whether a closed column's content can take focus.
pub type Reach {
  /// The content is in the page's tab order and reachable by assistive
  /// technology.
  Reachable

  /// The content is out of the tab order and hidden from assistive
  /// technology, as though it were not in the page.
  Unreachable
}

/// Both columns open on the Strands tab, which is how every page starts.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.initial()
///   == shell_rule.Layout(shell_rule.Open, shell_rule.Open, shell_rule.Strands)
/// ```
pub fn initial() -> Layout {
  Layout(sidebar: Open, panel: Open, tab: Strands)
}

/// The state of one column.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.state(shell_rule.initial(), shell_rule.Panel) == shell_rule.Open
/// ```
pub fn state(layout: Layout, region: Region) -> State {
  case region {
    Sidebar -> layout.sidebar
    Panel -> layout.panel
  }
}

/// The layout after the reader presses one column's button: that column
/// changes and the other stays as it was, as does the panel's tab.
///
/// ## Examples
///
/// ```gleam
/// let closed = shell_rule.toggled(shell_rule.initial(), shell_rule.Sidebar)
/// assert shell_rule.state(closed, shell_rule.Sidebar) == shell_rule.Closed
/// assert shell_rule.state(closed, shell_rule.Panel) == shell_rule.Open
/// ```
pub fn toggled(layout: Layout, region: Region) -> Layout {
  case region {
    Sidebar -> Layout(..layout, sidebar: flipped(layout.sidebar))
    Panel -> Layout(..layout, panel: flipped(layout.panel))
  }
}

fn flipped(state: State) -> State {
  case state {
    Open -> Closed
    Closed -> Open
  }
}

/// The layout after the reader presses a tab: the panel shows that tab and
/// nothing else changes. A tab is pressed inside the panel, so the panel is
/// open when this is called; a closed panel keeps the tab it had.
///
/// ## Examples
///
/// ```gleam
/// let chosen = shell_rule.chosen(shell_rule.initial(), shell_rule.Changes)
/// assert chosen.tab == shell_rule.Changes
/// assert chosen.panel == shell_rule.Open
/// ```
pub fn chosen(layout: Layout, tab: Tab) -> Layout {
  Layout(..layout, tab:)
}

/// The tabs, in the order the bar draws them.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.tabs()
///   == [shell_rule.Strands, shell_rule.Changes, shell_rule.Session]
/// ```
pub fn tabs() -> List(Tab) {
  [Strands, Changes, Session]
}

/// The word on a tab's button.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.tab_label(shell_rule.Changes) == "Changes"
/// ```
pub fn tab_label(tab: Tab) -> String {
  case tab {
    Strands -> "Strands"
    Changes -> "Changes"
    Session -> "Session"
  }
}

/// The custom state the element sets on itself while `tab` shows. The
/// stylesheet hides the panes of the other tabs with it
/// (`loom-shell:state(tab-changes)`), which is how a slotted pane the server
/// drew is hidden without the server knowing. Each is a whole literal, so the
/// stylesheet can spell it.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.tab_state(shell_rule.Session) == "tab-session"
/// ```
pub fn tab_state(tab: Tab) -> String {
  case tab {
    Strands -> "tab-strands"
    Changes -> "tab-changes"
    Session -> "tab-session"
  }
}

/// Whether the content of a column in `state` can take focus. A closed
/// column is out of the tab order, because a control the reader cannot see
/// must not hold the keyboard.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.reach(shell_rule.Closed) == shell_rule.Unreachable
/// ```
pub fn reach(state: State) -> Reach {
  case state {
    Open -> Reachable
    Closed -> Unreachable
  }
}

/// The words on a column's button: what pressing it does. They name the
/// column and hold nothing from the session.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.label(shell_rule.Sidebar, shell_rule.Open) == "Hide sessions"
/// assert shell_rule.label(shell_rule.Panel, shell_rule.Closed) == "Show strands"
/// ```
pub fn label(region: Region, state: State) -> String {
  case region, state {
    Sidebar, Open -> "Hide sessions"
    Sidebar, Closed -> "Show sessions"
    Panel, Open -> "Hide strands"
    Panel, Closed -> "Show strands"
  }
}

/// Whether the bar draws a button for a column: always for the panel, and
/// for the sidebar only when the page has one.
///
/// ## Examples
///
/// ```gleam
/// assert !shell_rule.has_button(shell_rule.Unlisted, shell_rule.Sidebar)
/// assert shell_rule.has_button(shell_rule.Unlisted, shell_rule.Panel)
/// ```
pub fn has_button(presence: Presence, region: Region) -> Bool {
  case region, presence {
    Sidebar, Unlisted -> False
    Sidebar, Listed | Panel, _ -> True
  }
}

/// The presence the server's `sidebar` attribute names. The attribute is a
/// fixed word (`listed` or `none`) that the server writes, and decoding is
/// total: any other value, including none at all, is `Unlisted`, so a page
/// that says nothing draws no button that does nothing.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.presence("listed") == shell_rule.Listed
/// assert shell_rule.presence("Listed ") == shell_rule.Unlisted
/// ```
pub fn presence(value: String) -> Presence {
  case value {
    "listed" -> Listed
    _ -> Unlisted
  }
}

/// How many strands need a decision, from the `needing` attribute the server
/// writes. The server writes a count, and decoding is total: anything that is
/// not a plain non-negative number of at most four digits is none, so a page
/// that says nothing, or something else, draws no badge.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.needing("2") == 2
/// assert shell_rule.needing("-1") == 0
/// assert shell_rule.needing("<b>") == 0
/// ```
pub fn needing(value: String) -> Int {
  let graphemes = string.to_graphemes(value)
  let plain =
    list.all(graphemes, fn(grapheme) { string.contains("0123456789", grapheme) })
    && list.length(graphemes) <= 4
  case plain {
    True -> result.unwrap(int.parse(value), 0)
    False -> 0
  }
}

/// What the Strands tab's badge says for `count` strands waiting on a
/// decision: nothing for none, the number up to nine, and `9+` past that.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.badge(0) == None
/// assert shell_rule.badge(3) == Some("3")
/// assert shell_rule.badge(12) == Some("9+")
/// ```
pub fn badge(count: Int) -> Option(String) {
  case count {
    count if count > 9 -> Some("9+")
    count if count > 0 -> Some(int.to_string(count))
    _ -> None
  }
}

/// The words a screen reader gets for the Strands tab: the label alone, or
/// with how many strands wait on a decision, since the badge is a number a
/// reader cannot see.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.strands_words(0) == "Strands"
/// assert shell_rule.strands_words(1) == "Strands, 1 needs approval"
/// assert shell_rule.strands_words(2) == "Strands, 2 need approval"
/// ```
pub fn strands_words(count: Int) -> String {
  case count {
    1 -> "Strands, 1 needs approval"
    count if count > 1 -> "Strands, " <> int.to_string(count) <> " need approval"
    _ -> "Strands"
  }
}
