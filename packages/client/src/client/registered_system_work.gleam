//// Original registered goal work, retained before any native permission exists.
//// A CheckingWork can only come from this module's successful Checking CAS and
//// exact readbacks. Its immutable record survives later goal overwrites; reading
//// that record grants observation, never a fresh CheckingWork or Broker ref.

import broker/broker
import broker/exec
import broker/policy
import client/goalstate
import core/generation
import core/ids
import core/json
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import runtime/api

/// Failed retention cannot authorize a task, even after an uncertain COMMIT.
@internal
pub type Error {
  /// The observed transition or immutable coordinates do not match.
  Refused

  /// The actual writer refused or could not confirm its original operation.
  Writer(api.ApiError)
}

/// Fresh local evidence of one actual Checking transition and immutable work.
@internal
pub opaque type CheckingWork {
  CheckingWork(
    seq: ids.Seq,
    goal: goalstate.Goal,
    command: String,
    request_id: ids.EntryId,
    spec: broker.CallSpec,
    owner: String,
    association: generation.GenerationAssociation,
    actor: process.Pid,
    backstop: Int,
    address: String,
    bytes: BitArray,
  )
}

/// Performs the Checking write itself, then retains its immutable occurrence.
/// The caller must be the original actor whose Subject will receive the result.
///
/// ## Examples
///
/// `transition(runtime, before, moved, command, id, spec, owner, association, subject, cap)` does not repeat a prior Checking write.
@internal
pub fn transition(
  runtime: api.Runtime,
  before: goalstate.Goal,
  moved: goalstate.Goal,
  command: String,
  request_id: ids.EntryId,
  spec: broker.CallSpec,
  owner: String,
  association: generation.GenerationAssociation,
  subject: process.Subject(message),
  backstop: Int,
) -> Result(CheckingWork, Error) {
  let ordered =
    goalstate.Goal(
      ..moved,
      updated_ms: int.max(moved.updated_ms, moved.created_ms),
    )
  use deadline <- result.try(checking_deadline(ordered))
  use Nil <- result.try(
    exact(fn() {
      case before.phase {
        goalstate.Checking(..) -> False
        _ -> before != ordered
      }
    }),
  )
  use Nil <- result.try(
    exact(fn() { ordered.check == Some(command) && command != "" }),
  )
  use Nil <- result.try(
    exact(fn() {
      spec.argv == ["bash", "-o", "pipefail", "-c", command]
      && spec.step_id == "goal-check"
      && spec.budget.deadline_ms == deadline
      && spec.grants == []
      && spec.response == broker.RefuseNarrowed
    }),
  )
  use actor <- result.try(
    process.subject_owner(subject) |> result.replace_error(Refused),
  )
  use Nil <- result.try(exact(fn() { actor == process.self() }))
  let key = api.goal_fact_prefix <> "state"
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(Writer),
  )
  use observed <- result.try(option_cell(cell))
  use Nil <- result.try(
    exact(fn() { observed.value == goalstate.encode(before) }),
  )

  // This is the sole original Checking transition. A lost reply is spent;
  // neither its latest value nor a retry can manufacture the returned proof.
  use seq <- result.try(
    api.put_reserved_fact_expecting(
      runtime,
      key,
      goalstate.encode(ordered),
      expected: Some(observed.seq),
    )
    |> result.map_error(Writer),
  )
  use Nil <- result.try(readback(
    api.fact_handle(runtime),
    key,
    seq,
    goalstate.encode(ordered),
  ))
  use record <- result.try(work_record(
    seq,
    ordered,
    command,
    request_id,
    spec,
    owner,
    association,
    actor,
    backstop,
  ))
  let address = api.goal_fact_prefix <> "check/" <> int.to_string(seq)
  use written <- result.try(
    api.put_reserved_fact_expecting(runtime, address, record, expected: None)
    |> result.map_error(Writer),
  )
  use Nil <- result.try(readback(
    api.fact_handle(runtime),
    address,
    written,
    record,
  ))
  let bytes = json.canonical(record) |> json.to_string |> bit_array.from_string
  Ok(CheckingWork(
    seq,
    ordered,
    command,
    request_id,
    spec,
    owner,
    association,
    actor,
    backstop,
    address,
    bytes,
  ))
}

