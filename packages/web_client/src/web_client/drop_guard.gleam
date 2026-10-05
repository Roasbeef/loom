//// The page-wide guard against dropping a file onto the page.
////
//// A browser's default for a file dropped where nothing handles it is to
//// navigate the tab to the file, which leaves the session page and drops
//// its socket. The composer takes image drops itself (`web_client/attach`),
//// but a file can miss it by a few pixels, land on the transcript, or be
//// dropped on a page that has no composer at all, such as an observer's or
//// the home. The guard listens for `dragover` and `drop` on the document and
//// cancels each one whose drag carries files (`drop_rule.carries_files`),
//// which is what stops the navigation. It attaches nothing: a drop that
//// reaches it was not on a composer that wanted it.
////
//// A drag without files is never cancelled, so text dragged into the editor
//// and links dragged between pages keep working.
////
//// The guard is installed once, when the bundle loads, and lives as long as
//// the document does. It belongs to no element, so there is no disconnect at
//// which to remove it, and installing it twice is harmless because cancelling
//// an event twice is the same as cancelling it once.

import gleam/dynamic.{type Dynamic}
import web_client/drop_rule
import web_client/internal/ffi_dom

/// Starts cancelling file drags on the document.
///
/// ## Examples
///
/// ```gleam
/// // drop_guard.install()
/// ```
pub fn install() -> Nil {
  let page = ffi_dom.get_document()
  let _ = ffi_dom.add_listener(page, "dragover", cancelling)
  let _ = ffi_dom.add_listener(page, "drop", cancelling)
  Nil
}

// A drag that carries files is cancelled, wherever on the page it is. The
// browser then neither navigates to the file nor refuses it as a drop target.
fn cancelling(event: Dynamic) -> Nil {
  case drop_rule.carries_files(ffi_dom.drag_types(event)) {
    True -> ffi_dom.prevent_default(event)
    False -> Nil
  }
}
