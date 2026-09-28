//// The page's scroll position and the lane's size, for `<loom-follow>`.
////
//// Following the tail needs three things from the browser: a report when
//// the page scrolls, a report when the lane changes size, and a way to
//// scroll the page to its bottom. Keeping the reader's place while older
//// rows load above them needs two more: where the lane's first row is on
//// screen, and a way to scroll the page by a distance. No Gleam library
//// offers any of them on the JavaScript target: `gleam_stdlib` has no DOM,
//// and Lustre's effects hand a component its shadow root but neither
//// observe sizes, measure boxes nor move the page. So these functions are
//// JavaScript, in `follow.mjs` beside this module. They read the page's
//// scroll position, the lane's box and its first row's box, and set the
//// page's scroll position; none of them reads or writes the lane's
//// content.

import gleam/dynamic.{type Dynamic}

/// A running watch, which `unwatch` stops.
pub type Watching

/// Starts watching the element whose shadow root is `root`. Every scroll of
/// the page calls `scrolled` with the distance, in whole pixels, from the
/// bottom of the viewport to the bottom of the page; every change in the
/// element's size calls `resized`.
///
/// ## Examples
///
/// ```gleam
/// // let watching = ffi_follow.watch(root, fn(gap) { .. }, fn() { .. })
/// ```
@external(javascript, "./follow.mjs", "watch")
pub fn watch(
  root: Dynamic,
  scrolled: fn(Int) -> Nil,
  resized: fn() -> Nil,
) -> Watching

/// Stops a watch: removes the scroll listener and the size observer.
///
/// ## Examples
///
/// ```gleam
/// // ffi_follow.unwatch(watching)
/// ```
@external(javascript, "./follow.mjs", "unwatch")
pub fn unwatch(watching: Watching) -> Nil

/// Scrolls the page to its bottom at once, without animation.
///
/// ## Examples
///
/// ```gleam
/// // ffi_follow.to_bottom()
/// ```
@external(javascript, "./follow.mjs", "to_bottom")
pub fn to_bottom() -> Nil

/// The lane's first row, held while older rows load above it, and where
/// its top edge was in the viewport when it was measured.
pub type Anchor

/// Whether a held row has been put back where it was.
pub type Keeping {
  /// The row is still the lane's first: the older rows have not arrived.
  Waiting

  /// The older rows arrived and the page was scrolled to put the row back
  /// where it was, or the row left the page. Nothing is held any more.
  Restored
}

/// Holds the first row of the lane inside the watched element, and where
/// it is on screen now.
///
/// ## Examples
///
/// ```gleam
/// // let anchor = ffi_follow.hold(watching)
/// ```
@external(javascript, "./follow.mjs", "hold")
pub fn hold(watching: Watching) -> Anchor

/// The same row, measured where it is on screen now.
///
/// ## Examples
///
/// ```gleam
/// // let anchor = ffi_follow.remeasure(anchor)
/// ```
@external(javascript, "./follow.mjs", "remeasure")
pub fn remeasure(anchor: Anchor) -> Anchor

/// Puts a held row back where it was measured, once rows have landed above
/// it, by scrolling the page by however far it moved.
///
/// ## Examples
///
/// ```gleam
/// // ffi_follow.keep(anchor) == ffi_follow.Waiting
/// ```
pub fn keep(anchor: Anchor) -> Keeping {
  case restore(anchor) {
    True -> Restored
    False -> Waiting
  }
}

@external(javascript, "./follow.mjs", "restore")
fn restore(anchor: Anchor) -> Bool
