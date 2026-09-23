//// Advisor commentary is projected from settled captured ancestry only.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import tui/advisor_history
import tui/snapshot
import tui/snapshot_view

fn id(number: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(number), number)).0
}

fn usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

fn view(main: Int, advisor: Int) -> snapshot_view.View {
  snapshot_view.View(
    [],
    dict.from_list([#("main", Some(id(main))), #("advisor", Some(id(advisor)))]),
    dict.new(),
    dict.new(),
    usage(),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    None,
    None,
  )
}

fn assistant(
  number: Int,
  parent: Int,
  content: List(message.AssistantBlock),
) -> entry.Entry {
  entry.MessageEntry(
    id(number),
    Some(id(parent)),
    number,
    number,
    message.AssistantMessage(
      content,
      "test",
      "test",
      "test",
      None,
      None,
      None,
      usage(),
      message.Stop,
      None,
      None,
      None,
      None,
      number,
    ),
    False,
  )
}

fn feed(number: Int, parent: Int) -> entry.Entry {
  entry.MessageEntry(
    id(number),
    Some(id(parent)),
    number,
    number,
    message.UserMessage([message.UserText("advisor feed", None)], number, None),
    False,
  )
}

fn call(verdict: String, text: String) -> message.AssistantBlock {
  message.AssistantToolCall(message.ToolCall(
    "call",
    "advise",
    json.Object([
      #("verdict", json.String(verdict)),
      #("text", json.String(text)),
    ]),
    None,
    None,
  ))
}

fn window(entries: List(entry.Entry)) -> snapshot.Window {
  snapshot.Window(
    list.map(entries, fn(value) { snapshot.Loaded(value, 100) }),
    100 * list.length(entries),
    None,
  )
}

pub fn full_advisor_text_excludes_inherited_primary_and_preserves_identity_test() {
  let root = assistant(1, 9, [message.AssistantText("Inherited primary", None)])
  let primary =
    assistant(2, 1, [message.AssistantText("Primary after fork", None)])
  let review =
    assistant(4, 3, [
      message.AssistantText("First paragraph.\nSecond paragraph.", None),
      message.AssistantThinking("private reasoning", None, False),
      message.AssistantText("Final paragraph.", None),
      call("block", "stop the primary"),
    ])
  let captured = window([review, feed(3, 1), primary, root])
  let board = advisor_history.project(view(2, 4), captured)

  assert list.map(board.items, fn(item) { item.text })
    == [
      "First paragraph.\nSecond paragraph.",
      "Final paragraph.",
    ]
  assert list.map(board.items, fn(item) { item.block_index }) == [0, 2]
  assert list.all(board.items, fn(item) {
    item.entry_id == ids.entry_id_to_string(id(4))
    && item.seq == 4
    && item.annotation == advisor_history.RequestedBlock
  })
}

pub fn quiet_and_unclassified_commentary_are_visible_without_delivery_claims_test() {
  let quiet =
    assistant(4, 3, [
      message.AssistantText("All good so far.", None),
      call("quiet", ""),
    ])
  let malformed =
    assistant(5, 4, [
      message.AssistantText("I see another concern.", None),
      call("nudge", ""),
    ])
  let nudge =
    assistant(6, 5, [
      message.AssistantText("A small correction can wait.", None),
      call("nudge", "check the edge case"),
    ])
  let captured = window([nudge, malformed, quiet, feed(3, 1)])
  let board = advisor_history.project(view(1, 6), captured)

  assert list.map(board.items, fn(item) { item.annotation })
    == [
      advisor_history.RequestedQuiet,
      advisor_history.AdvisorUpdate,
      advisor_history.RequestedNudge,
    ]
  assert list.map(board.items, fn(item) { item.text })
    == [
      "All good so far.",
      "I see another concern.",
      "A small correction can wait.",
    ]
}

pub fn ambiguous_tool_calls_and_missing_older_history_are_explicit_test() {
  let ambiguous =
    assistant(4, 3, [
      message.AssistantText("The review is ongoing.", None),
      call("block", "stop"),
      call("nudge", "later"),
    ])
  let captured = window([ambiguous])
  let board = advisor_history.project(view(2, 4), captured)

  assert list.map(board.items, fn(item) { item.annotation })
    == [
      advisor_history.AdvisorUpdate,
    ]
  assert board.unloaded == Some(ids.entry_id_to_string(id(3)))
}

pub fn absent_advisor_branch_adds_no_commentary_test() {
  let board = advisor_history.project(view(1, 4), window([]))
  assert board.items == []
  assert board.unloaded == Some(ids.entry_id_to_string(id(4)))
}
