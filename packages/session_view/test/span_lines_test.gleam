//// The lines of a timeline span: what a person said, what the agent said, each
//// call with how it ended and a compaction, in order, bounded, with the harness's
//// own messages and a peer's left out.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/composer
import session_view/span_lines.{Failed, NoResult, Prompted, Said, Step}

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn record(seq: Int, body: message.AgentMessage) -> entry.Entry {
  entry.MessageEntry(id(seq), None, seq, seq * 1000, body, False)
}

fn said(seq: Int, text: String) -> entry.Entry {
  record(seq, message.UserMessage([message.UserText(text, None)], 0, None))
}

fn response(seq: Int, blocks: List(message.AssistantBlock)) -> entry.Entry {
  record(
    seq,
    message.AssistantMessage(
      blocks,
      "t",
      "t",
      "t",
      None,
      None,
      None,
      message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
        usage_evidence.none(),
      ),
      message.Stop,
      None,
      None,
      None,
      None,
      0,
    ),
  )
}

fn call(seq: Int, call_id: String, command: String) -> entry.Entry {
  response(seq, [
    message.AssistantToolCall(message.ToolCall(
      call_id,
      "bash",
      json.Object([#("command", json.String(command))]),
      None,
      None,
    )),
  ])
}

fn result(seq: Int, call_id: String, is_error: Bool) -> entry.Entry {
  record(
    seq,
    message.ToolResultMessage(
      call_id,
      "bash",
      [message.ToolResultText("out", None)],
      Some(json.Object([#("exit_code", json.Int(0))])),
      None,
      None,
      is_error,
      0,
    ),
  )
}

pub fn a_span_reads_as_what_was_said_and_each_call_in_order_test() {
  let #(lines, omitted) =
    span_lines.of_records([
      said(1, "fix the replay\nmore detail"),
      response(2, [message.AssistantText("Looking at it.", None)]),
      call(3, "c1", "make check"),
      result(4, "c1", True),
      call(5, "c2", "git status"),
    ])

  assert omitted == 0
  assert list.map(lines, fn(line) { line.kind }) == [Prompted, Said, Step, Step]
  assert list.map(lines, fn(line) { line.words })
    == [
      "fix the replay",
      "Looking at it.",
      "Ran make check",
      "Ran git status",
    ]
  assert list.map(lines, fn(line) { line.outcome })
    == [span_lines.NoOutcome, span_lines.NoOutcome, Failed, NoResult]
  assert list.map(lines, fn(line) { line.seq }) == [1, 2, 3, 5]
}

pub fn harness_and_peer_messages_make_no_line_test() {
  let memory =
    composer.memory_attribution_lead
    <> "sessions.\n\n```loom-memory\n- (fact) a\n```"
  let peer =
    record(
      2,
      message.UserMessage(
        [message.UserText("hello", None)],
        0,
        Some(message.PeerOrigin("s", "main")),
      ),
    )
  let #(lines, _) =
    span_lines.of_records([said(1, memory), peer, said(3, "real")])

  assert list.map(lines, fn(line) { line.words }) == ["real"]
}

pub fn a_long_span_keeps_the_newest_lines_and_counts_the_rest_test() {
  let records =
    list.map(upto(150), fn(n) { said(n + 1, "line " <> int.to_string(n)) })
  let #(lines, omitted) = span_lines.of_records(records)

  assert list.length(lines) == span_lines.max_lines
  assert omitted == 50
  assert case lines {
    [first, ..] -> first.words == "line 50"
    [] -> False
  }
}

pub fn words_are_cut_in_bytes_at_a_character_boundary_test() {
  let #(lines, _) = span_lines.of_records([said(1, string.repeat("é", 300))])

  assert list.all(lines, fn(line) {
    string.byte_size(line.words) <= span_lines.words_bytes
    && string.ends_with(line.words, "…")
  })
}

fn upto(count: Int) -> List(Int) {
  int.range(from: 0, to: count, with: [], run: fn(found, n) { [n, ..found] })
  |> list.reverse
}
