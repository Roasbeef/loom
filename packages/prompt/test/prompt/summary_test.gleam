//// The summarization pack and its serializer.
////
//// Three things are pinned here. The shipped pack decodes and carries
//// every section and fragment `prompt/summary` reaches for, so a typo
//// in the pack is a test failure rather than a silently empty prompt.
//// The initial/update split is driven by the presence of a previous
//// summary, which is what makes a twice-compacted session merge rather
//// than restart. And the transcript is inert: a conversation containing
//// a placeholder, or a tool result the size of a log file, cannot reach
//// the model as either an expansion or the whole of the request.

import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import prompt/default
import prompt/pack
import prompt/summary

fn shipped() -> pack.Pack {
  let assert Ok(decoded) = pack.decode(default.summary_source)
    as "the shipped summary pack must decode"
  decoded
}

pub fn the_shipped_summary_pack_is_whole_test() {
  assert summary.problems(shipped()) == []
}

pub fn the_summary_pack_is_not_the_system_pack_test() {
  // Distinct identities, so telemetry can attribute a cache miss to the
  // one that actually moved.
  let assert Ok(system) = pack.decode(default.source)
  assert system.version != shipped().version
}

pub fn the_system_prompt_forbids_continuing_the_conversation_test() {
  let text = summary.system(shipped())
  assert string.contains(text, "Do not answer it")
  assert string.contains(text, "do not call")
}

pub fn an_absent_previous_summary_selects_the_initial_prompt_test() {
  let text =
    summary.instruction(
      shipped(),
      summary.Compaction(
        conversation: "<conversation>\n[User]: go\n</conversation>",
        previous_summary: None,
        custom_instructions: None,
        files_read: [],
        files_modified: [],
      ),
    )
  assert string.contains(text, "## Goal")
  assert string.contains(text, "[User]: go")
  assert !string.contains(text, "<previous-summary>")
  assert !string.contains(text, "PRESERVE all existing information")
}

pub fn a_previous_summary_selects_the_update_prompt_test() {
  let text =
    summary.instruction(
      shipped(),
      summary.Compaction(
        conversation: "<conversation>\n[User]: go\n</conversation>",
        previous_summary: Some("the earlier account"),
        custom_instructions: None,
        files_read: [],
        files_modified: [],
      ),
    )
  assert string.contains(text, "PRESERVE all existing information")
  assert string.contains(text, "<previous-summary>")
  assert string.contains(text, "the earlier account")
}

pub fn operator_instructions_are_fenced_and_attributed_test() {
  let text =
    summary.instruction(
      shipped(),
      summary.Compaction(
        conversation: "c",
        previous_summary: None,
        custom_instructions: Some("keep the API notes"),
        files_read: [],
        files_modified: [],
      ),
    )
  assert string.contains(text, "<instructions>\nkeep the API notes")
  assert string.contains(text, "from the operator")
}

pub fn file_operations_appear_only_when_there_are_any_test() {
  let without =
    summary.instruction(
      shipped(),
      summary.Compaction(
        conversation: "c",
        previous_summary: None,
        custom_instructions: None,
        files_read: [],
        files_modified: [],
      ),
    )
  assert !string.contains(without, "<read-files>")
  let with_ops =
    summary.instruction(
      shipped(),
      summary.Compaction(
        conversation: "c",
        previous_summary: None,
        custom_instructions: None,
        files_read: ["src/a.gleam"],
        files_modified: ["src/b.gleam"],
      ),
    )
  assert string.contains(with_ops, "<read-files>\nsrc/a.gleam")
  assert string.contains(with_ops, "<modified-files>\nsrc/b.gleam")
}

pub fn a_branch_input_renders_the_branch_prompt_test() {
  let text =
    summary.instruction(
      shipped(),
      summary.Branch(
        conversation: "<conversation>\nx\n</conversation>",
        custom_instructions: None,
      ),
    )
  assert string.contains(text, "## Why it was abandoned")
  assert !string.contains(text, "## Next Steps")
}

// The transcript is spliced with `pack.fill`, which never re-scans a
// substituted value. A conversation naming a binding must therefore
// reach the model as those characters, not as an expansion.
pub fn a_transcript_cannot_expand_a_placeholder_test() {
  let text =
    summary.instruction(
      shipped(),
      summary.Compaction(
        conversation: "MARKER {custom_instructions_text} {conversation}",
        previous_summary: None,
        custom_instructions: Some("SECRET"),
        files_read: [],
        files_modified: [],
      ),
    )
  // The braces reach the model as characters, not as an expansion.
  assert string.contains(text, "{custom_instructions_text} {conversation}")
  // And the transcript is spliced *once*. A second pass over the filled
  // template would expand the `{conversation}` inside it and the
  // transcript would appear twice — which is the shape a prompt
  // injection through a rendered placeholder takes.
  assert count(text, "MARKER") == 1
  // The operator's instruction appears exactly once — in its own fence,
  // never where the transcript asked for it.
  assert count(text, "SECRET") == 1
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, on: needle)) - 1
}

// --- serialization ---------------------------------------------------------

pub fn serialization_is_role_tagged_and_fenced_test() {
  let text =
    summary.serialize([
      user("add a retry"),
      assistant_text("I will wrap the call"),
      tool_result("bash", "ok\tloom/fetch", False),
    ])
  assert string.starts_with(text, "<conversation>\n")
  assert string.ends_with(text, "\n</conversation>")
  assert string.contains(text, "[User]: add a retry")
  assert string.contains(text, "[Assistant]: I will wrap the call")
  assert string.contains(text, "[Tool result: bash]: ok\tloom/fetch")
}

pub fn a_failed_tool_result_says_so_test() {
  let text = summary.serialize([tool_result("bash", "exit 1", True)])
  assert string.contains(text, "[Tool error: bash]: exit 1")
}

pub fn tool_calls_carry_their_arguments_test() {
  let text =
    summary.serialize([
      assistant([
        message.AssistantToolCall(call: message.ToolCall(
          id: "c1",
          name: "bash",
          arguments: json.Object([#("command", json.String("go test"))]),
          thought_signature: None,
          namespace: None,
        )),
      ]),
    ])
  assert string.contains(text, "(calls bash with ")
  assert string.contains(text, "go test")
}

pub fn an_oversized_tool_result_is_cut_and_says_so_test() {
  let huge = string.repeat("x", summary.tool_result_limit + 500)
  let text = summary.serialize([tool_result("bash", huge, False)])
  assert string.contains(text, "(truncated for summarization")
  assert !string.contains(text, huge)
}

pub fn an_empty_projection_still_produces_a_well_formed_element_test() {
  assert summary.serialize([]) == "<conversation>\n\n</conversation>"
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

fn assistant_text(text: String) -> message.AgentMessage {
  assistant([message.AssistantText(text:, text_signature: None)])
}

fn tool_result(
  name: String,
  text: String,
  is_error: Bool,
) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "c1",
    tool_name: name,
    content: [message.ToolResultText(text:, text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error:,
    timestamp: 0,
  )
}

fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
    api: "test",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: message.Usage(
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: 0,
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0,
      ),
    ),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}
