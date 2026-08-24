//// Property tests over seeded random scripts, driven by an automatic
//// responder that answers every `AwaitEffect` key: "every tool call
//// eventually has a result", "no state transitions out of terminal", and
//// "a committed aborted response implies a cancelled (aborted) run" —
//// the durable face of the cancelled-control invariant.
////
//// Randomness follows core's seeded-generator pattern (a SplitMix-style
//// draw threaded explicitly), so a failing case reproduces from its seed.

import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import machine/acceptance.{AcceptRun}
import machine/codec
import machine/operation.{ReplayNever, ReplaySafe, RunAborted, RunLastResult}
import machine/planner.{
  type EffectKey, type Observation, Admitted, AwaitEffect, Dispatch, Fault,
  Finish, ModelResolved, NoObservation, ObservedAdmission,
  ObservedAssistantSettled, ObservedResolution, ObservedRunEnd, ObservedRunStart,
  ObservedToolCleared, ObservedToolOrphaned, ObservedToolRefused,
  ObservedToolSettled, Prepared, Transition, Wait,
}
import machine/queue
import support/fixture
import support/scenario.{type World, World}
import support/store

// --- seeded randomness (core's test/support/generate pattern) -------------

type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Seed(state:))
}

fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

/// An inclusive integer range as a list.
fn range(from start: Int, to stop: Int) -> List(Int) {
  range_loop(start, stop, [])
  |> list.reverse
}

fn range_loop(current: Int, stop: Int, acc: List(Int)) -> List(Int) {
  case current > stop {
    True -> acc
    False -> range_loop(current + 1, stop, [current, ..acc])
  }
}

// --- scripts --------------------------------------------------------------

type CallPlan {
  ClearThenSettle(terminate: Bool)
  ClearThenOrphan
  Refuse
}

type Script {
  Script(calls: List(CallPlan), abort_at: Option(Int))
}

fn script_from(seed: Seed) -> Script {
  let #(call_count, seed) = int_between(seed, 0, 3)
  let #(plans, seed) =
    range(from: 1, to: call_count)
    |> list.fold(#([], seed), fn(acc, _index) {
      let #(plans, seed) = acc
      let #(kind, seed) = int_between(seed, 0, 3)
      let plan = case kind {
        0 -> ClearThenSettle(terminate: False)
        1 -> ClearThenSettle(terminate: True)
        2 -> ClearThenOrphan
        _ -> Refuse
      }
      #([plan, ..plans], seed)
    })
  let #(with_abort, seed) = int_between(seed, 0, 2)
  let #(abort_step, _seed) = int_between(seed, 1, 9)
  Script(calls: list.reverse(plans), abort_at: case with_abort {
    0 -> Some(abort_step)
    _ -> None
  })
}

fn call_names(script: Script) -> List(String) {
  list.index_map(script.calls, fn(_plan, index) { "t" <> int.to_string(index) })
}

fn call_id(source_index: Int) -> String {
  let name_index = source_index - 1
  "call_t" <> int.to_string(name_index) <> "_" <> int.to_string(name_index)
}

// --- the automatic responder ----------------------------------------------

