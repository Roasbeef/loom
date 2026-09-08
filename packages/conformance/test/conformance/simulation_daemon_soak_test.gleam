//// The daemon simulation's opt-in soak.
////
//// Nothing runs here unless `LOOM_DAEMON_SOAK_SECONDS` is set, the way the
//// session soak waits for `LOOM_SOAK_SEEDS`. `make soak-daemon-sim` sets it
//// and the whole budget is spent in one invocation, because the suite asks
//// eunit for a deadline that covers the budget rather than accepting the
//// default one.
////
//// The budget is wall clock rather than a seed count. A daemon seed opens a
//// real catalogue and starts two daemons, or three under a kill, so a seed
//// count buys an amount of lane time nobody can predict from the number.
////
//// The report goes to stderr, not to stdout: eunit truncates a panic message
//// and captures a test's stdout, and the point of this suite is that a gate
//// log alone says which seed failed and whether re-running it agreed.

import conformance/simulation/daemon/daemon_soak
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import support/internal/ffi_shell
import weft/poll

/// What the run may spend after its budget is exhausted, in seconds.
///
/// The loop checks the budget before a seed rather than during one, so the
/// last seed drawn runs in full. When that seed is the failing one it is
/// then corroborated: three re-runs, and a run drives up to three daemons
/// each of which may sit on the 20 s arrival backstop before giving up. The
/// failing run plus its three re-runs is therefore four executions of up to
/// 60 s, so 240 s is the worst case and 300 gives it room.
const corroboration_headroom_seconds = 300

/// gleeunit runs eunit with `ScaleTimeouts(10)`, and that scale multiplies
/// every timeout including one a generator asks for, so the number handed
/// to eunit is the number wanted divided by ten. Stated rather than folded
/// into the arithmetic because it is the trap: a reader who takes
/// `Timeout(360, _)` at face value would be setting an hour.
const gleeunit_timeout_scale = 10

/// eunit's test representation, built in Gleam rather than through FFI: a
/// Gleam constructor with fields compiles to a tagged Erlang tuple, so this
/// is literally `{timeout, Seconds, Body}`, which eunit reads back from a
/// zero-arity `*_test_` generator. The trailing underscore on the generator
/// below is what makes a timeout reachable from a gleeunit suite at all; a
/// plain `*_test` takes the default, which is about fifty seconds, and a
/// body that outlives it is reported as a timeout rather than as the
/// failing seed it found.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

/// Draws daemon seeds until the budget is spent, prints how many fit, and
/// fails on the first seed that failed.
///
/// The deadline asked of eunit is read from the same environment variable
/// the budget is, so one invocation covers whatever budget it was given.
///
/// ## Examples
///
/// `make soak-daemon-sim SOAK_DAEMON_BUDGET_SECONDS=30`.
pub fn daemon_soak_test_() -> EunitTest {
  let seconds = env_int("LOOM_DAEMON_SOAK_SECONDS", 0)
  let deadline =
    { seconds + corroboration_headroom_seconds } / gleeunit_timeout_scale

  Timeout(deadline, fn() {
    case seconds {
      0 -> Nil
      _ -> run(seconds)
    }
  })
}

fn run(seconds: Int) -> Nil {
  let from = env_int("LOOM_DAEMON_SOAK_FROM", 1)

  // The clock is `weft/poll`'s, whose `now` is `erlang:monotonic_time` in
  // milliseconds. A budget must be measured against a reading that cannot
  // go backwards under a clock adjustment, and taking weft's is what keeps
  // this package free of an external of its own.
  let outcome =
    daemon_soak.soak(
      from:,
      budget_ms: seconds * 1000,
      now: poll.monotonic().now,
    )

  // The count and the next seed are printed whatever the verdict, so a
  // reader resuming the range by hand knows where to start.
  io.println_error(daemon_soak.describe(outcome, from:))

  case outcome.failure {
    None -> Nil
    Some(report) -> {
      let text = "daemon soak failure:\n  " <> report
      io.println_error(text)
      panic as text
    }
  }
}

fn env_int(name: String, fallback: Int) -> Int {
  ffi_shell.get_env(name)
  |> result.try(int.parse)
  |> result.unwrap(fallback)
}
