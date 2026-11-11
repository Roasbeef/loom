//// The result wait backs off: a long wait probes the session store a few
//// times a second instead of a hundred.
////
//// The wait runs on a virtual clock, so a simulated minute costs no wall
//// time and every sleep the loop asks for is recorded. The probe count is
//// read off those sleeps, because every miss is followed by exactly one
//// sleep and the attempt after the last sleep is the one made at the
//// deadline: attempts are sleeps plus one.
////
//// The result is planted by the clock itself, when a sleep carries virtual
//// time to the moment the test names, which is what lets one wait observe
//// a result that lands early, late, or exactly at the deadline.

import core/clock
import core/ids.{type OpId}
import core/register
import core/tx
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import machine/codec
import machine/operation
import runtime/api
import session/session.{type Session}
import storage/storage
import weft/poll

type Message {
  Now(reply: Subject(Int))
  Sleep(ms: Int, reply: Subject(Nil))
  Sleeps(reply: Subject(List(Int)))
}

type Virtual {
  Virtual(now: Int, sleeps: List(Int), plant_at: Int, plant: fn() -> Nil)
}

fn handle(state: Virtual, message: Message) -> actor.Next(Virtual, Message) {
  case message {
    Now(reply:) -> {
      process.send(reply, state.now)
      actor.continue(state)
    }

    Sleep(ms:, reply:) -> {
      let now = state.now + ms
      let due = state.plant_at >= 0 && now >= state.plant_at
      case due {
        True -> state.plant()
        False -> Nil
      }
      process.send(reply, Nil)
      actor.continue(
        Virtual(
          ..state,
          now:,
          sleeps: [ms, ..state.sleeps],
          plant_at: case due {
            True -> -1
            False -> state.plant_at
          },
        ),
      )
    }

    Sleeps(reply:) -> {
      process.send(reply, list.reverse(state.sleeps))
      actor.continue(state)
    }
  }
}

type Rig {
  Rig(
    clock: poll.Clock,
    sleeps: fn() -> List(Int),
    store: Session,
    op: OpId,
    plant: fn() -> Nil,
  )
}

// A wait whose result lands once virtual time reaches `plant_at`, or never
// when it is -1.
fn rig(plant_at: Int) -> Rig {
  let assert Ok(store) = session.open_memory(clock.fixed(1000))
    as "the fixture session opens"
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(1000), seed: 7))

  let plant = fn() {
    let assert Ok(_) =
      storage.commit(
        store.store,
        tx.Tx(
          writes: [
            tx.SetRegister(
              register.FactCustom,
              operation.result_fact_key(op),
              register.RegisterValue(
                codec.encode_last_result(operation.RunLastResult(
                  operation: op,
                  leaf: None,
                  outcome: operation.RunCompleted(
                    completion: operation.CompletedByAssistant,
                  ),
                  final_assistant: None,
                )),
              ),
            ),
          ],
          expected: [],
        ),
      )
      as "the result fact commits"
    Nil
  }

  let assert Ok(started) =
    actor.new(Virtual(now: 0, sleeps: [], plant_at:, plant:))
    |> actor.on_message(handle)
    |> actor.start
    as "the virtual clock must start"
  let subject = started.data

  Rig(
    clock: poll.Clock(
      now: fn() { process.call_forever(subject, Now) },
      sleep: fn(ms) { process.call_forever(subject, Sleep(ms, _)) },
    ),
    sleeps: fn() { process.call_forever(subject, Sleeps) },
    store:,
    op:,
    plant:,
  )
}

fn wait(rig: Rig, within: Int) -> Bool {
  case
    api.await_stored_result_on(
      rig.clock,
      rig.store,
      "main",
      rig.op,
      within_ms: within,
    )
  {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

fn attempts(rig: Rig) -> Int {
  list.length(rig.sleeps()) + 1
}

pub fn the_schedule_doubles_to_its_cap_and_stays_test() {
  let rig = rig(-1)
  assert !wait(rig, 2000)

  // Every gap but the last is the schedule itself; the last is clipped to
  // the budget that remained, so it may be shorter than its place in the
  // sequence.
  let gaps = rig.sleeps()
  let schedule = list.take(gaps, list.length(gaps) - 1)
  assert list.take(schedule, 8) == [10, 20, 40, 80, 160, 250, 250, 250]
  assert list.all(schedule, fn(gap) { gap <= 250 })
  assert schedule == list.sort(schedule, by: int.compare)
}

pub fn a_result_that_is_already_there_is_found_without_sleeping_test() {
  let rig = rig(-1)
  rig.plant()
  assert wait(rig, 5000)
  assert rig.sleeps() == []
}

pub fn an_early_result_costs_at_most_the_old_latency_test() {
  // Lands during the first 10 ms gap, so the second attempt finds it: the
  // latency is the fixed poll's own.
  let rig = rig(5)
  assert wait(rig, 5000)
  assert rig.sleeps() == [10]
}

pub fn a_late_result_is_found_within_one_capped_interval_test() {
  let rig = rig(30_001)
  assert wait(rig, 60_000)
  let landed = 30_001
  let found_at = list.fold(rig.sleeps(), 0, fn(total, gap) { total + gap })
  assert found_at >= landed
  assert found_at - landed < 250
}

pub fn a_result_at_the_deadline_is_found_test() {
  // The planting sleep is the one clipped to the budget, and the attempt
  // after it is the final attempt at the deadline.
  let rig = rig(4000)
  assert wait(rig, 4000)
  assert list.fold(rig.sleeps(), 0, fn(total, gap) { total + gap }) == 4000
}

pub fn no_result_times_out_at_the_budget_test() {
  let rig = rig(-1)
  assert !wait(rig, 4000)
  assert list.fold(rig.sleeps(), 0, fn(total, gap) { total + gap }) == 4000
}

pub fn a_simulated_minute_probes_a_few_hundred_times_not_six_thousand_test() {
  let rig = rig(-1)
  assert !wait(rig, 60_000)
  let count = attempts(rig)
  assert count >= 240
  assert count <= 260
}
