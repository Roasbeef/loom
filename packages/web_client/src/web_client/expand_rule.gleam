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

import gleam/int

/// Whether the row's body is shown.
pub type Shown {
  /// Only the row's line.
  Closed

  /// The row's line and the body behind it.
  Open
}

/// What the server says a row is, by its `kind` attribute. A reasoning block
/// is drawn twice, first as a live row while the model writes it and then as
/// the settled row that replaces it, and a reader who opened the first
/// expects the second to be open.
pub type Kind {
  /// Any other row.
  Plain

  /// The reasoning row of a block still streaming.
  Live

  /// The reasoning row of a block that has settled.
  Settled
}

/// The kind a `kind` attribute names; anything else is a plain row.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.kind("live") == expand_rule.Live
/// ```
pub fn kind(value: String) -> Kind {
  case value {
    "live" -> Live
    "settled" -> Settled
    _ -> Plain
  }
}

/// The custom state the element holds while its body is shown, which the
/// stylesheet reads: a reasoning row's one-line preview repeats the first
/// line of the body, so it is hidden once the body is open.
pub const open_state = "open"

/// How long after a live row leaves the page a settled row that arrives
/// still takes its open state, in milliseconds. The two are one patch apart,
/// in either order.
pub const handoff_window_ms = 1500

/// The deadline a live row publishes while it is open and still on the page:
/// no time the clock will reach.
pub const standing = 1_000_000_000_000_000

/// Whether a published deadline, read back as the text it was stored as,
/// still offers its open state at `now` (Unix milliseconds). Text that is not
/// a number offers nothing.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.offers("2000", 1000)
/// assert !expand_rule.offers("900", 1000)
/// ```
pub fn offers(deadline: String, now: Int) -> Bool {
  case int.parse(deadline) {
    Ok(until) -> until > now
    Error(Nil) -> False
  }
}

/// Whether the server marked a settled reasoning row as the one allowed to
/// take a live row's open state: the newest settled reasoning row of the lane.
pub type Mark {
  /// The server wrote `handoff="yes"`.
  Marked

  /// Anything else, or no mark.
  Unmarked
}

/// The mark a `handoff` attribute names.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.mark("yes") == expand_rule.Marked
/// ```
pub fn mark(value: String) -> Mark {
  case value {
    "yes" -> Marked
    _ -> Unmarked
  }
}

/// Whether a row takes the published offer: only a marked row does, and only
/// while the offer has not run out. An unmarked row never takes it, which is
/// what keeps an older row, mounted while a live row is open, from opening in
/// its place.
///
/// Known edge: the offer is a note on the document, not a named block, so a
/// page switch within `handoff_window_ms` of an open live row leaving can offer
/// its state to the first marked row of the next page.
///
/// ## Examples
///
/// ```gleam
/// assert expand_rule.takes(expand_rule.Marked, "2000", 1000)
/// assert !expand_rule.takes(expand_rule.Unmarked, "2000", 1000)
/// ```
pub fn takes(mark: Mark, deadline: String, now: Int) -> Bool {
  case mark {
    Marked -> offers(deadline, now)
    Unmarked -> False
  }
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
