//// The holds: what each stage may not touch, and when the search stops.

import gepa/budget.{Costs, Design, Limits}
import gleam/float
import gleam/int
import gleam/option.{None, Some}
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
  use tune_trials <- qcheck.map(qcheck.bounded_int(1, 3))
  Design(validate_tasks:, minibatch_tasks:, trials:, tune_trials:)
}

fn close(left: Float, right: Float) -> Bool {
  float.absolute_value(left -. right) <. 1.0e-9
}

pub fn the_hold_only_shrinks_as_the_step_advances_and_never_below_the_confirm_test() {
  use #(costs, design) <- qcheck.given(qcheck.tuple2(costs(), design()))
  let confirm = budget.confirm_worst_case(costs, design)
  let first = budget.held_back(costs, design, budget.BeforeParentMinibatch)
  let second = budget.held_back(costs, design, budget.BeforeChildMinibatch)
  let third = budget.held_back(costs, design, budget.BeforeValidate)

  assert first >=. second && second >=. third
  assert close(third, confirm)
  assert confirm
    == budget.cell_worst_case(costs)
    *. float_of(2 * design.validate_tasks * design.trials)
}

pub fn the_step_worst_case_is_the_sum_of_its_stages_test() {
  use #(costs, design) <- qcheck.given(qcheck.tuple2(costs(), design()))
  let cell = budget.cell_worst_case(costs)
  let minibatch = float_of(design.minibatch_tasks * design.tune_trials) *. cell
  let validate = float_of(design.validate_tasks * design.trials) *. cell

  assert close(
    budget.step_worst_case(costs, design),
    2.0 *. minibatch +. validate +. costs.reflection,
  )
  assert close(
    budget.cell_worst_case(costs),
    costs.trial *. float_of(costs.attempts),
  )
}

pub fn the_search_stops_for_the_counted_ceilings_before_the_budget_test() {
  let costs = Costs(trial: 1.0, attempts: 1, reflection: 1.0)
  let design =
    Design(validate_tasks: 2, minibatch_tasks: 1, trials: 1, tune_trials: 1)
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
  assert budget.cap(remaining: 3.0, hold: 5.0) == 0.0
  assert budget.remaining(limits, spent: 101.0) == 0.0
  assert budget.parse_stop(budget.stop_name(budget.Candidates))
    == Ok(budget.Candidates)
}

fn float_of(value: Int) -> Float {
  int.to_float(value)
}