/// Projects only the exact immutable occurrence captured before the worker.
///
/// ## Examples
///
/// `fields(work)` does not consult a latest register or replacement actor.
@internal
pub fn fields(
  work: CheckingWork,
) -> #(
  ids.Seq,
  goalstate.Goal,
  String,
  ids.EntryId,
  broker.CallSpec,
  String,
  generation.GenerationAssociation,
  process.Pid,
  Int,
) {
  #(
    work.seq,
    work.goal,
    work.command,
    work.request_id,
    work.spec,
    work.owner,
    work.association,
    work.actor,
    work.backstop,
  )
}

/// Supplies bounded control metadata pointing to the complete ordinary record.
/// Hashing binds exact bytes; the actual register sequence identifies the event.
///
/// ## Examples
///
/// `manifest(work)` keeps the ordinary input outside SystemIntent's 8192-byte bound.
@internal
pub fn manifest(work: CheckingWork) -> #(String, BitArray) {
  let value =
    json.Object([
      #("domain", json.String("loom.goal.system-intent/1")),
      #("work", json.String(work.address)),
      #("checking_seq", json.Int(work.seq)),
      #("request_id", json.String(ids.entry_id_to_string(work.request_id))),
      #("bytes", json.Int(bit_array.byte_size(work.bytes))),
      #("sha256", json.String(hex(bootstrap.sha256(work.bytes)))),
    ])
  #(
    work.address,
    value |> json.canonical |> json.to_string |> bit_array.from_string,
  )
}

fn checking_deadline(goal: goalstate.Goal) -> Result(Int, Error) {
  case goal.phase {
    goalstate.Checking(deadline_ms) if deadline_ms > 0 -> Ok(deadline_ms)
    _ -> Error(Refused)
  }
}

fn option_cell(cell: Option(api.FactCell)) -> Result(api.FactCell, Error) {
  case cell {
    Some(value) -> Ok(value)
    None -> Error(Refused)
  }
}

fn readback(
  facts: api.FactHandle,
  key: String,
  seq: ids.Seq,
  value: json.JsonValue,
) -> Result(Nil, Error) {
  use observed <- result.try(
    api.fact_cell_with(facts, key) |> result.map_error(Writer),
  )
  case observed {
    Some(api.FactCell(actual, actual_seq)) ->
      exact(fn() { actual_seq == seq && actual == value })
    None -> Error(Refused)
  }
}

fn work_record(
  seq: ids.Seq,
  goal: goalstate.Goal,
  command: String,
  id: ids.EntryId,
  spec: broker.CallSpec,
  owner: String,
  association: generation.GenerationAssociation,
  actor: process.Pid,
  backstop: Int,
) -> Result(json.JsonValue, Error) {
  use base <- result.try(
    policy.encode(spec.base_policy) |> result.replace_error(Refused),
  )
  use requirements <- result.try(
    policy.encode(spec.requirements) |> result.replace_error(Refused),
  )
  use associated <- result.try(
    generation.encode_association(association) |> result.replace_error(Refused),
  )
  Ok(
    json.Object([
      #("domain", json.String("loom.goal.checking-work/1")),
      #("checking_seq", json.Int(seq)),
      #("goal", goalstate.encode(goal)),
      #("command", json.String(command)),
      #("request_id", json.String(ids.entry_id_to_string(id))),
      #("owner", json.String(owner)),
      #("generation", json.String(hex(associated))),
      #("actor", json.String(string.inspect(actor))),
      #("backstop", json.Int(backstop)),
      #("operation", json.String(ids.op_id_to_string(spec.op_id))),
      #("step", json.String(spec.step_id)),
      #("argv", json.Array(list.map(spec.argv, json.String))),
      #(
        "env",
        json.Array(
          list.map(spec.env, fn(pair) {
            json.Array([json.String(pair.0), json.String(pair.1)])
          }),
        ),
      ),
      #("cwd", json.String(spec.cwd)),
      #("base_policy", json.String(hex(base))),
      #("requirements", json.String(hex(requirements))),
      #(
        "demand",
        json.String(case spec.demand {
          exec.FullEnforcement -> "full"
          exec.PlatformEnforcement -> "platform"
          exec.BestEffort -> "best-effort"
        }),
      ),
      #("max_outstanding", json.Int(spec.budget.max_outstanding)),
      #("deadline", json.Int(spec.budget.deadline_ms)),
    ]),
  )
}

fn exact(predicate: fn() -> Bool) -> Result(Nil, Error) {
  use <- bool.guard(when: !predicate(), return: Error(Refused))
  Ok(Nil)
}

fn hex(bytes: BitArray) -> String {
  bytes |> bit_array.base16_encode |> string.lowercase
}
