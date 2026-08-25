//// `cap/task` — structured concurrency, and nothing else. There is no
//// raw spawn here: every task is a child of the combinator that started
//// it, joined or killed before that combinator returns, so no work ever
//// outlives its call and killing the satellite reaps the lot
//// (design §6.5).
////
//// ## Ordering
////
//// `parallel_map` preserves input order in its result regardless of
//// which task finishes first: each worker carries its item's index and
//// the results are reassembled by index at the end.
////
//// ## Cancellation is real
////
//// When `race` picks a winner, or `parallel_map` (fail-fast) hits its
//// first error, the losing workers are *killed*. A worker blocked in a
//// capability call is the caller the channel actor monitors, so its death
//// makes the channel emit a `cancel` frame for the in-flight `cap_call`
//// and the broker revokes the effect and kills its executor pgroup
//// (`cap/internal/channel`). Cancellation is not advisory.
////
//// ## Budget
////
//// Concurrency here fans out `cap_call`s, but the broker's budget is
//// pooled per execution: a 1000-way `parallel_map` shares one outstanding
//// cap and one wall deadline, so breadth cannot amplify footprint.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list

/// How one task ended, from the runner's point of view.
pub type Failure(e) {
  /// The task returned `Error(e)`.
  Returned(index: Int, error: e)
  /// The task's process died before returning (a panic in program code,
  /// or a cancellation). `reason` is a coarse label.
  Crashed(index: Int, reason: String)
}

// The internal outcome stored per index while a run is in flight.
type Outcome(b, e) {
  ValueOutcome(value: b)
  ErrorOutcome(error: e)
  CrashOutcome(reason: String)
}

// What a worker reports back, plus the monitor DOWNs, unified for one
// selector.
type Report(b, e) {
  Reported(index: Int, outcome: Result(b, e))
  WorkerDown(down: process.Down)
}

