//// The daemon simulation's long run, sized by wall clock rather than by a
//// seed count.
////
//// The session soak asks for a number of seeds. A daemon seed opens a real
//// SQLite catalogue on a real temporary directory and starts two daemons, or
//// three when the schedule draws a kill, so what a seed costs depends on the
//// machine's file system and on what the schedule drew. A fixed count
//// therefore buys an amount of wall clock that varies by more than the lane
//// can absorb. This module takes the budget instead and reports how many
//// seeds fit in it: about fifteen a second on a developer machine at the
//// time of writing, which is a measurement rather than a contract.
////
//// The caller supplies the clock. Everything under `src` here stays free of
//// externals, and the only thing the loop needs from the outside world is a
//// millisecond reading that never goes backwards; the test module passes one
//// in.
////
//// The runner list is the seam the rest of the wave appends to. Today it
//// holds the creation-key runner alone. When the lifecycle and revocation
//// scenarios land, their entry point joins `runners` and every seed the soak
//// draws runs both, so the budget covers the whole daemon script rather than
//// one scenario of it.

import conformance/simulation/daemon/daemon_runner
import conformance/simulation/runner
import gleam/int
import gleam/list

/// How many times a failed seed is re-run before the report calls it
/// reproducible. Three, matching the session runner, so the two soaks'
/// verdict lines mean the same thing.
const corroboration_runs = 3

/// One scenario the soak drives per seed.
///
/// The name is what a failure line leads with, because a seed number means
/// something different to each runner and a reader needs to know which one
/// to re-run.
pub type Runner {
  Runner(
    /// The scenario's name, as it appears in a failure line.
    name: String,
    /// Runs one seed, reporting the failure text on a red verdict.
    run: fn(Int) -> Result(Nil, String),
  )
}

/// What one budgeted run of the soak observed.
pub type Outcome {
  Outcome(
    /// How many seeds were drawn, whether or not they all passed. A budget
    /// too small for a single seed reports zero, which is a real answer
    /// about the machine rather than a silent pass.
    seeds: Int,
    /// The seed the next chunk should start at. The caller cannot compute
    /// this, because the count depends on how fast the machine was.
    next: Int,
    /// The failing seed's report, if the run reached one. The loop stops at
    /// the first failure: a daemon failure is expensive to reproduce and
    /// nothing later in the range is worth more than the one in hand.
    failures: List(String),
  )
}

/// The scenarios a seed runs, in order.
///
/// ## Examples
///
/// ```gleam
/// // list.map(daemon_soak.runners(), fn(one) { one.name })
/// ```
pub fn runners() -> List(Runner) {
  [Runner(name: "creation", run: creation)]
}

/// Draws seeds from `from` until `budget_ms` of wall clock has passed, or
/// until a seed fails.
///
/// The budget is checked before a seed rather than during it, so the run
/// overshoots by at most one seed. That is deliberate: a seed interrupted
/// partway through would leave a daemon and a catalogue behind and report
/// nothing about either.
///
/// ## Examples
///
/// ```gleam
/// // daemon_soak.soak(from: 1, budget_ms: 30_000, now: monotonic_ms)
/// ```
pub fn soak(
  from from: Int,
  budget_ms budget_ms: Int,
  now now: fn() -> Int,
) -> Outcome {
  let deadline = now() + budget_ms
  draw(from, from, deadline, now)
}

/// The summary line one budgeted run prints.
///
/// It is one line, prefixed the way `make soak`'s own progress lines are, so
/// the skip census and the signoff lane read this run the same way they read
/// the session soak.
///
/// ## Examples
///
/// ```gleam
/// // daemon_soak.describe(daemon_soak.Outcome(4, 5, []), from: 1)
/// ```
pub fn describe(outcome: Outcome, from from: Int) -> String {
  "==> daemon soak ran "
  <> int.to_string(outcome.seeds)
  <> " seeds from "
  <> int.to_string(from)
  <> ", next "
  <> int.to_string(outcome.next)
}

// Walks the seed range until the deadline or the first failure. `seed` is
// where the walk is; `from` is where it started, and is what the seed count
// is measured against.
fn draw(seed: Int, from: Int, deadline: Int, now: fn() -> Int) -> Outcome {
  case now() >= deadline {
    True -> Outcome(seeds: seed - from, next: seed, failures: [])
    False -> {
      let failures = list.filter_map(runners(), fn(one) { attempt(one, seed) })

      case failures {
        [] -> draw(seed + 1, from, deadline, now)
        lines ->
          Outcome(seeds: seed + 1 - from, next: seed + 1, failures: lines)
      }
    }
  }
}

// Runs one scenario against one seed, rendering a failure the way the
// session soak renders one: the check and its detail, then the reproduction
// line on its own, then what re-running the seed said about it.
fn attempt(one: Runner, seed: Int) -> Result(String, Nil) {
  case one.run(seed) {
    Ok(Nil) -> Error(Nil)
    Error(report) ->
      Ok(
        one.name
        <> " seed "
        <> int.to_string(seed)
        <> ": "
        <> report
        <> "\n    "
        <> runner.describe_corroboration(corroborate(one, seed)),
      )
  }
}

// Re-runs a failed seed so an unreproducible red says so in its own output.
//
// A daemon run drives more real processes than a session run does and the
// harness controls none of their interleavings, so the failure rate over a
// range is the signal and a single red is not. The session runner pays for
// this inside itself; the daemon runner does not, so the soak pays for it
// here, over the same three runs and against the same reading.
fn corroborate(one: Runner, seed: Int) -> runner.Corroboration {
  let reds = rerun(one, seed, corroboration_runs, 1)

  case reds == corroboration_runs + 1 {
    True -> runner.Reproducible(runs: reds)
    False -> runner.Unstable(failed: reds, of: corroboration_runs + 1)
  }
}

// Runs a seed `remaining` more times, carrying the count of failures so far,
// which starts at one for the run that brought us here.
fn rerun(one: Runner, seed: Int, remaining: Int, reds: Int) -> Int {
  case remaining <= 0 {
    True -> reds
    False ->
      case one.run(seed) {
        Ok(Nil) -> rerun(one, seed, remaining - 1, reds)
        Error(_report) -> rerun(one, seed, remaining - 1, reds + 1)
      }
  }
}

// The creation-key scenario, adapted to the runner surface. The verdict's
// detail names the script and the schedule the seed was drawn with, neither
// of which is recoverable from the seed by eye, so the line carries both.
fn creation(seed: Int) -> Result(Nil, String) {
  case daemon_runner.run(seed:) {
    daemon_runner.Passed -> Ok(Nil)
    daemon_runner.Failed(failure:, reproduce:, detail:, ..) ->
      Error(
        failure.check
        <> " — "
        <> failure.detail
        <> "\n    "
        <> detail
        <> "\n    "
        <> reproduce,
      )
  }
}
