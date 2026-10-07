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
import session_view/snapshot
import session_view/snapshot_view
import session_view/strand_name
import session_view/text_hygiene
import session_view/tool_activity

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
          0 -> no_pending_input
          _ -> int.to_string(count) <> " received, awaiting delivery"
        }
      }
    }
    Ok(Row(strand.id, current, retained, progress, pending))
  })
}

/// Reads the accepted task from operation metadata and available prompt entries.
///
/// The agent workspace also calls this for a terminal operation, which is no
/// longer in the live reviewer roster. An absent prompt returns no excerpt.
///
/// ## Examples
///
/// ```gleam
/// assert reviewer_status.task_excerpt([], [], "missing") == ""
/// ```
@internal
pub fn task_excerpt(
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

/// What a row's `pending` says when no input waits for the reviewer. The row
/// holds the words, so the filter below compares against this one constant
/// and not a second copy of the phrase.
pub const no_pending_input = "no pending input"

/// Drops the rows a page need not draw: the advisor with nothing waiting for
/// it. The panel's advisor card already says so, and a band line for it
/// would only repeat that card in a second place.
///
/// ## Examples
///
/// ```gleam
/// assert reviewer_status.without_idle_advisor([]) == []
/// ```
pub fn without_idle_advisor(rows: List(Row)) -> List(Row) {
  list.filter(rows, fn(row) {
    !{ row.strand == "advisor" && row.pending == no_pending_input }
  })
}

/// Produces two clipped rows per reviewer, with an explicit overflow count.
///
/// The second row names what the reviewer is for, never the prompt that
/// started it. The advisor is started by a feed the harness composes, which
/// is not a task a reader wrote, so its row says `watching` the strand it
/// follows. Any other reviewer's row is the first sentence of the brief it
/// was given, cut at a bound, because the whole brief is a page of
/// instructions.
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
        who(row.strand) <> " · " <> row.progress <> " · " <> row.pending,
        "  Task: " <> described(row, active),
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

// Who the row is about: its kind, then the name its parent chose. A
// sub-agent is a `Sub-agent` under the slug of its minted identity, without
// the parent or the suffix; the advisor keeps `Reviewer`, which is what it
// does; any other strand is a `Strand` under its own name.
fn who(strand: String) -> String {
  let name = text_hygiene.single_line(strand_name.short(strand))
  case strand, name {
    "advisor", _ -> "Reviewer advisor"
    "sub:" <> _, "sub:" <> bare -> "Sub-agent " <> bare
    "sub:" <> _, _ -> "Sub-agent " <> name
    _, _ -> "Strand " <> name
  }
}

// What a reviewer's task line says. The advisor's captured prompt is the
// harness's own feed, so it is replaced by the strand the advisor follows;
// any other reviewer's is cut to its first sentence.
fn described(row: Row, active: String) -> String {
  case row.strand {
    "advisor" -> "watching " <> active
    _ -> first_sentence(row.task)
  }
}

// The text up to the first sentence end, at most 100 characters, with an
// ellipsis when anything was cut at the bound. A brief with no sentence end
// is cut at the bound alone.
fn first_sentence(text: String) -> String {
  let cut =
    list.fold([". ", "! ", "? "], text, fn(kept, end) {
      case string.split_once(kept, end) {
        Ok(#(head, _)) -> head <> string.trim(end)
        Error(Nil) -> kept
      }
    })

  case string.length(cut) > 100 {
    True -> string.slice(cut, 0, 99) <> "…"
    False -> cut
  }
}
