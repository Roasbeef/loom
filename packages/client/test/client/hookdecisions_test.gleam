//// The decision readers, against the pinned Claude contract's own
//// examples: exit codes, stdout classification, per-event field
//// precedence. Pure — no processes, just the readers over outcomes.

import client/hookdecisions
import core/json
import gleam/list
import gleam/string

pub fn stdout_classification_follows_the_contract_test() {
  assert hookdecisions.Silent == hookdecisions.classify("")
  assert hookdecisions.Silent == hookdecisions.classify("   \n")
  let assert hookdecisions.Json(fields) = hookdecisions.classify(" {\"a\":1} ")
  assert Ok(json.Int(1)) == list.key_find(fields, "a")
  // A JSON array is plain text by the contract's brace rule.
  let assert hookdecisions.Plain("[1, 2]") = hookdecisions.classify("[1, 2]")
  // An object that does not parse is plain text too.
  let assert hookdecisions.Plain(_) = hookdecisions.classify("{\"open\": ")
}

pub fn pretooluse_exit_two_blocks_with_stderr_test() {
  let decision = hookdecisions.tool_permission(2, "no rm allowed", "", False)
  let assert hookdecisions.Deny(reason) = decision
  assert reason == "no rm allowed"
}

pub fn pretooluse_json_deny_wins_over_allow_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PreToolUse")),
        #("permissionDecision", json.String("deny")),
        #("permissionDecisionReason", json.String("blocked")),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Deny("blocked") =
    hookdecisions.tool_permission(0, "", stdout, False)
}

pub fn pretooluse_allow_with_updated_input_rewrites_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PreToolUse")),
        #("permissionDecision", json.String("allow")),
        #("updatedInput", json.Object([#("command", json.String("echo ok"))])),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Rewrite(updated) =
    hookdecisions.tool_permission(0, "", stdout, False)
  let assert Ok(json.Object(_)) = Ok(updated)
}

pub fn pretooluse_bare_allow_is_proceed_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PreToolUse")),
        #("permissionDecision", json.String("allow")),
      ])),
    ])
    |> json.to_string
  assert hookdecisions.Proceed == hookdecisions.tool_permission(0, "", stdout, False)
}

pub fn pretooluse_ask_escalates_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PreToolUse")),
        #("permissionDecision", json.String("ask")),
        #("permissionDecisionReason", json.String("confirm")),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Ask("confirm") =
    hookdecisions.tool_permission(0, "", stdout, False)
}

pub fn pretooluse_plain_stdout_is_no_decision_test() {
  assert hookdecisions.Proceed
    == hookdecisions.tool_permission(0, "", "hello world", False)
}

pub fn pretooluse_hookspecific_naming_another_event_is_ignored_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PostToolUse")),
        #("permissionDecision", json.String("deny")),
      ])),
    ])
    |> json.to_string
  assert hookdecisions.Proceed == hookdecisions.tool_permission(0, "", stdout, False)
}

pub fn pretooluse_a_timed_out_hook_renders_no_decision_test() {
  assert hookdecisions.Proceed
    == hookdecisions.tool_permission(2, "late", "{}", True)
}

pub fn pretooluse_a_nonblocking_exit_code_with_valid_json_decides_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PreToolUse")),
        #("permissionDecision", json.String("deny")),
        #("permissionDecisionReason", json.String("no")),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Deny("no") =
    hookdecisions.tool_permission(3, "", stdout, False)
}

pub fn posttooluse_exit_two_is_feedback_not_a_block_test() {
  let assert hookdecisions.Feedback("look at the output") =
    hookdecisions.tool_feedback(2, "look at the output", "", False)
}

pub fn posttooluse_decision_block_adds_reason_test() {
  let stdout =
    json.Object([
      #("decision", json.String("block")),
      #("reason", json.String("tests must pass first")),
    ])
    |> json.to_string
  let assert hookdecisions.Feedback("tests must pass first") =
    hookdecisions.tool_feedback(0, "", stdout, False)
}

