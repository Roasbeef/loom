//// The loop as a host runs it: the planted improvement is found and
//// confirmed, and over random designs and budgets the search never spends
//// past its budget, always pays for the confirm run it owes, replays to
//// the state it ended in, and resumes from any prefix of its log to the
//// same log.

import gepa
import gepa/budget.{Costs, Limits}
import gepa/judge
import gepa/log
import gepa/verdict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import qcheck
import support/world

fn tasks(prefix: String, count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, i) {
    prefix <> int.to_string(i)
  })
}

fn config() -> gepa.Config {
  gepa.Config(
    id: "search",
    objective: "be better",
    tune: tasks("u", 4),
    validate: tasks("v", 6),
    k: 2,
    k_tune: 1,
    minibatch: 2,
    slots: ["a", "b"],
    hidden: [],
    limits: Limits(
      budget: 1000.0,
      max_steps: 2,
      max_reflections: 5,
      max_candidates: 5,
    ),
    costs: Costs(trial: 1.0, attempts: 2, reflection: 1.0),
    judge: judge.sign_test,
  )
}

pub fn the_planted_improvement_is_found_and_confirmed_test() {
  let #(state, events) = world.search(config(), world.planted())

  assert state.stopped == Some(budget.Steps)
  assert state.step == 2
  assert gepa.children(state) == 2
  let assert Some(gepa.Confirmation(
    best:,
    acceptance: Some(verdict.Improved),
    ..,
  )) = state.confirmation
  assert best != "seed" && state.incumbent == best

  // Step 1 minted the planted child and it became the incumbent; step 2's
  // child changed nothing and was not shown better, so it joined the
  // Pareto tier at most.
  let dispositions =
    list.filter_map(events, fn(event) {
      case event {
        gepa.Judged(disposition:, basis: verdict.OnValidate, ..) ->
          Ok(disposition)
        _ -> Error(Nil)
      }
    })
  let assert [verdict.Incumbent, ..] = dispositions
  assert gepa.replay(events) == Ok(state)
  assert log.parse(log.render(events)) == Ok(events)
}

pub fn the_seed_is_validated_first_and_a_stop_without_a_best_has_no_confirm_test() {
  let assert Ok(first) = gepa.next(gepa.start("seed", []), config())
  let assert gepa.Evaluate(
    stage: gepa.SeedValidate,
    step: 0,
    candidate: "seed",
    cap:,
    ..,
  ) = first

  // The seed's cap already holds back the confirm run: 2 * 6 * 2 * 2 = 48.
  assert cap == 1000.0 -. 48.0

  // A search allowed no steps stops at once, and with nothing to confirm.
  let none =
    gepa.Config(..config(), limits: Limits(..config().limits, max_steps: 0))
  let #(state, _) = world.search(none, world.planted())
  assert state.stopped == Some(budget.Steps)
  assert state.confirmation == None
  assert state.pool == ["seed"]
}

pub fn an_unaffordable_reflection_writes_a_zero_cost_row_and_a_refusal_test() {
  // Under the cap discipline the reflection is always covered after the
  // parent's minibatch, so the path is reached only by a host that
  // ignores its caps: cells at 0.1, one attempt, a reflection at 30. One
  // step needs 0.2 + 0.2 + 1.2 + 30 = 31.6 and the confirm 2.4; the seed's
  // run charges 36 of 71, the step is taken at 35, the parent's minibatch
  // charges 6, and 29 no longer covers the reflection.
  let dear =
    gepa.Config(
      ..config(),
      costs: Costs(trial: 0.1, attempts: 1, reflection: 30.0),
      limits: Limits(..config().limits, budget: 71.0),
    )
  let #(state, events) = world.search(dear, world.World(world.Unbounded, []))

  assert list.contains(events, gepa.Reflected(1, 0.0, "", gepa.Unknown))
  assert list.contains(
    events,
    gepa.Refused(
      1,
      None,
      "budget: the search cannot cover a reflection's worst case",
    ),
  )
  assert state.reflections == 1
  assert state.stopped == Some(budget.Budget)
  assert float.loosely_equals(gepa.spent(state), 42.0, 1.0e-9)
  assert state.confirmation == None
}

