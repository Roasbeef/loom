//// What `<loom-popover>` decides: whether the home's account panel is open,
//// from the clicks and keys the page hears and the one word the server writes.
////
//// The home's sign-ins, its bookmark and the control that signs in another
//// device live in a panel the person's name opens (protocol-change/065, the
//// round-4 addendum on the account popover). Whether the panel is open is a
//// fact about the browser and nothing the server holds, so a press on the name
//// and a click elsewhere never cost a round trip, and the server never renders
//// for them. The server marks two places with the fixed attribute
//// `data-popover`: the button that toggles the panel, `toggle`, and the panel's
//// own region, `panel`. A click is read only by the marks of the nodes it
//// passed through, so what the person pressed is never matched by its text, its
//// class or its position.
////
//// A press on the toggle flips the state. A press anywhere in the panel leaves
//// it as it is, so a sign-out button does not close the panel it sits in. A
//// press anywhere else closes it, and so does Escape. The server's single input
//// is the word `open`, which it writes while a device link is on show so the
//// link is on screen; any other word, including the word it writes when the
//// link is done, is no message, so the person's own closing is never undone by
//// a re-render that carries the same state.
////
//// The module imports neither Lustre nor the DOM binding, so the tests load it
//// under Node.

import gleam/list

/// Whether the panel is showing.
pub type State {
  /// The panel is hidden.
  Closed

  /// The panel is showing under the bar.
  Open
}

/// What a node a click passed through is, by the server's fixed `data-popover`
/// attribute.
pub type Mark {
  /// The button in the bar that opens and closes the panel.
  Toggle

  /// The panel's own region.
  Panel
}

/// The mark a `data-popover` value names, or a refusal for any other word.
///
/// ## Examples
///
/// ```gleam
/// assert popover_rule.mark("toggle") == Ok(popover_rule.Toggle)
/// ```
pub fn mark(value: String) -> Result(Mark, Nil) {
  case value {
    "toggle" -> Ok(Toggle)
    "panel" -> Ok(Panel)
    _ -> Error(Nil)
  }
}

/// The state the server's `wanted` attribute asks for: `open` opens the panel,
/// and any other word asks for nothing.
///
/// ## Examples
///
/// ```gleam
/// assert popover_rule.wanted("closed") == Error(Nil)
/// ```
pub fn wanted(value: String) -> Result(State, Nil) {
  case value {
    "open" -> Ok(Open)
    _ -> Error(Nil)
  }
}

/// The state after a click that passed through nodes carrying `marks`.
///
/// ## Examples
///
/// ```gleam
/// assert popover_rule.after_click(popover_rule.Closed, [popover_rule.Toggle])
///   == popover_rule.Open
/// ```
pub fn after_click(state: State, marks: List(Mark)) -> State {
  case list.contains(marks, Toggle), list.contains(marks, Panel) {
    True, _ -> flipped(state)
    False, True -> state
    False, False -> Closed
  }
}

/// The state after a key. Escape closes the panel and no other key changes it.
///
/// ## Examples
///
/// ```gleam
/// assert popover_rule.after_key(popover_rule.Open, "Escape") == popover_rule.Closed
/// ```
pub fn after_key(state: State, key: String) -> State {
  case key {
    "Escape" -> Closed
    _ -> state
  }
}

/// The value the toggle's `aria-expanded` holds for a state.
///
/// ## Examples
///
/// ```gleam
/// assert popover_rule.expanded(popover_rule.Open) == "true"
/// ```
pub fn expanded(state: State) -> String {
  case state {
    Open -> "true"
    Closed -> "false"
  }
}

/// The custom state the element sets while the panel is open, which the
/// stylesheet reads to show the panel.
pub const open_state = "open"

fn flipped(state: State) -> State {
  case state {
    Open -> Closed
    Closed -> Open
  }
}
