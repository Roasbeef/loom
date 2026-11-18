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
//// A step inside a turn's fold is lifted as `<work key>#<index>`, and the
//// fold's steps are not rows of the lane while it is closed, so the turn's row
//// is the nearest row that holds it. `candidates` lists the key and then the
//// part before the `#`, and `resolve` takes the first of them the page has. A
//// key whose row is not in the loaded window resolves to nothing, and the
//// press does nothing visible.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

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

  /// A transcript row, by the keys that may name it, best first.
  Row(candidates: List(String))
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
    Ok(key) -> Some(Row(candidates(key)))
  }
}

/// The row keys a marker value may stand for: the value itself, and for a
/// step in a fold (`<work key>#<index>`) the turn's key as well.
///
/// ## Examples
///
/// ```gleam
/// assert jump_rule.candidates("9.0") == ["9.0"]
/// assert jump_rule.candidates("work:7#2") == ["work:7#2", "work:7"]
/// ```
pub fn candidates(key: String) -> List(String) {
  case string.split_once(key, "#") {
    Ok(#("", _)) | Error(Nil) -> [key]
    Ok(#(work, _)) -> [key, work]
  }
}

/// The first candidate the page holds a row for, or `Error` when it holds
/// none, which is a row older than the loaded window.
///
/// ## Examples
///
/// ```gleam
/// assert jump_rule.resolve(["a#1", "a"], ["a", "b"]) == Ok("a")
/// assert jump_rule.resolve(["z"], ["a"]) == Error(Nil)
/// ```
pub fn resolve(
  candidates: List(String),
  present: List(String),
) -> Result(String, Nil) {
  list.find(candidates, fn(key) { list.contains(present, key) })
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
