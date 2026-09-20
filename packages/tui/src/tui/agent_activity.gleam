//// Bounded activity summaries retain the provenance of the loaded branch.
//// Calls join results by provider identity in source order. Only entries after
//// an operation's accepted prompt belong to its recent activity; an evicted
//// prompt leaves that boundary unknown instead of borrowing a predecessor's
//// tools. Dependency labels come only from effect-pending agent_wait calls.

import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import tui/snapshot
import tui/snapshot_view
import tui/text_hygiene
import tui/tool_activity

/// Names an effect-pending wait's requested runs, never a quiet stream.
///
/// ## Examples
///
/// ```gleam
/// assert agent_activity.waiting([]) == None
/// ```
@internal
pub fn waiting(calls: List(message.ToolCall)) -> Option(String) {
  let waits = list.filter(calls, fn(call) { call.name == "agent_wait" })
  let names =
    waits
    |> list.flat_map(fn(call) {
      case call.arguments {
        json.Object(fields) ->
          case list.key_find(fields, "handles") {
            Ok(json.Array(handles)) -> list.filter_map(handles, handle_name)
            _ -> []
          }
        _ -> []
      }
    })
    |> list.unique
  case names {
    [] -> None
    names ->
      Some(
        "Waiting for "
        <> string.join(list.take(names, 3), ", ")
        <> case list.drop(names, 3) {
          [] -> ""
          more -> " + " <> int.to_string(list.length(more)) <> " runs"
        }
        <> case list.length(waits) < list.length(calls) {
          True -> " · other tools active"
          False -> ""
        },
      )
  }
}

fn handle_name(value: json.JsonValue) -> Result(String, Nil) {
  use text <- result.try(case value {
    json.String(text) -> Ok(text)
    _ -> Error(Nil)
  })
  case list.reverse(string.split(text, "#")) {
    [operation, first, ..rest] -> {
      use _ <- result.try(
        ids.parse_op_id(operation) |> result.replace_error(Nil),
      )
      let name = string.join(list.reverse([first, ..rest]), "#")
      case name {
        "" -> Error(Nil)
        _ -> Ok(text_hygiene.single_line(name))
      }
    }
    _ -> Error(Nil)
  }
}

/// Projects at most five invocation/result summaries for this operation.
///
/// ## Examples
///
/// ```gleam
/// // agent_activity.recent(view, window, "main", operation)
/// ```
@internal
pub fn recent(
  view: snapshot_view.View,
  window: snapshot.Window,
  strand: String,
  current: Option(String),
) -> List(String) {
  let branch = snapshot_view.branch(view, window, strand)
  let entries = list.map(branch.records, fn(row) { row.entry })
  let start = {
    use id <- result.try(option.to_result(current, Nil))
    use cell <- result.try(
      list.find(view.cells, fn(cell) {
        cell.namespace == register.OpMeta && cell.key == id
      }),
    )
    use meta <- result.try(
      codec.decode_operation(cell.value) |> result.replace_error(Nil),
    )
    case meta.intent {
      operation.RunIntent(prompts) ->
        entries
        |> list.filter(fn(value) { list.contains(prompts, value.id) })
        |> list.map(fn(value) { value.seq })
        |> list.sort(int.compare)
        |> list.first
      _ -> Error(Nil)
    }
  }
  case start {
    Error(Nil) -> []
    Ok(start) ->
      entries
      |> list.filter(fn(value) { value.seq > start })
      |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
      |> list.map(activity_entry)
      |> tool_activity.project
      |> list.flat_map(fn(item) {
        case item {
          tool_activity.Tools(calls) -> calls
          tool_activity.Narrative(_) -> []
        }
      })
      |> list.reverse
      |> list.take(5)
      |> list.reverse
      |> list.map(call_summary)
  }
}

// A response may contain prose and tool calls together. This projection only
// needs invocation identity; removing prose from this temporary copy lets the
// existing result join cover that shape without changing the stored message.
fn activity_entry(value: entry.Entry) -> entry.Entry {
  case value {
    entry.MessageEntry(
      message: message.AssistantMessage(content:, ..) as response,
      ..,
    ) ->
      entry.MessageEntry(
        ..value,
        message: message.AssistantMessage(
          ..response,
          content: list.filter(content, fn(block) {
            case block {
              message.AssistantToolCall(_) -> True
              message.AssistantText(..) | message.AssistantThinking(..) -> False
            }
          }),
        ),
      )
    _ -> value
  }
}

fn call_summary(call: tool_activity.Call) -> String {
  let status = case call.outcome {
    Some(message.ToolResultMessage(is_error: True, ..)) -> "× Failed · "
    Some(message.ToolResultMessage(is_error: False, ..)) -> "✓ Completed · "
    _ -> "· Result unavailable · "
  }
  status <> invocation(call.invocation)
}

/// A short action name drawn from known argument shapes.
///
/// ## Examples
///
/// ```gleam
/// // agent_activity.invocation(call)
/// ```
@internal
pub fn invocation(call: message.ToolCall) -> String {
  let detail = case call.arguments {
    json.Object(fields) ->
      ["path", "command", "pattern"]
      |> list.find_map(fn(key) {
        case list.key_find(fields, key) {
          Ok(json.String(value)) -> Ok(value)
          _ -> Error(Nil)
        }
      })
      |> result.unwrap("")
    _ -> ""
  }
  text_hygiene.single_line(
    call.name
    <> case detail {
      "" -> ""
      _ -> " · " <> detail
    },
  )
  |> string.slice(0, 160)
}
