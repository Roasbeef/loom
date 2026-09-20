//// Agent summaries are a projection of one coherent capture.
////
//// Operation identity owns the task and latest update. A successor cannot
//// inherit its predecessor's answer, and an idle phase cannot prove success.
//// The existing reviewer projection supplies accepted tasks and running tools;
//// total machine decoders supply waits, cancellation, and terminal outcomes.
//// Only bounded excerpts survive history eviction. No read or mutation starts
//// here, including when a pending approval becomes visible.

import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import tui/approval
import tui/protocol
import tui/reviewer_status
import tui/snapshot
import tui/snapshot_view
import tui/text_hygiene

/// Presentation vocabulary, never a second operation state machine.
@internal
pub type Status {
  /// Captured work is in progress.
  Working

  /// The machine recorded a provider retry or deferred-response wait.
  Waiting

  /// An exact pending approval belongs to this current operation.
  NeedsInput

  /// The latest operation has a successful terminal result.
  Finished

  /// The latest operation has a failed terminal result.
  Failed

  /// An idle strand retains input, or its last operation was aborted.
  Halted

  /// A coherent capture has neither current work nor a terminal result.
  Idle

  /// Current authority is missing or the retained view is disconnected.
  Unavailable
}

/// One strand's bounded presentation, shared by the rail and inspector.
@internal
pub type Row {
  Row(
    /// Stable identity; display names never route messages.
    id: String,
    /// Sanitized display name.
    name: String,
    /// The operation which owns the task and update, when known.
    operation: Option(String),
    /// State justified by the current capture.
    status: Status,
    /// Accepted task excerpt or an explicit unavailable explanation.
    task: String,
    /// Current action or the recorded outcome's explanation.
    activity: String,
    /// Latest designated assistant text, bounded to 320 characters.
    update: String,
    /// Exact assistant entry owning the retained update excerpt.
    update_entry: Option(ids.EntryId),
    /// Receipt evidence, which does not claim delivery or incorporation.
    pending: String,
    /// Exact pending decision identities, in captured order.
    approvals: List(String),
    /// Effective model from this same capture, when available.
    model: String,
  )
}

/// Builds truthful fallback rows for demos and older recordings.
///
/// ## Examples
///
/// ```gleam
/// assert agent_view.legacy([]) == []
/// ```
@internal
pub fn legacy(strands: List(protocol.Strand)) -> List(Row) {
  list.map(strands, fn(strand) {
    Row(
      strand.id,
      text_hygiene.single_line(option.unwrap(strand.name, strand.id)),
      None,
      case strand.live_phase {
        Some(_) -> Working
        None -> Unavailable
      },
      "Task unavailable",
      text_hygiene.single_line(option.unwrap(
        strand.live_phase,
        "State unavailable",
      )),
      "Latest update unavailable",
      None,
      "Pending input unknown",
      [],
      "Model unavailable",
    )
  })
}