fn respond(world: World, key: EffectKey, script: Script) -> Observation {
  case key {
    planner.RunStartKey(..) -> ObservedRunStart(messages: [])
    planner.AdmissionKey(..) ->
      ObservedAdmission(admission: Admitted(
        stream_options: json.Object([]),
        intended_output_limit: 4096,
        context_window: 200_000,
      ))
    planner.AssistantKey(..) -> {
      let answered =
        dict.values(world.store.entries)
        |> list.any(fn(stored) {
          case stored {
            entry.MessageEntry(message: message.AssistantMessage(..), ..) ->
              True
            _ -> False
          }
        })
      let response = case answered, script.calls {
        False, [_, ..] -> fixture.assistant_calls(call_names(script))
        _, _ -> fixture.assistant(message.Stop, "final answer", 25)
      }
      ObservedAssistantSettled(
        settled: fixture.settled(response),
        overflow_preparation: Some(Prepared(preparation: fixture.preparation())),
      )
    }
    planner.OverflowPreparationKey(..) -> NoObservation
    planner.ToolClearanceKey(source_index:, ..) ->
      case plan_at(script, source_index) {
        Refuse ->
          ObservedToolRefused(
            source_index:,
            result: error_result(source_index, "unknown tool"),
          )
        ClearThenSettle(..) ->
          ObservedToolCleared(
            source_index:,
            effective_arguments: json.Object([]),
            replay: ReplaySafe,
          )
        ClearThenOrphan ->
          ObservedToolCleared(
            source_index:,
            effective_arguments: json.Object([]),
            replay: ReplayNever,
          )
      }
    planner.ToolKey(source_index:, ..) ->
      case plan_at(script, source_index) {
        ClearThenSettle(terminate:) ->
          ObservedToolSettled(
            source_index:,
            result: fixture.tool_result(
              call_id(source_index),
              "t" <> int.to_string(source_index - 1),
              "output",
            ),
            terminate:,
          )
        ClearThenOrphan | Refuse ->
          ObservedToolOrphaned(
            source_index:,
            replay_still_safe: False,
            checkpoint: None,
          )
      }
    planner.PollAdmissionKey(..) | planner.SummaryKey(..) ->
      ObservedResolution(resolution: ModelResolved)
    planner.PollKey(..) ->
      ObservedAssistantSettled(
        settled: fixture.settled(fixture.assistant(message.Stop, "done", 5)),
        overflow_preparation: None,
      )
    planner.DecisionKey(..) ->
      planner.ObservedStructuralDecision(verdict: planner.VerdictDeclined)
    planner.SummaryProgressKey(..) ->
      planner.ObservedSummaryProgress(progress: planner.SummaryProduced(
        summary: "s",
        usage: None,
      ))
    planner.RunEndKey(..) -> ObservedRunEnd(follow_up: None)
  }
}

fn plan_at(script: Script, source_index: Int) -> CallPlan {
  case
    script.calls
    |> list.drop(source_index - 1)
    |> list.first
  {
    Ok(plan) -> plan
    Error(Nil) -> Refuse
  }
}

fn error_result(source_index: Int, text: String) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: call_id(source_index),
    tool_name: "t" <> int.to_string(source_index - 1),
    content: [message.ToolResultText(text:, text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: True,
    timestamp: 9,
  )
}

