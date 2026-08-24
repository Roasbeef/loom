//// Parallel tool execution (pi §3.8 batch modes, review finding
//// ORCH-M2): under `settings.tool_execution: Parallel` the planner
//// issues clearance and intents for every planned call in source order
//// while earlier calls are still effect-pending, effects settle
//// independently and out of order, and tree materialization stays
//// source-ordered. Under `Sequential` the batch still works one call at
//// a time.

import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import gleam/list
import gleam/option.{None, Some}
import machine/acceptance.{AcceptRun}
import machine/codec
import machine/operation.{
  Checkpoint, ReplaySafe, RunSettings, RunState, Sequential,
}
import machine/planner.{
  Admitted, AwaitEffect, Dispatch, NoObservation, ObservedAdmission,
  ObservedAssistantSettled, ObservedRunStart, ObservedToolCleared,
  ObservedToolSettled,
}
import support/fixture
import support/scenario.{type World, World}
import support/store

fn opts() -> scenario.StepOptions {
  scenario.default_options()
}

fn admitted() -> planner.Observation {
  ObservedAdmission(admission: Admitted(
    stream_options: json.Object([]),
    intended_output_limit: 4096,
    context_window: 200_000,
    api: "acme-api",
  ))
}

// Drives a fresh world (scenario settings: Parallel) into a two-call tool
// batch.
fn start_two_call_batch() -> World {
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(world, AcceptRun(prompts: [fixture.user("run both tools")]))
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, ObservedRunStart(messages: []), opts())
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(world, NoObservation, opts())
  let assert Ok(#(world, _action)) = scenario.step(world, admitted(), opts())
  let response = fixture.assistant_calls(["read", "write"])
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedAssistantSettled(
        settled: fixture.settled(response),
        overflow_preparation: None,
      ),
      opts(),
    )
  world
}

pub fn parallel_batch_dispatches_all_calls_before_waiting_test() {
  let world = start_two_call_batch()
  // Call at source index 1 clears and dispatches first.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolClearanceKey(source_index: 1, ..)) =
    action
  let assert Ok(#(world, action)) = scenario.step(world, cleared(1), opts())
  let assert Dispatch(intent: planner.ToolRequest(source_index: 1, ..), ..) =
    action
  // Parallel: while call 1 is effect-pending, the next planned call is
  // worked instead of parking on call 1.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolClearanceKey(source_index: 2, ..)) =
    action
  let assert Ok(#(world, action)) = scenario.step(world, cleared(2), opts())
  let assert Dispatch(intent: planner.ToolRequest(source_index: 2, ..), ..) =
    action
  // Every unfinished call is now in flight: park on the first pending.
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolKey(source_index: 1, ..)) = action
  // Effects settle out of order: call 2 first, staged but not
  // materialized (source order holds the tree).
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      ObservedToolSettled(
        source_index: 2,
        result: fixture.tool_result("call_write_1", "write", "out:write"),
        terminate: False,
      ),
      opts(),
    )
  assert writes == ["set:pending.entry", "set:op.state"]
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolKey(source_index: 1, ..)) = action
  // Call 1 settles; both staged outcomes materialize in source order.
  let assert Ok(#(world, _writes)) =
    scenario.step_writes(
      world,
      ObservedToolSettled(
        source_index: 1,
        result: fixture.tool_result("call_read_0", "read", "out:read"),
        terminate: False,
      ),
      opts(),
    )
  let assert Ok(#(world, writes)) =
    scenario.step_writes(world, NoObservation, opts())
  assert writes
    == [
      "insert:message", "del:pending.entry", "insert:message",
      "del:pending.entry", "set:strand.leaf", "del:op.tool_args",
      "del:op.tool_args", "set:op.state",
    ]
  // The batch is complete and the tree holds the results in source order:
  // read's result entry parents write's.
  let assert Ok(RunState(phase: Checkpoint(..), ..)) =
    scenario.read_op_state(world.store, world.op.id)
  let assert [first_id, second_id] = tool_result_entries(world)
  let assert Ok(entry.MessageEntry(
    message: message.ToolResultMessage(tool_name: "read", ..),
    ..,
  )) = store.get_entry(world.store, first_id)
  let assert Ok(entry.MessageEntry(
    message: message.ToolResultMessage(tool_name: "write", ..),
    parent: Some(write_parent),
    ..,
  )) = store.get_entry(world.store, second_id)
  assert ids.entry_id_to_string(write_parent) == first_id
}

pub fn sequential_batch_still_works_one_call_at_a_time_test() {
  let world = start_two_call_batch()
  let world = with_sequential_settings(world)
  let assert Ok(#(world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolClearanceKey(source_index: 1, ..)) =
    action
  let assert Ok(#(world, action)) = scenario.step(world, cleared(1), opts())
  let assert Dispatch(intent: planner.ToolRequest(source_index: 1, ..), ..) =
    action
  // Sequential parks on the pending call instead of clearing the next.
  let assert Ok(#(_world, action)) = scenario.step(world, NoObservation, opts())
  let assert AwaitEffect(key: planner.ToolKey(source_index: 1, ..)) = action
}

fn cleared(source_index: Int) -> planner.Observation {
  ObservedToolCleared(
    source_index:,
    effective_arguments: json.Object([]),
    replay: ReplaySafe,
  )
}

// Rewrites the open operation's settings snapshot to sequential tool
// execution, directly in the store (an unguarded register write, the way
// a settings migration would).
fn with_sequential_settings(world: World) -> World {
  let assert Ok(state) = scenario.read_op_state(world.store, world.op.id)
  let assert RunState(control:, settings:, phase:, inbox:, latest_assistant:) =
    state
  let sequential =
    RunState(
      control:,
      settings: RunSettings(..settings, tool_execution: Sequential),
      phase:,
      inbox:,
      latest_assistant:,
    )
  let assert Ok(next_store) =
    store.apply(
      world.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.OpState,
            key: ids.op_id_to_string(world.op.id),
            value: register.value(codec.encode_state(sequential)),
          ),
        ],
        expected: [],
      ),
    )
  World(..world, store: next_store)
}

// Every tool-result entry id, in insertion order.
fn tool_result_entries(world: World) -> List(String) {
  list.filter(world.store.entry_log, fn(id) {
    case store.get_entry(world.store, id) {
      Ok(entry.MessageEntry(message: message.ToolResultMessage(..), ..)) -> True
      _ -> False
    }
  })
}
