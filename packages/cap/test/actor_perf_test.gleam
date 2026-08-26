//// Perf smoke for `cap/actor`'s bounded queue (issue #45). A correctness
//// test cannot show a complexity regression — `handle_admit`'s
//// `list.length(state.queue) < state.bound` beside `list.append` made
//// filling a bounded queue to its bound cost O(bound²), and every unit
//// test stayed green while that was true (the same shape as `08cdbce`).
//// So this times the thing that regressed: admitting a burst of
//// concurrent sends into a queue near its bound.
////
//// The burst is engineered rather than hoped for. A single sequential
//// sender can never build up more than one admitted-but-undrained item,
//// because `send` blocks for its ack and the ack lands as soon as the
//// item is admitted — well before it is drained. So the handler stalls
//// on the very first item it drains (`process.sleep`), which blocks the
//// whole actor (handling is synchronous on its one process) while many
//// senders queue their `Admit` messages behind it. Once the stall lifts,
//// the actor works through that backlog back-to-back — exactly the
//// "many processes pushing at once" scenario the module's own docs cite
//// as what a bounded mailbox exists to survive, and exactly where the
//// old per-admit cost stacked up.

import cap/actor
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import support/internal/ffi_time

type Msg {
  Push(index: Int)
}

// Stalls only while draining the first item, giving every concurrently
// spawned sender time to land its `Admit` in the actor's real mailbox
// before draining resumes. `count` is how many items have been drained.
fn stall_first_drain(settle_ms: Int) -> fn(Int, Msg) -> actor.Next(Int) {
  fn(count, _msg) {
    case count {
      0 -> process.sleep(settle_ms)
      _ -> Nil
    }
    actor.continue(count + 1)
  }
}

// Blocks until `remaining` more `Nil`s have arrived on `subject`, one per
// admitted send. A per-message receive timeout rather than one overall
// deadline: the burst itself should be fast, but the surrounding spawn of
// thousands of sender processes is real scheduling and deserves room.
fn await_admits(subject: Subject(Nil), remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False ->
      case process.receive(subject, 4000) {
        Ok(Nil) -> await_admits(subject, remaining - 1)
        Error(Nil) ->
          panic as "timed out waiting for the queue to admit its burst"
      }
  }
}

// The ceiling a correct, linear admission path clears with room to
// spare, and a reverted, quadratic one blows through — see the mutation
// proof recorded in the commit/PR description this test ships with.
const admit_ceiling_us = 1_500_000

pub fn actor_admits_bounded_queue_in_linear_time_test() {
  let bound = 20_000
  let settle_ms = 800

  let assert Ok(address) =
    actor.spawn_bounded(0, bound, stall_first_drain(settle_ms))

  // Prime the stall: one send that gets admitted immediately (the queue
  // starts empty) and is then the item every other sender's burst piles
  // up behind while it drains.
  actor.send(address, Push(0))

  let done = process.new_subject()
  list.index_map(list.repeat(Nil, times: bound), fn(_nil, index) {
    let _pid =
      process.spawn_unlinked(fn() {
        actor.send(address, Push(index))
        process.send(done, Nil)
      })
    Nil
  })

  let started = ffi_time.now_us()
  await_admits(done, bound)
  let elapsed_us = ffi_time.now_us() - started

  io.println(
    "perf smoke [cap/actor]: admitting "
    <> int.to_string(bound)
    <> " concurrent sends to a bound-"
    <> int.to_string(bound)
    <> " queue took "
    <> int.to_string(elapsed_us / 1000)
    <> " ms (asserted ceiling: "
    <> int.to_string(admit_ceiling_us / 1000)
    <> " ms)",
  )
  // Asserted, not merely printed: a check that cannot fail is not a
  // check. A quadratic admission path — the pre-fix shape — multiplies
  // this by the bound itself and blows past the ceiling by orders of
  // magnitude rather than by a little.
  assert elapsed_us < admit_ceiling_us
    as {
      "admitting "
      <> int.to_string(bound)
      <> " sends regressed to "
      <> int.to_string(elapsed_us / 1000)
      <> " ms, past the "
      <> int.to_string(admit_ceiling_us / 1000)
      <> " ms ceiling — admission cost looks quadratic in the bound again"
    }

  actor.shutdown(address)
}
