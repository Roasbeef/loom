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
//// that is already finished is skipped.

import core/json
import eval/arm.{type Arm}
import eval/arm_settings
import eval/budget
import eval/ledger.{type Row}
import eval/plan.{type Plan, type RowKey, RowKey}
import eval/report
import eval/task.{type Task}
import eval/trial
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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

  let ran = rounds(ctx, loaded, directory, writer, account, worst)
  let status = budget.status(account)
  budget.stop(account)
  process.send(writer.subject, Close)

  use started <- result.try(ran)
  let note = budget.describe(status)
  use Nil <- result.try(write_notes(directory, note))
  use Nil <- result.try(report.write_run(
    directory,
    report.Inputs(loaded.plan, loaded.tasks, loaded.arms, note),
  ))

  Ok(Summary(directory:, started:, budget_note: note))
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

/// Runs attempt rounds one to three, returning how many trials started.
fn rounds(
  ctx: trial.Context,
  loaded: Loaded,
  directory: String,
  writer: Writer,
  account: budget.Account,
  worst: Dict(String, Float),
) -> Result(Int, String) {
  use Nil <- result.try(close_interrupted(ctx.plan_id, directory, writer))

  list.try_fold([1, 2, ledger.max_attempts], 0, fn(started, attempt) {
    use pending <- result.try(pending_cells(loaded.plan, directory, attempt))
    use count <- result.map(round(
      ctx,
      loaded,
      directory,
      writer,
      account,
      worst,
      pending,
      attempt,
    ))

    started + count
  })
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
/// // run.reload("runs/<plan id>") == Ok(report.Inputs(plan, tasks, arms, None))
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

  Ok(report.Inputs(loaded.plan, loaded.tasks, loaded.arms, note))
}
