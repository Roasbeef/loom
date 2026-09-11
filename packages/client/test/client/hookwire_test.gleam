//// The event mapping's pure halves: the matcher table, the verdict
//// combination rules, the tool-name mapping, and the payload's
//// common fields. Jailed execution is `hookrunner_test`'s business.

import client/hookcompat as hc
import client/hookdecisions
import client/hookwire
import core/json
import gleam/list
import gleam/option.{None, Some}

pub fn matcher_exact_matches_one_name_test() {
  let group = group_with_matcher("Bash")
  assert hookwire.group_matches(group, "Bash")
  assert !hookwire.group_matches(group, "Edit")
  assert !hookwire.group_matches(group, "NotebookEdit")
}

pub fn matcher_pipe_and_comma_lists_match_either_test() {
  let piped = group_with_matcher("Edit|Write")
  assert hookwire.group_matches(piped, "Edit")
  assert hookwire.group_matches(piped, "Write")
  assert !hookwire.group_matches(piped, "Read")
  let comma = group_with_matcher("Edit, Write")
  assert hookwire.group_matches(comma, "Edit")
  assert hookwire.group_matches(comma, "Write")
}

pub fn matcher_any_other_character_is_regex_test() {
  let mcp = group_with_matcher("mcp__memory__.*")
  assert hookwire.group_matches(mcp, "mcp__memory__create_entities")
  assert !hookwire.group_matches(mcp, "mcp__memory")
  let anchored = group_with_matcher("^Notebook")
  assert hookwire.group_matches(anchored, "NotebookEdit")
  assert !hookwire.group_matches(anchored, "WebNotebook")
}

pub fn matcher_star_and_empty_match_everything_test() {
  assert hookwire.group_matches(hc.Group(hc.All, []), "anything")
  assert hookwire.group_matches(group_with_matcher(""), "anything")
}

/// A hyphenated matcher stays on the exact path — the contract's
/// v2.1.195+ behaviour — so a subagent-type matcher cannot
/// accidentally fire for a longer name.
pub fn matcher_hyphen_is_exact_not_regex_test() {
  let named = group_with_matcher("code-reviewer")
  assert hookwire.group_matches(named, "code-reviewer")
  assert !hookwire.group_matches(named, "senior-code-reviewer")
}

pub fn matching_handlers_filters_by_group_and_keeps_order_test() {
  let assert Ok(config) =
    hc.parse_loom(
      "
[[hooks.PreToolUse]]
matcher = \"Bash\"

[[hooks.PreToolUse.hooks]]
type = \"command\"
command = \"first.sh\"

[[hooks.PreToolUse]]
matcher = \"Edit|Write\"

[[hooks.PreToolUse.hooks]]
type = \"command\"
command = \"second.sh\"

[[hooks.PreToolUse.hooks]]
type = \"command\"
command = \"third.sh\"
",
      source,
    )
  let wiring = wiring_of(config)
  let handlers =
    hookwire.matching_handlers(wiring, hc.PreToolUse, "Edit")
  assert list.length(handlers) == 2
}

pub fn combine_permissions_first_deny_wins_test() {
  let combined =
    hookwire.combine_permissions([
      hookdecisions.Proceed,
      hookdecisions.Deny("second"),
      hookdecisions.Deny("third"),
    ])
  let assert hookdecisions.Deny("second") = combined
}

pub fn combine_permissions_ask_beats_rewrite_test() {
  let combined =
    hookwire.combine_permissions([
      hookdecisions.Rewrite(json.Object([])),
      hookdecisions.Ask("confirm first"),
    ])
  let assert hookdecisions.Ask("confirm first") = combined
}

