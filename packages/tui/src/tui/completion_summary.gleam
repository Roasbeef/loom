//// Completion evidence belongs to an operation's captured ancestry interval.
////
//// Terminal commits delete OpMeta, so each observed start boundary survives
//// until its result can be read. Results are processed before successor
//// metadata in the same cut. An attachment which missed acceptance cannot
//// distinguish old history from this run and reports unavailable evidence.
//// This projection retains at most 32 strands, two boundaries per strand,
//// and 32 tool outcomes and edited paths per summary. It performs no I/O.

import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import tui/snapshot_view
import tui/tool_activity

/// How much of the operation's ancestry was available in this attachment.
pub type Coverage {
  /// The walk reached the captured source, including a known root source.
  Complete

  /// The source is known, but some ancestors are outside the loaded window.
  Partial

  /// Acceptance was not observed, so no history is attributed to the run.
  Unavailable
}

/// The captured result of one identity-matched tool invocation.
pub type ToolStatus {
  /// The tool reported success; this is not a claim about command semantics.
  Succeeded

  /// The tool reported an in-band failure.
  Failed
}

/// A bounded display record, with no inferred test classification.
pub type ToolOutcome {
  ToolOutcome(
    /// Provider call identity, paired with its actual result.
    id: String,
    /// Registered tool name.
    name: String,
    /// Actual success or failure from the result envelope.
    status: ToolStatus,
    /// A bash command excerpt, when present in the paired invocation.
    command: Option(String),
    /// The actual bash exit code, when captured in result details.
    exit_code: Option(Int),
    /// Added and removed lines from a successful captured fs_edit patch.
    edit_delta: Option(#(Int, Int)),
  )
}

/// The latest run result and the bounded evidence this client can attribute.
pub type Summary {
  Summary(
    /// Durable operation identity.
    operation: String,
    /// The machine's exact terminal outcome, including its failure reason.
    outcome: operation.RunOutcome,
    /// Completeness of the ancestry walk, independently of result status.
    coverage: Coverage,
    /// At most 32 distinct paths confirmed by successful file mutations.
    edits: List(String),
    /// At most 32 most recent paired tool results in execution order.
    tools: List(ToolOutcome),
    /// Distinct captured paths before presentation truncation.
    edit_count: Int,
    /// Recorded patch totals before presentation truncation.
    edit_delta: Option(#(Int, Int)),
    /// A bounded excerpt of the designated final assistant entry, if loaded.
    final_assistant: Option(String),
  )
}

type Boundary {
  Boundary(operation: String, source: Option(ids.EntryId))
}

type Strand {
  Strand(name: String, boundaries: List(Boundary), summary: Option(Summary))
}

/// Attachment-local provenance, bounded to the 32 most recently observed strands.
pub opaque type State {
  State(strands: List(Strand))
}

/// Starts an attachment with no claimed operation provenance.
///
/// ## Examples
///
/// ```gleam
/// assert completion_summary.latest(completion_summary.new(), "main") == None
/// ```
pub fn new() -> State {
  State([])
}

/// Observes a coherent cut and its loaded entries, in any entry order.
///
/// Keep this state across cuts of the same attachment and reset it when
/// switching sessions. Empty source leaves are known roots, not missing data.
///
/// ## Examples
///
/// ```gleam
/// assert completion_summary.observe(completion_summary.new(), [], [])
///   == completion_summary.new()
/// ```
pub fn observe(
  state: State,
  cells: List(snapshot_view.Cell),
  entries: List(entry.Entry),
) -> State {
  let indexed =
    dict.from_list(list.map(entries, fn(value) { #(value.id, value) }))
  let completed =
    list.fold(cells, state, fn(state, cell) {
      case cell.namespace {
        register.StrandLastResult -> observe_result(state, cell, indexed)
        _ -> state
      }
    })

  // A successor may already own OpMeta by the time its predecessor's
  // terminal result is visible. Preserve predecessor custody first.
  list.fold(cells, completed, fn(state, cell) {
    case cell.namespace {
      register.OpMeta -> observe_boundary(state, cell)
      _ -> state
    }
  })
}

/// Retrieves the most recent captured run result for one strand.
///
/// ## Examples
///
/// ```gleam
/// assert completion_summary.latest(completion_summary.new(), "absent") == None
/// ```
pub fn latest(state: State, strand: String) -> Option(Summary) {
  row(state, strand).summary
}

fn row(state: State, name: String) -> Strand {
  state.strands
  |> list.find(fn(value) { value.name == name })
  |> result.unwrap(Strand(name, [], None))
}

fn put(state: State, strand: Strand) -> State {
  State(
    [
      strand,
      ..list.filter(state.strands, fn(value) { value.name != strand.name })
    ]
    |> list.take(32),
  )
}

fn observe_boundary(state: State, cell: snapshot_view.Cell) -> State {
  case codec.decode_operation(cell.value) {
    Error(_) -> state
    Ok(meta) -> {
      let id = ids.op_id_to_string(meta.id)
      let strand = row(state, meta.strand)
      let boundaries =
        [
          Boundary(id, meta.source_leaf),
          ..list.filter(strand.boundaries, fn(boundary) {
            boundary.operation != id
          })
        ]
        |> list.take(2)
      case cell.key == id {
        True -> put(state, Strand(..strand, boundaries:))
        False -> state
      }
    }
  }
}

fn observe_result(
  state: State,
  cell: snapshot_view.Cell,
  entries: Dict(ids.EntryId, entry.Entry),
) {
  case codec.decode_last_result(cell.value) {
    Ok(operation.RunLastResult(operation: op, leaf:, outcome:, final_assistant:)) -> {
      let strand = row(state, cell.key)
      let id = ids.op_id_to_string(op)

      // A complete result is immutable evidence. Successor history eviction
      // must not erase edits or downgrade a completion we already captured.
      use <- bool.guard(complete_for(strand.summary, id), state)
      let boundary =
        list.find(strand.boundaries, fn(value) { value.operation == id })
      let #(coverage, history) = case boundary {
        Error(Nil) -> #(Unavailable, [])
        Ok(boundary) -> walk(entries, leaf, boundary.source, [], 2048)
      }
      let #(edits, tools, edit_count, edit_delta) = evidence(history)
      let summary =
        Summary(
          id,
          outcome,
          coverage,
          edits,
          tools,
          edit_count,
          edit_delta,
          assistant_text(dict.values(entries), final_assistant),
        )
      put(state, Strand(..strand, summary: Some(summary)))
    }
    Ok(operation.CompactionLastResult(..))
    | Ok(operation.NavigationLastResult(..))
    | Error(_) -> state
  }
}

fn complete_for(summary: Option(Summary), operation: String) -> Bool {
  case summary {
    Some(Summary(operation: id, coverage: Complete, ..)) -> id == operation
    Some(Summary(..)) | None -> False
  }
}

// The source is exclusive. Deleting visited entries also makes a corrupt
// cycle terminate as a partial window without inventing a second traversal.
fn walk(
  entries: Dict(ids.EntryId, entry.Entry),
  leaf: Option(ids.EntryId),
  source: Option(ids.EntryId),
  collected: List(entry.Entry),
  remaining: Int,
) {
  use <- bool.guard(leaf == source, #(Complete, collected))
  case leaf, remaining {
    None, _ -> #(Partial, collected)
    Some(_), 0 -> #(Partial, collected)
    Some(id), _ -> {
      case dict.get(entries, id) {
        Error(Nil) -> #(Partial, collected)
        Ok(value) ->
          walk(
            dict.delete(entries, id),
            value.parent,
            source,
            [value, ..collected],
            remaining - 1,
          )
      }
    }
  }
}

// Unlike the compact transcript, evidence includes calls alongside prose.
// A fresh assistant batch owns its call ids; a result cannot match an old
// invocation merely because the provider reused its id in a later response.
fn evidence(history) {
  let #(_, edits, tools, delta) =
    list.fold(history, #(dict.new(), [], [], None), collect)
  #(
    list.reverse(list.take(edits, 32)),
    list.reverse(tools),
    list.length(edits),
    delta,
  )
}

fn collect(
  acc: #(
    Dict(String, #(ids.EntryId, message.ToolCall)),
    List(String),
    List(ToolOutcome),
    Option(#(Int, Int)),
  ),
  value: entry.Entry,
) {
  let #(pending, edits, tools, delta) = acc
  case value {
    entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) -> {
      let calls =
        list.filter_map(content, fn(block) {
          case block {
            message.AssistantToolCall(call) -> Ok(#(call.id, #(value.id, call)))
            message.AssistantText(..) | message.AssistantThinking(..) ->
              Error(Nil)
          }
        })
      #(dict.from_list(calls), edits, tools, delta)
    }
    entry.MessageEntry(
      message: message.ToolResultMessage(tool_call_id:, tool_name:, ..) as outcome,
      ..,
    ) -> {
      let paired = dict.get(pending, tool_call_id)
      let pending = dict.delete(pending, tool_call_id)
      case paired {
        Ok(#(source, call)) if call.name == tool_name -> {
          let paired =
            tool_activity.Call(source, call, Some(outcome), Some(value.id))
          let #(path, tool) = extract(paired)
          #(
            pending,
            add_path(edits, path),
            list.take([tool, ..tools], 32),
            add_delta(delta, tool.edit_delta),
          )
        }
        Ok(_) | Error(Nil) -> #(pending, edits, tools, delta)
      }
    }
    _ -> acc
  }
}

fn extract(call: tool_activity.Call) {
  let invocation = call.invocation
  let #(status, details) = case call.outcome {
    Some(message.ToolResultMessage(is_error: False, details:, ..)) -> #(
      Succeeded,
      details,
    )
    Some(message.ToolResultMessage(is_error: True, details:, ..)) -> #(
      Failed,
      details,
    )
    _ -> #(Failed, None)
  }
  let path = case invocation.name, status {
    "fs_edit", Succeeded | "fs_write", Succeeded -> text_field(details, "path")
    _, _ -> None
  }
  let #(command, exit_code) = case invocation.name {
    "bash" -> #(
      text_field(Some(invocation.arguments), "command"),
      int_field(details, "exit_code"),
    )
    _ -> #(None, None)
  }
  #(
    path,
    ToolOutcome(
      invocation.id,
      invocation.name,
      status,
      command,
      exit_code,
      captured_delta(invocation.name, status, details),
    ),
  )
}

