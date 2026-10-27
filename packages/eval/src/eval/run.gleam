//// The runner: a frozen plan in, a ledger and a report out.
////
//// A run directory, `<out>/<plan id>/`, holds everything one run is: the
//// plan, copies of the tasks and arms it names, the append-only ledger
//// `trials.jsonl`, a `notes.txt` for facts about the run that are not rows,
//// and the report. Each attempt works in `<task>/<arm>/<index>/attempt-<n>/`
//// below it, never in `/tmp`, where the jail would replace the directory.
////
//// Work proceeds in rounds, one per attempt number. Round one runs every cell
//// that has no row; round two runs the cells whose attempt one ended in an
//// infrastructure fault, and round three the ones that failed again. Cells run
//// as weft tasks, `budgets.concurrency` at a time. A round's tasks are
//// independent, which is why retries can be rounds: the ledger's sequencing
//// rule, that attempt k+1 follows an `Infra` row at k and nothing follows a
//// scored one, is then true of the file by construction.
////
//// New cells are admitted in waves of whole tasks, and between waves the
//// runner asks `evalstat.futility` whether any completion of the plan could
//// still reach a verdict. When none could, it stops admitting cells and says
//// so; the cells it never ran are missing, so the report reads `Incomplete`,
//// which is the honest account of a run that chose to spend less.
////
//// Three disciplines keep the ledger honest.
////
//// - Every row is appended by one writer process, as one line with its
////   newline, so a crash leaves a parseable prefix. A `Running` row is
////   written before a trial starts; on resume, a `Running` row with no
////   successor is closed with an `Infra` row and its attempt is spent.
//// - A trial is admitted by `eval/budget` against *measured* spend, and the
////   first refusal ends admission for the run. The cells that never ran have
////   no rows, so the verdict over them is `Incomplete`, and the run records
////   how many trials it got through.
//// - A trial that crashes its task becomes an `Infra` row. It is never
////   dropped, because a dropped trial is a smaller sample.
////
//// Resuming is the same call: the existing ledger is read first, and any cell
//// that is already finished is skipped. The budget account starts with the
//// dollars the ledger already records debited from the cap, so the cap bounds
//// the plan's spend across every attempt to run it.

import core/json
import eval/arm.{type Arm}
import eval/arm_settings
import eval/budget
import eval/ledger.{type Row}
import eval/plan.{type Plan, type RowKey, RowKey}
import eval/report
import eval/task.{type Task}
import eval/trial
import evalstat
import evalstat/trial as stat
import evalstat/verdict as stat_verdict
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile
import weft
import weft/actor

/// A plan with the tasks and arms it names.
pub type Loaded {
  Loaded(
    /// The frozen plan.
    plan: Plan,
    /// The tasks, in the plan's order.
    tasks: List(Task),
    /// The arms, in the plan's order: the first is the baseline.
    arms: List(Arm),
  )
}

/// What a run did.
pub type Summary {
  Summary(
    /// The run directory.
    directory: String,
    /// Trials started during this call (not counting earlier calls).
    started: Int,
    /// The sentence about the budget stop, if the budget stopped the run.
    budget_note: Option(String),
    /// The sentence about the futility stop, if futility stopped admission.
    futility_note: Option(String),
  )
}

/// Reads a plan and the tasks and arms it names from two directories, each
/// holding `<id>.json` files, and refuses a plan that fails `plan.check`.
///
/// ## Examples
///
/// ```gleam
/// // run.load("plans/p.json", "tasks", "arms") == Ok(Loaded(plan, tasks, arms))
/// ```
///
pub fn load(
  plan_path: String,
  tasks_dir: String,
  arms_dir: String,
) -> Result(Loaded, String) {
  use frozen <- result.try(plan.load(plan_path))
  use frozen <- result.try(plan.check(frozen))
  use tasks <- result.try(
    list.try_map(frozen.task_ids, fn(id) {
      task.load(tasks_dir <> "/" <> id <> ".json")
    }),
  )
  use arms <- result.try(
    list.try_map(frozen.arm_ids, fn(id) {
      load_arm(arms_dir <> "/" <> id <> ".json", id)
    }),
  )

  Ok(Loaded(plan: frozen, tasks:, arms:))
}

