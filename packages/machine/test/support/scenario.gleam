//// The scenario driver: a small interpreter that drives
//// `planner.next_action` over the fake store, replaying pi's worked
//// examples transaction for transaction.
////
//// Each `step` rebuilds `PlannerInputs` from the store alone — decoding
//// `op.state` and every referenced register through the real codecs — so
//// every step doubles as a crash-restore: nothing process-local survives
//// between steps except the driver's clock and seed counters. "Kill the
//// process between any two transactions" is therefore the default mode of
//// operation, not a special case.

import core/clock
import core/entry
import core/ids.{type EntryId, type OpId}
import core/json
import core/message.{type AgentMessage}
import core/register
import core/tx.{type Tx}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/acceptance.{type AcceptRequest, AcceptCtx}
import machine/codec
import machine/operation.{
  type Operation, type OperationState, type PendingEntry, AwaitingDeferred,
  CompactionSettings, ConsumeAll, DeferredEffectPending, DeferredSuspended,
  NormalizedRetryPolicy, Parallel, RunSettings, RunState, Tools,
}
import machine/planner.{
  type Action, type Observation, type PlannerInputs, type ThresholdStatus,
  PlannerInputs, ThresholdNotExceeded,
}
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration, StrandState,
  ThinkingOff,
}
import support/store.{type Store}

/// The deterministic world a scenario threads: the durable store plus the
/// driver's clock/seed counters and the operation's immutable metadata.
pub type World {
  World(store: Store, op: Operation, now: Int, seed: Int)
}

/// Per-step knobs beyond the observation.
pub type StepOptions {
  StepOptions(threshold: ThresholdStatus, poll_permit: Bool)
}

/// Default step options: threshold not exceeded, no poll permit.
pub fn default_options() -> StepOptions {
  StepOptions(threshold: ThresholdNotExceeded, poll_permit: False)
}

/// The default strand configuration used by scenarios.
pub fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: ["bash"],
  )
}

/// The default run settings snapshot.
pub fn settings() -> operation.RunSettings {
  RunSettings(
    compaction: CompactionSettings(
      enabled: True,
      reserve_tokens: 1000,
      keep_recent_tokens: 500,
    ),
    steering_mode: ConsumeAll,
    follow_up_mode: ConsumeAll,
    tool_execution: Parallel,
  )
}

/// A fresh world over an empty store with a configured idle strand.
pub fn fresh() -> World {
  let empty = store.new()
  let assert Ok(seeded) =
    store.apply(
      empty,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.StrandConfig,
            key: "main",
            value: register.value(codec.encode_configuration(configuration())),
          ),
          tx.SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(None),
          ),
          tx.SetRegister(
            ns: register.StrandState,
            key: "main",
            value: register.value(
              codec.encode_strand_state(
                StrandState(current_operation: None, pending_next_run: []),
              ),
            ),
          ),
        ],
        expected: [],
      ),
    )
  // The op field is a placeholder until acceptance installs a real one.
  World(
    store: seeded,
    op: operation.Operation(
      id: mint_op_id(0),
      strand: "main",
      source_leaf: None,
      started_at: 0,
      intent: operation.RunIntent(prompt_entries: []),
    ),
    now: 1_000_000,
    seed: 1,
  )
}

fn mint_op_id(seed: Int) -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1), seed: seed + 77))
  id
}

/// Accepts a request against the world's strand, applying the acceptance
/// transaction and installing the operation.
pub fn accept(
  world: World,
  request: AcceptRequest,
) -> Result(#(World, Tx), String) {
  let #(strand_seq, strand_state) = read_strand_state(world.store)
  let leaf = read_leaf(world.store)
  let ctx =
    AcceptCtx(
      strand: "main",
      now: world.now,
      generator: generator(world),
      strand_state:,
      strand_state_seq: strand_seq,
      leaf:,
      leaf_seq: read_leaf_seq(world.store),
      settings: settings(),
      pending: pending_payloads(world.store),
    )
  case acceptance.accept_prompt(request, ctx) {
    Error(reason) -> Error("acceptance rejected: " <> describe_reject(reason))
    Ok(acceptance.AcceptancePlan(operation:, state: _, tx: plan_tx)) ->
      case store.apply(world.store, plan_tx) {
        Error(message) -> Error(message)
        Ok(store) ->
          Ok(#(
            World(
              store:,
              op: operation,
              now: world.now + 1000,
              seed: world.seed + 1,
            ),
            plan_tx,
          ))
      }
  }
}

