//// The holds: what each stage may not touch, and when the search stops.

import gepa/budget.{Costs, Design, Limits}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import qcheck

fn costs() -> qcheck.Generator(budget.Costs) {
  use trial <- qcheck.bind(qcheck.bounded_float(0.0, 2.0))
  use attempts <- qcheck.bind(qcheck.bounded_int(1, 4))
  use reflection <- qcheck.map(qcheck.bounded_float(0.0, 3.0))
  Costs(trial:, attempts:, reflection:)
}

fn design() -> qcheck.Generator(budget.Design) {
  use validate_tasks <- qcheck.bind(qcheck.bounded_int(1, 12))
  use minibatch_tasks <- qcheck.bind(qcheck.bounded_int(1, 6))
  use trials <- qcheck.bind(qcheck.bounded_int(1, 4))
  use tune_trials <- qcheck.bind(qcheck.bounded_int(1, 3))
  use proposals <- qcheck.map(qcheck.bounded_int(1, 4))
  Design(validate_tasks:, minibatch_tasks:, trials:, tune_trials:, proposals:)
}

fn close(left: Float, right: Float) -> Bool {
  float.absolute_value(left -. right) <. 1.0e-9
}

pub fn the_hold_only_shrinks_as_the_step_advances_and_never_below_the_confirm_test() {
  use #(costs, design) <- qcheck.given(qcheck.tuple2(costs(), design()))
  let confirm = budget.confirm_worst_case(costs, design)
  let n = design.proposals
  let first = budget.held_back(costs, design, budget.BeforeParentMinibatch)
  let reflections =
    list.map(counting(1, n), fn(i) {
      budget.held_back(costs, design, budget.BeforeReflection(i))
    })
  let minibatches =
    list.map(list.reverse(counting(0, n - 1)), fn(later) {
      budget.held_back(costs, design, budget.BeforeChildMinibatch(later))
    })
  let last = budget.held_back(costs, design, budget.BeforeValidate)

  // The walk through a step's stages never raises the hold, and the first
  // reflection's hold is the parent minibatch's: nothing is owed between
  // them.
  let walk = list.flatten([[first], reflections, minibatches, [last]])
  assert list.window_by_2(walk)
    |> list.all(fn(pair) { pair.0 >=. pair.1 })
  assert close(first, list.first(reflections) |> result.unwrap(0.0))
  assert close(last, confirm)
  assert confirm
    == budget.cell_worst_case(costs)
    *. float_of(2 * design.validate_tasks * design.trials)
}

pub fn the_step_worst_case_is_the_sum_of_its_stages_test() {
  use #(costs, design) <- qcheck.given(qcheck.tuple2(costs(), design()))
  let cell = budget.cell_worst_case(costs)
  let minibatch = float_of(design.minibatch_tasks * design.tune_trials) *. cell
  let validate = float_of(design.validate_tasks * design.trials) *. cell
  let n = float_of(design.proposals)

  assert close(
    budget.step_worst_case(costs, design),
    minibatch +. n *. { costs.reflection +. minibatch } +. validate,
  )
  assert close(
    budget.cell_worst_case(costs),
    costs.trial *. float_of(costs.attempts),
  )
}