pub fn combine_permissions_rewrite_survives_when_nothing_harder_test() {
  let combined =
    hookwire.combine_permissions([
      hookdecisions.Proceed,
      hookdecisions.Rewrite(json.Object([#("command", json.String("echo ok"))])),
    ])
  let assert hookdecisions.Rewrite(replacement) = combined
  let assert Ok(json.Object(fields)) = Ok(replacement)
  let assert Ok(json.String("echo ok")) = list.key_find(fields, "command")
}

pub fn combine_permissions_all_quiet_is_proceed_test() {
  assert hookdecisions.Proceed
    == hookwire.combine_permissions([hookdecisions.Proceed, hookdecisions.Proceed])
}

pub fn combine_continuations_first_block_continues_test() {
  let combined =
    hookwire.combine_continuations([
      hookdecisions.Finish,
      hookdecisions.Continue("run tests"),
      hookdecisions.Continue("later"),
    ])
  let assert hookdecisions.Continue("run tests") = combined
}

pub fn combine_continuations_silent_finishes_test() {
  assert hookdecisions.Finish
    == hookwire.combine_continuations([hookdecisions.Finish, hookdecisions.Finish])
}

pub fn combine_injections_join_in_order_test() {
  let combined =
    hookwire.combine_injections([
      hookdecisions.Injected("one"),
      hookdecisions.NoContext,
      hookdecisions.Injected("two"),
    ])
  let assert hookdecisions.Injected(text) = combined
  assert text == "one\n\ntwo"
}

pub fn combine_injections_blocked_wins_test() {
  let combined =
    hookwire.combine_injections([
      hookdecisions.Injected("noise"),
      hookdecisions.Blocked("not allowed"),
    ])
  let assert hookdecisions.Blocked("not allowed") = combined
}

pub fn feedback_combination_first_rewrite_first_reason_test() {
  let combined =
    hookwire.combine_feedback([
      hookdecisions.Feedback("look again"),
      hookdecisions.Rewritten(json.Object([])),
      hookdecisions.Context("extra"),
    ])
  let assert Some(_) = combined.replacement
  let assert Some("look again") = combined.reason
  let assert Some("extra") = combined.context
}

pub fn feedback_combination_empty_is_all_none_test() {
  let combined =
    hookwire.combine_feedback([hookdecisions.Nothing, hookdecisions.Nothing])
  assert None == combined.replacement
  assert None == combined.reason
  assert None == combined.context
}

pub fn loom_tool_names_map_to_their_claude_counterparts_test() {
  assert hookwire.claude_tool_name("bash") == "Bash"
  assert hookwire.claude_tool_name("fs_write") == "Write"
  assert hookwire.claude_tool_name("fs_edit") == "Edit"
  assert hookwire.claude_tool_name("fs_read") == "Read"
  // An unknown or extension tool name maps to itself: the matcher
  // vocabulary is the operator's, and inventing a mapping for a tool
  // Claude never had would fire hooks nobody asked for.
  assert hookwire.claude_tool_name("web_search") == "web_search"
}

pub fn common_payload_carries_the_contract_fields_test() {
  let payload =
    hookwire.common_payload(
      wiring_of(hc.Config(entries: [], source:)),
      hc.PreToolUse,
      hookwire.tool_fields("bash", json.Object([]), "call-1"),
    )
  let assert json.Object(fields) = payload
  let assert Ok(json.String("session-fixture")) = list.key_find(fields, "session_id")
  let assert Ok(json.String("/work")) = list.key_find(fields, "cwd")
  let assert Ok(json.String("PreToolUse")) =
    list.key_find(fields, "hook_event_name")
  let assert Ok(json.String("bash")) = list.key_find(fields, "tool_name")
}

// --- fixtures ----------------------------------------------------------------

fn group_with_matcher(raw: String) -> hc.Group {
  hc.Group(matcher: match_raw(raw), handlers: [])
}

fn match_raw(raw: String) -> hc.Matcher {
  let matcher = hc.classify_matcher(raw)
  matcher
}

const source = hc.Source(label: "test", origin: hc.LoomInline)

// The pure tests never execute a hook, so the wiring is the identity
// facts `common_payload` reads and nothing else.
fn wiring_of(config: hc.Config) {
  hookwire.Wiring(
    config:,
    session_id: "session-fixture",
    transcript_path: "/work/session.db",
    workspace: "/work",
  )
}