/// One driver iteration: rebuild inputs from the store, plan, apply any
/// emitted transaction. Returns the action for assertions.
pub fn step(
  world: World,
  observation: Observation,
  options: StepOptions,
) -> Result(#(World, Action), String) {
  use state <- result.try(read_op_state(world.store, world.op.id))
  let inputs = build_inputs(world, state, observation, options)
  let action = planner.next_action(world.op, state, inputs)
  let advanced = World(..world, now: world.now + 1000, seed: world.seed + 1)
  case action {
    planner.Transition(next: _, tx: plan_tx)
    | planner.Dispatch(intent: _, next: _, tx: plan_tx)
    | planner.Finish(result: _, tx: plan_tx) ->
      case store.apply(world.store, plan_tx) {
        Error(message) -> Error("commit failed: " <> message)
        Ok(store) -> Ok(#(World(..advanced, store:), action))
      }
    planner.AwaitEffect(..) | planner.Wait(..) | planner.Fault(..) ->
      Ok(#(advanced, action))
  }
}

/// Builds the planner inputs for the current durable state.
pub fn build_inputs(
  world: World,
  state: OperationState,
  observation: Observation,
  options: StepOptions,
) -> PlannerInputs {
  let #(strand_seq, strand_state) = read_strand_state(world.store)
  let op_state_seq = case
    store.get_register(world.store, register.OpState, op_key(world.op.id))
  {
    Ok(#(seq, _)) -> seq
    Error(Nil) -> 0
  }
  let configuration_seq = case
    store.get_register(world.store, register.StrandConfig, "main")
  {
    Ok(#(seq, _)) -> seq
    Error(Nil) -> 0
  }
  PlannerInputs(
    now: world.now,
    generator: generator(world),
    op_state_seq:,
    strand_state:,
    strand_state_seq: strand_seq,
    leaf: read_leaf(world.store),
    configuration: read_configuration(world.store),
    configuration_seq:,
    stream_options: json.Object([]),
    retry_policy: NormalizedRetryPolicy(max_attempts: 3, base_delay_ms: 100),
    pending: pending_payloads(world.store),
    projected_custom_types: ["projected"],
    batch_source: batch_source(world.store, state),
    deferred_source: deferred_source(world.store, state),
    preparation: preparation(world.store, world.op.id),
    tool_args_keys: store.list_register_keys(
      world.store,
      register.OpToolArgs,
      op_key(world.op.id),
    ),
    preparation_keys: store.list_register_keys(
      world.store,
      register.OpPreparation,
      op_key(world.op.id),
    ),
    threshold: options.threshold,
    poll_permit: options.poll_permit,
    observation:,
  )
}

/// Reads and decodes the current operation state — the crash-restore
/// read.
pub fn read_op_state(
  store_value: Store,
  op: OpId,
) -> Result(OperationState, String) {
  case store.get_register(store_value, register.OpState, op_key(op)) {
    Error(Nil) -> Error("op.state absent")
    Ok(#(_seq, register.RegisterValue(payload:))) ->
      case codec.decode_state(payload) {
        Ok(state) -> Ok(state)
        Error(_report) -> Error("op.state failed to decode")
      }
  }
}

fn op_key(op: OpId) -> String {
  ids.op_id_to_string(op)
}

fn generator(world: World) -> ids.Generator {
  ids.generator(clock.fixed(at: world.now), seed: world.seed * 7919)
}

fn read_strand_state(store_value: Store) -> #(Int, strand.StrandState) {
  case store.get_register(store_value, register.StrandState, "main") {
    Ok(#(seq, register.RegisterValue(payload:))) ->
      case codec.decode_strand_state(payload) {
        Ok(state) -> #(seq, state)
        Error(_report) -> #(
          seq,
          StrandState(current_operation: None, pending_next_run: []),
        )
      }
    Error(Nil) -> #(
      0,
      StrandState(current_operation: None, pending_next_run: []),
    )
  }
}

fn read_leaf_seq(store_value: Store) -> Option(Int) {
  case store.get_register(store_value, register.StrandLeaf, "main") {
    Ok(#(seq, _value)) -> Some(seq)
    Error(Nil) -> None
  }
}

fn read_leaf(store_value: Store) -> Option(EntryId) {
  case store.get_register(store_value, register.StrandLeaf, "main") {
    Ok(#(_seq, value)) ->
      case register.read_leaf(value) {
        Ok(leaf) -> leaf
        Error(_report) -> None
      }
    Error(Nil) -> None
  }
}

fn read_configuration(store_value: Store) -> StrandConfiguration {
  case store.get_register(store_value, register.StrandConfig, "main") {
    Ok(#(_seq, register.RegisterValue(payload:))) ->
      case codec.decode_configuration(payload) {
        Ok(configuration) -> configuration
        Error(_report) -> configuration()
      }
    Error(Nil) -> configuration()
  }
}

fn pending_payloads(store_value: Store) -> Dict(String, PendingEntry) {
  store.list_register_keys(store_value, register.PendingEntry, "")
  |> list.filter_map(fn(key) {
    case store.get_register(store_value, register.PendingEntry, key) {
      Ok(#(_seq, register.RegisterValue(payload:))) ->
        case codec.decode_pending_entry(payload) {
          Ok(pending) -> Ok(#(key, pending))
          Error(_report) -> Error(Nil)
        }
      Error(Nil) -> Error(Nil)
    }
  })
  |> dict.from_list
}

fn batch_source(
  store_value: Store,
  state: OperationState,
) -> Option(AgentMessage) {
  case state {
    RunState(phase: Tools(batch:), ..) ->
      entry_message(store_value, batch.assistant_entry)
    _ -> None
  }
}

fn deferred_source(
  store_value: Store,
  state: OperationState,
) -> Option(message.DeferredHandle) {
  let source = case state {
    RunState(
      phase: AwaitingDeferred(deferred: DeferredSuspended(source_entry:, ..)),
      ..,
    )
    | RunState(
        phase: AwaitingDeferred(deferred: DeferredEffectPending(
          source_entry:,
          ..,
        )),
        ..,
      ) -> Some(source_entry)
    _ -> None
  }
  case source {
    None -> None
    Some(entry_id) ->
      case entry_message(store_value, entry_id) {
        Some(message.AssistantMessage(deferred:, ..)) -> deferred
        _ -> None
      }
  }
}

fn entry_message(store_value: Store, id: EntryId) -> Option(AgentMessage) {
  case store.get_entry(store_value, ids.entry_id_to_string(id)) {
    Ok(entry.MessageEntry(message:, ..)) -> Some(message)
    Ok(_) | Error(Nil) -> None
  }
}

fn preparation(
  store_value: Store,
  op: OpId,
) -> Option(operation.StructuralPreparation) {
  case
    store.list_register_keys(store_value, register.OpPreparation, op_key(op))
  {
    [key, ..] ->
      case store.get_register(store_value, register.OpPreparation, key) {
        Ok(#(_seq, register.RegisterValue(payload:))) ->
          case codec.decode_preparation(payload) {
            Ok(preparation) -> Some(preparation)
            Error(_report) -> None
          }
        Error(Nil) -> None
      }
    [] -> None
  }
}

fn describe_reject(reason: acceptance.RejectReason) -> String {
  case reason {
    acceptance.StrandBusy -> "strand busy"
    acceptance.InvalidMessage(reason:) -> "invalid message: " <> reason
    acceptance.NothingToCompact -> "nothing to compact"
    acceptance.InvalidNavigation(reason:) -> "invalid navigation: " <> reason
    acceptance.UnknownTarget -> "unknown target"
    acceptance.QueueCorruption(report: _) -> "queue corruption"
  }
}

/// A compact description of a transaction's writes, for trace assertions
/// against pi's `TX[...]` narratives.
pub fn write_names(tx_value: Tx) -> List(String) {
  list.map(tx_value.writes, fn(write) {
    case write {
      tx.InsertEntry(entry: inserted) ->
        case inserted {
          entry.MessageEntry(..) -> "insert:message"
          entry.CompactionEntry(..) -> "insert:compaction"
          entry.BranchSummaryEntry(..) -> "insert:branch_summary"
          entry.CustomEntry(..) -> "insert:custom"
        }
      tx.InsertUsage(..) -> "insert:usage"
      tx.SetRegister(ns:, ..) -> "set:" <> register.ns_to_string(ns)
      tx.DeleteRegister(ns:, ..) -> "del:" <> register.ns_to_string(ns)
    }
  })
}

/// The number the driver's clock currently reads; useful in assertions.
pub fn now(world: World) -> Int {
  world.now
}

/// Convenience: run `step` and require an applied transition, returning
/// the world and the names of the transaction's writes.
pub fn step_writes(
  world: World,
  observation: Observation,
  options: StepOptions,
) -> Result(#(World, List(String)), String) {
  use #(world, action) <- result.try(step(world, observation, options))
  case action {
    planner.Transition(next: _, tx: plan_tx)
    | planner.Dispatch(intent: _, next: _, tx: plan_tx)
    | planner.Finish(result: _, tx: plan_tx) ->
      Ok(#(world, write_names(plan_tx)))
    planner.AwaitEffect(..) -> Error("expected a commit, got AwaitEffect")
    planner.Wait(..) -> Error("expected a commit, got Wait")
    planner.Fault(..) -> Error("expected a commit, got Fault")
  }
}
