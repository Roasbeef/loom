//// An orchestrator's calls against an executor that restarts, checked against a
//// model.
////
//// `surface_test` walks the cases of the repair by hand. This module asks
//// whether the promises hold in whatever order a session calls, repeats a call,
//// loses its executor, gets it back, or loses it again. `statem` draws
//// sequences of those commands, runs each against a real host, ledger and
//// surface in one VM, and compares what it finds with a small pure model after
//// every command.
////
//// The executor's workspace plane is the part a restart loses, so the model
//// tracks only that. The plane is `Present`, `Missing` (the executor restarted
//// and can build one) or `Unbuildable` (it restarted and cannot). The promises:
////
//// - A call never runs twice, however often it is sent and however many
////   restarts come between the sends. A resent call is answered from the
////   ledger and does not build a plane.
//// - A call after a restart runs once when the executor can build the plane,
////   and is refused with the builder's own reason when it cannot. It is never
////   refused for the missing plane, because the surface builds the plane first.
//// - Calls that meet a restart together share one build.
//// - A dead runtime, holding an old token, is refused by the fence in every
////   state, and does not build a plane or take the scope from the live runtime.
//// - A session is never stuck: after any schedule, one restart onto a healthy
////   executor makes the next call run.
////
//// The seed and the sizes are constants, so the gate is deterministic: a failure
//// names the run and the shrunk command list, and replays.

import client/remote/surface
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import qcheck
import runtime/effects
import statem
import support/remote_fixtures as fixtures
import support/restart_rig.{type Rig}

const sequence_seed = 2611

const sequence_count = 30

const sequence_length = 10

// --- the model ------------------------------------------------------------------

// What the executor's host holds for the scope's workspace.
type Plane {
  Present
  Missing
  Unbuildable
}

// `steps` numbers the calls made so far, so every call has a key of its own.
// `finished` lists the steps whose call ran, and `builds` counts the planes the
// executor built after the first one.
type Model {
  Model(plane: Plane, steps: Int, finished: List(Int), builds: Int)
}

// Whether the executor can build a plane after the restart.
type Health {
  Healthy
  Broken
}

type Command {
  // A fresh call through the live surface.
  Call
  // The same call again, chosen from the finished ones by position.
  Resend(pick: Int)
  // A call through a surface holding a token the scope has moved past.
  DeadCall
  // The executor restarts.
  Restart(Health)
  // Two calls arrive while the plane is being built.
  Burst
}

fn initial() -> Model {
  Model(plane: Present, steps: 0, finished: [], builds: 0)
}

// The model's whole transition function. Reading it beside `perform` is the
// review: each arm is what the design says the command does.
fn step(model: Model, command: Command) -> Model {
  case command {
    Call ->
      case model.plane {
        Present ->
          Model(..model, steps: model.steps + 1, finished: [
            model.steps,
            ..model.finished
          ])
        Missing ->
          Model(
            plane: Present,
            steps: model.steps + 1,
            finished: [model.steps, ..model.finished],
            builds: model.builds + 1,
          )

        // The refused call took a step number and ran nothing.
        Unbuildable -> Model(..model, steps: model.steps + 1)
      }

    Resend(_pick) -> model

    DeadCall -> Model(..model, steps: model.steps + 1)

    Restart(Healthy) -> Model(..model, plane: Missing)

    Restart(Broken) -> Model(..model, plane: Unbuildable)

    Burst ->
      Model(
        plane: Present,
        steps: model.steps + 2,
        finished: [model.steps + 1, model.steps, ..model.finished],
        builds: model.builds + 1,
      )
  }
}

fn admitted(model: Model, command: Command) -> statem.Admission {
  case command, model.finished {
    Resend(_), [] -> statem.Reject
    Burst, _ ->
      case model.plane {
        Missing -> statem.Admit
        Present | Unbuildable -> statem.Reject
      }
    _, _ -> statem.Admit
  }
}

// --- the system under test ------------------------------------------------------

// The executor, the live surface and a surface that holds the token the live one
// replaced.
type Sut {
  Sut(rig: Rig, live: surface.Surface(String), dead: surface.Surface(String))
}

fn new_sut() -> Sut {
  let rig =
    restart_rig.rig("restart_model", fixtures.Open, fixtures.AsksNothing)
  let dead = restart_rig.attached(rig, 1)
  let live = restart_rig.attached(rig, 2)
  Sut(rig:, live:, dead:)
}

