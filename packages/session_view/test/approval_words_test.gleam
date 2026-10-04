//// The words a consent card is written in: what a request asks to do, in a
//// fixed table for the harness's own tools, and a bash request shown as the
//// command alone, its permissions left to the authority lines.

import core/json
import gleam/option.{None}
import gleam/string
import session_view/approval

pub fn the_harness_tools_have_fixed_words_test() {
  assert approval.wants("bash") == "run a command"
  assert approval.wants("fs_write") == "write a file"
  assert approval.wants("fs_edit") == "edit a file"
  assert approval.wants("fs_read") == "read a file"
  assert approval.wants("") == "make a request"
}

pub fn another_tool_is_named_after_use_test() {
  assert approval.wants("net_fetch") == "use net_fetch"
}

pub fn a_bash_request_is_the_command_and_its_grants_are_authority_lines_test() {
  let record =
    approval.Review(
      "esc",
      7,
      approval.Pending,
      "bash",
      "{\"command\":\"printf hi > /w/out.txt\",\"permissions\":{\"writable_roots\":[\"/w\"]}}",
      None,
      approval.Exact("digest", [
        json.Object([
          #("type", json.String("writable_root")),
          #("path", json.String("/w")),
        ]),
      ]),
      strand: None,
    )
  let assert Ok(shown) = approval.presentation(record)
  assert shown.action == "Run \"printf hi > /w/out.txt\""
  assert !string.contains(shown.action, "permissions")
  assert shown.authority == ["- Write files under: \"/w\""]
}
