//// Recorded child cancellation causes, joined to exact operation results.
////
//// A provider cancellation diagnostic describes acknowledgement, not why the
//// harness stopped the work. The reserved child-run fact owns that reason.
//// Joining it through an operation's terminal result keeps resumed runs and
//// historical aborts separate. This projection uses only a captured cut.

import core/ids
import core/json
import core/register
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import session_view/snapshot_view.{type Cell}

/// Returns recorded causes keyed by the exact aborted assistant entry.
/// Missing or malformed lifecycle metadata contributes no inferred reason.
///
/// ## Examples
///
/// ```gleam
/// assert child_stop.entry_reasons([], "main") == dict.new()
/// ```
@internal
pub fn entry_reasons(
  cells: List(Cell),
  strand: String,
) -> Dict(String, String) {
  cells
  |> list.filter_map(fn(cell) {
    use _ <- result.try(case cell.namespace {
      register.StrandLastResult -> Ok(Nil)
      register.FactCustom ->
        case string.starts_with(cell.key, "operation-result/") {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    })
    use decoded <- result.try(
      codec.decode_last_result(cell.value) |> result.replace_error(Nil),
    )
    case decoded {
      operation.RunLastResult(
        operation: id,
        outcome: operation.RunAborted,
        final_assistant: Some(entry),
        ..,
      ) -> {
        use reason <- result.try(
          operation_reason(cells, ids.op_id_to_string(id), strand)
          |> option.to_result(Nil),
        )
        Ok(#(ids.entry_id_to_string(entry), reason))
      }
      _ -> Error(Nil)
    }
  })
  |> dict.from_list
}

/// Returns the harness's cause for this exact operation and strand.
///
/// ## Examples
///
/// ```gleam
/// assert child_stop.operation_reason([], "operation", "main") == None
/// ```
@internal
pub fn operation_reason(
  cells: List(Cell),
  operation: String,
  strand: String,
) -> Option(String) {
  cells
  |> list.find_map(fn(cell) {
    use _ <- result.try(
      case
        cell.namespace == register.FactCustom
        && cell.key == "child-run/" <> operation
      {
        True -> Ok(Nil)
        False -> Error(Nil)
      },
    )
    use fields <- result.try(case cell.value {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use recorded <- result.try(list.key_find(fields, "strand"))
    use _ <- result.try(case recorded == json.String(strand) {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    use stop <- result.try(list.key_find(fields, "stop"))
    case stop {
      json.String("parent_finished") ->
        Ok("Stopped because the parent run ended.")
      json.String("released") ->
        Ok("Stopped because the parent session was deleted.")
      json.String("token_budget_spent") ->
        Ok("Stopped because the child's token budget was spent.")
      json.String("budget_expired") ->
        Ok("Stopped because the child run's wall-clock budget expired.")
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}
