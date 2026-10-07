//// Original registered goal work, retained before any native permission exists.
//// A CheckingWork can only come from this module's successful Checking CAS and
//// exact readbacks. Its immutable record survives later goal overwrites; reading
//// that record grants observation, never a fresh CheckingWork or Broker ref.
////
//// Registered imported hooks use the same ordinary writer discipline through
//// `retain_hook_occurrence` → `hook_works` → `hook_manifest`. The complete source
//// inventory, stdin and all fixed handler declarations live under the reserved
//// session prefix. The small SystemIntent manifest binds their actual sequence,
//// canonical digest and byte count without enlarging its existing bound.

import broker/broker
import broker/exec
import broker/policy
import client/goalstate
import core/generation
import core/ids
import core/json
import core/workspace
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

/// Original declaration positions, assigned before matching or kind filtering.
@internal
pub type HookPosition {
  /// Each index addresses the original source and parsed declaration inventory.
  HookPosition(
    /// The document's original acquisition position, including skipped sources.
    source: Int,
    /// The event entry's original position in the parsed configuration.
    entry: Int,
    /// The original matcher-group position within that event entry.
    group: Int,
    /// The original handler position, including unsupported handler kinds.
    handler: Int,
  )
}

/// One immutable handler plan, captured with every other plan at the gate.
@internal
pub type HookPlan {
  /// The definition is the complete canonical parsed handler declaration.
  HookPlan(
    /// The complete original address before matching or kind filtering.
    position: HookPosition,
    /// Canonical parsed handler and matcher declaration, without truncation.
    definition: String,
    /// This handler's sole native request UUID, captured at gate acceptance.
    request_id: ids.EntryId,
    /// The immutable policy, coordinates, environment, command and deadline.
    spec: broker.CallSpec,
  )
}

/// One actual gate invocation before its sole write-once ordinary COMMIT.
@internal
pub type HookOccurrenceInput {
  /// The full inventory and stdin remain ordinary data, outside control bounds.
  HookOccurrenceInput(
    /// The sole actual event UUID, distinct from every handler's native UUID.
    request_id: ids.EntryId,
    /// The existing compatibility event spelling for this actual gate.
    event: String,
    /// The complete immutable indexed source inventory and trust dispositions.
    sources: json.JsonValue,
    /// The exact ordinary event payload, preserved in the occurrence record.
    stdin: String,
    /// Every selected original declaration and deadline before execution begins.
    plans: List(HookPlan),
    /// The administratively configured original owner identity.
    owner: String,
    /// The immutable association retained by the original ready custodian.
    association: generation.GenerationAssociation,
    /// The actual original caller whose death cancels the managed gate worker.
    caller: process.Pid,
    /// The single acceptance timestamp from the original captured clock.
    accepted_ms: Int,
    /// The original aggregate deadline, including fixed observation room.
    backstop_ms: Int,
  )
}

/// Fresh evidence comes only from the original successful CAS and readback.
@internal
pub opaque type HookOccurrence {
  HookOccurrence(
    seq: ids.Seq,
    address: String,
    input: HookOccurrenceInput,
    bytes: Int,
    digest: String,
  )
}

