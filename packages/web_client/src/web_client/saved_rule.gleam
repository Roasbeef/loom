//// What `<loom-saved>` decides: whether the sidebar's saved sessions are
//// showing, and how that choice is kept between pages.
////
//// The sidebar lists the sessions a process runs and keeps the saved ones
//// behind a quiet "N saved" line (`web_view/view/sidebar`). Whether they are
//// showing is a fact about the browser and nothing the server holds, so
//// pressing the line costs no round trip and the server never renders for it.
//// Each session page is a page of its own, though, and a person who opened the
//// saved sessions would not want them folded again on the next one, so the
//// choice is kept in the browser's storage under one item for the origin,
//// which is per viewer (`key`). The storage is a convenience: a blocked or
//// missing item is the default, hidden, and the page works the same without it.
////
//// The item holds one of two fixed words, and `restored` reads any other value
//// as hidden, so a stale or hand-edited item never changes what a page shows
//// beyond what a press would. The module imports neither Lustre nor the DOM
//// binding, so the tests load it under Node.

/// Whether the saved sessions are showing.
pub type State {
  /// The saved sessions are folded behind the "N saved" line.
  Hidden

  /// The saved sessions are listed under the line.
  Shown
}

/// The storage item the choice is kept under. It holds no identity and no
/// workspace: the same choice applies to every session and project the
/// sidebar lists.
pub const key = "loom.sidebar.saved.v1"

/// The custom state the element sets while the saved sessions are showing,
/// which the stylesheet reads.
pub const shown_state = "shown"

/// The state after a press on the line.
///
/// ## Examples
///
/// ```gleam
/// assert saved_rule.flipped(saved_rule.Hidden) == saved_rule.Shown
/// ```
pub fn flipped(state: State) -> State {
  case state {
    Hidden -> Shown
    Shown -> Hidden
  }
}

/// The word stored for a state.
///
/// ## Examples
///
/// ```gleam
/// assert saved_rule.encode(saved_rule.Shown) == "shown"
/// ```
pub fn encode(state: State) -> String {
  case state {
    Hidden -> "hidden"
    Shown -> "shown"
  }
}

/// The state a stored item names. `shown` is shown, and every other value,
/// whether the item is missing, blocked, stale or edited, is hidden.
///
/// ## Examples
///
/// ```gleam
/// assert saved_rule.restored(Error(Nil)) == saved_rule.Hidden
/// ```
pub fn restored(item: Result(String, Nil)) -> State {
  case item {
    Ok("shown") -> Shown
    Ok(_) | Error(Nil) -> Hidden
  }
}

/// The value the toggle's `aria-expanded` holds for a state.
///
/// ## Examples
///
/// ```gleam
/// assert saved_rule.expanded(saved_rule.Shown) == "true"
/// ```
pub fn expanded(state: State) -> String {
  case state {
    Shown -> "true"
    Hidden -> "false"
  }
}
