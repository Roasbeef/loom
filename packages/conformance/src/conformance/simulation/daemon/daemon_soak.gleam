//// The daemon simulation's long run, sized by wall clock rather than by a
//// seed count.
////
//// The session soak asks for a number of seeds. A daemon seed opens a real
//// SQLite catalogue on a real temporary directory and starts several daemon
//// incarnations, so what a seed costs depends on the machine's file system
//// and on what the schedules drew. A fixed count therefore buys an amount of
//// wall clock that varies by more than the lane can absorb. This module takes
//// the budget instead and reports how many seeds fit in it.
////
//// The caller supplies the clock. Everything under `src` here stays free of
//// externals, and the only thing the loop needs from the outside world is a
//// millisecond reading that never goes backwards; the test module passes one
//// in.
////
//// The runner list is the seam that holds each daemon scenario. It contains
//// creation-key, lifecycle and domain-retirement runners, so every seed the
//// soak draws covers all three scenario families within the same budget.

import conformance/simulation/daemon/daemon_fault
import conformance/simulation/daemon/daemon_runner
import conformance/simulation/daemon/domain_runner
import conformance/simulation/daemon/lifecycle_faults
import conformance/simulation/daemon/lifecycle_runner
import conformance/simulation/runner
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// How many candidates a shrink may try. The same twelve the session soak
/// spends (`runner.soak`); a daemon schedule is one fault, so it is rarely
/// reached.
const shrink_budget = 12

/// A failing seed as the runner reported it: the named check, which a shrink
/// must keep failing, and the text a reader sees.
pub type Reported {
  Reported(
    /// The check that failed, by name.
    check: String,
    /// The failure line, with the reproduction command.
    text: String,
  )
}

