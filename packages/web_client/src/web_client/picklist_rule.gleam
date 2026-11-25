//// What `<loom-picklist>` decides: where the keyboard goes inside the new-session
//// composer's folder list, and when a key closes the list.
////
//// The Code chip's list (`web_view/view/new_session`) opens under the chip with a
//// search field above a column of rows. Which row has the focus is a fact about
//// the browser, and moving it costs the server nothing, so the arrow keys, and
//// Escape to leave, are decided here and never cross the socket. Enter needs no
//// rule: in the search field it submits the field's form, which the server hears
//// as `Entered`, and on a focused row it presses that row's own button.
////
//// The list is one ordered column: the search field first when there is one, then
//// each row that can be pressed. A position is an index into it, and `-1` stands
//// for a focus that is somewhere else on the page, which the arrows leave alone
//// (`Ignore`) so a page's own scrolling is not taken from a person who is not in
//// the list.
////
//// The module imports neither Lustre nor the DOM binding, so the tests load it
//// under Node.

/// What a key asks of the list.
pub type Move {
  /// Move the focus to the item at this index of the column.
  Focus(index: Int)

  /// Close the list.
  Close

  /// The key is not the list's, or the focus is not in it: leave the event as it
  /// is.
  Ignore
}

/// The move a key makes, from the focused item's position in a column of `count`
/// items. Down goes one item on and stays on the last; up goes one item back and
/// stays on the first, which is the search field. Escape closes the list wherever
/// the focus is, since a list that is open is the one thing on the page that
/// Escape is for. Every other key, and an arrow with the focus outside the list or
/// no item to move to, is left alone.
///
/// ## Examples
///
/// ```gleam
/// assert picklist_rule.after_key("ArrowDown", 0, 3) == picklist_rule.Focus(1)
/// assert picklist_rule.after_key("ArrowUp", 0, 3) == picklist_rule.Focus(0)
/// assert picklist_rule.after_key("Escape", -1, 3) == picklist_rule.Close
/// ```
pub fn after_key(key: String, position: Int, count: Int) -> Move {
  case key, position >= 0 && position < count {
    "Escape", _ -> Close
    "ArrowDown", True -> Focus(clamped(position + 1, count))
    "ArrowUp", True -> Focus(clamped(position - 1, count))
    _, _ -> Ignore
  }
}

/// An index kept inside a column of `count` items.
fn clamped(index: Int, count: Int) -> Int {
  case index < 0, index >= count {
    True, _ -> 0
    False, True -> count - 1
    False, False -> index
  }
}
