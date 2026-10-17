//// Property tests over generated scripts, driven by an automatic
//// responder that answers every `AwaitEffect` key: "every tool call
//// eventually has a result", "no state transitions out of terminal", and
//// "a committed aborted response implies a cancelled (aborted) run" —
//// the durable face of the cancelled-control invariant.
////
//// Scripts come from a qcheck generator rather than a hand-threaded seed.
//// The generator carries its own shrink tree, so a failing script is
//// reported already reduced: fewer tool calls, each plan pulled toward the
//// plain settle, and the abort dropped when the failure survives without
//// it. A script is a list of independent per-call plans indexed by the
//// call's position, so a shorter list is a simpler session rather than a
//// different one, which is what lets the shrink be trusted here.
////
//// The run uses a fixed qcheck seed, so the gate stays deterministic: a red
//// run is the same red run on every machine.

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
import qcheck
import support/fixture
import support/scenario.{type World, World}
import support/store

// --- scripts --------------------------------------------------------------

type CallPlan {
  ClearThenSettle(terminate: Bool)
  ClearThenOrphan
  Refuse(ending: planner.RefusalEnding)
}

type Script {
  Script(calls: List(CallPlan), abort_at: Option(Int))
}

/// The number of scripts each property is checked over, and the seed they
/// are drawn from. Every property shares both, so a failure in one names a
/// script the others were also run on.
const script_count = 100

const script_seed = 25

fn script_config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(script_count)
  |> qcheck.with_seed(qcheck.seed(script_seed))
}

/// Up to three tool calls and an optional abort step. Each call's plan is
/// drawn as an index so that shrinking moves it toward index zero, the
/// plain non-terminating settle, which is the least eventful thing a call
/// can do; `option_from` shrinks the abort toward `None` first.
fn script_generator() -> qcheck.Generator(Script) {
  let plan = qcheck.map(qcheck.bounded_int(from: 0, to: 4), plan_of_kind)

  let calls =
    qcheck.generic_list(
      elements_from: plan,
      length_from: qcheck.bounded_int(from: 0, to: 3),
    )

  let abort_at = qcheck.option_from(qcheck.bounded_int(from: 1, to: 9))
  qcheck.map2(calls, abort_at, fn(calls, abort_at) { Script(calls:, abort_at:) })
}

fn plan_of_kind(kind: Int) -> CallPlan {
  case kind {
    0 -> ClearThenSettle(terminate: False)
    1 -> ClearThenSettle(terminate: True)
    2 -> ClearThenOrphan
    3 -> Refuse(ending: planner.RefusalEndsRun)
    _ -> Refuse(ending: planner.RefusalContinues)
  }
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
        api: "acme-api",
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
        accounting: fixture.report(fixture.settled(response)),
        overflow_preparation: Some(Prepared(preparation: fixture.preparation())),
      )
    }
    planner.OverflowPreparationKey(..) -> NoObservation
    planner.ToolClearanceKey(source_index:, ..) ->
      case plan_at(script, source_index) {
        Refuse(ending:) ->
          ObservedToolRefused(
            source_index:,
            result: error_result(source_index, "unknown tool"),
            ending:,
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
        ClearThenOrphan | Refuse(..) ->
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
        accounting: fixture.report(
          fixture.settled(fixture.assistant(message.Stop, "done", 5)),
        ),
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
    Error(Nil) -> Refuse(ending: planner.RefusalContinues)
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

fn run_script(script: Script) -> World {
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(world, AcceptRun(prompts: [fixture.user("go")]))
  drive(world, script, 1, 200)
}

// --- the properties -------------------------------------------------------

pub fn every_tool_call_has_a_result_test() {
  use script <- qcheck.run(script_config(), script_generator())
  let world = run_script(script)

  // Every tool call in every answerable assistant entry has exactly one
  // matching tool-result entry, whatever interleaving of settles,
  // refusals, orphans, and aborts happened. A response that settles
  // under cancelled control commits normalized to `Aborted` with its
  // calls intact and no results staged for them; that is sound only
  // because context projection drops aborted responses (spec WP-C), so
  // those calls never reach a provider and are owed nothing. The
  // generator found that case (one plain settle, abort at step four)
  // within its first hundred scripts; the seeds this replaced never did.
  let entries = dict.values(world.store.entries)
  let call_ids =
    list.flat_map(entries, fn(stored) {
      case stored {
        entry.MessageEntry(
          message: message.AssistantMessage(stop_reason:, content:, ..),
          ..,
        )
          if stop_reason != message.Aborted
        ->
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
}

pub fn terminal_cleanup_leaves_no_operation_state_test() {
  use script <- qcheck.run(script_config(), script_generator())
  let world = run_script(script)
  // The terminal transaction removed every operation-owned register.
  assert store.list_register_keys(world.store, register.OpState, "") == []
  assert store.list_register_keys(world.store, register.OpMeta, "") == []
  assert store.list_register_keys(world.store, register.OpToolArgs, "") == []
  assert store.list_register_keys(world.store, register.OpPreparation, "") == []
  assert store.list_register_keys(world.store, register.PendingEntry, "") == []
  // And the strand is durably idle.
  let assert Ok(#(_seq, register.RegisterValue(payload:))) =
    store.get_register(world.store, register.StrandState, "main")
  let assert Ok(strand_state) = codec.decode_strand_state(payload)
  assert strand_state.current_operation == None
  // No state transitions out of terminal: the next drive finds no
  // program counter at all.
  let next = case
    scenario.step(world, NoObservation, scenario.default_options())
  {
    Error(message) -> Error(message)
    Ok(_) -> Ok(Nil)
  }
  assert next == Error("op.state absent")
}

pub fn terminal_result_is_recorded_operation_keyed_test() {
  use script <- qcheck.run(script_config(), script_generator())
  let world = run_script(script)
  // The terminal transaction wrote the result twice, atomically: the
  // strand's latest-wins register, and the operation-keyed copy that a
  // waiter can still observe after a later run overwrites the strand
  // register. The two payloads must agree, and the operation-keyed
  // key must derive from the operation the result itself names.
  let assert Ok(#(_seq, register.RegisterValue(payload: latest))) =
    store.get_register(world.store, register.StrandLastResult, "main")
  let assert Ok(result) = codec.decode_last_result(latest)
  let op = case result {
    RunLastResult(operation:, ..) -> operation
    operation.CompactionLastResult(operation:, ..) -> operation
    operation.NavigationLastResult(operation:, ..) -> operation
  }
  let assert Ok(#(_seq, register.RegisterValue(payload: keyed))) =
    store.get_register(
      world.store,
      register.FactCustom,
      operation.result_fact_key(op),
    )
  assert keyed == latest
}

pub fn aborted_response_implies_aborted_run_test() {
  use script <- qcheck.run(script_config(), script_generator())
  let world = run_script(script)
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
}