/// Reads one arm file and checks it is the arm its name says.
fn load_arm(path: String, id: String) -> Result(Arm, String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(error)
    }),
  )
  use value <- result.try(
    json.parse(body)
    |> result.map_error(fn(_report) { path <> ": not valid JSON" }),
  )
  use decoded <- result.try(arm.decode(value))
  use decoded <- result.try(arm.verify_id(decoded))

  // The file's name is the arm's id, so a copied or renamed file cannot stand in for another arm.
  case decoded.id == id {
    True -> Ok(decoded)
    False -> Error(path <> ": the file holds arm " <> decoded.id)
  }
}

/// Runs, or resumes, a plan under `out` and writes its report.
///
/// ## Examples
///
/// ```gleam
/// // run.execute(ctx, loaded, "runs") -> Ok(Summary("runs/<plan id>", 8, None))
/// ```
///
pub fn execute(
  ctx: trial.Context,
  loaded: Loaded,
  out: String,
) -> Result(Summary, String) {
  let directory = out <> "/" <> loaded.plan.id

  use worst <- result.try(preflight(ctx, loaded))
  use Nil <- result.try(prepare_directory(directory, loaded))
  use writer <- result.try(start_writer(directory <> "/trials.jsonl"))
  use account <- result.try(
    budget.start(case ctx.lane {
      trial.Live | trial.Recording(..) -> budget.cap_of(ctx.budgets)
      trial.Taped(..) -> budget.Unmetered
    }),
  )

  use Nil <- result.try(charge_prior_spend(account, directory))

  let ran = rounds(ctx, loaded, directory, writer, account, worst)
  let status = budget.status(account)
  budget.stop(account)
  process.send(writer.subject, Close)

  use progress <- result.try(ran)
  let note = budget.describe(status)
  let futility = futility_note(progress.futile_after)
  use Nil <- result.try(write_notes(directory, note))
  use Nil <- result.try(write_futility(directory, futility))
  use Nil <- result.try(report.write_run(
    directory,
    report.Inputs(loaded.plan, loaded.tasks, loaded.arms, note, futility),
  ))

  Ok(Summary(
    directory:,
    started: progress.started,
    budget_note: note,
    futility_note: futility,
  ))
}

/// Debits what the ledger already records from a fresh account. The cap is a
/// promise about the plan, not about one call of `execute`: an account that
/// began at the full cap on every resume would let a crash after nine of ten
/// dollars be followed by nine more. Every row's measured dollars count,
/// `Infra` rows included, because a faulted attempt still paid its requests;
/// `settle` with a zero reservation charges them without touching in-flight
/// worst cases.
fn charge_prior_spend(
  account: budget.Account,
  directory: String,
) -> Result(Nil, String) {
  use rows <- result.map(read_rows(directory))
  let spent =
    list.fold(rows, 0.0, fn(total, row) { total +. row.usage.dollars })

  budget.settle(account, 0.0, measured: spent)
}

/// Every arm must apply and every arm's worst case must be known before a
/// single trial starts, so a configuration fault is one refusal and not
/// three attempts times every cell.
fn preflight(
  ctx: trial.Context,
  loaded: Loaded,
) -> Result(Dict(String, Float), String) {
  use pairs <- result.map(
    list.try_map(loaded.arms, fn(each) {
      use _settings <- result.try(arm_settings.to_settings(each, ctx.base))
      use _profiles <- result.try(arm_settings.profiles(each, ctx.base))
      use cost <- result.map(trial.worst_case(ctx, each))

      #(each.id, cost)
    }),
  )

  dict.from_list(pairs)
}

/// Creates the run directory and freezes the plan, tasks and arms into it.
fn prepare_directory(directory: String, loaded: Loaded) -> Result(Nil, String) {
  use Nil <- result.try(make_directory(directory <> "/tasks"))
  use Nil <- result.try(make_directory(directory <> "/arms"))
  use Nil <- result.try(write_file(
    directory <> "/plan.json",
    json.to_string(plan.to_json(loaded.plan)),
  ))
  use Nil <- result.try(
    list.try_each(loaded.tasks, fn(each) {
      write_file(
        directory <> "/tasks/" <> each.id <> ".json",
        json.to_string(task.to_json(each)),
      )
    }),
  )

  list.try_each(loaded.arms, fn(each) {
    write_file(
      directory <> "/arms/" <> each.id <> ".json",
      json.to_string(arm.to_json(each)),
    )
  })
}

