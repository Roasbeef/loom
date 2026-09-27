//// The page's scroll position and the lane's size, for `<loom-follow>`.
////
//// Following the tail needs three things from the browser: a report when
//// the page scrolls, a report when the lane changes size, and a way to
//// scroll the page to its bottom. No Gleam library offers any of them on
//// the JavaScript target: `gleam_stdlib` has no DOM, and Lustre's effects
//// hand a component its shadow root but neither observe sizes nor move the
//// page. So these three functions are JavaScript, in `follow.mjs` beside
//// this module. They read the page's scroll position and the lane's box
//// and set the page's scroll position; none of them reads or writes the
//// lane's content.

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