pub fn the_search_stops_for_the_counted_ceilings_before_the_budget_test() {
  let costs = Costs(trial: 1.0, attempts: 1, reflection: 1.0)
  let design =
    Design(
      validate_tasks: 2,
      minibatch_tasks: 1,
      trials: 1,
      tune_trials: 1,
      proposals: 1,
    )
  let limits =
    Limits(budget: 100.0, max_steps: 3, max_reflections: 5, max_candidates: 5)
  let counts = budget.Counts(steps: 0, reflections: 0, candidates: 0)

  assert budget.stop_reason(limits, counts, 100.0, costs, design) == None
  assert budget.stop_reason(
      limits,
      budget.Counts(..counts, steps: 3),
      100.0,
      costs,
      design,
    )
    == Some(budget.Steps)
  assert budget.stop_reason(
      limits,
      budget.Counts(..counts, reflections: 5),
      100.0,
      costs,
      design,
    )
    == Some(budget.Reflections)
  assert budget.stop_reason(
      limits,
      budget.Counts(..counts, candidates: 5),
      100.0,
      costs,
      design,
    )
    == Some(budget.Candidates)

  // One step costs 2 * 1 + 2 + 1 = 5 and the confirm 4: nine is enough,
  // a hair less is not.
  assert budget.stop_reason(limits, counts, 9.0, costs, design) == None
  assert budget.stop_reason(limits, counts, 8.999, costs, design)
    == Some(budget.Budget)

  // Admission is strict where the two reservation questions are not: a
  // hair under the step's need is a budget stop, a hair under the confirm
  // or the reflection is still covered.
  let hair = 9.0 -. 1.0e-12
  assert budget.stop_reason(limits, counts, hair, costs, design)
    == Some(budget.Budget)
  assert budget.confirm_affordable(remaining: 4.0 -. 1.0e-12, costs:, design:)
  // The reflection's hold is the whole of the rest of the step: 1 + 1 + 2 + 4.
  assert budget.reflection_affordable(
    remaining: 8.0 -. 1.0e-12,
    costs:,
    design:,
    proposal: 1,
  )
  assert !budget.reflection_affordable(
    remaining: 7.99,
    costs:,
    design:,
    proposal: 1,
  )
  assert !budget.confirm_affordable(remaining: 3.99, costs:, design:)
  assert budget.cap(remaining: 3.0, hold: 5.0) == 0.0
  assert budget.remaining(limits, spent: 101.0) == 0.0
  assert budget.parse_stop(budget.stop_name(budget.Candidates))
    == Ok(budget.Candidates)
}

fn float_of(value: Int) -> Float {
  int.to_float(value)
}

/// The integers from `from` to `to`, both included, ascending.
fn counting(from: Int, to: Int) -> List(Int) {
  int.range(from:, to: to + 1, with: [], run: list.prepend) |> list.reverse
}

pub fn a_step_of_several_proposals_is_held_and_counted_whole_test() {
  let costs = Costs(trial: 1.0, attempts: 1, reflection: 1.0)
  let design =
    Design(
      validate_tasks: 2,
      minibatch_tasks: 1,
      trials: 1,
      tune_trials: 1,
      proposals: 3,
    )
  let limits =
    Limits(budget: 100.0, max_steps: 9, max_reflections: 5, max_candidates: 5)
  let counts = budget.Counts(steps: 0, reflections: 0, candidates: 0)

  // One step is the parent's minibatch, three reflections, three child
  // minibatches and the validate run: 1 + 3 + 3 + 2 = 9; the confirm is 4.
  assert budget.step_worst_case(costs, design) == 9.0
  assert budget.stop_reason(limits, counts, 13.0, costs, design) == None
  assert budget.stop_reason(limits, counts, 12.999, costs, design)
    == Some(budget.Budget)

  // The holds: before the parent's minibatch everything after it, before
  // reflection two the two reflections left and all three minibatches,
  // before the second child's minibatch the one after it and validate.
  assert budget.held_back(costs, design, budget.BeforeParentMinibatch) == 12.0
  assert budget.held_back(costs, design, budget.BeforeReflection(1)) == 12.0
  assert budget.held_back(costs, design, budget.BeforeReflection(2)) == 11.0
  assert budget.held_back(costs, design, budget.BeforeReflection(3)) == 10.0
  assert budget.held_back(costs, design, budget.BeforeChildMinibatch(2)) == 8.0
  assert budget.held_back(costs, design, budget.BeforeChildMinibatch(1)) == 7.0
  assert budget.held_back(costs, design, budget.BeforeChildMinibatch(0)) == 6.0
  assert budget.reflection_affordable(
    remaining: 10.0,
    costs:,
    design:,
    proposal: 3,
  )
  assert !budget.reflection_affordable(
    remaining: 10.0,
    costs:,
    design:,
    proposal: 2,
  )

  // The ceilings are read against the whole step: three reflections made
  // leave room for two, not three; four children minted leave room for
  // one.
  assert budget.stop_reason(
      limits,
      budget.Counts(..counts, reflections: 2),
      100.0,
      costs,
      design,
    )
    == None
  assert budget.stop_reason(
      limits,
      budget.Counts(..counts, reflections: 3),
      100.0,
      costs,
      design,
    )
    == Some(budget.Reflections)
  assert budget.stop_reason(
      limits,
      budget.Counts(..counts, candidates: 4),
      100.0,
      costs,
      design,
    )
    == Some(budget.Candidates)
}