// fs_edit emits headerless unified hunks. The counts describe recorded edit
// operations, which may touch the same line twice; they are not a Git net diff.
fn captured_delta(name, status, details) {
  case name, status, full_text_field(details, "diff") {
    "fs_edit", Succeeded, Some(patch) -> {
      let rows = string.split(patch, "\n")
      Some(#(
        list.count(rows, string.starts_with(_, "+")),
        list.count(rows, string.starts_with(_, "-")),
      ))
    }
    _, _, _ -> None
  }
}

/// Summarizes captured mutations belonging to this operation alone.
///
/// A shell command can change files without producing an fs_edit patch. These
/// counts therefore name their evidence and never claim to equal the workspace.
///
/// ## Examples
///
/// ```gleam
/// // completion_summary.edit_totals(summary)
/// ```
@internal
pub fn edit_totals(summary: Summary) -> String {
  use <- bool.guard(
    summary.coverage == Unavailable,
    "Turn file-tool edits unavailable",
  )
  case summary.coverage {
    Partial -> "Partial turn file-tool edits: "
    Complete | Unavailable -> "Turn file-tool edits: "
  }
  <> int.to_string(summary.edit_count)
  <> " paths"
  <> case summary.edit_delta {
    None -> " · line counts unavailable"
    Some(#(added, removed)) ->
      " · recorded +" <> int.to_string(added) <> "/−" <> int.to_string(removed)
  }
}

fn add_path(paths, path) {
  case path {
    None -> paths
    Some(path) -> {
      case list.contains(paths, path) {
        True -> paths
        False -> [path, ..paths]
      }
    }
  }
}

// Aggregate the bounded ancestry before discarding its display excerpts.
fn add_delta(total, next) {
  case total, next {
    _, None -> total
    None, Some(_) -> next
    Some(#(added, removed)), Some(#(more_added, more_removed)) ->
      Some(#(added + more_added, removed + more_removed))
  }
}

fn full_text_field(value, key) {
  case field(value, key) {
    Ok(json.String(text)) -> Some(text)
    _ -> None
  }
}

fn field(value, key) {
  case value {
    Some(json.Object(fields)) -> list.key_find(fields, key)
    _ -> Error(Nil)
  }
}

fn text_field(value, key) {
  case field(value, key) {
    Ok(json.String(text)) -> Some(string.slice(text, 0, 512))
    _ -> None
  }
}

fn int_field(value, key) {
  case field(value, key) {
    Ok(json.Int(value)) -> Some(value)
    _ -> None
  }
}

fn assistant_text(history: List(entry.Entry), final: Option(ids.EntryId)) {
  use id <- option.then(final)
  use value <- option.then(
    list.find(history, fn(value) { value.id == id }) |> option.from_result,
  )
  case value {
    entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) -> {
      let text =
        list.filter_map(content, fn(block) {
          case block {
            message.AssistantText(text:, ..) -> Ok(text)
            _ -> Error(Nil)
          }
        })
        |> string.join("\n")
      Some(case string.length(text) > 8192 {
        True -> string.slice(text, 0, 8192) <> "\n\n[Continues in transcript]"
        False -> text
      })
    }
    _ -> None
  }
}

/// Names the actual terminal state for an automatic completion card.
///
/// ## Examples
///
/// ```gleam
/// // completion_summary.brief(summary)
/// ```
pub fn brief(summary: Summary) -> String {
  case summary.outcome {
    operation.RunCompleted(operation.CompletedByAssistant) ->
      "Completed by assistant"
    operation.RunCompleted(operation.CompletedByTerminatedTools) ->
      "Completed by terminating tools"
    operation.RunFailed(error) ->
      "Failed: " <> string.slice(error.message, 0, 512)
    operation.RunAborted -> "Aborted"
  }
}

/// Formats bounded evidence; callers append current queue and live-job state.
///
/// ## Examples
///
/// ```gleam
/// // completion_summary.lines(summary)
/// ```
pub fn lines(summary: Summary) -> List(String) {
  let coverage = case summary.coverage {
    Complete ->
      "Captured operation history complete; up to 32 edits and tool outcomes shown."
    Partial ->
      "Partial captured history; earlier operation evidence is unavailable."
    Unavailable ->
      "Operation start was not observed; edit and tool evidence unavailable."
  }
  list.flatten([
    [brief(summary)],
    case summary.final_assistant {
      Some(text) -> ["", text, ""]
      None -> ["Final assistant result is not loaded."]
    },
    ["Operation: " <> summary.operation, coverage, edit_totals(summary)],
    list.map(summary.edits, fn(path) { "Changed: " <> path }),
    [
      "",
      "Captured tool outcomes (exit status does not establish test coverage):",
    ],
    list.map(summary.tools, tool_line),
  ])
}

fn tool_line(tool: ToolOutcome) {
  let status = case tool.status {
    Succeeded -> "succeeded"
    Failed -> "failed"
  }
  let exit = case tool.exit_code {
    Some(code) -> "; exit " <> int.to_string(code)
    None -> ""
  }
  let command = case tool.command {
    Some(command) -> ": " <> command
    None -> ""
  }
  tool.name <> " " <> status <> exit <> command
}