fn random_config() -> qcheck.Generator(gepa.Config) {
  use tune <- qcheck.bind(qcheck.bounded_int(1, 5))
  use validate <- qcheck.bind(qcheck.bounded_int(1, 8))
  use k <- qcheck.bind(qcheck.bounded_int(1, 3))
  use k_tune <- qcheck.bind(qcheck.bounded_int(1, 2))
  use minibatch <- qcheck.bind(qcheck.bounded_int(1, 4))
  use trial <- qcheck.bind(qcheck.bounded_float(0.1, 1.0))
  use attempts <- qcheck.bind(qcheck.bounded_int(1, 3))
  use reflection <- qcheck.bind(qcheck.bounded_float(0.0, 2.0))
  use max_steps <- qcheck.bind(qcheck.bounded_int(0, 3))
  use max_reflections <- qcheck.bind(qcheck.bounded_int(0, 4))
  use max_candidates <- qcheck.bind(qcheck.bounded_int(0, 3))
  use scale <- qcheck.map(qcheck.bounded_float(0.0, 3.5))
  let costs = Costs(trial:, attempts:, reflection:)
  let design =
    budget.Design(
      validate_tasks: validate,
      minibatch_tasks: int_min(minibatch, tune),
      trials: k,
      tune_trials: k_tune,
    )
  let unit =
    budget.step_worst_case(costs, design)
    +. budget.confirm_worst_case(costs, design)

  gepa.Config(
    id: "search",
    objective: "be better",
    tune: tasks("u", tune),
    validate: tasks("v", validate),
    k:,
    k_tune:,
    minibatch:,
    slots: ["a", "b"],
    hidden: [],
    limits: Limits(
      budget: scale *. unit,
      max_steps:,
      max_reflections:,
      max_candidates:,
    ),
    costs:,
    judge: judge.sign_test,
  )
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

fn charge() -> qcheck.Generator(world.Charge) {
  qcheck.from_generators(qcheck.return(world.WorstCase), [
    qcheck.return(world.Greedy),
  ])
}

pub fn the_search_never_spends_past_its_budget_and_always_pays_for_its_confirm_test() {
  use #(config, charge) <- qcheck.given(qcheck.tuple2(random_config(), charge()))
  let #(state, events) =
    world.search(config, world.World(charge, [#(1, "better")]))

  assert state.stopped != None
  assert gepa.spent(state) <=. config.limits.budget +. 1.0e-6

  // Every evaluation stayed within the cap it was handed.
  assert list.all(events, fn(event) {
    case event {
      gepa.Evaluated(cap:, cost:, ..) -> cost <=. cap +. 1.0e-9
      _ -> True
    }
  })

  // A best that is not the seed was always confirmed: the holds kept the
  // confirm run payable whatever the steps spent.
  case state.incumbent == state.seed, state.confirmation {
    True, None -> Nil
    False, Some(gepa.Confirmation(acceptance: Some(_), ..)) -> Nil
    _, _ -> panic as "a best that is not the seed must have been confirmed"
  }
}

pub fn the_log_replays_to_the_final_state_and_resumes_from_any_prefix_test() {
  use #(config, charge) <- qcheck.given(qcheck.tuple2(random_config(), charge()))
  let scripted = world.World(charge, [#(1, "better"), #(2, "even better")])
  let #(state, events) = world.search(config, scripted)

  assert gepa.replay(events) == Ok(state)
  let assert Ok(parsed) = log.parse(log.render(events))
  assert parsed == events

  // Cut the log after every row, replay what is left, and carry on: the
  // search ends with the same log, byte for byte.
  list.index_map(events, fn(_, i) { i + 1 })
  |> list.each(fn(length) {
    let prefix = list.take(events, length)

    // A cut right after a reflection is the one place resume is not a
    // replay: the answer was lost, so the reflection is made again and
    // charged again, and every later cap is smaller by that charge.
    // `replay_test` pins that the fold counts it; here it is skipped.
    case list.last(prefix) {
      Ok(gepa.Reflected(..)) -> Nil
      _ -> {
        let assert Ok(resumed) = gepa.replay(prefix)
        let #(again, replayed) = world.drive(resumed, prefix, config, scripted)

        assert replayed == events
        assert again == state
      }
    }
  })
}

pub fn draws_are_the_same_from_the_same_seed_test() {
  // Two searches with the same id draw the same parents and minibatches,
  // which is what makes a resumed step find the rows it wrote.
  let #(_, first) = world.search(config(), world.planted())
  let #(_, second) = world.search(config(), world.planted())
  assert first == second

  let other = gepa.Config(..config(), id: "another")
  let #(_, third) = world.search(other, world.planted())
  let minibatches = fn(events) {
    list.filter_map(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, tasks:, ..) -> Ok(tasks)
        _ -> Error(Nil)
      }
    })
  }
  assert minibatches(first) != minibatches(third)
}
