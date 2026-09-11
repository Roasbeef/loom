//// Compact tool activity, with results joined by provider call identity.
////
//// Consecutive calls belong to one visual group until human or assistant
//// prose resumes. The group keeps source order even when parallel results
//// arrive out of order. It never guesses ownership from a command or path:
//// an orphan result remains an ordinary entry. Expanded history bypasses
//// this projection and shows every original message, including reasoning.

import core/entry
import core/ids
import core/message
import core/register
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/codec
import machine/operation
import tui/snapshot_view

/// One boundary in the compact transcript.
pub type Item {
  /// Prose, structural history, or a result whose call is outside the window.
  Narrative(value: entry.Entry)

  /// A source-ordered group of calls and their identity-matched results.
  Tools(calls: List(Call))
}

/// One invocation, which remains distinct even when arguments repeat.
pub type Call {
  Call(
    /// Durable owner disambiguates identical or reused provider call IDs.
    source: ids.EntryId,
    /// The original call, including the provider-assigned identity.
    invocation: message.ToolCall,
    /// The complete result, or absence when this window has no result yet.
    outcome: Option(message.AgentMessage),
  )
}

type Group {
  Group(order: List(String), calls: Dict(String, Call))
}

/// Projects oldest-first entries without changing their durable contents.
///
/// ## Examples
///
/// ```gleam
/// assert tool_activity.project([]) == []
/// ```
pub fn project(entries: List(entry.Entry)) -> List(Item) {
  let #(items, group) =
    list.fold(entries, #([], Group([], dict.new())), collect)
  flush(items, group) |> list.reverse
}

/// Finds effect-pending calls in the captured current operation.
///
/// Transcript order cannot establish current work: an old call can lack a
/// visible result after retention or cancellation. The operation's batch and
/// source indices are the authority, and a missing producing entry leaves
/// the caller with a generic phase label rather than a guessed command.
///
/// ## Examples
///
/// ```gleam
/// assert tool_activity.running([], [], "absent") == []
/// ```
pub fn running(
  cells: List(snapshot_view.Cell),
  entries: List(entry.Entry),
  current: String,
) -> List(message.ToolCall) {
  let state =
    cells
    |> list.find(fn(cell) {
      cell.namespace == register.OpState && cell.key == current
    })
    |> result.try(fn(cell) {
      codec.decode_state(cell.value) |> result.replace_error(Nil)
    })
  case state {
    Ok(operation.RunState(phase: operation.Tools(batch), ..)) ->
      running_batch(entries, batch)
    Ok(operation.RunState(..))
    | Ok(operation.CompactionState(..))
    | Ok(operation.NavigationState(..))
    | Error(Nil) -> []
  }
}

fn running_batch(entries: List(entry.Entry), batch: operation.ToolBatch) {
  let pending =
    list.filter_map(batch.calls, fn(call) {
      case call {
        operation.CallEffectPending(source_index:, ..) -> Ok(source_index)
        operation.CallPlanned(..)
        | operation.CallOutcomeReady(..)
        | operation.CallCompleted(..) -> Error(Nil)
      }
    })
  case list.find(entries, fn(value) { value.id == batch.assistant_entry }) {
    Ok(entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..)) ->
      content
      |> list.index_map(fn(block, index) { #(block, index) })
      |> list.filter_map(fn(pair) {
        case pair.0, list.contains(pending, pair.1) {
          message.AssistantToolCall(call), True -> Ok(call)
          _, _ -> Error(Nil)
        }
      })
    Ok(_) | Error(Nil) -> []
  }
}

fn collect(acc: #(List(Item), Group), value: entry.Entry) {
  let #(items, group) = acc
  case value {
    entry.MessageEntry(
      message: message.AssistantMessage(content:, error_message: None, ..),
      ..,
    ) -> collect_assistant(items, group, value, content)
    entry.MessageEntry(
      message: message.ToolResultMessage(tool_call_id:, ..) as outcome,
      ..,
    ) -> {
      // An out-of-window result cannot acquire a call merely because its
      // tool name or text resembles one already on screen.
      case dict.get(group.calls, tool_call_id) {
        Error(Nil) -> boundary(items, group, value)
        Ok(call) -> #(
          items,
          Group(
            ..group,
            calls: dict.insert(
              group.calls,
              tool_call_id,
              Call(..call, outcome: Some(outcome)),
            ),
          ),
        )
      }
    }
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> boundary(items, group, value)
  }
}

fn collect_assistant(
  items: List(Item),
  group: Group,
  value: entry.Entry,
  content: List(message.AssistantBlock),
) {
  case list.any(content, has_prose) {
    True -> boundary(items, group, value)
    False -> {
      let calls =
        list.filter_map(content, fn(block) {
          case block {
            message.AssistantToolCall(call) -> Ok(call)
            message.AssistantText(..) | message.AssistantThinking(..) ->
              Error(Nil)
          }
        })

      // Thinking between tool batches remains available in expanded mode.
      // Before the first tool, however, it is ordinary narrative history.
      case calls, group.order {
        [], [] -> boundary(items, group, value)
        _, _ ->
          list.fold(calls, #(items, group), fn(acc, call) {
            collect_call(acc, value.id, call)
          })
      }
    }
  }
}

// Provider call ids can be reused by a later response. End the visual group
// at reuse so one dictionary can never overwrite an earlier invocation.
// This also leaves malformed duplicate ids visible rather than dropping text.
fn collect_call(
  acc: #(List(Item), Group),
  source: ids.EntryId,
  invocation: message.ToolCall,
) {
  let #(items, group) = acc
  case dict.has_key(group.calls, invocation.id) {
    False -> #(items, add_call(group, source, invocation))
    True -> #(
      flush(items, group),
      add_call(Group([], dict.new()), source, invocation),
    )
  }
}

fn has_prose(block) {
  case block {
    message.AssistantText(text:, ..) -> text != ""
    message.AssistantThinking(thinking:, redacted:, ..) ->
      !redacted && thinking != ""
    message.AssistantToolCall(_) -> False
  }
}

fn add_call(group: Group, source: ids.EntryId, invocation: message.ToolCall) {
  let message.ToolCall(id:, ..) = invocation
  Group(
    order: [id, ..group.order],
    calls: dict.insert(group.calls, id, Call(source, invocation, None)),
  )
}

fn boundary(items: List(Item), group: Group, value: entry.Entry) {
  #([Narrative(value), ..flush(items, group)], Group([], dict.new()))
}

fn flush(items: List(Item), group: Group) {
  case group.order {
    [] -> items
    order -> {
      let calls =
        order
        |> list.reverse
        |> list.filter_map(dict.get(group.calls, _))
      [Tools(calls), ..items]
    }
  }
}
