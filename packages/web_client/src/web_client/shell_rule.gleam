//// What `<loom-shell>` decides: which of the page's two side columns are
//// open, what each toggle says, whether a column can be reached by the
//// keyboard, and whether the page has a sidebar at all.
////
//// The element (`web_client/shell`) draws the page's frame around the
//// server's regions: the top bar, the sessions sidebar on the left, the
//// centre, and the strand panel on the right. The server writes what is in
//// each region and knows nothing of whether a column is shown. Which columns
//// are shown is a preference of the reader's browser that changes with
//// nothing the server holds, so it lives in the element, and the two
//// buttons that change it are the whole of its behaviour. This module holds
//// the rules over plain values and imports neither Lustre nor the DOM
//// binding, so the tests load it under Node
//// (`scripts/web_client_test.sh` checks that).
////
//// Nothing here is remembered: a reload opens both columns
//// (docs/design-notes/web-design.md, section 4, puts persistence in a later
//// change). Nothing here handles a key.

/// One of the two side columns.
pub type Region {
  /// The sessions sidebar, on the left.
  Sidebar

  /// The strand panel, on the right.
  Panel
}

/// Whether a column is shown.
pub type State {
  /// The column takes its width and its content is reachable.
  Open

  /// The column takes no width and its content is not reachable.
  Closed
}

/// Which columns are shown.
pub type Layout {
  Layout(
    /// The sessions sidebar's state.
    sidebar: State,
    /// The strand panel's state.
    panel: State,
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

/// Both columns open, which is how every page starts.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.initial() == shell_rule.Layout(shell_rule.Open, shell_rule.Open)
/// ```
pub fn initial() -> Layout {
  Layout(sidebar: Open, panel: Open)
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
/// changes and the other stays as it was.
///
/// ## Examples
///
/// ```gleam
/// let closed = shell_rule.toggled(shell_rule.initial(), shell_rule.Sidebar)
/// assert closed == shell_rule.Layout(shell_rule.Closed, shell_rule.Open)
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