type Runner(b, e) {
  Runner(
    collector: Subject(Report(b, e)),
    selector: process.Selector(Report(b, e)),
    max_concurrency: Int,
    pending: List(#(Int, fn() -> Result(b, e))),
    running: Dict(Int, #(Pid, Monitor)),
    done: Dict(Int, Outcome(b, e)),
  )
}

/// Maps `f` over `items` concurrently, at most `max_concurrency` at once,
/// and returns the results in input order. Failures aggregate: if any
/// task fails or crashes, every task still runs to completion and the
/// error is the list of all failures, in index order. For early exit use
/// `parallel_map_fail_fast`.
pub fn parallel_map(
  items: List(a),
  max_concurrency max_concurrency: Int,
  with f: fn(a) -> Result(b, e),
) -> Result(List(b), List(Failure(e))) {
  run_collect(index_tasks(items, f), max_concurrency, fail_fast: False)
}

/// Like `parallel_map`, but the first failure cancels every still-running
/// task (killing them, which cancels their in-flight cap calls) and is
/// returned alone.
pub fn parallel_map_fail_fast(
  items: List(a),
  max_concurrency max_concurrency: Int,
  with f: fn(a) -> Result(b, e),
) -> Result(List(b), Failure(e)) {
  case run_collect(index_tasks(items, f), max_concurrency, fail_fast: True) {
    Ok(values) -> Ok(values)
    Error([first, ..]) -> Error(first)
    // fail_fast always yields at least one failure on the error path.
    Error([]) -> Error(Crashed(index: 0, reason: "empty failure set"))
  }
}

/// Runs every thunk concurrently (unbounded), aggregating failures.
pub fn all(
  tasks: List(fn() -> Result(a, e)),
) -> Result(List(a), List(Failure(e))) {
  run_collect(
    list.index_map(tasks, fn(task, index) { #(index, task) }),
    list.length(tasks),
    fail_fast: False,
  )
}

/// Runs two tasks concurrently and returns both results, or the first
/// failure (cancelling the other).
pub fn both(
  first: fn() -> Result(a, e),
  second: fn() -> Result(b, e),
) -> Result(#(a, b), Failure(e)) {
  // Run under a shared runner by wrapping both into one error-typed,
  // value-tagged pair, so a single collect covers them.
  let tagged = [
    #(0, fn() { first() |> map_ok(Left) }),
    #(1, fn() { second() |> map_ok(Right) }),
  ]
  case run_collect(tagged, 2, fail_fast: True) {
    Error([failure, ..]) -> Error(failure)
    Error([]) -> Error(Crashed(index: 0, reason: "empty failure set"))
    Ok(sides) ->
      case sides {
        [Left(a), Right(b)] | [Right(b), Left(a)] -> Ok(#(a, b))
        _ -> Error(Crashed(index: 0, reason: "both: lost a side"))
      }
  }
}

/// Runs the tasks concurrently and returns the first to *complete*,
/// killing the rest. A killed loser's in-flight cap call is cancelled at
/// the broker. If the winner returned an error, that error is returned.
pub fn race(tasks: List(fn() -> Result(a, e))) -> Result(a, Failure(e)) {
  case tasks {
    [] -> Error(Crashed(index: 0, reason: "race: no tasks"))
    _ -> run_race(list.index_map(tasks, fn(task, index) { #(index, task) }))
  }
}

// A two-sided union so `both` can carry differently-typed results through
// one runner.
type Side(a, b) {
  Left(a)
  Right(b)
}

fn map_ok(result: Result(a, e), with f: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(f(value))
    Error(error) -> Error(error)
  }
}

fn index_tasks(
  items: List(a),
  f: fn(a) -> Result(b, e),
) -> List(#(Int, fn() -> Result(b, e))) {
  list.index_map(items, fn(item, index) { #(index, fn() { f(item) }) })
}

// --- the collecting runner ----------------------------------------------

fn run_collect(
  tasks: List(#(Int, fn() -> Result(b, e))),
  max_concurrency: Int,
  fail_fast fail_fast: Bool,
) -> Result(List(b), List(Failure(e))) {
  let count = list.length(tasks)
  let collector = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(collector, fn(report) { report })
    |> process.select_monitors(WorkerDown)
  let runner =
    Runner(
      collector:,
      selector:,
      max_concurrency: clamp_concurrency(max_concurrency),
      pending: tasks,
      running: dict.new(),
      done: dict.new(),
    )
  let done = collect_loop(fill(runner), fail_fast)
  assemble(count, done)
}

fn collect_loop(
  runner: Runner(b, e),
  fail_fast: Bool,
) -> Dict(Int, Outcome(b, e)) {
  case dict.is_empty(runner.running) && runner.pending == [] {
    True -> runner.done
    False ->
      case process.selector_receive(runner.selector, within: 60_000) {
        Error(Nil) -> {
          // The satellite's wall deadline is the real bound; a stall here
          // means the channel is gone. Cancel everything and stop.
          cancel_running(runner.running)
          runner.done
        }
        Ok(Reported(index:, outcome:)) -> {
          let runner = retire(runner, index)
          let stored = case outcome {
            Ok(value) -> ValueOutcome(value)
            Error(error) -> ErrorOutcome(error)
          }
          let runner =
            Runner(..runner, done: dict.insert(runner.done, index, stored))
          case fail_fast && is_error(outcome) {
            True -> {
              cancel_running(runner.running)
              runner.done
            }
            False -> collect_loop(fill(runner), fail_fast)
          }
        }
        Ok(WorkerDown(down:)) ->
          case down_index(runner, down) {
            // A DOWN for a worker we already retired (its Normal exit
            // after Reported): ignore.
            Error(Nil) -> collect_loop(runner, fail_fast)
            Ok(#(index, reason)) -> {
              let runner = retire(runner, index)
              let runner =
                Runner(
                  ..runner,
                  done: dict.insert(runner.done, index, CrashOutcome(reason)),
                )
              case fail_fast {
                True -> {
                  cancel_running(runner.running)
                  runner.done
                }
                False -> collect_loop(fill(runner), fail_fast)
              }
            }
          }
      }
  }
}

// --- the racing runner --------------------------------------------------

fn run_race(
  tasks: List(#(Int, fn() -> Result(a, e))),
) -> Result(a, Failure(e)) {
  let collector = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(collector, fn(report) { report })
    |> process.select_monitors(WorkerDown)
  // Race runs all at once; concurrency is the field count.
  let runner =
    Runner(
      collector:,
      selector:,
      max_concurrency: list.length(tasks),
      pending: tasks,
      running: dict.new(),
      done: dict.new(),
    )
  race_loop(fill(runner))
}

fn race_loop(runner: Runner(a, e)) -> Result(a, Failure(e)) {
  case process.selector_receive(runner.selector, within: 60_000) {
    Error(Nil) -> {
      cancel_running(runner.running)
      Error(Crashed(index: 0, reason: "race: channel stalled"))
    }
    Ok(Reported(index:, outcome:)) -> {
      let runner = retire(runner, index)
      cancel_running(runner.running)
      case outcome {
        Ok(value) -> Ok(value)
        Error(error) -> Error(Returned(index:, error:))
      }
    }
    Ok(WorkerDown(down:)) ->
      case down_index(runner, down) {
        Error(Nil) -> race_loop(runner)
        Ok(#(index, reason)) -> {
          let runner = retire(runner, index)
          cancel_running(runner.running)
          Error(Crashed(index:, reason:))
        }
      }
  }
}

// --- shared runner plumbing ---------------------------------------------

// Dispatch pending tasks until `max_concurrency` are running.
fn fill(runner: Runner(b, e)) -> Runner(b, e) {
  case runner.pending, dict.size(runner.running) < runner.max_concurrency {
    [#(index, task), ..rest], True -> {
      let child = spawn_worker(runner.collector, index, task)
      fill(
        Runner(
          ..runner,
          pending: rest,
          running: dict.insert(runner.running, index, child),
        ),
      )
    }
    _, _ -> runner
  }
}

fn spawn_worker(
  collector: Subject(Report(b, e)),
  index: Int,
  task: fn() -> Result(b, e),
) -> #(Pid, Monitor) {
  // Unlinked + monitored: a worker panic becomes a `WorkerDown` we turn
  // into a `Crashed` failure, never a crash of the runner itself.
  let pid =
    process.spawn_unlinked(fn() {
      process.send(collector, Reported(index:, outcome: task()))
    })
  #(pid, process.monitor(pid))
}

// Remove a worker from the running set, demonitoring so its later Normal
// DOWN does not reach us.
fn retire(runner: Runner(b, e), index: Int) -> Runner(b, e) {
  case dict.get(runner.running, index) {
    Error(Nil) -> runner
    Ok(#(_pid, monitor)) -> {
      process.demonitor_process(monitor)
      Runner(..runner, running: dict.delete(runner.running, index))
    }
  }
}

fn down_index(
  runner: Runner(b, e),
  down: process.Down,
) -> Result(#(Int, String), Nil) {
  case down {
    process.ProcessDown(pid:, reason:, ..) ->
      list.find_map(dict.to_list(runner.running), fn(entry) {
        let #(index, #(worker_pid, _monitor)) = entry
        case worker_pid == pid {
          True -> Ok(#(index, reason_text(reason)))
          False -> Error(Nil)
        }
      })
    process.PortDown(..) -> Error(Nil)
  }
}

fn cancel_running(running: Dict(Int, #(Pid, Monitor))) -> Nil {
  list.each(dict.to_list(running), fn(entry) {
    let #(_index, #(pid, monitor)) = entry
    process.demonitor_process(monitor)
    process.kill(pid)
  })
}

fn assemble(
  count: Int,
  done: Dict(Int, Outcome(b, e)),
) -> Result(List(b), List(Failure(e))) {
  let indices = indices_up_to(count)
  let results = list.map(indices, fn(index) { one(index, done) })
  let failures =
    list.filter_map(results, fn(entry) {
      case entry {
        Error(failure) -> Ok(failure)
        Ok(_) -> Error(Nil)
      }
    })
  case failures {
    [] ->
      Ok(
        list.filter_map(results, fn(entry) {
          case entry {
            Ok(value) -> Ok(value)
            Error(_) -> Error(Nil)
          }
        }),
      )
    _ -> Error(failures)
  }
}

fn one(index: Int, done: Dict(Int, Outcome(b, e))) -> Result(b, Failure(e)) {
  case dict.get(done, index) {
    Ok(ValueOutcome(value:)) -> Ok(value)
    Ok(ErrorOutcome(error:)) -> Error(Returned(index:, error:))
    Ok(CrashOutcome(reason:)) -> Error(Crashed(index:, reason:))
    // Unreachable: every dispatched index is recorded before assemble.
    Error(Nil) -> Error(Crashed(index:, reason: "no outcome recorded"))
  }
}

// `[0, 1, ..., count - 1]`, ascending. Built tail-recursively because
// this stdlib has no `list.range`.
fn indices_up_to(count: Int) -> List(Int) {
  indices_loop(count - 1, [])
}

fn indices_loop(index: Int, accumulator: List(Int)) -> List(Int) {
  case index < 0 {
    True -> accumulator
    False -> indices_loop(index - 1, [index, ..accumulator])
  }
}

fn is_error(result: Result(b, e)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

fn clamp_concurrency(max_concurrency: Int) -> Int {
  case max_concurrency < 1 {
    True -> 1
    False -> max_concurrency
  }
}

fn reason_text(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(_) -> "abnormal"
  }
}
