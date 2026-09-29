//// What `<loom-expand>` decides: which of its two slots is shown, and the
//// words on its button.
////
//// The element (`web_client/expand`) holds a row's compact rows in a slot
//// named `compact` and the same row in full in a slot named `full`, both
//// written by the server. The reader chooses which one the page shows, and
//// nothing else about the row changes, so this is the whole of the logic:
//// two states, the toggle between them, and the fixed words for each. It
//// imports neither Lustre nor the DOM binding, so the tests load it under
//// Node (`scripts/web_client_test.sh` checks that).

/// Which slot the element shows.
pub type Shown {
  /// The compact rows the lane always drew.
  Compact

  /// The row in full, as the terminal's `Ctrl+g` shows it.
  Full
}

/// The state after the reader presses the button.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.toggled(expand_rule.Compact) == expand_rule.Full
/// ```
pub fn toggled(shown: Shown) -> Shown {
  case shown {
    Compact -> Full
    Full -> Compact
  }
}

/// The name of the slot to draw: the one the server's children carry as
/// their `slot` attribute.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.slot(expand_rule.Full) == "full"
/// ```
pub fn slot(shown: Shown) -> String {
  case shown {
    Compact -> "compact"
    Full -> "full"
  }
}

/// The button's words. They name what pressing does, and hold nothing from
/// the session.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.words(expand_rule.Compact) == "Expand"
/// ```
pub fn words(shown: Shown) -> String {
  case shown {
    Compact -> "Expand"
    Full -> "Collapse"
  }
}

/// The glyph before the words, drawn as the fold's is: it points right while
/// there is more to show and down once it is shown.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.glyph(expand_rule.Full) == "▾"
/// ```
pub fn glyph(shown: Shown) -> String {
  case shown {
    Compact -> "▸"
    Full -> "▾"
  }
}