/// Retains roster order and operation-owned excerpts across coherent captures.
///
/// Existing identities retain their position; newly captured identities append.
/// Disappearing identities leave the roster, but the inspector keeps its own
/// selected identity until the operator navigates again.
///
/// ## Examples
///
/// ```gleam
/// // agent_view.observe(previous, window, view, reviewers)
/// ```
@internal
pub fn observe(
  previous: List(Row),
  window: snapshot.Window,
  view: snapshot_view.View,
  reviewers: List(reviewer_status.Row),
) -> List(Row) {
  let entries =
    list.filter_map(window.items, fn(item) {
      case item {
        snapshot.Loaded(value, _) -> Ok(#(value.id, value))
        snapshot.Unloaded(..) -> Error(Nil)
      }
    })
    |> dict.from_list
  let old_ids = list.map(previous, fn(row) { row.id })
  let retained =
    list.filter_map(previous, fn(row) {
      list.find(view.strands, fn(strand) { strand.id == row.id })
    })
  let added =
    list.filter(view.strands, fn(strand) { !list.contains(old_ids, strand.id) })

  let reviews = approval.records(view.cells) |> result.unwrap([])
  list.map(list.append(retained, added), fn(strand) {
    let #(current, status, activity, latest) = evidence(view, strand.id)
    let earlier =
      list.find(previous, fn(row) {
        row.id == strand.id && row.operation == current && current != None
      })
    let reviewer =
      list.find(reviewers, fn(row) {
        row.strand == strand.id && Some(row.operation) == current
      })
    let task = case reviewer {
      Ok(row) -> row.task
      Error(Nil) -> {
        let captured = case current {
          None -> ""
          Some(id) ->
            reviewer_status.task_excerpt(view.cells, dict.values(entries), id)
        }
        case captured {
          "" ->
            earlier
            |> result.map(fn(row) { row.task })
            |> result.unwrap("Task brief outside loaded history")
          text -> text
        }
      }
    }
    let update =
      latest
      |> option.to_result(Nil)
      |> result.try(fn(id) { dict.get(entries, id) })
      |> result.try(assistant_text)
      |> result.lazy_unwrap(fn() {
        case latest {
          None -> "Latest update unavailable"
          Some(_) ->
            earlier
            |> result.try(fn(row) {
              case row.update_entry == latest {
                True -> Ok(row.update)
                False -> Error(Nil)
              }
            })
            |> result.unwrap("Latest update unavailable")
        }
      })

    // The journal can retain an unanswered escalation after its operation
    // aborts or times out. Only a live operation can still need that answer.
    let approvals = case status {
      Working | Waiting ->
        pending_approvals(view.cells, reviews, strand.id, current)
      NeedsInput | Finished | Failed | Halted | Idle | Unavailable -> []
    }
    let status = case approvals {
      [] -> status
      [_, ..] -> NeedsInput
    }
    let activity = case status, activity {
      Working, "Working" ->
        reviewer
        |> result.map(fn(row) { row.progress })
        |> result.unwrap(activity)
      NeedsInput, _ -> "Approval required"
      _, _ -> activity
    }

    Row(
      strand.id,
      text_hygiene.single_line(option.unwrap(strand.name, strand.id)),
      current,
      status,
      text_hygiene.single_line(task),
      text_hygiene.single_line(activity),
      update,
      latest,
      pending_text(view.pending_inputs, strand.id),
      approvals,
      dict.get(view.configurations, strand.id)
        |> result.map(fn(config) { config.configuration.model.model_id })
        |> result.unwrap("Model unavailable")
        |> text_hygiene.single_line,
    )
  })
}

fn evidence(
  view: snapshot_view.View,
  strand: String,
) -> #(Option(String), Status, String, Option(ids.EntryId)) {
  case dict.get(view.operations, strand) {
    Ok(current) -> {
      let state =
        cell(view.cells, register.OpState, current)
        |> result.try(fn(value) {
          codec.decode_state(value) |> result.replace_error(Nil)
        })
      case state {
        Ok(state) -> {
          let #(status, activity, latest) = live_state(state)
          #(Some(current), status, activity, latest)
        }
        Error(Nil) -> #(
          Some(current),
          Unavailable,
          "Operation state unavailable",
          None,
        )
      }
    }
    Error(Nil) -> idle_state(view, strand)
  }
}

fn live_state(
  state: operation.OperationState,
) -> #(Status, String, Option(ids.EntryId)) {
  case state {
    operation.RunState(
      control: operation.CancelRequested(..),
      latest_assistant:,
      ..,
    ) -> #(Working, "Stopping", latest_assistant)
    operation.RunState(
      phase: operation.Assistant(operation.GenerationRetryWait(..)),
      latest_assistant:,
      ..,
    ) -> #(Waiting, "Waiting for provider retry", latest_assistant)
    operation.RunState(
      phase: operation.AwaitingDeferred(_),
      latest_assistant:,
      ..,
    ) -> #(Waiting, "Waiting for deferred response", latest_assistant)
    operation.RunState(latest_assistant:, ..) -> #(
      Working,
      "Working",
      latest_assistant,
    )
    operation.CompactionState(..) -> #(Working, "Compacting", None)
    operation.NavigationState(..) -> #(Working, "Navigating", None)
  }
}

fn idle_state(
  view: snapshot_view.View,
  strand: String,
) -> #(Option(String), Status, String, Option(ids.EntryId)) {
  let latest =
    cell(view.cells, register.StrandLastResult, strand)
    |> result.try(fn(value) {
      codec.decode_last_result(value) |> result.replace_error(Nil)
    })
  let result = case latest {
    Error(Nil) ->
      case cell(view.cells, register.StrandLastResult, strand) {
        Ok(_) -> #(None, Unavailable, "Terminal result unavailable", None)
        Error(Nil) -> #(None, Idle, "No current operation", None)
      }
    Ok(operation.RunLastResult(operation: id, outcome:, final_assistant:, ..)) -> {
      let #(status, reason) = run_outcome(outcome)
      #(Some(ids.op_id_to_string(id)), status, reason, final_assistant)
    }
    Ok(operation.CompactionLastResult(operation: id, outcome:, ..))
    | Ok(operation.NavigationLastResult(operation: id, outcome:, ..)) -> {
      let #(status, reason) = structural_outcome(outcome)
      #(Some(ids.op_id_to_string(id)), status, reason, None)
    }
  }

  // The gateway drains ordinary held input at the idle edge before exposing
  // its cut. Remaining rows wait for an explicit submission (protocol 033).
  case has_held_input(view.pending_inputs, strand) {
    True -> #(result.0, Halted, "Input held until your next message", result.3)
    False -> result
  }
}

