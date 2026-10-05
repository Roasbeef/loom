//// What `<loom-rename>` decides: whether the rename field opens holding the
//// session's current name, and what it holds.
////
//// A rename field that opens empty makes a one-letter fix cost the whole name.
//// The server cannot fill it, because a session's name is only ever a text node
//// on the page (protocol-change/051): never a `value`, a `placeholder` or any
//// other attribute. So the browser does it. The server already draws the name
//// as text in the form's lead, and `<loom-rename>` (`web_client/rename`) reads
//// that text node and writes it into the field once, when the form appears.
//// This module is the whole decision, kept free of Lustre and the DOM so the
//// tests load it under Node (`scripts/web_client_test.sh` checks that).
////
//// Two rules keep the copy harmless. It happens only into a field that is
//// still empty, so a re-run can never replace what the owner has typed; and it
//// copies only the name's own text, never a label, never a field's value
//// elsewhere on the page. The field's `maxlength` is 256 characters, and a
//// script write ignores it, so the copy is cut to that length here and a name
//// the daemon accepted is never made longer than the field allows.

import gleam/list
import gleam/string

/// The longest name the field holds, the same number as the field's
/// `maxlength`, in characters.
pub const limit = 256

/// The text to write into the rename field, or nothing to leave it alone.
/// `name` is the text of the element the server marked as the session's name,
/// and `typed` is what the field holds now. A field that holds anything, or a
/// name that is empty, gets no copy.
///
/// ## Examples
///
/// ```gleam
/// assert rename_rule.copy("review auth", "") == Ok("review auth")
/// assert rename_rule.copy("review auth", "rev") == Error(Nil)
/// assert rename_rule.copy("", "") == Error(Nil)
/// ```
pub fn copy(name: String, typed: String) -> Result(String, Nil) {
  case typed, name {
    "", "" -> Error(Nil)
    "", _ ->
      name
      |> string.to_graphemes
      |> list.take(limit)
      |> string.concat
      |> Ok
    _, _ -> Error(Nil)
  }
}
