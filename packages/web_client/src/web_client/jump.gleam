//// The live rail's jump, in the page: the DOM half of `jump_rule`.
////
//// `<loom-follow>` hears a click on the document and asks this module what
//// the click names, where the named row is, and to land on it. Each function
//// is one step over `ffi_dom` with the decision left to `jump_rule`, and none
//// of them keeps state: whether the transcript stops following, and the
//// order of the steps, are the element's (`web_client/follow`).
////
//// The rows and the rail are in one tree, the server component's shadow
//// root, so a button's root node is where its row is looked up. The row keys
//// are compared as strings and never placed in a selector, because a key is
//// the server's text for an identity and this module does not parse it.
////
//// ## Flow
////
//// `pressed` → `find` → `land`, or `pressed` → `reveal_dock`
////
//// 1. `pressed` reads a click's path and says where the innermost marker
////    sends it.
//// 2. `find` looks for the row a marker value names among the page's rows.
//// 3. `land` scrolls that row to the middle of the transcript, marks it for a
////    moment and closes the phone sheet the press was in.
//// 4. `reveal_dock` scrolls the dock into view for an approval entry.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import web_client/internal/ffi_dom
import web_client/jump_rule

/// What a click on the page asks for: where it goes and the element that
/// carried the marker. Nothing when its path holds no marker.
///
/// ## Examples
///
/// ```gleam
/// // jump.pressed(event)
/// ```
pub fn pressed(
  event: Dynamic,
) -> Option(#(jump_rule.Destination, ffi_dom.Element)) {
  let path = ffi_dom.composed_path(event)

  // The innermost element that carries the marker decides, as the rule says.
  let marked =
    list.find(path, fn(node) {
      result.is_ok(ffi_dom.attribute(node, jump_rule.marker))
    })

  // A click outside the rail has no marker on its path, and is none of ours.
  case marked {
    Error(Nil) -> None
    Ok(origin) ->
      jump_rule.destination([ffi_dom.attribute(origin, jump_rule.marker)])
      |> option.map(fn(destination) { #(destination, origin) })
  }
}

/// The row one of `candidates` names, among the rows in the tree `origin` is
/// in, or `Error` when the page holds none: the row is older than the loaded
/// window, and the press does nothing.
///
/// ## Examples
///
/// ```gleam
/// // jump.find(["9.0"], button)
/// ```
pub fn find(
  candidates: List(String),
  origin: ffi_dom.Element,
) -> Result(ffi_dom.Element, Nil) {
  let rows =
    ffi_dom.query_selector_all(
      ffi_dom.root_node(origin),
      "[" <> jump_rule.row_marker <> "]",
    )
    |> list.filter_map(fn(row) {
      ffi_dom.attribute(row, jump_rule.row_marker)
      |> result.map(fn(key) { #(key, row) })
    })

  jump_rule.resolve(candidates, list.map(rows, fn(row) { row.0 }))
  |> result.try(fn(key) { list.key_find(rows, key) })
}

/// Scrolls `row` to the middle of the transcript `host` scrolls, marks it for
/// `jump_rule.marked_for` milliseconds, and closes the phone sheet `origin`
/// is in, if it is in one.
///
/// ## Examples
///
/// ```gleam
/// // jump.land(host, row, button)
/// ```
pub fn land(
  host: ffi_dom.Element,
  row: ffi_dom.Element,
  origin: ffi_dom.Element,
) -> Nil {
  close_sheet(origin)

  ffi_dom.scroll_by(
    host,
    jump_rule.centring(
      row: ffi_dom.bounding_top(row),
      host: ffi_dom.bounding_top(host),
      view: ffi_dom.client_height(host),
      height: ffi_dom.offset_height(row),
    ),
  )

  // The mark is an attribute of its own, because the server draws a row's
  // classes and a later render of the row would reset them.
  ffi_dom.set_attribute(row, jump_rule.marked_attribute, "")
  ffi_dom.after(jump_rule.marked_for, fn() {
    ffi_dom.remove_attribute(row, jump_rule.marked_attribute)
  })
}

/// Brings the dock, where an approval card is decided, into view, and closes
/// the phone sheet `origin` is in. The press is only a scroll: it decides
/// nothing, and the card keeps its own controls.
///
/// ## Examples
///
/// ```gleam
/// // jump.reveal_dock(button)
/// ```
pub fn reveal_dock(origin: ffi_dom.Element) -> Nil {
  close_sheet(origin)

  // A page with no dock, an observer's, has no approval entry to press.
  let _ =
    ffi_dom.query_selector(ffi_dom.root_node(origin), "footer.dock")
    |> result.map(ffi_dom.scroll_into_view)

  Nil
}

/// Closes the sheet a rail button is in. The browser owns a `<details>`
/// element's `open` state and the server never draws it, so removing the
/// attribute is the whole of closing.
fn close_sheet(origin: ffi_dom.Element) -> Nil {
  let _ =
    ffi_dom.closest(origin, jump_rule.sheet_selector)
    |> result.map(fn(sheet) { ffi_dom.remove_attribute(sheet, "open") })

  Nil
}
