//// What `<loom-rename>` decides (`web_client/rename_rule`): when the rename
//// field is filled with the session's name, and with what.

import gleam/string
import web_client/rename_rule

pub fn an_empty_field_opens_holding_the_current_name_test() {
  assert rename_rule.copy("review auth", "") == Ok("review auth")
}

// A field the owner has typed in is theirs: a second run must not replace it.
pub fn a_field_that_holds_text_is_left_alone_test() {
  assert rename_rule.copy("review auth", "rev") == Error(Nil)
  assert rename_rule.copy("review auth", " ") == Error(Nil)
}

pub fn a_session_with_no_name_copies_nothing_test() {
  assert rename_rule.copy("", "") == Error(Nil)
}

// The text is copied as it is, spaces and markup characters included: it is a
// value written into a field, and never read as markup.
pub fn the_name_is_copied_exactly_test() {
  let name = " <b>a & b</b> \"q\" "
  assert rename_rule.copy(name, "") == Ok(name)
}

// The field's `maxlength` does not bind a script's write, so the copy is cut.
pub fn a_long_name_is_cut_to_the_fields_length_test() {
  let long = string.repeat("é", rename_rule.limit + 40)
  let assert Ok(copied) = rename_rule.copy(long, "")
  assert string.length(copied) == rename_rule.limit
  assert rename_rule.copy(string.repeat("a", rename_rule.limit), "")
    == Ok(string.repeat("a", rename_rule.limit))
}