/// One scenario the soak drives per seed.
///
/// The name is what a failure line leads with, because a seed number means
/// something different to each runner and a reader needs to know which one
/// to re-run.
pub type Runner {
  Runner(
    /// The scenario's name, as it appears in a failure line.
    name: String,
    /// Runs one seed, reporting the failure on a red verdict.
    run: fn(Int) -> Result(Nil, Reported),
    /// Given a seed whose failure was just corroborated and the check it
    /// failed, searches for a simpler fault that still fails that check, and
    /// says what it found. `None` where the scenario has no fault to
    /// simplify. Only a reproducible failure is shrunk, for the reason the
    /// session runner gives: whether a smaller case still fails is a coin
    /// toss for a seed whose own verdict is one.
    shrink: fn(Int, String) -> Option(String),
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
    /// the first failure, so there is at most one: a daemon failure is
    /// expensive to reproduce and nothing later in the range is worth more
    /// than the one in hand.
    failure: Option(String),
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
  [
    Runner(name: "creation", run: creation, shrink: shrink_creation),
    Runner(name: "lifecycle", run: lifecycle, shrink: shrink_lifecycle),
    Runner(
      name: "domain-retirement",
      run: domain_retirement,
      shrink: shrink_domain,
    ),
  ]
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
/// a reader skimming a lane log finds it where the session soak's lines are.
/// The next seed is on it so that somebody resuming the range by hand knows
/// where to start; nothing parses it.
///
/// ## Examples
///
/// ```gleam
/// // daemon_soak.describe(daemon_soak.Outcome(4, 5, None), from: 1)
/// ```
pub fn describe(outcome: Outcome, from from: Int) -> String {
  "==> daemon soak ran "
  <> int.to_string(outcome.seeds)
  <> " seeds from "
  <> int.to_string(from)
  <> ", next "
  <> int.to_string(outcome.next)
}

/// Draws and executes soak scenarios sequentially across seed ranges until deadline.
fn draw(seed: Int, from: Int, deadline: Int, now: fn() -> Int) -> Outcome {
  // Check whether the soak wall-clock deadline has expired.
  case now() >= deadline {
    True -> Outcome(seeds: seed - from, next: seed, failure: None)
    False -> {
      let attempted = list.try_each(runners(), fn(one) { attempt(one, seed) })

      // Check if any runner failed on the current seed.
      case attempted {
        Ok(Nil) -> draw(seed + 1, from, deadline, now)

        // `try_each` stops before running a later scenario once one failed.
        // The range stops at that report, so the unrun scenario cannot
        // perform work after the failure the soak will return.
        Error(report) ->
          Outcome(seeds: seed + 1 - from, next: seed + 1, failure: Some(report))
      }
    }
  }
}

/// Runs one soak scenario against a seed, returning an error report on failure.
fn attempt(one: Runner, seed: Int) -> Result(Nil, String) {
  // Execute the scenario runner on the given seed.
  case one.run(seed) {
    Ok(Nil) -> Ok(Nil)
    Error(Reported(check:, text:)) -> {
      let corroboration = corroborate(one, seed, check)
      Error(
        one.name
        <> " seed "
        <> int.to_string(seed)
        <> ": "
        <> text
        <> "\n    "
        <> runner.describe_corroboration(corroboration)
        <> shrunk(one, seed, check, corroboration),
      )
    }
  }
}

/// Attempts to shrink a failing schedule if corroboration succeeded.
fn shrunk(
  one: Runner,
  seed: Int,
  check: String,
  corroboration: runner.Corroboration,
) -> String {
  case corroboration {
    runner.Unstable(..) -> ""
    runner.Reproducible(..) ->
      case one.shrink(seed, check) {
        Some(line) -> "\n    " <> line
        None -> ""
      }
  }
}

/// Re-runs a failed seed multiple times to verify reproducibility.
fn corroborate(one: Runner, seed: Int, check: String) -> runner.Corroboration {
  runner.corroborate(check, fn() {
    case one.run(seed) {
      Ok(Nil) -> Ok(Nil)
      Error(Reported(check:, text:)) -> Error(runner.Failure(check, text))
    }
  })
}

/// Runner adapter for the creation-key daemon soak scenario.
fn creation(seed: Int) -> Result(Nil, Reported) {
  case daemon_runner.run(seed:) {
    daemon_runner.Passed -> Ok(Nil)
    daemon_runner.Failed(failure:, reproduce:, detail:, ..) ->
      Error(Reported(
        check: failure.check,
        text: failure.check
          <> " — "
          <> failure.detail
          <> "\n    "
          <> detail
          <> "\n    "
          <> reproduce,
      ))
  }
}

/// Shrinks a creation failure schedule by dropping or pulling faults.
fn shrink_creation(seed: Int, check: String) -> Option(String) {
  let #(_script, drawn) = daemon_runner.plan(seed)
  let #(smallest, _failure) = daemon_runner.shrink(seed, check, shrink_budget)
  Some(describe_shrunk(
    daemon_fault.describe(drawn),
    daemon_fault.describe(smallest),
    check,
  ))
}

/// Runner adapter for the daemon lifecycle scenario.
fn lifecycle(seed: Int) -> Result(Nil, Reported) {
  case lifecycle_runner.run(seed:) {
    lifecycle_runner.Passed -> Ok(Nil)
    lifecycle_runner.Failed(failure:, reproduce:, ..) ->
      Error(Reported(
        check: failure.check,
        text: failure.check <> ": " <> failure.detail <> "\n    " <> reproduce,
      ))
  }
}

/// Shrinks a lifecycle failure schedule against its drawn faults.
fn shrink_lifecycle(seed: Int, check: String) -> Option(String) {
  use #(smallest, _failure) <- option.map(lifecycle_runner.shrink(
    seed,
    check,
    budget: shrink_budget,
  ))

  // Recover the drawn fault for the failing lifecycle script.
  let drawn = case lifecycle_runner.script_of(check) {
    Some(script) -> lifecycle_runner.drawn_fault(seed, script)
    None -> smallest
  }

  describe_shrunk(
    lifecycle_faults.describe(drawn),
    lifecycle_faults.describe(smallest),
    check,
  )
}

/// Runner adapter for the domain retirement scenario.
fn domain_retirement(seed: Int) -> Result(Nil, Reported) {
  domain_runner.run(seed:)
  |> result.map_error(fn(failure) {
    Reported(
      check: failure.check,
      text: failure.check
        <> ": "
        <> failure.detail
        <> "\n    domain_runner.run(seed: "
        <> int.to_string(seed)
        <> ")",
    )
  })
}

// The domain schedule is a two-way choice between an open after retirement
// and an open during it, and the first is the baseline the second is
// compared with. Neither is a simpler form of the other, so there is nothing
// to shrink; saying so keeps the report from reading as an omission.
fn shrink_domain(_seed: Int, _check: String) -> Option(String) {
  Some(
    "[shrunk] not shrunk: the domain schedule is one hold with no simpler "
    <> "form, and its only alternative is the baseline it is compared with.",
  )
}

/// Formats a description of the shrunk schedule comparison.
fn describe_shrunk(drawn: String, smallest: String, check: String) -> String {
  case drawn == smallest {
    True ->
      "[shrunk] no simpler schedule fails "
      <> check
      <> " on every run; kept the drawn one: "
      <> drawn
    False ->
      "[shrunk] "
      <> smallest
      <> " still fails "
      <> check
      <> " on every run (drawn: "
      <> drawn
      <> ")"
  }
}
