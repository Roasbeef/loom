//// Recovery ceilings narrow the serialized policy, not an error-local counter.
//// Every scenario step reloads op.state through the production total codec.

import core/accounting
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import machine/acceptance
import machine/operation
import machine/planner
import support/fixture
import support/scenario.{type World, World}

fn options() {
  scenario.default_options()
}

fn policy(budget) {
  operation.NormalizedRetryPolicy(budget, 0, 0)
}

fn run(budget) -> World {
  let world = World(..scenario.fresh(), retry_policy: policy(budget))
  let assert Ok(#(world, _)) =
    scenario.accept(world, acceptance.AcceptRun([fixture.user("recover")]))
    as "Run admitted."
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.ObservedRunStart([]), options())
    as "Run started."
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.NoObservation, options())
    as "Generation ready."
  dispatch(world)
}

fn dispatch(world) {
  let assert Ok(#(world, planner.Dispatch(..))) =
    scenario.step(
      world,
      planner.ObservedAdmission(planner.Admitted(
        json.Object([]),
        4096,
        200_000,
        "acme-api",
      )),
      options(),
    )
    as "Attempt dispatched."
  world
}

fn failed(world, diagnostics) {
  let assert message.AssistantMessage(..) as failure =
    fixture.assistant_error("original failure", True)
    as "Assistant failure fixture."
  let failure = message.AssistantMessage(..failure, diagnostics:)
  let assert Ok(#(world, writes)) =
    scenario.step_writes(
      world,
      planner.ObservedAssistantSettled(
        fixture.settled(failure),
        fixture.report(fixture.settled(failure)),
        None,
      ),
      options(),
    )
    as "Failure committed."
  assert writes
    == ["insert:message", "set:strand.leaf", "insert:usage", "set:op.state"]
  world
}

fn cap(value) {
  Some(json.Object([#("retry_max_attempts", value)]))
}

fn retry(world: World, expected) {
  let assert Ok(operation.RunState(
    phase: operation.Assistant(operation.GenerationRetryWait(
      context:,
      next_attempt:,
      ..,
    )),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
    as "Retry survives durable decode."
  assert context.retry.attempts == operation.Bounded(expected)
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.NoObservation, options())
    as "Wait released."
  assert next_attempt > 1
  dispatch(world)
}

fn exhausted(world: World, count) {
  let assert Ok(operation.RunState(phase: operation.FailureDrain(..), ..)) =
    scenario.read_op_state(world.store, world.op.id)
    as "Budget exhaustion is terminal."
  assert list.length(world.store.usage) == count
}

pub fn corruption_transport_corruption_stops_at_three_test() {
  let world = run(operation.Unbounded) |> failed(cap(json.Int(3))) |> retry(3)
  let world = failed(world, None) |> retry(3)
  exhausted(failed(world, cap(json.Int(3))), 3)
}

pub fn server_retry_advice_and_recovery_cap_survive_the_same_reload_test() {
  let initial = run(operation.Unbounded)
  let settled_at = initial.now
  let world =
    failed(
      initial,
      Some(
        json.Object([
          #("retry_max_attempts", json.Int(3)),
          #("retry_after_ms", json.Int(60_000)),
        ]),
      ),
    )
  let assert Ok(operation.RunState(
    phase: operation.Assistant(operation.GenerationRetryWait(
      context:,
      not_before:,
      ..,
    )),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
    as "The production total codec preserves advice and the narrowed policy."
  assert context.retry.attempts == operation.Bounded(3)
  assert not_before == settled_at + 60_000

  // Even with the retry budget remaining, the server's minimum delay keeps
  // the next generation parked until its captured deadline.
  let assert Ok(#(_, planner.Wait(..))) =
    scenario.step(
      World(..world, now: not_before - 1),
      planner.NoObservation,
      options(),
    )
    as "A retry cannot dispatch before the server-advised deadline."
}

pub fn stricter_configured_budgets_win_test() {
  exhausted(run(operation.Bounded(1)) |> failed(cap(json.Int(3))), 1)
  let world = run(operation.Bounded(2)) |> failed(cap(json.Int(3))) |> retry(2)
  exhausted(failed(world, None), 2)
}

pub fn orphan_inherits_the_narrowed_budget_test() {
  let world = run(operation.Unbounded) |> failed(cap(json.Int(3))) |> retry(3)
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.ObservedAssistantOrphaned([]), options())
    as "Orphan settled."
  let world = retry(world, 3)
  exhausted(failed(world, None), 3)
}

pub fn malformed_caps_and_larger_caps_never_increase_budget_test() {
  list.each(
    [json.Int(0), json.Int(-1), json.String("3"), json.Array([]), json.Int(100)],
    fn(value) {
      let world = run(operation.Bounded(2)) |> failed(cap(value)) |> retry(2)
      exhausted(failed(world, None), 2)
    },
  )
}

fn summary(budget) {
  let world = World(..scenario.fresh(), retry_policy: policy(budget))
  let assert Ok(#(world, _)) =
    scenario.accept(
      world,
      acceptance.AcceptCompaction(None, Some(fixture.preparation())),
    )
    as "Compaction admitted."
  let assert Ok(#(world, _)) =
    scenario.step(
      world,
      planner.ObservedStructuralDecision(planner.VerdictGenerate),
      options(),
    )
    as "Summary selected."
  summary_dispatch(world)
}

fn summary_dispatch(world) {
  let assert Ok(#(world, _)) =
    scenario.step(
      world,
      planner.ObservedResolution(planner.ModelResolved),
      options(),
    )
    as "Summary resolved."
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.NoObservation, options())
    as "Summary request dispatched."
  let assert Ok(#(world, _)) =
    scenario.step(
      world,
      planner.ObservedSummaryReturned(
        accounting.from_usage(fixture.usage_of(10, 5)),
      ),
      options(),
    )
    as "Summary usage committed."
  world
}

fn summary_failure(world, details) {
  let assert Ok(#(world, _)) =
    scenario.step(
      world,
      planner.ObservedSummaryProgress(planner.SummaryFailed(
        operation.OperationError("summary_failed", "original failure", details),
        True,
      )),
      options(),
    )
    as "Summary failure observed."
  world
}

fn summary_retry(world: World, expected) {
  let assert Ok(operation.CompactionState(
    structural: operation.Generating(
      generation: operation.SummaryRetryWait(context:, ..),
      ..,
    ),
    ..,
  )) = scenario.read_op_state(world.store, world.op.id)
    as "Summary ceiling survives durable codec."
  assert context.retry.attempts == operation.Bounded(expected)
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.NoObservation, options())
    as "Summary wait released."
  summary_dispatch(world)
}

pub fn summary_corruption_transport_corruption_stops_at_three_test() {
  let world =
    summary(operation.Unbounded)
    |> summary_failure(cap(json.Int(3)))
    |> summary_retry(3)
  let world = summary_failure(world, None) |> summary_retry(3)
  let world = summary_failure(world, cap(json.Int(3)))
  assert list.length(world.store.usage) == 3
  assert scenario.read_op_state(world.store, world.op.id)
    == Error("op.state absent")
}

pub fn summary_stricter_configured_budget_wins_test() {
  let single =
    summary(operation.Bounded(1)) |> summary_failure(cap(json.Int(3)))
  assert scenario.read_op_state(single.store, single.op.id)
    == Error("op.state absent")

  let world =
    summary(operation.Bounded(2))
    |> summary_failure(cap(json.Int(3)))
    |> summary_retry(2)
  let world = summary_failure(world, None)
  assert scenario.read_op_state(world.store, world.op.id)
    == Error("op.state absent")
}

pub fn summary_orphan_inherits_ceiling_test() {
  let world =
    summary(operation.Unbounded)
    |> summary_failure(cap(json.Int(3)))
    |> summary_retry(3)
  let assert Ok(#(world, _)) =
    scenario.step(world, planner.ObservedSummaryOrphaned, options())
    as "Summary orphan advances under captured ceiling."
  let world = summary_dispatch(world) |> summary_failure(None)
  assert scenario.read_op_state(world.store, world.op.id)
    == Error("op.state absent")
}

pub fn summary_malformed_caps_leave_stricter_budget_test() {
  list.each(
    [json.Int(0), json.Int(-1), json.String("3"), json.Array([]), json.Int(100)],
    fn(value) {
      let world =
        summary(operation.Bounded(2))
        |> summary_failure(cap(value))
        |> summary_retry(2)
      let world = summary_failure(world, None)
      assert scenario.read_op_state(world.store, world.op.id)
        == Error("op.state absent")
    },
  )
}
