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

fn config_record(preview: String) -> approval.Review {
  approval.Review(
    "config",
    9,
    approval.Pending,
    "loom_config",
    preview,
    None,
    approval.Exact("exact-action", []),
    strand: None,
  )
}

pub fn configuration_diff_is_literal_and_once_only_test() {
  let preview =
    json.to_string(
      json.Object([
        #("action", json.String("edit")),
        #("path", json.String("/home/loom.toml")),
        #("digest", json.String("sha256:base")),
        #("old", json.String("model = \"old\"\n")),
        #("new", json.String("model = \"new\"\n# <script>\u{001b}")),
      ]),
    )
  let record = config_record(preview)
  let assert Ok(shown) = approval.presentation(record)
    as "the complete edit is presentable"
  assert shown.question == "Apply this configuration edit?"
    as "the question names the mutation"
  assert string.contains(shown.action, "- model = \\\"old\\\"")
    as "the removed text is escaped literally"
  assert string.contains(shown.action, "+ # <script>\\u001b")
    as "terminal controls remain visible text"
  let assert Error(_) = approval.rememberable(record)
    as "config consent cannot be retained"
  let assert Ok(encoded) = approval.approve(1, record)
    as "one exact decision is encodable"
  assert string.contains(encoded, "exact-action")
    as "the decision echoes captured identity"
}

pub fn truncated_configuration_preview_disables_approval_test() {
  assert approval.presentation(config_record("{\"action\":\"edit\""))
    == Error("incomplete configuration edit")
    as "a partial edit cannot produce an approvable presentation"
}
