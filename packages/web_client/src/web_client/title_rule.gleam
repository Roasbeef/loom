//// What `<loom-title>` decides: the words of the tab's title for a session
//// page, from the name the bar draws and the number of strands that wait on
//// the person.
////
//// A tab's title is what a person sees in the tab strip, in the window list
//// and in the browser's history, so it has to tell one session's tab from
//// another's. The server cannot write it into the document, because the
//// session's name is not known until the component has connected and drawn the
//// bar, and a title the server did write could only be the session's identity,
//// which names nothing. The element reads the name the bar already shows as
//// text, and this module turns that text and a count into the title.
////
//// The name is the owner's label or the page's fallback for an unnamed
//// session. It is never interpolated into markup: the element assigns the
//// result to the document's title, which the browser stores as text
//// (protocol-change/051, the addendum on the session switcher, applies to
//// every client element that reads the page).
////
//// The module imports neither Lustre nor the DOM binding, so the tests load it
//// under Node.

import gleam/int
import gleam/string

/// The product's name, which ends every title and stands alone while the page
/// has no session name to show.
pub const product = "Loom"

/// The title of a session page: the session's name and the product, with the
/// number of strands that wait on a decision in front when there is one.
/// A name that is blank leaves the product alone, so a page that has not drawn
/// its bar yet never reads as an empty session.
///
/// ## Examples
///
/// ```gleam
/// assert title_rule.session("ws · main", 0) == "ws · main — Loom"
/// assert title_rule.session("ws · main", 2) == "(2) ws · main — Loom"
/// assert title_rule.session("  ", 1) == "Loom"
/// ```
pub fn session(name: String, needing: Int) -> String {
  case string.trim(name) {
    "" -> product
    name -> waiting_prefix(needing) <> name <> " — " <> product
  }
}

/// The count the server wrote in the frame's `needing` attribute, or zero for
/// text that is not a whole number above zero. The attribute is a decimal the
/// server writes, so anything else is a page that is not one of ours.
///
/// ## Examples
///
/// ```gleam
/// assert title_rule.needing_from("3") == 3
/// assert title_rule.needing_from("many") == 0
/// assert title_rule.needing_from("-1") == 0
/// ```
pub fn needing_from(text: String) -> Int {
  case int.parse(string.trim(text)) {
    Ok(count) if count > 0 -> count
    Ok(_) | Error(Nil) -> 0
  }
}

// The count in front of the name: `(2) `, or nothing when no strand waits.
fn waiting_prefix(needing: Int) -> String {
  case needing > 0 {
    True -> "(" <> int.to_string(needing) <> ") "
    False -> ""
  }
}
