//// A session the insight triage tests share: a primary strand whose every turn
//// ends with a failed tool call, so each turn lifts one Insights row.
////
//// A turn is four entries: the owner's request, an assistant message that
//// reasons and then calls `bash`, the call's failed result, and the closing
//// message. Entries are numbered from one in the order they happened, and
//// each is the child of the one before, as a primary strand's branch is.

import core/clock
import core/entry.{type Entry}
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None, Some}

/// The reasoning every assistant message carries, which no request may show.
pub const secret_thought = "private reasoning that must stay out"

/// The primary strand's branch for `turns` failed turns, newest first, as
/// `storage.scan_branch` returns it. Each failed result holds `output`.
pub fn failed_turns(turns: Int, output: String) -> List(Entry) {
  list.repeat(Nil, turns)
  |> list.index_map(fn(_, turn) { one_turn(turn, output) })
  |> list.flatten
  |> list.reverse
}

/// One turn's four entries, oldest first.
fn one_turn(turn: Int, output: String) -> List(Entry) {
  let base = turn * 4
  let call_id = "call-" <> int.to_string(turn)

  [
    at(base + 1, said("turn " <> int.to_string(turn) <> ": run the build")),
    at(
      base + 2,
      assistant([
        message.AssistantThinking(secret_thought, None, False),
        message.AssistantToolCall(message.ToolCall(
          call_id,
          "bash",
          json.Object([#("command", json.String("make build"))]),
          None,
          None,
        )),
      ]),
    ),
    at(
      base + 3,
      message.ToolResultMessage(
        call_id,
        "bash",
        [message.ToolResultText(output, None)],
        Some(json.Object([#("exit_code", json.Int(2))])),
        None,
        None,
        True,
        0,
      ),
    ),
    at(
      base + 4,
      assistant([
        message.AssistantText(
          "turn " <> int.to_string(turn) <> " ended with the build failing",
          None,
        ),
      ]),
    ),
  ]
}

/// The entry numbered `seq`, the child of the one before it.
fn at(seq: Int, body: message.AgentMessage) -> Entry {
  let parent = case seq {
    1 -> None
    _ -> Some(entry_id(seq - 1))
  }

  entry.MessageEntry(entry_id(seq), parent, seq, seq * 10_000, body, False)
}

/// The identity of the entry numbered `seq`.
fn entry_id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

/// An owner message.
fn said(text: String) -> message.AgentMessage {
  message.UserMessage([message.UserText(text, None)], 0, None)
}

/// An assistant message that stopped normally.
fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content,
    "test",
    "test",
    "test",
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
  )
}
