//// The count of committed `ask` results the shared record keeps for readers
//// that act once per ask, such as the terminal's ask poll.

import core/clock
import core/entry
import core/ids
import core/message
import gleam/option.{None}
import session_view/event_fold
import session_view/inbox
import session_view/model.{type Shared}
import session_view/msg
import session_view/protocol
import session_view/step

fn fresh() -> Shared(String, Nil, String, String) {
  step.new(
    "main",
    "session",
    msg.Stamp(1000, 1000),
    inbox.new("frames"),
    inbox.new("replay"),
  )
}

fn result_of(tool: String, seq: Int) -> protocol.Event {
  let id = ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
  protocol.EntryAdded(protocol.EntryRecord(
    strand: "main",
    entry: entry.MessageEntry(
      id:,
      parent: None,
      seq:,
      ts: seq,
      message: message.ToolResultMessage(
        tool_call_id: "call-1",
        tool_name: tool,
        content: [message.ToolResultText("done", None)],
        details: None,
        usage: None,
        added_tool_names: None,
        is_error: False,
        timestamp: seq,
      ),
      terminate: False,
    ),
  ))
}

pub fn only_a_committed_ask_result_is_counted_test() {
  let shared = fresh()
  assert shared.ask_results == 0

  let after_other = event_fold.apply_event(shared, result_of("fs_read", 1))
  assert after_other.ask_results == 0

  let after_ask = event_fold.apply_event(after_other, result_of("ask", 2))
  assert after_ask.ask_results == 1
}
