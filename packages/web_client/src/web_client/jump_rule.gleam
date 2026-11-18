//// The live rail's jump: which click goes where, and which transcript row a
//// key names.
////
//// The server draws the rail ("Lifted from this session",
//// `web_view/view/lifted`) beside the transcript and tags each row's button
//// with `data-loom-jump`. Its value is a transcript row's key, or `dock`. The
//// server draws every transcript row with its engine key as `data-loom-row`.
//// A press on a tagged button scrolls the matching row into view in the
//// browser, with no round trip and no event to the server (`web_client/follow`
//// does the scrolling; this module decides).
////
//// Nothing here touches the page, so the decisions are plain functions over
//// strings: which marker a click's path carries, which keys a marker value may
//// stand for, and which of the rows on the page is the one. The values are
//// daemon identities. A value is compared with each row's key and is never put
//// in a selector or parsed as markup.
////
//// ## Keys
////
//// The server names the row itself: a failed turn's rail row carries the
//// turn's own key, so the value is looked up as it stands. A key whose row is
//// not in the loaded window finds nothing, and the press does nothing visible.

import gleam/list
import gleam/option.{type Option, None, Some}

/// The attribute the rail's buttons carry. Its value is a row key or
/// `dock_value`.
pub const marker = "data-loom-jump"

/// The attribute a transcript row carries its engine key in.
pub const row_marker = "data-loom-row"

/// The marker value that names the dock, where an approval card is decided.
pub const dock_value = "dock"

/// The attribute set on a row for `marked_for` milliseconds after a jump
/// lands on it. The stylesheet tints a row that carries it. It is an attribute
/// of its own, not a class, because the server draws a row's classes and a
/// later render of the row would reset them.
pub const marked_attribute = "data-loom-jumped"

/// The selector of the phone sheet's `<details>`, which a jump closes.
pub const sheet_selector = "details[data-loom-sheet]"

/// How long a row stays marked after a jump, in milliseconds.
pub const marked_for = 900

/// Where a press goes.
pub type Destination {
  /// The approval card's place: the dock above the composer.
  Dock

  /// A transcript row, by the key the server drew it with.
  Row(key: String)
}

/// The destination of a click, given the value of `marker` on each element of
/// its path, innermost first (`Error` for an element with none). The innermost
/// marked element decides, and a marker whose value is empty names nothing.
///
/// ## Examples
///
/// ```gleam
/// assert jump_rule.destination([Error(Nil), Ok("dock")]) == Some(jump_rule.Dock)
/// assert jump_rule.destination([Error(Nil)]) == None
/// ```
pub fn destination(path: List(Result(String, Nil))) -> Option(Destination) {
  case list.find_map(path, fn(value) { value }) {
    Ok("") | Error(Nil) -> None
    Ok(value) if value == dock_value -> Some(Dock)
    Ok(key) -> Some(Row(key))
  }
}

/// How far to scroll a transcript so that a row lands in the middle of its
/// view: the row's top edge relative to the scroller's, less half of what is
/// left of the view after the row. All four are pixels. A row taller than the
/// view puts its top edge above the middle, as centring a tall row must.
///
/// ## Examples
///
/// ```gleam
/// assert jump_rule.centring(row: 500.0, host: 100.0, view: 400.0, height: 100.0) == 250.0
/// ```
pub fn centring(
  row row: Float,
  host host: Float,
  view view: Float,
  height height: Float,
) -> Float {
  row -. host -. { view -. height } /. 2.0
}
