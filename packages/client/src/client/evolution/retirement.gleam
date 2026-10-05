//// Native cleanup progresses by replacing its remaining obligation.
////
//// A failed close carries the exact next task, rather than replaying a step
//// whose witness may already have consumed its native owner. This keeps late
//// pool retirement retryable and successful retirement ahead of deletion.

import gleam/list
import gleam/result

/// One native cleanup obligation; only its failed continuation remains owned.
pub type Task {
  Task(
    /// Performs the remaining cleanup once and yields its next obligation.
    run: fn() -> Result(Nil, Failure),
  )
}

/// Cleanup has not completed, so the caller must retain the continuation.
pub type Failure {
  Failure(
    /// The bounded native refusal rendered to an operator.
    reason: String,
    /// The remaining obligation, excluding already confirmed steps.
    retry: Task,
  )
}

/// Performs one obligation without discarding its failed continuation.
///
/// ## Examples
///
/// `perform(task)` returns a replacement task only when cleanup is uncertain.
pub fn perform(task: Task) -> Result(Nil, Failure) {
  task.run()
}

/// Adapts an existing native capability whose failure may be re-asked.
///
/// ## Examples
///
/// `repeat(fn() { close_original_pool() })` retains the same pool on timeout.
pub fn repeat(run: fn() -> Result(Nil, String)) -> Task {
  Task(fn() {
    run() |> result.map_error(fn(reason) { Failure(reason, repeat(run)) })
  })
}

/// Replaces a first close with its direct native retry after any refusal.
///
/// ## Examples
///
/// `first(close_executor, close_original_pool)` never replays executor.close.
pub fn first(
  run: fn() -> Result(Nil, String),
  retry: fn() -> Result(Nil, String),
) -> Task {
  Task(fn() {
    run() |> result.map_error(fn(reason) { Failure(reason, repeat(retry)) })
  })
}

/// Runs cleanup steps in order and keeps only steps that remain incomplete.
///
/// ## Examples
///
/// `sequence(retire_pool, remove_directory)` retries deletion after pool success.
pub fn sequence(before: Task, after: Task) -> Task {
  Task(fn() {
    case perform(before) {
      Ok(Nil) -> perform(after)
      Error(failed) ->
        Error(Failure(failed.reason, sequence(failed.retry, after)))
    }
  })
}

/// Attempts independent obligations in order, retaining only failed tasks.
/// A missing runtime report must not prevent retirement of its native helpers.
///
/// ## Examples
///
/// `join([drain_runtime, retire_helpers])` reports uncertainty after both calls.
pub fn join(tasks: List(Task)) -> Task {
  Task(fn() {
    let failed =
      list.filter_map(tasks, fn(task) {
        case perform(task) {
          Ok(Nil) -> Error(Nil)
          Error(failed) -> Ok(failed)
        }
      })
    case failed {
      [] -> Ok(Nil)
      [first, ..] ->
        Error(Failure(
          first.reason,
          join(list.map(failed, fn(failed) { failed.retry })),
        ))
    }
  })
}