fn make_directory(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(error) {
    "cannot create " <> path <> ": " <> simplifile.describe_error(error)
  })
}

fn write_file(path: String, text: String) -> Result(Nil, String) {
  simplifile.write(path, text)
  |> result.map_error(fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

fn write_notes(directory: String, note: Option(String)) -> Result(Nil, String) {
  case note {
    Some(text) -> write_file(directory <> "/notes.txt", text <> "\n")
    None -> Ok(Nil)
  }
}

/// The futility stop is kept in a file of its own, so a report rebuilt from
/// the run directory says the same thing the run said.
fn write_futility(
  directory: String,
  note: Option(String),
) -> Result(Nil, String) {
  case note {
    Some(text) -> write_file(directory <> "/futility.txt", text <> "\n")
    None -> Ok(Nil)
  }
}

/// The sentence the report and the notes carry for a futility stop.
fn futility_note(futile_after: Option(Int)) -> Option(String) {
  option.map(futile_after, fn(pairs) {
    "stopped for futility after " <> int.to_string(pairs) <> " pairs"
  })
}

// --- the ledger writer ----------------------------------------------------------

type WriterMessage {
  Append(row: Row, reply: Subject(Result(Nil, String)))
  Close
}

type Writer {
  Writer(subject: Subject(WriterMessage))
}

/// Starts the process that owns the ledger file.
fn start_writer(path: String) -> Result(Writer, String) {
  actor.new(path)
  |> actor.on_message(write_row)
  |> actor.start
  |> result.map(fn(started) { Writer(started.data) })
  |> result.replace_error("the ledger writer did not start")
}

/// One process appends, one whole line at a time. `simplifile.append` opens,
/// writes and closes, so the line is on disk before the reply, and a crash
/// between rows leaves a file that `ledger.parse` still reads.
fn write_row(
  path: String,
  message: WriterMessage,
) -> actor.Next(String, WriterMessage) {
  // One writer process owns the file, so rows never interleave.
  case message {
    Close -> actor.stop()

    Append(row:, reply:) -> {
      let written =
        simplifile.append(path, ledger.encode_line(row) <> "\n")
        |> result.map_error(fn(error) {
          "cannot append to the ledger: " <> simplifile.describe_error(error)
        })

      process.send(reply, written)
      actor.continue(path)
    }
  }
}

fn append(writer: Writer, row: Row) -> Result(Nil, String) {
  actor.call(writer.subject, waiting: 10_000, sending: Append(row, _))
}

// --- rounds -----------------------------------------------------------------------

// What the rounds got through: the trials they started, and the pair count
// at which futility stopped admission, if it did.
type Progress {
  Progress(started: Int, futile_after: Option(Int))
}

/// Runs attempt rounds one to three. Round one admits new cells, so it is the
/// only round futility can stop; the retries are of cells already admitted.
fn rounds(
  ctx: trial.Context,
  loaded: Loaded,
  directory: String,
  writer: Writer,
  account: budget.Account,
  worst: Dict(String, Float),
) -> Result(Progress, String) {
  use Nil <- result.try(close_interrupted(ctx.plan_id, directory, writer))

  list.try_fold(
    [1, 2, ledger.max_attempts],
    Progress(0, None),
    fn(progress, attempt) {
      use pending <- result.try(pending_cells(loaded.plan, directory, attempt))

      // Only the first round admits cells nobody has tried, so only it is gated by futility.
      use more <- result.map(case attempt {
        1 ->
          admit_in_waves(
            ctx,
            loaded,
            directory,
            writer,
            account,
            worst,
            pending,
          )

        _ ->
          round(
            ctx,
            loaded,
            directory,
            writer,
            account,
            worst,
            pending,
            attempt,
          )
          |> result.map(fn(count) { Progress(count, None) })
      })

      Progress(
        started: progress.started + more.started,
        futile_after: option.or(progress.futile_after, more.futile_after),
      )
    },
  )
}

/// Runs round one a few whole tasks at a time, asking before each wave
/// whether the plan can still reach a verdict.
///
/// A wave is whole tasks so that a pair is never half-measured when the check
/// runs, and it holds enough tasks to keep `concurrency` cells busy. The
/// check precedes every wave, the first included, because a resumed run
/// starts with rows an earlier call wrote and may already be futile.
fn admit_in_waves(
  ctx: trial.Context,
  loaded: Loaded,
  directory: String,
  writer: Writer,
  account: budget.Account,
  worst: Dict(String, Float),
  pending: List(RowKey),
) -> Result(Progress, String) {
  let per_task =
    int.max(1, list.length(loaded.arms)) * loaded.plan.trials_per_cell
  let tasks_per_wave =
    int.max(1, { ctx.budgets.concurrency + per_task - 1 } / per_task)
  let waves =
    pending
    |> list.chunk(fn(key) { key.task })
    |> list.sized_chunk(tasks_per_wave)
    |> list.map(list.flatten)

  admit_wave(
    ctx,
    loaded,
    directory,
    writer,
    account,
    worst,
    waves,
    Progress(0, None),
  )
}

/// One wave, then the rest: stop at the first wave the futility check refuses.
fn admit_wave(
  ctx: trial.Context,
  loaded: Loaded,
  directory: String,
  writer: Writer,
  account: budget.Account,
  worst: Dict(String, Float),
  waves: List(List(RowKey)),
  progress: Progress,
) -> Result(Progress, String) {
  // No waves left is a run that got through them all.
  case waves {
    [] -> Ok(progress)

    [wave, ..later] -> {
      use rows <- result.try(read_rows(directory))

      // The check reads the ledger, so it sees exactly the pairs that finished; a stop leaves the later waves without rows, which is how the report knows.
      case futile_after(loaded.plan, rows) {
        Some(pairs) -> Ok(Progress(..progress, futile_after: Some(pairs)))

        None -> {
          use count <- result.try(round(
            ctx,
            loaded,
            directory,
            writer,
            account,
            worst,
            wave,
            1,
          ))

          admit_wave(
            ctx,
            loaded,
            directory,
            writer,
            account,
            worst,
            later,
            Progress(..progress, started: progress.started + count),
          )
        }
      }
    }
  }
}

// How one candidate stands in the futility check.
type Hope {
  // A completion of the plan could still decide it.
  Open

  // It could have been decided when the run began, and no longer can be.
  Stalled(pairs: Int)

  // No completion could ever have decided it, so nothing seen since matters.
  Hopeless
}

/// The number of completed pairs at which the run should stop admitting new
/// cells, or `None` while it should go on.
///
/// Each candidate is judged by `evalstat.futility` against the baseline over
/// the pairs both arms have finished, with every unfinished pair counted as
/// still to come. Two refinements keep the check from overreaching. A
/// candidate the plan could never decide, a few tasks at most, is `Hopeless`
/// from the start: stopping it "for futility" would stop the run before it
/// began, and its verdict, `Underpowered`, is already the finding. And the
/// run stops only when no candidate is `Open`, so one comparison that can
/// still be decided is never cut short by another that cannot.
///
/// ## Examples
///
/// ```gleam
/// // run.futile_after(plan, []) == None
/// ```
///
pub fn futile_after(frozen: Plan, rows: List(Row)) -> Option(Int) {
  // Futility compares candidates with a baseline, so a plan with one arm has nothing to stop.
  case frozen.arm_ids {
    [] | [_] -> None

    [baseline, ..candidates] -> {
      let finished =
        rows
        |> last_rows
        |> dict.values
        |> list.filter(fn(row) { row.state != ledger.Running })
        |> list.map(report.to_stat)
      let hopes =
        list.map(candidates, fn(candidate) {
          hope(finished, baseline, candidate, frozen)
        })
      let stalled =
        list.filter_map(hopes, fn(each) {
          // Only a stalled candidate gives the run a reason to stop.
          case each {
            Stalled(pairs:) -> Ok(pairs)
            Open | Hopeless -> Error(Nil)
          }
        })

      // Stop when nothing is open and something stalled; otherwise carry on.
      case list.contains(hopes, Open), stalled {
        False, [pairs, ..] -> Some(pairs)
        True, _ | False, [] -> None
      }
    }
  }
}

/// Where one candidate stands against the baseline after `finished` rows.
///
/// The futility bound counts how many task signs the rest of the plan could
/// still move. Each sign belongs to a task, so with K trials per cell the
/// remaining pairs overstate the moves: three tasks of three pairs each can
/// change at most three signs, however many pairs are left. The bound is the
/// smaller of the remaining pairs and twice the tasks that still have an
/// unfinished pair (`futility_from_signs` counts one move per sign change, and
/// flipping a task from the other side is a removal plus an addition). That is
/// still an upper bound, so the check still only under-claims.
fn hope(
  finished: List(stat.Trial),
  baseline: String,
  candidate: String,
  frozen: Plan,
) -> Hope {
  let done = completed_pairs(finished, baseline, candidate)
  let tasks = list.length(frozen.task_ids)
  let planned = tasks * frozen.trials_per_cell
  let open_tasks =
    list.count(frozen.task_ids, fn(task) {
      set.filter(done, fn(pair) { pair.0 == task })
      |> set.size
      < frozen.trials_per_cell
    })
  let remaining = int.min(planned - set.size(done), 2 * open_tasks)

  // Hopeless is read first: a plan that could never have decided is not stalled by what it has seen.
  case
    evalstat.futility([], baseline, candidate, int.min(planned, tasks)),
    evalstat.futility(finished, baseline, candidate, remaining)
  {
    stat_verdict.StopUndecided, _ -> Hopeless
    stat_verdict.Continue, stat_verdict.StopUndecided -> Stalled(set.size(done))
    stat_verdict.Continue, stat_verdict.Continue -> Open
  }
}

/// The `(task, index)` pairs that have a counted trial on both arms.
fn completed_pairs(
  finished: List(stat.Trial),
  baseline: String,
  candidate: String,
) -> Set(#(String, Int)) {
  let counted_on = fn(arm: String) {
    finished
    |> list.filter(fn(row) {
      row.arm == arm
      && case stat.standing(row.outcome) {
        stat.Counted(..) -> True
        stat.Excluded -> False
      }
    })
    |> list.map(fn(row) { #(row.task, row.index) })
    |> set.from_list
  }

  set.intersection(counted_on(baseline), counted_on(candidate))
}

/// A `Running` row with nothing after it is a trial the previous call never
/// finished. The attempt it names is spent: it is closed as an infrastructure
/// fault, and the cell either retries or, at the last attempt, ends.
fn close_interrupted(
  plan_id: String,
  directory: String,
  writer: Writer,
) -> Result(Nil, String) {
  use rows <- result.try(read_rows(directory))
  let last = last_rows(rows)

  last
  |> dict.values
  |> list.filter(fn(row) { row.state == ledger.Running })
  |> list.try_each(fn(row) {
    append(
      writer,
      trial.infra_row(
        plan_id,
        RowKey(row.task, row.arm, row.index),
        row.attempt,
        "interrupted: the run ended before this attempt finished",
      ),
    )
  })
}

/// Reads the ledger, treating an absent file as empty.
fn read_rows(directory: String) -> Result(List(Row), String) {
  case simplifile.read(directory <> "/trials.jsonl") {
    Ok(text) -> ledger.parse(text)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

fn last_rows(rows: List(Row)) -> Dict(RowKey, Row) {
  list.fold(rows, dict.new(), fn(held, row) {
    dict.insert(held, RowKey(row.task, row.arm, row.index), row)
  })
}

/// The cells that owe this attempt: nothing yet for attempt one, and for a
/// later attempt, an infrastructure row at the attempt before.
fn pending_cells(
  frozen: Plan,
  directory: String,
  attempt: Int,
) -> Result(List(RowKey), String) {
  use rows <- result.map(read_rows(directory))
  let last = last_rows(rows)

  list.filter(plan.rows(frozen), fn(key) {
    case dict.get(last, key), attempt {
      Error(Nil), 1 -> True
      Error(Nil), _ -> False
      Ok(row), _ -> row.state == ledger.Infra && row.attempt == attempt - 1
    }
  })
}

type Ran {
  Ran
  Skipped
}

/// Runs one attempt round over the pending cells, bounded by the plan's concurrency, and writes an `Infra` row for any task that did not finish.
fn round(
  ctx: trial.Context,
  loaded: Loaded,
  directory: String,
  writer: Writer,
  account: budget.Account,
  worst: Dict(String, Float),
  pending: List(RowKey),
  attempt: Int,
) -> Result(Int, String) {
  let tasks =
    list.map(pending, fn(key) {
      fn() {
        cell(ctx, loaded, directory, writer, account, worst, key, attempt)
      }
    })

  let outcomes =
    weft.new(tasks)
    |> weft.limit(ctx.budgets.concurrency)
    |> weft.start

  // A task that died or never started owes its cell a row, so the failure is
  // visible in the ledger instead of being a hole the plan later reports.
  use counts <- result.map(
    list.zip(pending, outcomes)
    |> list.try_map(fn(pair) {
      settle_outcome(ctx.plan_id, writer, pair.0, attempt, pair.1)
    }),
  )

  list.fold(counts, 0, int.add)
}

/// Turns one weft outcome into the number of trials it started, writing an `Infra` row if the task failed.
fn settle_outcome(
  plan_id: String,
  writer: Writer,
  key: RowKey,
  attempt: Int,
  outcome: weft.Outcome(Ran, String),
) -> Result(Int, String) {
  case outcome {
    weft.Completed(value: Ran, ..) -> Ok(1)
    weft.Completed(value: Skipped, ..) -> Ok(0)

    weft.Failed(error:, ..) ->
      append(writer, trial.infra_row(plan_id, key, attempt, error))
      |> result.replace(1)

    weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) ->
      append(
        writer,
        trial.infra_row(
          plan_id,
          key,
          attempt,
          "the trial's task did not finish",
        ),
      )
      |> result.replace(1)
  }
}

/// Runs one cell's attempt: admit against the budget, write the `Running` row, run the trial, settle the budget and append the result.
fn cell(
  ctx: trial.Context,
  loaded: Loaded,
  directory: String,
  writer: Writer,
  account: budget.Account,
  worst: Dict(String, Float),
  key: RowKey,
  attempt: Int,
) -> Result(Ran, String) {
  let cost = result.unwrap(dict.get(worst, key.arm), 0.0)

  // A refused admission skips the cell without a row: the missing cell is how the report knows the budget ended the run.
  case budget.admit(account, cost) {
    budget.Exhausted(..) -> Ok(Skipped)

    budget.Admitted -> {
      use task <- result.try(find_task(loaded.tasks, key.task))
      use chosen <- result.try(find_arm(loaded.arms, key.arm))
      use Nil <- result.try(append(
        writer,
        trial.running_row(ctx.plan_id, key, attempt),
      ))

      let root =
        string.join(
          [
            directory,
            key.task,
            key.arm,
            int.to_string(key.index),
            "attempt-" <> int.to_string(attempt),
          ],
          "/",
        )
      let row = trial.run_one(ctx, task, chosen, key, attempt, root)

      budget.settle(account, cost, measured: row.usage.dollars)
      use Nil <- result.map(append(writer, row))

      Ran
    }
  }
}

fn find_task(tasks: List(Task), id: String) -> Result(Task, String) {
  list.find(tasks, fn(each) { each.id == id })
  |> result.map_error(fn(_) {
    "the plan names task " <> id <> " but it was not loaded"
  })
}

fn find_arm(arms: List(Arm), id: String) -> Result(Arm, String) {
  list.find(arms, fn(each) { each.id == id })
  |> result.map_error(fn(_) {
    "the plan names arm " <> id <> " but it was not loaded"
  })
}

/// Rebuilds a report's inputs from a run directory written by `execute`: the
/// plan and the copies of the tasks and arms beside it.
///
/// ## Examples
///
/// ```gleam
/// // run.reload("runs/<plan id>") == Ok(report.Inputs(plan, tasks, arms, None, None))
/// ```
///
pub fn reload(directory: String) -> Result(report.Inputs, String) {
  use loaded <- result.try(load(
    directory <> "/plan.json",
    directory <> "/tasks",
    directory <> "/arms",
  ))

  // A missing note file means the run had nothing to note.
  let note = case simplifile.read(directory <> "/notes.txt") {
    Ok(text) -> Some(string.trim(text))
    Error(_) -> None
  }

  // Likewise a run that was never stopped for futility has no such file.
  let futility = case simplifile.read(directory <> "/futility.txt") {
    Ok(text) -> Some(string.trim(text))
    Error(_) -> None
  }

  Ok(report.Inputs(loaded.plan, loaded.tasks, loaded.arms, note, futility))
}