pub fn posttooluse_updated_output_replaces_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PostToolUse")),
        #("updatedToolOutput", json.Object([#("stdout", json.String("[redacted]"))])),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Rewritten(replacement) =
    hookdecisions.tool_feedback(0, "", stdout, False)
  let assert Ok(json.Object(fields)) = Ok(replacement)
  let assert Ok(json.String("[redacted]")) = list.key_find(fields, "stdout")
}

pub fn posttooluse_additional_context_is_injected_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("PostToolUse")),
        #("additionalContext", json.String("generated file; edit src instead")),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Context("generated file; edit src instead") =
    hookdecisions.tool_feedback(0, "", stdout, False)
}

pub fn stop_exit_two_continues_with_stderr_test() {
  let assert hookdecisions.Continue("run the tests first") =
    hookdecisions.continuation(2, "run the tests first", "", False)
}

pub fn stop_decision_block_continues_test() {
  let stdout =
    json.Object([
      #("decision", json.String("block")),
      #("reason", json.String("must run the suite")),
    ])
    |> json.to_string
  let assert hookdecisions.Continue("must run the suite") =
    hookdecisions.continuation(0, "", stdout, False)
}

pub fn stop_additional_context_continues_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("Stop")),
        #("additionalContext", json.String("run the test suite before finishing")),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Continue("run the test suite before finishing") =
    hookdecisions.continuation(0, "", stdout, False)
}

pub fn stop_silent_allows_finishing_test() {
  assert hookdecisions.Finish == hookdecisions.continuation(0, "", "", False)
}

pub fn stop_timed_out_finishes_test() {
  assert hookdecisions.Finish == hookdecisions.continuation(2, "x", "", True)
}

pub fn userpromptsubmit_exit_two_blocks_the_prompt_test() {
  let assert hookdecisions.Blocked("ask first") =
    hookdecisions.context_injection("UserPromptSubmit", True, 2, "ask first", "", False)
}

pub fn userpromptsubmit_decision_block_blocks_test() {
  let stdout =
    json.Object([
      #("decision", json.String("block")),
      #("reason", json.String("not in CI")),
    ])
    |> json.to_string
  let assert hookdecisions.Blocked("not in CI") =
    hookdecisions.context_injection("UserPromptSubmit", True, 0, "", stdout, False)
}

pub fn userpromptsubmit_plain_stdout_is_context_test() {
  let assert hookdecisions.Injected("branch context here") =
    hookdecisions.context_injection("UserPromptSubmit", True, 0, "", "branch context here", False)
}

pub fn userpromptsubmit_json_context_test() {
  let stdout =
    json.Object([
      #("hookSpecificOutput", json.Object([
        #("hookEventName", json.String("UserPromptSubmit")),
        #("additionalContext", json.String("today is friday")),
      ])),
    ])
    |> json.to_string
  let assert hookdecisions.Injected("today is friday") =
    hookdecisions.context_injection("UserPromptSubmit", True, 0, "", stdout, False)
}

pub fn sessionstart_cannot_block_test() {
  // Exit 2 on a non-blocking context event is not a rejection: the
  // contract's per-event table has no block for SessionStart.
  let decision =
    hookdecisions.context_injection("SessionStart", False, 2, "whatever", "", False)
  assert hookdecisions.NoContext == decision
}

pub fn sessionstart_plain_stdout_is_context_test() {
  let assert hookdecisions.Injected("current branch: main") =
    hookdecisions.context_injection("SessionStart", False, 0, "", "current branch: main", False)
}

pub fn output_caps_at_ten_thousand_test() {
  // Ten thousand characters pass through; the ten-thousand-and-first
  // brings the preview marker the contract's cap demands.
  let within = string.repeat("x", 10_000)
  assert hookdecisions.capped(within) == within
  let over = string.repeat("x", 10_001)
  let capped = hookdecisions.capped(over)
  assert string.length(capped) < 11_200
  assert string.contains(capped, "hook output capped")
}