fn inject_abort(world: World) -> World {
  case scenario.read_op_state(world.store, world.op.id) {
    Error(_message) -> world
    Ok(state) -> {
      let op_state_seq = case
        store.get_register(
          world.store,
          register.OpState,
          ids.op_id_to_string(world.op.id),
        )
      {
        Ok(#(seq, _value)) -> seq
        Error(Nil) -> 0
      }
      case
        queue.request_abort(world.op, state, op_state_seq, scenario.now(world))
      {
        queue.AbortPlanned(next: _, tx: abort_tx, ..) ->
          case store.apply(world.store, abort_tx) {
            Ok(aborted) -> World(..world, store: aborted)
            Error(_message) -> world
          }
        queue.AbortAlreadyRequested(..) -> world
      }
    }
  }
}

fn drive(world: World, script: Script, step_index: Int, fuel: Int) -> World {
  case fuel <= 0 {
    True -> panic as "auto driver ran out of fuel"
    False -> {
      let world = case script.abort_at == Some(step_index) {
        True -> inject_abort(world)
        False -> world
      }
      let assert Ok(#(world, action)) =
        scenario.step(world, NoObservation, scenario.default_options())
      case action {
        Finish(result: _, tx: _) -> world
        Fault(report: _) -> panic as "auto driver hit a fault"
        AwaitEffect(key:) -> {
          let observation = respond(world, key, script)
          let assert Ok(#(world, answered)) =
            scenario.step(world, observation, scenario.default_options())
          case answered {
            Finish(result: _, tx: _) -> world
            Fault(report: _) -> panic as "auto driver hit a fault on answer"
            _ -> drive(world, script, step_index + 1, fuel - 1)
          }
        }
        Wait(until: _) -> drive(world, script, step_index + 1, fuel - 1)
        Transition(..) | Dispatch(..) ->
          drive(world, script, step_index + 1, fuel - 1)
      }
    }
  }
}

fn run_script(seed_value: Int) -> #(World, Script) {
  let script = script_from(Seed(state: seed_value))
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(world, AcceptRun(prompts: [fixture.user("go")]))
  #(drive(world, script, 1, 200), script)
}

// --- the properties -------------------------------------------------------

pub fn every_tool_call_has_a_result_test() {
  list.each(range(from: 1, to: 25), fn(seed_value) {
    let #(world, _script) = run_script(seed_value)
    // Every tool call in every assistant entry has exactly one matching
    // tool-result entry, whatever interleaving of settles, refusals,
    // orphans, and aborts happened.
    let entries = dict.values(world.store.entries)
    let call_ids =
      list.flat_map(entries, fn(stored) {
        case stored {
          entry.MessageEntry(
            message: message.AssistantMessage(content:, ..),
            ..,
          ) ->
            list.filter_map(content, fn(block) {
              case block {
                message.AssistantToolCall(call:) -> Ok(call.id)
                _ -> Error(Nil)
              }
            })
          _ -> []
        }
      })
    list.each(call_ids, fn(id) {
      let results =
        list.filter(entries, fn(stored) {
          case stored {
            entry.MessageEntry(
              message: message.ToolResultMessage(tool_call_id:, ..),
              ..,
            ) -> tool_call_id == id
            _ -> False
          }
        })
      assert list.length(results) == 1
    })
  })
}

pub fn terminal_cleanup_leaves_no_operation_state_test() {
  list.each(range(from: 1, to: 25), fn(seed_value) {
    let #(world, _script) = run_script(seed_value)
    // The terminal transaction removed every operation-owned register.
    assert store.list_register_keys(world.store, register.OpState, "") == []
    assert store.list_register_keys(world.store, register.OpMeta, "") == []
    assert store.list_register_keys(world.store, register.OpToolArgs, "") == []
    assert store.list_register_keys(world.store, register.OpPreparation, "")
      == []
    assert store.list_register_keys(world.store, register.PendingEntry, "")
      == []
    // And the strand is durably idle.
    let assert Ok(#(_seq, register.RegisterValue(payload:))) =
      store.get_register(world.store, register.StrandState, "main")
    let assert Ok(strand_state) = codec.decode_strand_state(payload)
    assert strand_state.current_operation == None
    // No state transitions out of terminal: the next drive finds no
    // program counter at all.
    let assert Error("op.state absent") = case
      scenario.step(world, NoObservation, scenario.default_options())
    {
      Error(message) -> Error(message)
      Ok(_) -> Ok(Nil)
    }
  })
}

pub fn aborted_response_implies_aborted_run_test() {
  list.each(range(from: 1, to: 25), fn(seed_value) {
    let #(world, _script) = run_script(seed_value)
    let assert Ok(#(_seq, register.RegisterValue(payload:))) =
      store.get_register(world.store, register.StrandLastResult, "main")
    let assert Ok(result) = codec.decode_last_result(payload)
    let aborted_run = case result {
      RunLastResult(outcome: RunAborted, ..) -> True
      _ -> False
    }
    let has_aborted_response =
      dict.values(world.store.entries)
      |> list.any(fn(stored) {
        case stored {
          entry.MessageEntry(
            message: message.AssistantMessage(stop_reason: message.Aborted, ..),
            ..,
          ) -> True
          _ -> False
        }
      })
    // A committed aborted response is only reachable under cancelled
    // control, whose only exit is the aborted terminal transaction.
    case has_aborted_response {
      True -> {
        assert aborted_run
      }
      False -> Nil
    }
  })
}