/// A selected handler beneath one fresh occurrence, never decoded from history.
@internal
pub opaque type HookWork {
  HookWork(occurrence: HookOccurrence, plan: HookPlan)
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

/// Retains complete ordinary input and all fixed plans before any native effect.
/// Unknown writes are spent observations, never a reason to mint another UUID.
///
/// ## Examples
///
/// `retain_hook_occurrence(facts, input)` uses the existing reserved session lane.
@internal
pub fn retain_hook_occurrence(
  facts: api.FactHandle,
  input: HookOccurrenceInput,
) -> Result(HookOccurrence, Error) {
  let scope =
    generation.key_scope(generation.association_key(input.association))
  let #(session, _) = workspace.scope_fields(scope)
  use identity <- result.try(
    api.fact_cell_with(facts, "session/id") |> result.map_error(Writer),
  )
  use identity <- result.try(option_cell(identity))
  use Nil <- result.try(
    exact(fn() {
      identity.value == json.String(ids.session_id_to_string(session))
    }),
  )
  use Nil <- result.try(
    exact(fn() {
      string.byte_size(input.stdin) <= 1_048_576
      && input.plans != []
      && input.event != ""
      && input.owner != ""
      && input.backstop_ms > input.accepted_ms
      && list.all(input.plans, fn(plan) {
        plan.spec.budget.deadline_ms > input.accepted_ms
        && plan.spec.grants == []
        && plan.spec.response == broker.RefuseNarrowed
        && plan.position.source >= 0
        && plan.position.entry >= 0
        && plan.position.group >= 0
        && plan.position.handler >= 0
      })
      && list.unique(list.map(input.plans, fn(plan) { plan.position }))
      == list.map(input.plans, fn(plan) { plan.position })
      && list.unique(list.map(input.plans, fn(plan) { plan.request_id }))
      == list.map(input.plans, fn(plan) { plan.request_id })
    }),
  )
  use record <- result.try(hook_record(input))
  let address =
    api.session_fact_prefix
    <> "hook-occurrence/"
    <> ids.entry_id_to_string(input.request_id)
  use seq <- result.try(
    api.put_reserved_fact_expecting_with(facts, address, record, expected: None)
    |> result.map_error(Writer),
  )
  use Nil <- result.try(readback(facts, address, seq, record))
  let bytes = json.canonical(record) |> json.to_string |> bit_array.from_string
  Ok(HookOccurrence(
    seq,
    address,
    input,
    bit_array.byte_size(bytes),
    hex(bootstrap.sha256(bytes)),
  ))
}

/// Derives only the captured selected work from its actual fresh occurrence.
///
/// ## Examples
///
/// `hook_works(occurrence)` has no historical reconstruction overload.
@internal
pub fn hook_works(occurrence: HookOccurrence) -> List(HookWork) {
  list.map(occurrence.input.plans, fn(plan) { HookWork(occurrence, plan) })
}

/// Projects the exact captured declaration and ordinary stdin for this handler.
///
/// ## Examples
///
/// `hook_fields(work)` consults neither current config nor current registers.
@internal
pub fn hook_fields(
  work: HookWork,
) -> #(HookPlan, String, String, generation.GenerationAssociation, process.Pid) {
  #(
    work.plan,
    work.occurrence.input.stdin,
    work.occurrence.input.owner,
    work.occurrence.input.association,
    work.occurrence.input.caller,
  )
}

/// Binds a handler position to the complete actual ordinary COMMIT, in 8 KiB.
/// The fragment names a plan inside that one cell, rather than a second write.
///
/// ## Examples
///
/// `hook_manifest(work)` never embeds or truncates the complete stdin.
@internal
pub fn hook_manifest(work: HookWork) -> #(String, BitArray) {
  let original = work.occurrence
  let p = work.plan.position
  let fragment =
    [p.source, p.entry, p.group, p.handler]
    |> list.map(int.to_string)
    |> string.join("/")
  let address = original.address <> "#handler=" <> fragment
  let record =
    json.Object([
      #("domain", json.String("loom.hook.system-intent/1")),
      #("work", json.String(original.address)),
      #("occurrence_seq", json.Int(original.seq)),
      #("handler", json.String(fragment)),
      #("request_id", json.String(ids.entry_id_to_string(work.plan.request_id))),
      #("bytes", json.Int(original.bytes)),
      #("sha256", json.String(original.digest)),
    ])
  #(
    address,
    record |> json.canonical |> json.to_string |> bit_array.from_string,
  )
}

fn hook_record(input: HookOccurrenceInput) -> Result(json.JsonValue, Error) {
  use associated <- result.try(
    generation.encode_association(input.association)
    |> result.replace_error(Refused),
  )
  use plans <- result.try(list.try_map(input.plans, hook_plan_record))
  Ok(
    json.canonical(
      json.Object([
        #("domain", json.String("loom.hook.occurrence/1")),
        #("request_id", json.String(ids.entry_id_to_string(input.request_id))),
        #("event", json.String(input.event)),
        #("sources", input.sources),
        #("stdin", json.String(input.stdin)),
        #("plans", json.Array(plans)),
        #("owner", json.String(input.owner)),
        #("generation", json.String(hex(associated))),
        #("caller", json.String(string.inspect(input.caller))),
        #("accepted_ms", json.Int(input.accepted_ms)),
        #("backstop_ms", json.Int(input.backstop_ms)),
      ]),
    ),
  )
}

fn hook_plan_record(plan: HookPlan) -> Result(json.JsonValue, Error) {
  let spec = plan.spec
  use base <- result.try(
    policy.encode(spec.base_policy) |> result.replace_error(Refused),
  )
  use requirements <- result.try(
    policy.encode(spec.requirements) |> result.replace_error(Refused),
  )
  let p = plan.position
  Ok(
    json.Object([
      #(
        "position",
        json.Array(list.map([p.source, p.entry, p.group, p.handler], json.Int)),
      ),
      #("definition", json.String(plan.definition)),
      #("request_id", json.String(ids.entry_id_to_string(plan.request_id))),
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