fn run_outcome(outcome: operation.RunOutcome) -> #(Status, String) {
  case outcome {
    operation.RunCompleted(_) -> #(Finished, "Finished")
    operation.RunFailed(error) -> #(Failed, error.message)
    operation.RunAborted -> #(Halted, "Operation aborted")
  }
}

fn structural_outcome(
  outcome: operation.StructuralOutcome,
) -> #(Status, String) {
  case outcome {
    operation.StructuralCompleted -> #(Finished, "Finished")
    operation.StructuralDeclined -> #(Idle, "Operation declined")
    operation.StructuralFailed(error) -> #(Failed, error.message)
    operation.StructuralAborted -> #(Halted, "Operation aborted")
  }
}

fn cell(
  cells: List(snapshot_view.Cell),
  namespace: register.RegisterNs,
  key: String,
) -> Result(json.JsonValue, Nil) {
  cells
  |> list.find(fn(cell) { cell.namespace == namespace && cell.key == key })
  |> result.map(fn(cell) { cell.value })
}

fn assistant_text(value: entry.Entry) -> Result(String, Nil) {
  case value {
    entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) -> {
      let text =
        content
        |> list.filter_map(fn(block) {
          case block {
            message.AssistantText(text, _) -> Ok(text)
            _ -> Error(Nil)
          }
        })
        |> string.join("\n")
        |> text_hygiene.single_line
        |> string.slice(0, 320)
      case text {
        "" -> Error(Nil)
        _ -> Ok(text)
      }
    }
    _ -> Error(Nil)
  }
}

fn pending_approvals(
  cells: List(snapshot_view.Cell),
  records: List(approval.Review),
  strand: String,
  current: Option(String),
) -> List(String) {
  list.filter_map(records, fn(review) {
    use _ <- result.try(case review.status == approval.Pending {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    use fields <- result.try(
      cell(cells, register.FactCustom, "escalation/" <> review.id)
      |> result.try(object),
    )
    use scope <- result.try(list.key_find(fields, "scope"))
    use scope <- result.try(object(scope))
    case list.key_find(scope, "strand"), list.key_find(scope, "operation") {
      Ok(json.String(owner)), Ok(json.String(operation))
        if owner == strand && Some(operation) == current
      -> Ok(review.id)
      _, _ -> Error(Nil)
    }
  })
}

fn object(
  value: json.JsonValue,
) -> Result(List(#(String, json.JsonValue)), Nil) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(Nil)
  }
}

fn has_held_input(
  inputs: Option(List(snapshot_view.PendingInput)),
  strand: String,
) -> Bool {
  case inputs {
    None -> False
    Some(inputs) -> list.any(inputs, fn(input) { input.strand == strand })
  }
}

fn pending_text(
  inputs: Option(List(snapshot_view.PendingInput)),
  strand: String,
) -> String {
  case inputs {
    None -> "Pending input unknown"
    Some(inputs) -> {
      let count = list.count(inputs, fn(input) { input.strand == strand })
      case count {
        0 -> "No pending input"
        _ -> int.to_string(count) <> " received, awaiting delivery"
      }
    }
  }
}

/// Whether this row has concrete attention evidence.
///
/// ## Examples
///
/// ```gleam
/// assert agent_view.needs_attention(agent_view.Failed)
/// ```
@internal
pub fn needs_attention(status: Status) -> Bool {
  case status {
    NeedsInput | Failed | Halted -> True
    Working | Waiting | Finished | Idle | Unavailable -> False
  }
}

/// The label carries the meaning even without terminal color.
///
/// ## Examples
///
/// ```gleam
/// assert agent_view.label(agent_view.NeedsInput) == "Needs input"
/// ```
@internal
pub fn label(status: Status) -> String {
  case status {
    Working -> "Working"
    Waiting -> "Waiting"
    NeedsInput -> "Needs input"
    Finished -> "Finished"
    Failed -> "Failed"
    Halted -> "Halted"
    Idle -> "Idle"
    Unavailable -> "Unavailable"
  }
}
