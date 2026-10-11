//// The browser calls the site makes outside Lustre.
////
//// Each function is a thin binding to `loom_site_ffi.mjs`. They exist
//// because Gleam's standard library has no DOM, timer or `fetch` bindings.
//// Everything the site decides lives in Gleam; this module only reaches the
//// browser.

/// The current URL fragment, including the leading `#`, or an empty string.
@external(javascript, "../loom_site_ffi.mjs", "get_hash")
pub fn get_hash() -> String

/// Replaces the URL fragment, which fires a `hashchange` event.
@external(javascript, "../loom_site_ffi.mjs", "set_hash")
pub fn set_hash(hash: String) -> Nil

/// Calls back with the new fragment each time it changes.
@external(javascript, "../loom_site_ffi.mjs", "on_hash_change")
pub fn on_hash_change(callback: fn(String) -> Nil) -> Nil

/// Sets the document title.
@external(javascript, "../loom_site_ffi.mjs", "set_title")
pub fn set_title(title: String) -> Nil

/// Runs the callback once after the given number of milliseconds.
@external(javascript, "../loom_site_ffi.mjs", "after")
pub fn after(milliseconds: Int, callback: fn() -> Nil) -> Nil

/// Fetches a text file from the site's own origin.
@external(javascript, "../loom_site_ffi.mjs", "fetch_text")
pub fn fetch_text(url: String, callback: fn(Result(String, Nil)) -> Nil) -> Nil

/// Whether the reader asked the system for less motion.
@external(javascript, "../loom_site_ffi.mjs", "prefers_reduced_motion")
pub fn prefers_reduced_motion() -> Bool

/// Scrolls the element with this id to the top of the viewport, or scrolls
/// to the top of the page when there is no such element.
@external(javascript, "../loom_site_ffi.mjs", "scroll_to_id")
pub fn scroll_to_id(id: String) -> Nil

/// Scrolls to the top of the page.
@external(javascript, "../loom_site_ffi.mjs", "scroll_to_top")
pub fn scroll_to_top() -> Nil

/// Starts the scroll spy that reports which step of which figure is under
/// the reading line.
@external(javascript, "../loom_site_ffi.mjs", "start_scroll_spy")
pub fn start_scroll_spy(callback: fn(String, Int) -> Nil) -> Nil

/// Records the step Gleam holds for a figure, so the spy reports only changes.
@external(javascript, "../loom_site_ffi.mjs", "note_step")
pub fn note_step(figure: String, step: Int) -> Nil

/// Scrolls the text block of a step under the reading line.
@external(javascript, "../loom_site_ffi.mjs", "reveal_step")
pub fn reveal_step(figure: String, step: Int) -> Nil
