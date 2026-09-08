//// The daemon simulation's opt-in soak.
////
//// Nothing runs here unless `LOOM_DAEMON_SOAK_SECONDS` is set, the way the
//// session soak waits for `LOOM_SOAK_SEEDS`. `make soak-daemon-sim` sets it
//// and chunks the budget, because the test framework's per-test timeout is
//// about a minute and a chunk that outlives it reports a timeout rather than
//// a result.
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
import gleam/result
import gleam/string
import support/internal/ffi_shell
import weft/poll

/// Draws daemon seeds until the budget is spent, prints how many fit, and
/// fails on the first seed that failed.
///
/// ## Examples
///
/// `make soak-daemon-sim SOAK_DAEMON_BUDGET_SECONDS=30`.
pub fn daemon_soak_test() {
  case env_int("LOOM_DAEMON_SOAK_SECONDS", 0) {
    0 -> Nil
    seconds -> run(seconds)
  }
}

fn run(seconds: Int) -> Nil {
  let from = env_int("LOOM_DAEMON_SOAK_FROM", 1)
  // The clock is `weft/poll`'s, whose `now` is `erlang:monotonic_time` in
  // milliseconds. A budget must be measured against a reading that cannot go
  // backwards under a clock adjustment, and taking weft's is what keeps this
  // package free of an external of its own.
  let outcome =
    daemon_soak.soak(
      from:,
      budget_ms: seconds * 1000,
      now: poll.monotonic().now,
    )

  // The count and the next seed are printed whatever the verdict, because
  // the make loop reads them to place the following chunk and a failing
  // chunk still moved the range along.
  io.println_error(daemon_soak.describe(outcome, from:))

  case outcome.failures {
    [] -> Nil
    lines -> {
      let text = "daemon soak failures:\n  " <> string.join(lines, "\n  ")
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
