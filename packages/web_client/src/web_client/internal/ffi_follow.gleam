//// The transcript'"'"'s scroll position and size, for `<loom-follow>`.
////
//// Following the tail needs four things from the browser: a report when
//// the transcript scrolls and how far, a report when its content changes
//// size, its distance from the bottom, and a way to scroll it to the
//// bottom. Keeping the reader'"'"'s place while older rows load above them
//// needs two more: where the lane'"'"'s first row is on screen, and a way to
//// scroll the transcript by a distance. No Gleam library offers any of them
//// on the JavaScript target: `gleam_stdlib` has no DOM, and Lustre'"'"'s
//// effects hand a component its shadow root but neither observe sizes,
//// measure boxes nor move a scroll position. So these functions are
//// JavaScript, in `follow.mjs` beside this module. They read the
//// scroller'"'"'s scroll position, its content'"'"'s boxes and the first row'"'"'s
//// box, and set the scroller'"'"'s scroll position; none of them reads or
//// writes the lane'"'"'s content. The scroller is the `<loom-follow>` element
//// itself, which the stylesheet makes a scroll container of its own.

import gleam/dynamic.{type Dynamic}

/// A running watch, which `unwatch` stops.
pub type Watching

/// Starts watching the element whose shadow root is `root`. Every scroll of
/// it calls `scrolled` with the distance, in whole pixels, from the bottom
/// of its view to the bottom of its content, and with how far the scroll
/// moved, negative for a move up. Every change in the size of the element
/// or of its content calls `resized`.
///
/// ## Examples
///
/// ```gleam
/// // let watching = ffi_follow.watch(root, fn(gap, moved) { .. }, fn() { .. })
/// ```
@external(javascript, "./follow.mjs", "watch")
pub fn watch(
  root: Dynamic,
  scrolled: fn(Int, Int) -> Nil,
  resized: fn() -> Nil,
) -> Watching

/// Stops a watch: removes the scroll listener and the size observers.
///
/// ## Examples
///
/// ```gleam
/// // ffi_follow.unwatch(watching)
/// ```
@external(javascript, "./follow.mjs", "unwatch")
pub fn unwatch(watching: Watching) -> Nil

/// The distance, in whole pixels, from the bottom of the watched element'"'"'s
/// view to the bottom of its content, read now.
///
/// ## Examples
///
/// ```gleam
/// // let gap = ffi_follow.measure(watching)
/// ```
@external(javascript, "./follow.mjs", "measure")
pub fn measure(watching: Watching) -> Int

/// Scrolls the watched element to the bottom of its content at once,
/// without animation.
///
/// ## Examples
///
/// ```gleam
/// // ffi_follow.to_bottom(watching)
/// ```
@external(javascript, "./follow.mjs", "to_bottom")
pub fn to_bottom(watching: Watching) -> Nil

/// The lane's first row, held while older rows load above it, and where
/// its top edge was in the viewport when it was measured.
pub type Anchor

/// Whether a held row has been put back where it was.
pub type Keeping {
  /// The row is still the lane's first: the older rows have not arrived.
  Waiting

  /// The older rows arrived and the transcript was scrolled to put the row back
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
/// it, by scrolling the transcript by however far it moved.
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
