//// What the durable conversation means in ACP: entries to updates, the live
//// stream reconciled with the committed message, escalations to permission
//// requests and back, and a run's end to a stop reason.

import core/accounting
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import session_view/approval
import tui/acp/schema
import tui/acp/translate

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn entry_of(seq: Int, body: message.AgentMessage) -> entry.Entry {
  entry.MessageEntry(id(seq), None, seq, seq * 1000, body, False)
}

fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content,
    "test",
    "test",
    "test",
    None,
    None,
    None,
    accounting.zero_usage(),
    message.Stop,
    None,
    None,
    None,
    None,
    0,
  )
}

fn said(text: String) -> message.AssistantBlock {
  message.AssistantText(text, None)
}

fn call(name: String, arguments: json.JsonValue) -> message.AssistantBlock {
  message.AssistantToolCall(message.ToolCall("c1", name, arguments, None, None))
}

fn result_of(text: String, is_error: Bool) -> message.AgentMessage {
  message.ToolResultMessage(
    "c1",
    "bash",
    [message.ToolResultText(text, None)],
    None,
    None,
    None,
    is_error,
    0,
  )
}

fn updates(entry: entry.Entry) -> List(schema.Update) {
  translate.entry_updates(entry, translate.Live, translate.nothing_streamed).0
}

pub fn an_answer_with_nothing_streamed_is_sent_whole_test() {
  assert updates(entry_of(1, assistant([said("All done.")])))
    == [schema.AgentText("All done.")]
}

pub fn reasoning_and_answer_keep_their_order_test() {
  let body =
    assistant([message.AssistantThinking("hmm", None, False), said("ok")])

  assert updates(entry_of(1, body))
    == [schema.AgentThought("hmm"), schema.AgentText("ok")]
}

pub fn redacted_reasoning_and_blank_text_are_never_forwarded_test() {
  let body =
    assistant([
      message.AssistantThinking("secret", Some("sig"), True),
      said("   "),
      message.AssistantThinking("", None, False),
    ])

  assert updates(entry_of(1, body)) == []
}

