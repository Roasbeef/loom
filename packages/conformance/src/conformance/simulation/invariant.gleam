//// The named checks a simulated session is held to.
////
//// Every check has a name, and a failure reports it, because "the
//// simulation failed" is not a bug report. The checks split in two: the
//// *boundary* checks run inside the commit path at every commit, so a
//// violation is caught at the transaction that caused it rather than at
//// the end of the run; the *terminal* checks run once the strand is
//// idle again.
////
//// Nothing here compares two runs — that is the runner's job. These are
//// the properties one run must have on its own.

import core/entry.{type Entry}
import core/ids.{type EntryId}
import core/message as core_message
import core/register
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation.{
  type Control, type OperationState, CancelRequested, CompactionState,
  NavigationState, RunState, Running,
}
import machine/strand.{type StrandState}
import storage/storage.{type Register, type Storage}

/// A violated check: which one, and what was seen.
pub type Violation {
  Violation(check: String, detail: String)
}

/// Renders a violation for a failure message.
///
/// ## Examples
///
/// ```gleam
/// // invariant.describe(Violation(check: "placement/queued-id", detail: ".."))
/// ```
///
pub fn describe(violation: Violation) -> String {
  violation.check <> ": " <> violation.detail
}

/// `placement/queued-id`, checked at every commit boundary: a queued
/// entry id has its pending register, or its entry, or neither — never
/// both. Holding both would mean a drained item could be placed twice.
///
/// ## Examples
///
/// ```gleam
/// // invariant.placement(store, "main")
/// ```
///
pub fn placement(
  store: Storage(handle),
  strand strand: String,
) -> Result(Nil, Violation) {
  use ids <- result.try(queued_ids(store, strand))
  list.try_fold(ids, Nil, fn(_acc, id) {
    let key = ids.entry_id_to_string(id)
    let registered = case
      storage.get_register(store, register.PendingEntry, key)
    {
      Ok(Some(_)) -> True
      _ -> False
    }
    let placed = case storage.get_entries(store, [id]) {
      Ok(entries) -> dict.has_key(entries, id)
      Error(_) -> False
    }
    case registered && placed {
      True ->
        Error(Violation(
          check: "placement/queued-id",
          detail: "queued id "
            <> key
            <> " has both a pending register and a placed entry",
        ))
      False -> Ok(Nil)
    }
  })
}

fn queued_ids(
  store: Storage(handle),
  strand: String,
) -> Result(List(EntryId), Violation) {
  case storage.get_register(store, register.StrandState, strand) {
    Ok(None) -> Ok([])
    Error(error) ->
      Error(Violation(
        check: "placement/queued-id",
        detail: "strand state unreadable: " <> describe_error(error),
      ))
    Ok(Some(cell)) -> queued_ids_from_strand_state(store, cell)
  }
}

fn queued_ids_from_strand_state(
  store: Storage(handle),
  cell: Register,
) -> Result(List(EntryId), Violation) {
  use state <- result.try(decoded_strand_state(cell, "placement/queued-id"))
  case state.current_operation {
    None -> Ok(state.pending_next_run)
    Some(op) -> queued_ids_with_open_op(store, state, op)
  }
}

// Decoded under the caller's own check name, so a corrupt strand state is
// reported as whichever boundary check was reading it.
fn decoded_strand_state(
  cell: Register,
  check: String,
) -> Result(StrandState, Violation) {
  case codec.decode_strand_state(cell.value.payload) {
    Ok(state) -> Ok(state)
    Error(report) ->
      Error(Violation(
        check:,
        detail: "strand state corrupt at " <> report.boundary,
      ))
  }
}

fn queued_ids_with_open_op(
  store: Storage(handle),
  state: StrandState,
  op: ids.OpId,
) -> Result(List(EntryId), Violation) {
  case storage.get_register(store, register.OpState, ids.op_id_to_string(op)) {
    Ok(Some(op_cell)) ->
      case codec.decode_state(op_cell.value.payload) {
        Ok(op_state) ->
          Ok(list.append(state.pending_next_run, inbox_ids(op_state)))
        Error(report) ->
          Error(Violation(
            check: "placement/queued-id",
            detail: "op state corrupt at " <> report.boundary,
          ))
      }

    // No op state yet (or already gone): the strand's own queue is all
    // there is to check.
    _ -> Ok(state.pending_next_run)
  }
}

fn inbox_ids(state: OperationState) -> List(EntryId) {
  case state {
    RunState(inbox:, control:, ..) ->
      list.flatten([
        inbox.steer,
        inbox.follow_up,
        inbox.writes,
        drained(control),
      ])
    CompactionState(control:, ..) | NavigationState(control:, ..) ->
      drained(control)
  }
}

fn drained(control: Control) -> List(EntryId) {
  case control {
    Running -> []
    CancelRequested(drained_steer:, drained_follow_up:, ..) ->
      list.append(drained_steer, drained_follow_up)
  }
}