// The numbers from zero up to, and not including, `n`.
fn below(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_nothing, index) { index })
}

fn call_id(step: Int) -> String {
  "call_" <> int.to_string(step)
}

fn run_of(step: Int) {
  fixtures.tool_run(call_id(step), step)
}

fn violation(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

// Runs one command and checks what the surface answered. The state is checked
// afterwards by `check`, so this judges only the answers.
fn perform(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  case command {
    Call -> {
      let run = run_of(model.steps)
      answered(sut, model, command, surface.run(sut.live, run), run)
    }

    Resend(pick:) -> {
      let steps = list.reverse(model.finished)
      let assert [chosen, ..] = list.drop(steps, pick % list.length(steps))
        as "a resend is admitted only when a call has finished"
      let run = run_of(chosen)
      case surface.run(sut.live, run) == fixtures.expected_outcome(run) {
        True -> Ok(sut)
        False ->
          violation(
            "resend",
            "a resent call was not answered with its stored outcome",
          )
      }
    }

    DeadCall -> {
      let run = run_of(model.steps)
      case surface.run(sut.dead, run) {
        effects.ToolFailed(reason:) ->
          case string.contains(reason, "newer attachment") {
            True -> Ok(sut)
            False ->
              violation("fence", "a dead runtime was refused for: " <> reason)
          }
        other ->
          violation(
            "fence",
            "a dead runtime's call was answered " <> string.inspect(other),
          )
      }
    }

    Restart(health) -> {
      let factory = case health {
        Healthy -> restart_rig.healthy(sut.rig)
        Broken -> restart_rig.broken()
      }
      Ok(Sut(..sut, rig: restart_rig.restart(sut.rig, factory)))
    }

    Burst -> burst(sut, model)
  }
}

// What a fresh call is allowed to answer in the state the model holds.
fn answered(
  sut: Sut,
  model: Model,
  command: Command,
  outcome: effects.ToolOutcome,
  run: effects.ToolRun,
) -> Result(Sut, statem.Violation) {
  case model.plane, outcome {
    Unbuildable, effects.ToolFailed(reason:) ->
      case string.contains(reason, restart_rig.broken_reason) {
        True -> Ok(sut)
        False ->
          violation(
            "refusal",
            "a call the executor cannot serve was refused for: " <> reason,
          )
      }
    Unbuildable, other ->
      violation(
        "refusal",
        "a call the executor cannot serve was answered "
          <> string.inspect(other),
      )
    Present, _ | Missing, _ ->
      case outcome == fixtures.expected_outcome(run) {
        True -> Ok(sut)
        False ->
          violation(
            "answer",
            string.inspect(command)
              <> " in plane "
              <> string.inspect(model.plane)
              <> " was answered "
              <> string.inspect(outcome),
          )
      }
  }
}

// Two calls sent from processes of their own while the plane is held in its
// build. The first repair starts the build; the second is told one is under way.
fn burst(sut: Sut, model: Model) -> Result(Sut, statem.Violation) {
  fixtures.hold_build(sut.rig.probe, "s1")
  let expected_builds = model.builds + 2
  let calls =
    list.map([model.steps, model.steps + 1], fn(step) {
      let outcome = process.new_subject()
      let _caller =
        process.spawn_unlinked(fn() {
          process.send(outcome, surface.run(sut.live, run_of(step)))
        })
      #(step, outcome)
    })
  let started =
    fixtures.eventually(fn() {
      list.length(fixtures.builds(sut.rig.probe)) == expected_builds
    })
  fixtures.release_build(sut.rig.probe, "s1")

  case started {
    False -> violation("burst", "the calls did not start a build")
    True ->
      list.try_each(calls, fn(entry) {
        let #(step, outcome) = entry
        case
          process.receive(outcome, 5000)
          == Ok(fixtures.expected_outcome(run_of(step)))
        {
          True -> Ok(Nil)
          False ->
            violation(
              "burst",
              "call " <> int.to_string(step) <> " did not complete once",
            )
        }
      })
      |> result.replace(sut)
  }
}

// Every call the model says ran has run once and no other has run, and the
// executor has built the planes the model counts.
fn check(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(
    list.try_each(below(model.steps), fn(step) {
      let want = case list.contains(model.finished, step) {
        True -> 1
        False -> 0
      }
      let ran = fixtures.run_count(sut.rig.probe, call_id(step))
      case ran == want {
        True -> Ok(Nil)
        False ->
          violation(
            "ran-once",
            "call "
              <> int.to_string(step)
              <> " ran "
              <> int.to_string(ran)
              <> " times, the model says "
              <> int.to_string(want),
          )
      }
    }),
  )
  let built = list.length(fixtures.builds(sut.rig.probe))
  case built == model.builds + 1 {
    True -> Ok(Nil)
    False ->
      violation(
        "builds",
        "the executor built "
          <> int.to_string(built)
          <> " planes, the model says "
          <> int.to_string(model.builds + 1),
      )
  }
}

fn execute(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  use next <- result.try(perform(sut, model, command))
  use Nil <- result.map(check(next, step(model, command)))
  next
}

// A session is never stuck: whatever happened, one restart onto a healthy
// executor makes its next call run.
fn finish(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  let healed = restart_rig.restart(sut.rig, restart_rig.healthy(sut.rig))
  let run = run_of(model.steps)
  let outcome = surface.run(sut.live, run)
  restart_rig.stop(healed)

  case outcome == fixtures.expected_outcome(run) {
    True -> Ok(Nil)
    False ->
      violation(
        "stuck",
        "the call after a healthy restart did not run, from model "
          <> string.inspect(model),
      )
  }
}

fn commands() -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(#(5, qcheck.return(Call)), [
    #(3, qcheck.map(qcheck.bounded_int(from: 0, to: 7), fn(n) { Resend(n) })),
    #(2, qcheck.return(DeadCall)),
    #(3, qcheck.return(Restart(Healthy))),
    #(1, qcheck.return(Restart(Broken))),
    #(2, qcheck.return(Burst)),
  ])
}

