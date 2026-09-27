//// The wake schedule a socket keeps for a reader that sleeps between polls.
////
//// `websocket.pace` decides, for one delivery at one instant, whether the
//// reader is woken now, woken once at the end of the current interval, or
//// already covered by a wake scheduled for it. The socket actor applies it
//// after every message it files and arms one timer when it asks to. These
//// tests replay generated delivery schedules through the same decision and
//// the timer it arms, on a clock the test owns, and check the contract the
//// terminal relies on: every delivery is followed by a wake no later than
//// one interval after it, and no two wakes are closer than one interval, so
//// a burst wakes the reader about once per interval rather than once per
//// frame.

import gleam/list
import gleam/option.{type Option, None, Some}
import host/websocket

const interval = 16

/// What the replay saw: when each delivery landed and when each wake went.
type Trace {
  Trace(deliveries: List(Int), wakes: List(Int))
}

// Replays deliveries at the given instants, oldest first. A scheduled wake
// fires at its instant, before any delivery that lands at or after it, as
// the actor's timer message would be read before a later frame.
fn replay(instants: List(Int)) -> Trace {
  let #(pacing, due, trace) =
    list.fold(instants, #(start(instants), None, Trace([], [])), fn(state, now) {
      let #(pacing, due, trace) = fire(state, now)
      let trace = Trace(..trace, deliveries: [now, ..trace.deliveries])
      case websocket.pace(pacing, now, interval) {
        #(pacing, websocket.WakeNow) -> #(
          pacing,
          due,
          Trace(..trace, wakes: [now, ..trace.wakes]),
        )
        #(pacing, websocket.WakeIn(delay_ms:)) -> #(
          pacing,
          Some(now + delay_ms),
          trace,
        )
        #(pacing, websocket.Covered) -> #(pacing, due, trace)
      }
    })
  let #(_, _, trace) = fire(#(pacing, due, trace), 1_000_000_000_000)
  Trace(
    deliveries: list.reverse(trace.deliveries),
    wakes: list.reverse(trace.wakes),
  )
}

// The schedule the actor opens with, at a reading taken before its first
// delivery: the actor reads its clock when it starts, before any frame.
fn start(instants: List(Int)) -> websocket.Pacing {
  case instants {
    [first, ..] -> websocket.start_pacing(first - 1)
    [] -> websocket.start_pacing(0)
  }
}

// The timer the actor armed fires if its instant has come by `now`, and
// opens the next interval from the instant it fired.
fn fire(
  state: #(websocket.Pacing, Option(Int), Trace),
  now: Int,
) -> #(websocket.Pacing, Option(Int), Trace) {
  let #(pacing, due, trace) = state
  case pacing, due {
    websocket.Scheduled, Some(at) if at <= now -> #(
      websocket.Open(at + interval),
      None,
      Trace(..trace, wakes: [at, ..trace.wakes]),
    )
    _, _ -> state
  }
}

// Every delivery has a wake at or after it and within one interval.
fn announced(trace: Trace) -> Bool {
  list.all(trace.deliveries, fn(delivered) {
    list.any(trace.wakes, fn(woke) {
      woke >= delivered && woke <= delivered + interval
    })
  })
}

// No two wakes are closer than one interval.
fn spaced(trace: Trace) -> Bool {
  case trace.wakes {
    [] | [_] -> True
    [first, ..rest] ->
      list.fold(rest, #(first, True), fn(state, woke) {
        #(woke, state.1 && woke - state.0 >= interval)
      }).1
  }
}

// A deterministic schedule of `count` deliveries whose gaps cycle through
// a mix of same-instant bursts, gaps inside the interval and long silences.
fn schedule(seed: Int, count: Int) -> List(Int) {
  let gaps = [0, 0, 1, 3, 7, 15, 16, 17, 40, 0, 2, 250]
  let #(_, instants) =
    list.fold(list.repeat(Nil, count), #(seed, [0]), fn(state, _) {
      let #(n, instants) = state
      let assert [last, ..] = instants
      let gap = case list.drop(gaps, n % list.length(gaps)) {
        [gap, ..] -> gap
        [] -> 0
      }
      #(n * 7 + 3, [last + gap, ..instants])
    })
  list.reverse(instants)
}

pub fn every_delivery_is_woken_within_one_interval_test() {
  list.each([1, 2, 3, 5, 8, 13, 21, 34, 55, 89], fn(seed) {
    let trace = replay(schedule(seed, 200))
    assert announced(trace)
      as "a delivery waited longer than one interval for its wake"
    assert spaced(trace) as "two wakes were closer than one interval"
  })
}

// Forty frames in one instant are one wake then, and one more at the
// interval's end for the frames the first did not announce, not forty.
pub fn a_burst_wakes_the_reader_twice_not_once_per_frame_test() {
  let trace = replay(list.repeat(100, 40))
  assert trace.wakes == [100, 100 + interval]
  assert announced(trace)
}

// The BEAM's monotonic clock is negative on this platform, and a socket's
// first frame must wake the reader at once whatever the offset. A schedule
// that opened at zero instead held the first wake for days and covered every
// frame after it, which is what the first live drive found.
pub fn a_negative_clock_still_wakes_on_the_first_frame_test() {
  let early = -576_460_751_000
  let trace = replay([early, early + 1, early + 40])
  assert trace.wakes == [early, early + interval, early + 40]
  assert announced(trace)
}

// A delivery on its own after a silence wakes the reader at once.
pub fn a_lone_frame_wakes_the_reader_at_once_test() {
  let trace = replay([500])
  assert trace.wakes == [500]
  let trace = replay([500, 900])
  assert trace.wakes == [500, 900]
}