/// `terminal/registers`: no operation-owned or pending register survives
/// a terminal transaction, and the strand is idle again.
///
/// ## Examples
///
/// ```gleam
/// // invariant.terminal_registers(store, "main")
/// ```
///
pub fn terminal_registers(
  store: Storage(handle),
  strand strand: String,
) -> Result(Nil, Violation) {
  let namespaces = [
    register.OpMeta,
    register.OpState,
    register.OpToolArgs,
    register.OpPreparation,
    register.PendingEntry,
  ]
  use _ <- result.try(
    list.try_fold(namespaces, Nil, fn(_acc, ns) {
      case storage.list_registers(store, ns, None) {
        Ok([]) -> Ok(Nil)
        Ok(cells) ->
          Error(Violation(
            check: "terminal/registers",
            detail: int_to_count(list.length(cells))
              <> " register(s) survived the terminal transaction in "
              <> ns_name(ns),
          ))
        Error(error) ->
          Error(Violation(
            check: "terminal/registers",
            detail: "register listing failed: " <> describe_error(error),
          ))
      }
    }),
  )
  case storage.get_register(store, register.StrandState, strand) {
    Ok(Some(cell)) -> check_strand_idle(cell)
    _ ->
      Error(Violation(
        check: "terminal/registers",
        detail: "the strand state is missing",
      ))
  }
}

fn check_strand_idle(cell: Register) -> Result(Nil, Violation) {
  use state <- result.try(decoded_strand_state(cell, "terminal/registers"))
  case state.current_operation {
    None -> Ok(Nil)
    Some(_) ->
      Error(Violation(
        check: "terminal/registers",
        detail: "the strand still names an open operation",
      ))
  }
}

/// `tree/calls-answered`: every tool call block in an *executable*
/// assistant response has exactly one tool-result entry.
///
/// Aborted and errored responses are excluded from the demand side: a
/// response that really settled while cancellation was durable commits
/// normalized to `aborted` *retaining its content* (pi §4.6 — including
/// any tool-call blocks), and an overflow commits normalized to `error`.
/// Neither ever plans a batch, both are dropped from every projection,
/// so their calls are never executable and never answered. Their call
/// ids still may not collide with an executed call's — the exactly-once
/// count below covers that, because a duplicated id would give the
/// executed call two result entries.
///
/// ## Examples
///
/// ```gleam
/// // invariant.calls_answered(store)
/// ```
///
pub fn calls_answered(store: Storage(handle)) -> Result(Nil, Violation) {
  case storage.scan_entries(store, storage.entry_scan()) {
    Error(error) ->
      Error(Violation(
        check: "tree/calls-answered",
        detail: "entry scan failed: " <> describe_error(error),
      ))
    Ok(entries) -> {
      let messages = list.filter_map(entries, message_of)
      let answered = answered_call_ids(messages)
      let called = executable_call_ids(messages)
      list.try_fold(called, Nil, fn(_acc, id) {
        case list.count(answered, fn(other) { other == id }) {
          1 -> Ok(Nil)
          count ->
            Error(Violation(
              check: "tree/calls-answered",
              detail: "tool call "
                <> id
                <> " has "
                <> int_to_count(count)
                <> " result entries",
            ))
        }
      })
    }
  }
}

fn answered_call_ids(
  messages: List(core_message.AgentMessage),
) -> List(String) {
  list.filter_map(messages, fn(message) {
    case message {
      core_message.ToolResultMessage(tool_call_id:, ..) -> Ok(tool_call_id)
      _ -> Error(Nil)
    }
  })
}

// Aborted and errored responses never plan a batch (doc comment above),
// so their tool-call blocks are excluded from the demand side; every
// other assistant response's calls are executable.
fn executable_call_ids(
  messages: List(core_message.AgentMessage),
) -> List(String) {
  list.flat_map(messages, fn(message) {
    case message {
      core_message.AssistantMessage(stop_reason:, content:, ..) ->
        case stop_reason {
          core_message.Aborted | core_message.Errored -> []
          _ -> list.filter_map(content, tool_call_id_of)
        }
      _ -> []
    }
  })
}

fn tool_call_id_of(block: core_message.AssistantBlock) -> Result(String, Nil) {
  case block {
    core_message.AssistantToolCall(call:) -> Ok(call.id)
    _ -> Error(Nil)
  }
}

fn message_of(row: Entry) -> Result(core_message.AgentMessage, Nil) {
  case row {
    entry.MessageEntry(message:, ..) -> Ok(message)
    _ -> Error(Nil)
  }
}

fn ns_name(ns: register.RegisterNs) -> String {
  case ns {
    register.OpMeta -> "op.meta"
    register.OpState -> "op.state"
    register.OpToolArgs -> "op.tool_args"
    register.OpPreparation -> "op.preparation"
    register.PendingEntry -> "pending.entry"
    _ -> "other"
  }
}

fn describe_error(error: storage.StorageError) -> String {
  case error {
    storage.CorruptRow(report:) -> "corrupt row at " <> report.boundary
    storage.UnknownEntry(id:) -> "unknown entry " <> ids.entry_id_to_string(id)
    storage.BackendFault(reason:) -> reason
    storage.HandleClosed -> "handle closed"
  }
}

fn int_to_count(n: Int) -> String {
  string.inspect(n)
}
