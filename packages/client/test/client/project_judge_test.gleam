//// The fan-out of a live verdict, run over a decision function the test writes.
////
//// The session that backs a decision in the daemon is tested beside the real
//// project actor. These tests are about what the fan-out does with whatever
//// decides: the order of its samples, the sum of its spend, what a failure
//// cancels, and what a wall limit leaves.

import client/project_judge.{
  type Limits, type Spend, Decision, Failure, Judge, Limits, Spend,
}
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import project/gate
import project/judge
import project/model
import project/tape

fn frame(id: String) -> tape.Frame {
  tape.Frame(
    trigger: model.Trigger(
      id: model.TriggerId(id),
      source: model.SourceId("github"),
      thread: model.ThreadId("th-" <> id),
      actor: model.ActorId("alice"),
      inputs: model.Inputs(
        sender: model.Unlisted,
        addressing: model.Unaddressed,
        rule: None,
      ),
      generation: 0,
      at_ms: 1000,
    ),
    text: "text of " <> id,
    relation: gate.UnrelatedThread,
    thread: [],
    recorded: tape.Declined,
  )
}

fn work(count: Int) -> List(#(tape.Frame, model.Label)) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, position) {
    let label = case position < 2 {
      True -> model.ShouldAccept
      False -> model.ShouldNotAccept
    }
    #(frame("t" <> string.inspect(position)), label)
  })
}

fn limits() -> Limits {
  Limits(concurrency: 3, wall_ms: 20_000)
}

pub fn a_complete_run_gives_samples_in_trigger_order_and_sums_its_spend_test() {
  let judged =
    Judge(
      decide: fn(found, index, _custody) {
        // The first trial of the first trigger is left unrouted.
        let unrouted = found.trigger.id.value == "t0" && index == 0
        Ok(Decision(
          choice: judge.Take,
          routing: case unrouted {
            True -> project_judge.Unrouted
            False -> project_judge.Routed
          },
          spend: Spend(calls: 1, tokens: 10 + index),
        ))
      },
      limits: limits(),
    )
  let progress = process.new_subject()
  let assert Ok(measured) =
    project_judge.measure(work(4), judged, 3, fn(spent) {
      process.send(progress, spent)
    })
  assert list.map(measured.samples, fn(each) { each.trigger.value })
    == ["t0", "t1", "t2", "t3"]
  assert list.all(measured.samples, fn(each) {
    list.length(each.candidate) == 3
  })
  assert measured.spend == Spend(calls: 12, tokens: 12 * 10 + 4 * { 0 + 1 + 2 })
  assert measured.unrouted == 1

  // Every trial reported its spend as it ended.
  assert list.length(drain(progress)) == 12
}

fn drain(inbox: process.Subject(Spend)) -> List(Spend) {
  case process.receive(inbox, 50) {
    Ok(one) -> [one, ..drain(inbox)]
    Error(Nil) -> []
  }
}

pub fn the_first_failure_ends_the_run_and_the_trials_still_to_come_never_start_test() {
  let started = process.new_subject()
  let judged =
    Judge(
      decide: fn(found, _index, _custody) {
        process.send(started, found.trigger.id.value)
        case found.trigger.id.value {
          "t0" ->
            Error(Failure("the model refused", Spend(calls: 1, tokens: 5)))
          _ -> {
            process.sleep(2000)
            Ok(Decision(
              judge.Take,
              project_judge.Routed,
              project_judge.no_spend,
            ))
          }
        }
      },
      limits: Limits(concurrency: 1, wall_ms: 20_000),
    )
  let progress = process.new_subject()
  let assert Error(words) =
    project_judge.measure(work(10), judged, 3, fn(spent) {
      process.send(progress, spent)
    })
  assert string.contains(words, "the model refused")
  assert string.contains(words, "0 of 30 trials done")
  assert string.contains(words, "records no verdict")

  // With one trial at a time the failing trial was the first, so nothing else
  // began, and its spend was still reported.
  assert list.length(drain_names(started)) == 1
  assert drain(progress) == [Spend(calls: 1, tokens: 5)]
}

fn drain_names(inbox: process.Subject(String)) -> List(String) {
  case process.receive(inbox, 50) {
    Ok(one) -> [one, ..drain_names(inbox)]
    Error(Nil) -> []
  }
}

pub fn a_run_past_its_wall_limit_is_cut_off_and_says_how_far_it_got_test() {
  let judged =
    Judge(
      decide: fn(found, _index, _custody) {
        // Only the first trigger answers in time.
        case found.trigger.id.value {
          "t0" ->
            Ok(Decision(
              judge.Take,
              project_judge.Routed,
              project_judge.no_spend,
            ))
          _ -> {
            process.sleep(10_000)
            Ok(Decision(
              judge.Take,
              project_judge.Routed,
              project_judge.no_spend,
            ))
          }
        }
      },
      limits: Limits(concurrency: 4, wall_ms: 1000),
    )
  let assert Error(words) =
    project_judge.measure(work(3), judged, 2, fn(_) { Nil })
  assert string.contains(words, "wall limit of 1 seconds")
  assert string.contains(words, "2 of 6 trials done")
  assert string.contains(words, "records no verdict")
}
