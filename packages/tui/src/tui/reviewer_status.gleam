//// Reviewer rows use the same captured operation and queue as the transcript.
//// Only a bounded task excerpt survives capture eviction, keyed by operation
//// identity. Progress always comes from the current cut, never a missing tool
//// result which might belong to an earlier turn.

import core/entry
import core/message
import core/register
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import tui/snapshot
import tui/snapshot_view
import tui/text_hygiene
import tui/tool_activity

/// One current reviewer with a bounded task excerpt.
@internal
pub type Row {
  Row(
    /// Strand identity also opens the reviewer's transcript.
    strand: String,
    /// Operation identity prevents carrying an old task into its successor.
    operation: String,
    /// Human-readable accepted task, when its prompt was captured.
    task: String,
    /// Current phase or effect-pending tool names.
    progress: String,
    /// Receipt evidence, separate from incorporation into the task.
    pending: String,
  )
}

/// Projects live reviewers and retains bounded task excerpts for the captured strand set.
///
/// ## Examples
///
/// ```gleam
/// // reviewer_status.observe(previous, cut.window, view)
/// ```
@internal
pub fn observe(
  previous: List(Row),
  window: snapshot.Window,
  view: snapshot_view.View,
) -> List(Row) {
  let entries =
    list.filter_map(window.items, fn(record) {
      case record {
        snapshot.Loaded(value, _) -> Ok(value)
        snapshot.Unloaded(..) -> Error(Nil)
      }
    })
  view.strands
  |> list.filter_map(fn(strand) {
    use current <- result.try(dict.get(view.operations, strand.id))
    let task = task_excerpt(view.cells, entries, current)
    let retained = case task {
      "" ->
        previous
        |> list.find(fn(row) {
          row.operation == current && row.strand == strand.id
        })
        |> result.map(fn(row) { row.task })
        |> result.unwrap("task brief outside loaded history")
      text -> text
    }
    let calls = tool_activity.running(view.cells, entries, current)
    let progress = case calls {
      [] -> option.unwrap(strand.live_phase, "running")
      calls ->
        calls
        |> list.take(3)
        |> list.map(fn(call) { call.name })
        |> string.join(", ")
    }
    let pending = case view.pending_inputs {
      None -> "pending input unknown"
      Some(inputs) -> {
        let count = list.count(inputs, fn(input) { input.strand == strand.id })
        case count {
          0 -> "no pending input"
          _ -> int.to_string(count) <> " received, awaiting delivery"
        }
      }
    }
    Ok(Row(strand.id, current, retained, progress, pending))
  })
}

fn task_excerpt(
  cells: List(snapshot_view.Cell),
  entries: List(entry.Entry),
  current: String,
) -> String {
  let prompt = {
    use cell <- result.try(
      list.find(cells, fn(cell) {
        cell.namespace == register.OpMeta && cell.key == current
      }),
    )
    use meta <- result.try(
      codec.decode_operation(cell.value) |> result.replace_error(Nil),
    )
    case meta.intent {
      operation.RunIntent(prompts) -> Ok(prompts)
      operation.CompactionIntent(..) | operation.NavigationIntent(..) ->
        Error(Nil)
    }
  }
  case prompt {
    Error(Nil) -> ""
    Ok(prompts) ->
      entries
      |> list.filter_map(fn(value) {
        case value {
          entry.MessageEntry(
            id:,
            message: message.UserMessage(content:, ..),
            ..,
          ) ->
            case list.contains(prompts, id) {
              True -> Ok(content)
              False -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> list.flatten
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(brief_body(text))
          _ -> Error(Nil)
        }
      })
      |> string.join(" ")
      |> text_hygiene.single_line
      |> string.slice(0, 160)
  }
}

fn brief_body(text) {
  case
    string.starts_with(text, "[task brief from "),
    string.split_once(text, "\n")
  {
    True, Ok(#(_, body)) ->
      case string.split_once(body, "\n[end brief.") {
        Ok(#(brief, _)) -> brief
        Error(Nil) -> body
      }
    _, _ -> text
  }
}

/// Produces two clipped rows per reviewer, with an explicit overflow count.
///
/// ## Examples
///
/// ```gleam
/// assert reviewer_status.lines([], "main") == []
/// ```
@internal
pub fn lines(rows: List(Row), active: String) -> List(String) {
  let others = list.filter(rows, fn(row) { row.strand != active })
  let visible = list.take(others, 3)
  let lines =
    list.flat_map(visible, fn(row) {
      [
        "Reviewer "
          <> text_hygiene.single_line(row.strand)
          <> " · "
          <> row.progress
          <> " · "
          <> row.pending,
        "  Task: " <> row.task,
      ]
    })
  case list.length(others) - list.length(visible) {
    0 -> lines
    count ->
      list.append(lines, [
        "+" <> int.to_string(count) <> " more running · /agents to inspect",
      ])
  }
}
