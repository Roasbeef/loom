//// What `<loom-expand>` decides: whether a row's body is shown, and the
//// chevron that says so.
////
//// The element (`web_client/expand`) draws a row as its line, which the
//// server writes in a child marked `slot="head"`, and the rest of the row in
//// a child marked `slot="body"`. The reader chooses whether the body shows,
//// and nothing else about the row changes, so this is the whole of the
//// logic: two states, the toggle between them, and the glyph for each. It
//// imports neither Lustre nor the DOM binding, so the tests load it under
//// Node (`scripts/web_client_test.sh` checks that).

/// Whether the row's body is shown.
pub type Shown {
  /// Only the row's line.
  Closed

  /// The row's line and the body behind it.
  Open
}

/// The state after the reader presses the row.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.toggled(expand_rule.Closed) == expand_rule.Open
/// ```
pub fn toggled(shown: Shown) -> Shown {
  case shown {
    Closed -> Open
    Open -> Closed
  }
}

/// The glyph before the row's line, drawn as the fold's is: it points right
/// while there is more to show and down once it is shown. It is the row's one
/// chevron.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.glyph(expand_rule.Open) == "▾"
/// ```
pub fn glyph(shown: Shown) -> String {
  case shown {
    Closed -> "▸"
    Open -> "▾"
  }
}
