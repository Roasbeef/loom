//// Ownership and budget of one run on a reusable child strand.
////
//// Lineage identifies a conversation and its original spawn. A deadline or
//// cancellation belongs to one operation instead: continuing a child must
//// neither inherit a spent deadline nor hide the earlier operation's result.
//// These records are keyed by operation, committed with renewed admission,
//// and retained so an old wait handle can still explain why its run stopped.

import core/corruption.{type CorruptionReport}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/async_execution

/// The default wall-clock budget for a child run, in milliseconds.
pub const default_within_ms = 600_000

/// Harness-only facts, separate from the immutable lineage listing.
pub const key_prefix = "child-run/"

/// A cancellation decision, recorded before requesting that exact run's abort.
pub type Stop {
  /// No harness cancellation has been requested.
  Unstopped

  /// The run reached its own absolute deadline.
  BudgetExpired

  /// The parent operation that owns this run ended.
  ParentFinished

  /// An older lineage record says reaped but did not record its cause.
  LegacyReaped
}

/// The lifetime whose closure cancels a child operation.
pub type Owner {
  /// The ordinary parent run, cancelled at its run-end boundary.
  ParentRun(operation: OpId)

  /// A background execution, cancelled when its durable custody closes.
  AsyncExecution(operation: OpId, execution: String)
}

/// One operation's lifecycle, independent of later runs on the same strand.
pub type Run {
  Run(
    /// Conversation on which this operation was accepted.
    strand: String,
    /// Parent operation whose completion cancels this run, or no owner.
    owner: Option(Owner),
    /// Absolute session-clock deadline, or an explicitly unbounded run.
    deadline: Option(Int),
    /// Durable reason for a requested cancellation.
    stop: Stop,
  )
}

/// The reserved fact key for an operation's lifecycle.
///
/// ## Examples
///
/// ```gleam
/// // child_run.key(operation)
/// ```
pub fn key(operation: OpId) -> String {
  key_prefix <> ids.op_id_to_string(operation)
}

/// Encodes a complete lifecycle record for a durable write.
///
/// ## Examples
///
/// ```gleam
/// assert child_run.decode(child_run.encode(run)) == Ok(run)
/// ```
pub fn encode(run: Run) -> JsonValue {
  json.Object([
    #("strand", json.String(run.strand)),
    #("owner", case run.owner {
      None -> json.Null
      Some(ParentRun(operation)) -> json.String(ids.op_id_to_string(operation))
      Some(AsyncExecution(operation, execution)) ->
        json.Object([
          #("operation", json.String(ids.op_id_to_string(operation))),
          #("execution", json.String(execution)),
        ])
    }),
    #("deadline", case run.deadline {
      None -> json.Null
      Some(at) -> json.Int(at)
    }),
    #(
      "stop",
      json.String(case run.stop {
        Unstopped -> "none"
        BudgetExpired -> "budget_expired"
        ParentFinished -> "parent_finished"
        LegacyReaped -> "legacy_reaped"
      }),
    ),
  ])
}

/// Decodes the whole record; malformed ownership or budgets never unbound it.
///
/// ## Examples
///
/// ```gleam
/// assert child_run.decode(json.Null) |> result.is_error
/// ```
pub fn decode(value: JsonValue) -> Result(Run, CorruptionReport) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    other -> invalid("payload", "an object", other)
  })
  use strand <- result.try(field(fields, "strand"))
  use strand <- result.try(case strand {
    json.String(text) -> Ok(text)
    other -> invalid("strand", "a string", other)
  })
  use owner <- result.try(field(fields, "owner"))
  use owner <- result.try(case owner {
    json.Null -> Ok(None)
    json.String(text) ->
      ids.parse_op_id(text) |> result.map(fn(id) { Some(ParentRun(id)) })
    json.Object(fields) -> {
      use operation <- result.try(field(fields, "operation"))
      use operation <- result.try(case operation {
        json.String(text) -> ids.parse_op_id(text)
        other -> invalid("owner.operation", "an operation id", other)
      })
      use execution <- result.try(field(fields, "execution"))
      use execution <- result.try(case execution {
        json.String(text) -> {
          case async_execution.valid_id(text) {
            True -> Ok(text)
            False -> invalid("owner.execution", "an execution id", execution)
          }
        }
        other -> invalid("owner.execution", "an execution id", other)
      })
      Ok(Some(AsyncExecution(operation, execution)))
    }
    other -> invalid("owner", "null or an operation id", other)
  })

  use deadline <- result.try(field(fields, "deadline"))
  use deadline <- result.try(case deadline {
    json.Null -> Ok(None)
    json.Int(at) -> Ok(Some(at))
    other -> invalid("deadline", "null or an absolute millisecond", other)
  })
  use stop <- result.try(field(fields, "stop"))
  use stop <- result.try(case stop {
    json.String("none") -> Ok(Unstopped)
    json.String("budget_expired") -> Ok(BudgetExpired)
    json.String("parent_finished") -> Ok(ParentFinished)
    json.String("legacy_reaped") -> Ok(LegacyReaped)
    other -> invalid("stop", "a known cancellation reason", other)
  })
  Ok(Run(strand:, owner:, deadline:, stop:))
}

fn field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, CorruptionReport) {
  case list.key_find(fields, name) {
    Ok(value) -> Ok(value)
    Error(Nil) -> invalid(name, "a present field", json.Null)
  }
}

fn invalid(
  name: String,
  expected: String,
  value: JsonValue,
) -> Result(a, CorruptionReport) {
  Error(corruption.report(
    at: "runtime/child_run.decode",
    on: name,
    expected:,
    context: json.to_string(value),
  ))
}

/// The immutable original async brief, committed before lineage publication.
/// Recovery must not infer this identity from a strand's mutable latest run.
///
/// ## Examples
///
/// ```gleam
/// // child_run.initial_key("sub:main/reviewer")
/// ```
pub fn initial_key(strand: String) -> String {
  "client/child-initial/" <> strand
}