pub fn a_tool_call_announces_pending_with_its_arguments_test() {
  let arguments = json.Object([#("command", json.String("ls -la\nrm x"))])
  let assert [schema.ToolStarted(started)] =
    updates(entry_of(1, assistant([call("bash", arguments)])))

  assert started.id == "c1"
  assert started.title == "bash: ls -la"
  assert started.kind == schema.Execute
  assert started.status == schema.Pending
  assert started.raw_input == arguments
}

pub fn tool_kinds_follow_loom_tool_names_test() {
  let kind = fn(name) {
    let assert [schema.ToolStarted(started)] =
      updates(entry_of(1, assistant([call(name, json.Null)])))
    started.kind
  }

  assert kind("fs_read") == schema.Read
  assert kind("fs_edit") == schema.Edit
  assert kind("fs_write") == schema.Edit
  assert kind("grep") == schema.Search
  assert kind("bash") == schema.Execute
  assert kind("agent_send") == schema.Other
}

pub fn a_long_argument_is_cut_in_the_title_test() {
  let arguments = json.Object([#("path", json.String(string.repeat("p", 500)))])
  let assert [schema.ToolStarted(started)] =
    updates(entry_of(1, assistant([call("fs_read", arguments)])))

  assert string.length(started.title) < 120
  assert string.ends_with(started.title, "...")
}

pub fn a_tool_result_completes_or_fails_its_call_test() {
  let assert [
    schema.ToolProgress(id: "c1", status: schema.Completed, output:, ..),
  ] = updates(entry_of(2, result_of("fine", False)))
  assert output == Some("fine")

  let assert [schema.ToolProgress(status: schema.Failed, raw_output:, ..)] =
    updates(entry_of(3, result_of("boom", True)))
  assert raw_output
    == Some(
      json.Object([
        #("output", json.String("boom")),
        #("is_error", json.Bool(True)),
      ]),
    )
}

pub fn a_huge_tool_output_is_bounded_and_says_so_test() {
  let big = string.repeat("x", translate.max_output_chars + 100)
  let assert [schema.ToolProgress(output: Some(shown), ..)] =
    updates(entry_of(2, result_of(big, False)))

  assert string.length(shown) < translate.max_output_chars + 40
  assert string.ends_with(shown, "[output truncated]")
}

pub fn the_users_own_message_is_echoed_only_in_a_replay_test() {
  let body =
    message.UserMessage(
      [message.UserText("fix it", None), message.UserImage("AA", "image/png")],
      0,
      None,
    )
  let none = translate.nothing_streamed

  assert translate.entry_updates(entry_of(1, body), translate.Live, none).0
    == []
  assert translate.entry_updates(entry_of(1, body), translate.Replay, none).0
    == [schema.UserText("fix it"), schema.UserText("[image: image/png]")]
}

pub fn bookkeeping_entries_produce_nothing_test() {
  let custom = entry.CustomEntry(id(1), None, 1, 0, "note", None)

  assert updates(custom) == []
}

pub fn streamed_text_is_not_shown_again_when_the_message_commits_test() {
  let #(shown, streamed) =
    translate.fragment("text", "All ", translate.nothing_streamed)
  let #(_, streamed) = translate.fragment("text", "done.", streamed)
  assert shown == Some(schema.AgentText("All "))

  let #(again, rest) =
    translate.entry_updates(
      entry_of(1, assistant([said("All done.")])),
      translate.Live,
      streamed,
    )

  assert again == []
  assert rest == translate.nothing_streamed
}

pub fn an_unstreamed_tail_is_sent_when_the_stream_stopped_short_test() {
  let #(_, streamed) =
    translate.fragment("text", "All ", translate.nothing_streamed)

  let #(rest, left) =
    translate.entry_updates(
      entry_of(1, assistant([said("All done.")])),
      translate.Live,
      streamed,
    )

  assert rest == [schema.AgentText("done.")]
  assert left == translate.nothing_streamed
}

pub fn the_next_requests_stream_survives_the_previous_commit_test() {
  let #(_, streamed) =
    translate.fragment("text", "first. second", translate.nothing_streamed)

  let #(rest, left) =
    translate.entry_updates(
      entry_of(1, assistant([said("first. ")])),
      translate.Live,
      streamed,
    )

  assert rest == []
  assert left.text == "second"
}

pub fn text_that_diverged_from_the_stream_is_shown_in_full_test() {
  let #(_, streamed) =
    translate.fragment("text", "draft", translate.nothing_streamed)

  let #(rest, left) =
    translate.entry_updates(
      entry_of(1, assistant([said("final")])),
      translate.Live,
      streamed,
    )

  assert rest == [schema.AgentText("final")]
  assert left == translate.nothing_streamed
}

pub fn thinking_is_reconciled_separately_from_text_test() {
  let #(_, streamed) =
    translate.fragment("thinking", "plan", translate.nothing_streamed)
  let body =
    assistant([message.AssistantThinking("plan", None, False), said("go")])

  let #(rest, _) =
    translate.entry_updates(entry_of(1, body), translate.Live, streamed)

  assert rest == [schema.AgentText("go")]
}

pub fn a_stream_kind_acp_has_no_word_for_is_ignored_test() {
  let #(update, streamed) =
    translate.fragment("tool_args", "{\"a\"", translate.nothing_streamed)

  assert update == None
  assert streamed == translate.nothing_streamed
}

pub fn unmatched_stream_text_is_bounded_test() {
  let big = string.repeat("a", translate.max_streamed_chars)
  let #(_, streamed) =
    translate.fragment("text", big, translate.nothing_streamed)
  let #(_, streamed) = translate.fragment("text", "tail", streamed)

  assert string.length(streamed.text) == translate.max_streamed_chars
  assert string.ends_with(streamed.text, "tail")
}

pub fn a_tool_tail_is_a_running_update_test() {
  assert translate.tool_tail("c1", "partial")
    == schema.ToolProgress("c1", schema.InProgress, Some("partial"), None)
}

fn review(grants: List(json.JsonValue)) -> approval.Review {
  approval.Review(
    "e1",
    4,
    approval.Pending,
    "bash",
    "rm -rf build\nsecond line",
    None,
    approval.Exact("digest", grants),
    strand: Some("main"),
    remote: None,
  )
}

fn readable_root() -> json.JsonValue {
  json.Object([
    #("type", json.String("readable_root")),
    #("path", json.String("/work")),
  ])
}

pub fn an_exact_escalation_offers_once_session_and_deny_test() {
  let #(request, options) = translate.permission(review([readable_root()]))

  assert request.id == "escalation-e1"
  assert request.kind == schema.Execute
  assert string.contains(request.title, "rm -rf build")
  assert !string.contains(request.title, "second line")
  assert list.map(options, fn(option) { #(option.id, option.kind) })
    == [
      #("allow", schema.AllowOnce),
      #("allow_session", schema.AllowAlways),
      #("reject", schema.RejectOnce),
    ]
}

pub fn authority_that_cannot_be_remembered_offers_no_session_choice_test() {
  let wall =
    json.Object([
      #("type", json.String("limit")),
      #("field", json.String("wall_seconds")),
      #("value", json.Int(60)),
    ])

  let #(_, options) = translate.permission(review([wall, readable_root()]))

  assert list.map(options, fn(option) { option.id }) == ["allow", "reject"]
}

pub fn an_escalation_that_cannot_be_encoded_can_only_be_denied_test() {
  let unavailable =
    approval.Review(
      ..review([]),
      permission: approval.Unavailable("no action digest"),
    )

  let #(request, options) = translate.permission(unavailable)

  assert list.map(options, fn(option) { option.id }) == ["reject"]
  assert string.contains(json.to_string(request.raw_input), "no action digest")
}

pub fn only_a_recognised_allow_option_widens_authority_test() {
  assert translate.decision(schema.Selected("allow")) == translate.Approve
  assert translate.decision(schema.Selected("allow_session"))
    == translate.ApproveForSession
  assert translate.decision(schema.Selected("reject")) == translate.Deny
  assert translate.decision(schema.Selected("allow ")) == translate.Deny
  assert translate.decision(schema.Selected("surprise")) == translate.Deny
  assert translate.decision(schema.Dismissed) == translate.Deny
}

fn run_result(outcome: operation.RunOutcome) -> operation.LastResult {
  operation.RunLastResult(
    ids.mint_op(ids.generator(clock.fixed(1), 1)).0,
    None,
    outcome,
    None,
  )
}

pub fn a_runs_end_is_a_stop_reason_or_an_error_test() {
  let failed =
    operation.RunFailed(operation.OperationError("provider_error", "x", None))

  assert translate.outcome(
      run_result(operation.RunCompleted(operation.CompletedByAssistant)),
    )
    == Some(translate.Stopped(schema.EndTurn))
  assert translate.outcome(run_result(operation.RunAborted))
    == Some(translate.Stopped(schema.Cancelled))
  let assert Some(translate.Errored(reason)) =
    translate.outcome(run_result(failed))
  assert string.contains(reason, "provider_error")
}

pub fn a_compaction_result_ends_no_turn_test() {
  let compaction =
    operation.CompactionLastResult(
      ids.mint_op(ids.generator(clock.fixed(1), 1)).0,
      None,
      operation.StructuralCompleted,
    )

  assert translate.outcome(compaction) == None
}

pub fn a_turns_tokens_are_the_difference_of_cumulative_usage_test() {
  let before =
    message.Usage(
      ..accounting.zero_usage(),
      input: 100,
      output: 20,
      cache_read: 5,
      cache_write: 1,
      total_tokens: 126,
    )
  let after =
    message.Usage(
      ..accounting.zero_usage(),
      input: 160,
      output: 50,
      cache_read: 9,
      cache_write: 1,
      total_tokens: 220,
      reasoning: Some(7),
    )

  assert translate.turn_usage(before, after)
    == schema.TurnUsage(
      input: 60,
      output: 30,
      total: 94,
      thought: Some(7),
      cached_read: 4,
      cached_write: 0,
    )
  assert translate.turn_usage(after, before).total == 0
}