fn lifecycle() -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: initial(),
    command: fn(_model) { commands() },
    precondition: admitted,
    next_model: step,
    new_sut: new_sut,
    execute:,
    finish:,
    teardown: fn(sut) {
      restart_rig.stop(sut.rig)
      Nil
    },
  )
}

pub fn any_order_of_calls_resends_and_restarts_keeps_every_promise_test() {
  let config =
    statem.default_config(seed: sequence_seed)
    |> statem.with_test_count(sequence_count)
    |> statem.with_max_commands(sequence_length)
  case statem.check(lifecycle(), config) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

// A property that never reaches a state proves nothing about it, so the model
// is replayed over the generated lists and must visit the states the promises
// are about.
pub fn the_generated_sequences_reach_the_states_the_promises_are_about_test() {
  let config =
    statem.default_config(seed: sequence_seed)
    |> statem.with_test_count(sequence_count)
    |> statem.with_max_commands(sequence_length)
  let spec = lifecycle()
  let visited =
    below(sequence_count)
    |> list.flat_map(fn(run) {
      let #(_, seen) =
        list.map_fold(
          statem.commands(spec, config, run),
          spec.initial,
          fn(model, command) {
            let next = step(model, command)
            #(next, #(command, model, next))
          },
        )
      seen
    })
  assert list.any(visited, fn(each) {
    let #(command, before, _after) = each
    command == Call && before.plane == Missing
  })
    as "some call is the first after a restart"
  assert list.any(visited, fn(each) {
    let #(command, before, _after) = each
    command == Call && before.plane == Unbuildable
  })
    as "some call meets an executor that cannot build"
  assert list.any(visited, fn(each) {
    let #(command, before, _after) = each
    case command {
      Resend(_) -> before.plane == Missing
      _ -> False
    }
  })
    as "some call is resent before the plane is back"
  assert list.any(visited, fn(each) {
    let #(command, _before, _after) = each
    command == Burst
  })
    as "some calls meet the build together"
  assert list.any(visited, fn(each) {
    let #(command, before, _after) = each
    command == DeadCall && before.plane == Missing
  })
    as "some dead runtime calls an executor with no plane"
  assert list.any(visited, fn(each) {
    let #(command, before, _after) = each
    command == Restart(Healthy) && before.plane == Unbuildable
  })
    as "some broken executor is restarted healthy"
}
