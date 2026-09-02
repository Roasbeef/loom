//// The session's injected clock, as the pair a `weft/poll` wait runs on.
////
//// Two seams in this package wait in the foreground on something a
//// session is about to make true — an escalation a human has yet to
//// decide, a spawned child that has yet to settle — and both are bounded
//// by the session's own time base rather than by the operating system's.
//// That is not a preference: a simulated session never sleeps, so a wait
//// that measured `erlang:monotonic_time` inside one would either hang the
//// simulation, which advances logical time only when the runner steps it,
//// or make a simulated run depend on how fast the machine it ran on
//// happened to be.
////
//// `weft/poll` takes that decision as a value, and this module is the one
//// place the two halves are adapted: `core/clock` for the reading and the
//// seam's own injected `rest` for the resting. Both seams call it, so the
//// ruling below is written once rather than twice.
////
//// ## Why the successor clock is discarded
////
//// `core/clock.read` hands back both the instant and the clock to use for
//// the next read, and this adapter throws the second half away. That is
//// the ruling rather than an oversight, and it rests on what the
//// constructors actually do. `from_function` — what the runtime builds
//// over the system clock, and what the simulation builds over its own
//// logical clock actor — returns *itself* as the successor and calls the
//// injected function again on every read, so re-reading the same value is
//// precisely what threading would do. `fixed` never moves at all. Only
//// `stepping` advances by threading, and it cannot serve a wait like
//// these anyway: the loop holds one clock value across many reads, so a
//// stepping clock would freeze at its first instant and the wait would
//// never end. Every fixture in this tree that drives one of these waits
//// is already a `from_function` over a counter actor, and each one says
//// so in a comment.
////
//// The consequence is worth stating where a reader will meet it: a wait
//// built on a clock whose `now` does not move is a wait that never
//// expires. That is a fact about the clock, and the fixtures are built to
//// respect it.

import core/clock.{type Clock}
import weft/poll

/// The `weft/poll` clock that reads `time` and rests through `rest`.
///
/// `rest` is the seam's own injected sleep rather than `process.sleep`,
/// so a test that wants to count slices without taking them can, and a
/// simulated session can rest by letting its runner advance instead of by
/// blocking a scheduler.
///
/// ## Examples
///
/// ```gleam
/// poll.until_on(
///   clock: timebase.on(config.clock, config.rest),
///   within: parked.until - now,
///   every: poll.Fixed(config.poll_interval_ms),
///   attempt: probe,
/// )
/// ```
///
pub fn on(time: Clock, rest: fn(Int) -> Nil) -> poll.Clock {
  poll.Clock(now: fn() { clock.read(time).0 }, sleep: rest)
}
