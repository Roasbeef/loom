//// The host loop `README.md` shows, compiled and run, so the example
//// cannot rot: the README's code block is this module's `run` and `step`
//// verbatim, with the two host functions a reader supplies spelt out as
//// the simplest things they could be.

import gepa
import gepa/budget
import gepa/judge
import gepa/log
import gepa/prompt
import gepa/verdict
import gleam/list
import gleam/option.{Some}
import gleam/string

// --- the README's loop, verbatim ------------------------------------------------------

fn run(state: gepa.State, config: gepa.Config, events: List(gepa.Event)) {
  let assert Ok(request) = gepa.next(state, config)

  case request {
    gepa.Done -> #(state, events)

    // The search decided something that needs no effect: apply it.
    gepa.Record(event:) -> step(state, config, events, event)

    // Evaluate `candidate` on `tasks`, spending at most `cap`; for the
    // `Confirm` stage evaluate `state.seed` alongside and measure both.
    gepa.Evaluate(stage:, step: at, candidate:, tasks:, trials:, cap:) -> {
      let #(measured, cost) =
        my_evaluate(state, candidate, stage, tasks, trials, cap)
      step(
        state,
        config,
        events,
        gepa.Evaluated(
          stage:,
          step: at,
          candidate:,
          tasks:,
          cap:,
          ref: "my-run-id",
          measured:,
          cost:,
        ),
      )
    }

    // Show the model the prompt, record the call, then admit the answer.
    gepa.Reflect(step: at, slot:, request:, worst_case:, ..) -> {
      let #(text, cost) = my_model(prompt.render(request), worst_case)
      let reflected =
        gepa.Reflected(step: at, cost:, ref: "", finish: gepa.Unknown)
      let assert Ok(state) = gepa.apply(state, reflected)
      let events = list.append(events, [reflected])
      let assert Ok(minted) =
        gepa.admit(state, slot, prompt.answer(text), gepa.content_id)
      step(state, config, events, minted)
    }
  }
}

fn step(
  state: gepa.State,
  config: gepa.Config,
  events: List(gepa.Event),
  event: gepa.Event,
) {
  let assert Ok(state) = gepa.apply(state, event)
  // Persist `log.encode(event)` here: the log is the state.
  run(state, config, list.append(events, [event]))
}

// --- the two things the host supplies -------------------------------------------------

/// A candidate scores one on every task when any component says
/// "better", else zero; a run costs its worst case.
fn my_evaluate(
  state: gepa.State,
  candidate: String,
  stage: gepa.Stage,
  tasks: List(String),
  trials: Int,
  cap: Float,
) -> #(List(gepa.Measured), Float) {
  let both = case stage {
    gepa.Confirm -> [state.seed, candidate]
    _ -> [candidate]
  }
  let measured =
    list.map(both, fn(id) {
      let assert Ok(member) =
        list.find(state.members, fn(m) { m.candidate == id })
      let value = case
        list.any(member.components, fn(c) { string.contains(c.1, "better") })
      {
        True -> 1.0
        False -> 0.0
      }
      gepa.Measured(
        id,
        list.map(tasks, fn(task) { gepa.Score(task, value, "ran") }),
      )
    })
  let worst = 0.5 *. int_float(list.length(tasks) * trials * list.length(both))

  #(measured, float_min(cap, worst))
}

/// A model that always proposes the same improvement, at its worst case.
fn my_model(_prompt: String, worst_case: Float) -> #(String, Float) {
  #("be better", worst_case)
}

fn int_float(value: Int) -> Float {
  list.fold(list.repeat(1.0, value), 0.0, fn(a, b) { a +. b })
}

fn float_min(a: Float, b: Float) -> Float {
  case a <. b {
    True -> a
    False -> b
  }
}

// --- the test ------------------------------------------------------------------------------

pub fn the_readme_loop_runs_a_search_and_writes_a_replayable_log_test() {
  let config =
    gepa.Config(
      id: "readme",
      objective: "be better",
      tune: ["u1", "u2", "u3"],
      validate: ["v1", "v2", "v3", "v4", "v5", "v6"],
      k: 1,
      k_tune: 1,
      minibatch: 2,
      slots: ["system"],
      hidden: [],
      limits: budget.Limits(
        budget: 1000.0,
        max_steps: 1,
        max_reflections: 3,
        max_candidates: 3,
      ),
      costs: budget.Costs(trial: 0.5, attempts: 1, reflection: 1.0),
      judge: judge.sign_test,
    )
  let seeded = gepa.Seeded("seed", [#("system", "plain")])
  let #(state, events) =
    run(gepa.start("seed", [#("system", "plain")]), config, [seeded])

  // The loop found and confirmed the improvement, and every row it applied
  // was the one the search asked for, Reflected included.
  assert state.stopped == Some(budget.Steps)
  let assert Some(gepa.Confirmation(acceptance: Some(verdict.Improved), ..)) =
    state.confirmation
  assert list.any(events, fn(event) {
    case event {
      gepa.Reflected(..) -> True
      _ -> False
    }
  })
  assert gepa.replay_checked(events, config) == Ok(state)
  let assert Ok(parsed) = log.parse(log.render(events))
  assert gepa.replay_checked(parsed, config) == Ok(state)
}
