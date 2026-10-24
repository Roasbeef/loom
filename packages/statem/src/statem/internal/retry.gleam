//// The retry policy for one shrink candidate, free of any execution.
////
//// A system whose failure depends on scheduling can pass a candidate that
//// does fail, so the shrinker may give a candidate several executions. The
//// policy is separate from the driver so it can be tested with a `run` that
//// fails on chosen attempt numbers, which a pure package cannot arrange with
//// a real system: nothing in it outlives a call. The driver passes
//// `fn(_attempt) { execute_list(..) }`.

import gleam/option.{type Option, None, Some}

/// How one candidate fared.
pub type Attempted(failure) {
  Attempted(
    /// The first failure the caller's `wanted` test accepted, or `None`
    /// when every execution passed or failed some other way.
    accepted: Option(failure),
    /// Executions performed, which the caller charges to its budget.
    executions: Int,
  )
}

/// Execute up to `attempts` times, stopping at the first failure `wanted`
/// accepts or when `budget` executions are left to spend, whichever comes
/// first. `run` receives the zero-based attempt index.
///
/// ## Examples
///
/// ```gleam
/// retry.first_failure(3, 10, fn(attempt) { Error(attempt) }, fn(n) { n == 1 })
/// // Attempted(accepted: Some(1), executions: 2)
/// ```
pub fn first_failure(
  attempts: Int,
  budget: Int,
  run: fn(Int) -> Result(Nil, failure),
  wanted: fn(failure) -> Bool,
) -> Attempted(failure) {
  loop(0, attempts, budget, run, wanted)
}

/// One execution, then either an answer or the next attempt. The first
/// attempt always runs: the caller has already checked that budget remains.
fn loop(
  done: Int,
  attempts: Int,
  budget: Int,
  run: fn(Int) -> Result(Nil, failure),
  wanted: fn(failure) -> Bool,
) -> Attempted(failure) {
  let done = done + 1

  // Run the trial attempt and test for the target failure.
  case run(done - 1) {
    Error(failure) ->
      case wanted(failure) {
        True -> Attempted(Some(failure), done)
        False -> next(done, attempts, budget, run, wanted)
      }

    Ok(Nil) -> next(done, attempts, budget, run, wanted)
  }
}

/// An execution did not reproduce the bug: retry only while both the attempt
/// allowance and the budget have room.
fn next(
  done: Int,
  attempts: Int,
  budget: Int,
  run: fn(Int) -> Result(Nil, failure),
  wanted: fn(failure) -> Bool,
) -> Attempted(failure) {
  case done < attempts && done < budget {
    True -> loop(done, attempts, budget, run, wanted)
    False -> Attempted(None, done)
  }
}
