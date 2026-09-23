//// Durable identities for named child operations, owned by the Agency actor.
////
//// The workflow header fixes version and input before any child can start.
//// A step fixes its assignment and original call site before spawning. If the
//// process dies between that intent and the receipt, Agency reconciliation
//// finds the same child. Completed and failed operations retain their handles;
//// retrying failed work requires an explicit new step name. No workspace effect
//// or volatile actor state is replayed by this ledger.

import core/ids
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import runtime/api
import tools/agent
import tools/blob

/// Stable user names and immutable workflow inputs supplied to one child step.
pub type Step {
  Step(
    /// Names one workflow run within the authenticated strand.
    workflow: String,
    /// The caller's explicit algorithm version, fixed for this run.
    version: String,
    /// Canonical input text fixed for this run.
    input: String,
    /// Stable step name; execution order does not determine identity.
    name: String,
    /// Digest of the exact child assignment, including result requirements.
    assignment: String,
  )
}

/// Reserves a step identity before spawning, or recovers its original caller.
/// Invoke under the Agency's serialized admission boundary.
///
/// ## Examples
///
/// ```gleam
/// // workflow_ledger.reserve(runtime, caller, step)
/// ```
pub fn reserve(
  runtime: api.Runtime,
  caller: agent.Caller,
  step: Step,
) -> Result(agent.Caller, String) {
  use Nil <- result.try(
    case
      valid_name(step.workflow)
      && valid_name(step.version)
      && valid_name(step.name)
      && string.byte_size(step.input) <= 65_536
    {
      True -> Ok(Nil)
      False ->
        Error(
          "workflow names must be 1..128 bytes and input at most 65536 bytes",
        )
    },
  )
  let run_key =
    "client/workflow/run/"
    <> digest(
      json.Array([json.String(caller.strand), json.String(step.workflow)]),
    )
  let header =
    json.Object([
      #("strand", json.String(caller.strand)),
      #("name", json.String(step.workflow)),
      #("version", json.String(step.version)),
      #("input", json.String(step.input)),
    ])
  use Nil <- result.try(ensure_same(runtime, run_key, header))
  let step_key =
    "client/workflow/step/"
    <> digest(json.Array([json.String(run_key), json.String(step.name)]))
  use existing <- result.try(
    api.fact(runtime, step_key) |> result.map_error(string.inspect),
  )
  case existing {
    Some(value) -> {
      use assignment <- result.try(text(value, "assignment"))
      use Nil <- result.try(case assignment == step.assignment {
        True -> Ok(Nil)
        False ->
          Error(
            "workflow step assignment changed; choose an explicit new step name",
          )
      })
      use operation <- result.try(text(value, "operation"))
      use operation <- result.try(
        ids.parse_op_id(operation) |> result.map_error(string.inspect),
      )
      Ok(agent.Caller(caller.strand, operation, step_key, 0, agent.ToolCall))
    }
    None -> {
      use _ <- result.try(
        api.put_reserved_fact_expecting(
          runtime,
          step_key,
          json.Object([
            #("run", json.String(run_key)),
            #("name", json.String(step.name)),
            #("assignment", json.String(step.assignment)),
            #("operation", json.String(ids.op_id_to_string(caller.operation))),
          ]),
          None,
        )
        |> result.map_error(string.inspect),
      )
      Ok(agent.Caller(
        caller.strand,
        caller.operation,
        step_key,
        0,
        agent.ToolCall,
      ))
    }
  }
}

fn ensure_same(runtime, key, value) -> Result(Nil, String) {
  use existing <- result.try(
    api.fact(runtime, key) |> result.map_error(string.inspect),
  )
  case existing {
    Some(old) if old == value -> Ok(Nil)
    Some(_) ->
      Error("workflow version or input changed; choose a new workflow run name")
    None ->
      api.put_reserved_fact_expecting(runtime, key, value, None)
      |> result.replace(Nil)
      |> result.map_error(string.inspect)
  }
}

fn valid_name(value) -> Bool {
  string.byte_size(value) > 0 && string.byte_size(value) <= 128
}

fn digest(value) -> String {
  blob.ref_for(<<json.to_string(value):utf8>>)
}

fn text(value: JsonValue, key: String) -> Result(String, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("invalid workflow record")
  })
  use field <- result.try(
    list.key_find(fields, key) |> result.replace_error("missing workflow field"),
  )
  case field {
    json.String(value) -> Ok(value)
    _ -> Error("invalid workflow field")
  }
}
