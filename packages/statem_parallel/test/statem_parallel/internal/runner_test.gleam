//// Tests for the concurrent runner, with calls that can only succeed if the
//// branches really are running at the same time.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/yielder
import statem/linearize.{type Event}
import statem_parallel/internal/runner
import support/counter
import weft/poll

/// A call that waits until `parties` calls have arrived. If the branches ran
/// one after another the first would wait forever, so this answers only when
/// they are concurrent.
fn rendezvous(tally: counter.Tally, parties: Int, cmd: Int) -> Int {
  counter.note(tally, "arrived")

  // An expired wait is not reported here: a branch that gave up returns
  // early, and the overlap assertion in the test is what notices that the
  // branches did not all meet.
  let _ =
    poll.until(within: 3000, every: 5, attempt: fn() {
      case counter.count(tally, "arrived") >= parties {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })

  cmd
}

/// More branches than any machine has schedulers, so a run whose slot limit
/// were the scheduler count would leave some branches unstarted while the
/// started ones waited for them, and time out.
const crowd = 32

pub fn branches_run_at_the_same_time_test() {
  let tally = counter.start_tally()
  let commands = yielder.range(1, crowd) |> yielder.to_list

  let assert Ok(histories) =
    runner.race(
      fn(_, cmd) { rendezvous(tally, crowd, cmd) },
      Nil,
      list.map(commands, fn(cmd) { [cmd] }),
      10_000,
    )

  assert list.map(histories, fn(events) {
      list.map(events, fn(e) { e.response })
    })
    == list.map(commands, fn(cmd) { [cmd] })

  // Everyone arrived before anyone left, so every call overlapped every
  // other: each returned no earlier than the last one was invoked.
  let events = list.flatten(histories)
  let assert Ok(latest_start) =
    events
    |> list.map(fn(event) { event.invoked_at })
    |> list.reduce(int.max)

  assert list.all(events, fn(event) { event.returned_at >= latest_start })
}

pub fn a_branchs_events_are_in_order_with_ordered_instants_test() {
  let assert Ok([events]) =
    runner.race(fn(_, cmd) { cmd * 10 }, Nil, [[1, 2, 3]], 5000)

  assert list.map(events, fn(event: Event(Int, Int)) { event.response })
    == [10, 20, 30]
  assert list.all(events, fn(event) { event.invoked_at <= event.returned_at })

  let assert [first, second, third] = events

  assert first.returned_at <= second.invoked_at
  assert second.returned_at <= third.invoked_at
}

pub fn no_branches_is_no_histories_test() {
  assert runner.race(fn(_, cmd) { cmd }, Nil, [], 100) == Ok([])
}

pub fn a_branch_past_the_deadline_is_a_timeout_and_is_killed_test() {
  let tally = counter.start_tally()

  let assert Error(violation) =
    runner.race(
      fn(_, cmd) {
        process.sleep(400)
        counter.note(tally, "finished")
        cmd
      },
      Nil,
      [[1], [2]],
      100,
    )

  assert violation.tag == runner.timeout_tag

  // The calls would have finished at 400 ms. Had the run left its workers
  // alive they would have noted by now.
  process.sleep(700)

  assert counter.count(tally, "finished") == 0
}

pub fn a_crash_is_reported_and_outranks_a_sibling_timeout_test() {
  let assert Error(violation) =
    runner.race(
      fn(_, cmd) {
        case cmd {
          1 -> {
            process.sleep(5000)
            cmd
          }

          _ -> panic as "this branch crashed"
        }
      },
      Nil,
      [[1], [2]],
      300,
    )

  assert violation.tag == "statem.crash"
}
