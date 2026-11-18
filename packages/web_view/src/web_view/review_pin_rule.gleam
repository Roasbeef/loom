//// Where a find is drawn in a review: at the line it names when that line is
//// in a shown hunk, at the top of its file when the file is shown and the line
//// is not, and at the top of the pane otherwise (the attention inbox's review
//// pane, `docs/design-notes/attention-inbox/README.md` section 2.1).
////
//// A find records an optional path and an optional line, written by the agent.
//// A review shows bounded hunks (`web_view/review_feed`), so a find's line may
//// lie in a hunk that was cut, in a file that was left out, or nowhere in the
//// diff at all, since an agent can notice something outside what it changed.
//// The rule never pretends otherwise: a find is placed at a line only when
//// that line is in the lines the page will draw, and every find lands in
//// exactly one place, so none is lost and none is drawn twice.
////
//// The module is pure. It imports no Lustre. A find's path and text are the
//// agent's, and the rule only compares and counts them: the view draws what
//// this module places as text nodes.
////
//// ## Flow
////
//// `place` → `at_line` / `loose`
////
//// 1. `place` walks the review's files in the order the pane draws them and
////    gives each the finds that name its path.
//// 2. For each such find, `locate` looks for the line in the file's shown
////    hunks. A find at a shown line is an `Anchor`, and any other is loose in
////    its file.
//// 3. A find that names no shown file is returned apart, for the top of the
////    pane.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import session_view/diff_view
import web_view/review_feed.{type File}

/// One find as the rule sees it: an identifier the page keeps, and the place
/// the agent gave. Nothing here is drawn.
pub type Pin {
  Pin(
    /// The find's identifier, which the view looks the find up by.
    id: String,
    /// The path the agent named, if it named one.
    path: Option(String),
    /// The line in that path, if it named one.
    line: Option(Int),
  )
}

/// A find drawn after one line of one hunk.
pub type Anchor {
  Anchor(
    /// The hunk's position among the file's shown hunks, from zero.
    hunk: Int,
    /// The line's position among that hunk's shown lines, from zero.
    line: Int,
    /// The find's identifier.
    find: String,
  )
}

/// Where one shown file draws finds.
pub type FilePins {
  FilePins(
    /// The file's path, as the review has it.
    path: String,
    /// The finds drawn at a line of a shown hunk, in the order the lines come.
    anchored: List(Anchor),
    /// The finds that name the file and are drawn at its top: no line, or a
    /// line that no shown hunk holds.
    loose: List(String),
  )
}

/// Where every find is drawn.
pub type Placed {
  Placed(
    /// One entry for each shown file, in the review's order.
    files: List(FilePins),
    /// The finds that name no shown file, drawn at the top of the pane.
    unplaced: List(String),
  )
}

/// Places every find. A path is compared as the review holds it, after a
/// leading `./` is dropped from the find's, since an agent writes the path it
/// was working with. No other normalising is done: a path that differs in any
/// other way names another file.
///
/// ## Examples
///
/// ```gleam
/// assert review_pin_rule.place([], []) == review_pin_rule.Placed([], [])
/// ```
pub fn place(files: List(File), pins: List(Pin)) -> Placed {
  let files_pins =
    list.map(files, fn(file) {
      let named = list.filter(pins, fn(pin) { names(pin, file.path) })
      let located = list.map(named, fn(pin) { #(pin, locate(file, pin)) })

      FilePins(
        path: file.path,
        anchored: located
          |> list.filter_map(fn(entry) {
            let #(pin, spot) = entry

            case spot {
              Some(#(hunk, line)) -> Ok(Anchor(hunk:, line:, find: pin.id))
              None -> Error(Nil)
            }
          })
          |> list.sort(by_position),
        loose: list.filter_map(located, fn(entry) {
          let #(pin, spot) = entry

          case spot {
            Some(_) -> Error(Nil)
            None -> Ok(pin.id)
          }
        }),
      )
    })

  // A find that names none of the shown files is drawn at the pane's top.
  let unplaced =
    list.filter_map(pins, fn(pin) {
      case list.any(files, fn(file) { names(pin, file.path) }) {
        True -> Error(Nil)
        False -> Ok(pin.id)
      }
    })

  Placed(files: files_pins, unplaced:)
}

/// The anchors of one hunk's line, for a view that draws after each line.
///
/// ## Examples
///
/// ```gleam
/// assert review_pin_rule.at_line(file_pins, 0, 2) == []
/// ```
pub fn at_line(pins: FilePins, hunk: Int, line: Int) -> List(String) {
  pins.anchored
  |> list.filter(fn(anchor) { anchor.hunk == hunk && anchor.line == line })
  |> list.map(fn(anchor) { anchor.find })
}

/// The finds a file draws at its top.
///
/// ## Examples
///
/// ```gleam
/// assert review_pin_rule.loose(review_pin_rule.FilePins("a", [], ["f"])) == ["f"]
/// ```
pub fn loose(pins: FilePins) -> List(String) {
  pins.loose
}

/// Whether a find names a path. A leading `./` on the find's path is dropped.
fn names(pin: Pin, path: String) -> Bool {
  case pin.path {
    Some(named) -> trimmed(named) == path
    None -> False
  }
}

/// A path without a leading `./`.
fn trimmed(path: String) -> String {
  case string.starts_with(path, "./") {
    True -> string.drop_start(path, 2)
    False -> path
  }
}

/// The hunk and line position of a find's line among a file's shown lines, or
/// nothing when it names no line or no shown line carries it. Only a line that
/// has a number in the new file can be named: an added line or a context line.
fn locate(file: File, pin: Pin) -> Option(#(Int, Int)) {
  case pin.line {
    None -> None
    Some(wanted) ->
      file.hunks
      |> list.index_map(fn(hunk, hunk_index) {
        hunk.lines
        |> list.index_map(fn(line, line_index) {
          case line.new == Some(wanted), line.kind {
            True, diff_view.Added | True, diff_view.Context ->
              Ok(#(hunk_index, line_index))
            True, diff_view.Removed
            | True, diff_view.Hunk
            | True, diff_view.FileHeader
            | True, diff_view.NoNewline
            | False, _
            -> Error(Nil)
          }
        })
        |> list.filter_map(fn(found) { found })
      })
      |> list.flatten
      |> list.first
      |> option.from_result
  }
}

/// Orders anchors by hunk and line, and then by find, so two reads agree.
fn by_position(left: Anchor, right: Anchor) -> order.Order {
  case int.compare(left.hunk, right.hunk) {
    order.Eq ->
      case int.compare(left.line, right.line) {
        order.Eq -> string.compare(left.find, right.find)
        other -> other
      }
    other -> other
  }
}
