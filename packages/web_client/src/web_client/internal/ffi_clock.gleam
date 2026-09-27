//// The browser's wall clock and its repeating timer, for `<loom-elapsed>`.
////
//// No Gleam library offers either on the JavaScript target: `gleam_stdlib`
//// has no clock, Lustre's effects have no timer, and `gleam_erlang`'s are
//// the BEAM's. So these three functions are JavaScript, in
//// `clock.mjs` beside this module, and nothing else in the package
//// touches a browser API directly. They read and schedule; none of them
//// reaches the page's DOM.

/// A running repeating timer, which `cancel` stops.
pub type Timer

/// The browser's wall clock, in Unix milliseconds (`Date.now`). The daemon
/// states an operation's start on the same scale, so the difference is how
/// long the operation has run as this browser's clock sees it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_clock.now() > 0
/// ```
@external(javascript, "./clock.mjs", "now")
pub fn now() -> Int

/// Calls `callback` every `interval` milliseconds until the timer is
/// cancelled (`setInterval`).
///
/// ## Examples
///
/// ```gleam
/// // let timer = ffi_clock.every(1000, fn() { dispatch(Ticked) })
/// ```
@external(javascript, "./clock.mjs", "every")
pub fn every(interval: Int, callback: fn() -> Nil) -> Timer

/// Stops a timer (`clearInterval`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_clock.cancel(timer)
/// ```
@external(javascript, "./clock.mjs", "cancel")
pub fn cancel(timer: Timer) -> Nil
