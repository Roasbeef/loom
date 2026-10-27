//// The command line of the governed door:
//// `gleam run -m eval/admit_cli -- --split tune|validate --tasks <dir>
//// --plan <plan.json> --session <id> --state <dir> [--loomd <program>]`.
////
//// The command converts the tasks of one split into a version-two task-set
//// payload (`eval/admit`) and submits it by running `loomd evolution
//// admit_tasks`. It never opens a session, reads a credential or links the
//// admission code: the daemon's private owner credential stays behind the
//// operator door that already exists, and this process is only a client of
//// it. The split's salt is the plan's, so a re-salted plan is a different
//// split and the command says nothing about the old one.
////
//// `--split holdout` is parsed and then refused by the seal, before the tasks
//// directory is read, with a message naming the holdout.

import argv
import client/internal/ffi_os
import client/secrets
import core/json
import eval/admit
import eval/plan
import eval/task.{type Task}
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// What a run of the command was asked for.
pub type Request {
  Request(
    /// The split's name as typed.
    split: String,
    /// Directory of `<id>.json` task files.
    tasks: String,
    /// The plan file whose salt assigns the split.
    plan: String,
    /// The resident session to admit into.
    session: String,
    /// The daemon's state directory.
    state: String,
    /// The daemon program to run.
    loomd: String,
  )
}

/// Runs the command. Usage errors exit 2, a refusal or failure exits 1.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/admit_cli -- --split tune --tasks tasks --plan plan.json --session s --state ~/.loom
/// ```
///
pub fn main() -> Nil {
  // A malformed command line is a usage error; a refused or failed request is
  // a different status so scripts can tell a typo from a refusal.
  case request(argv.load().arguments, Request("", "", "", "", "", "loomd")) {
    Error(reason) -> {
      io.println_error("eval/admit_cli: " <> reason)
      io.println_error(
        "usage: --split tune|validate --tasks <dir> --plan <file> --session <id> --state <dir> [--loomd <program>]",
      )
      ffi_os.halt(2)
    }
    Ok(asked) ->
      case run(asked, secrets.host_runner()) {
        Ok(summary) -> io.println(summary)
        Error(reason) -> {
          io.println_error("eval/admit_cli: " <> reason)
          ffi_os.halt(1)
        }
      }
  }
}

/// Reads the flags one at a time; the first unknown one is named so a typo is
/// never taken for a default.
///
/// ## Examples
///
/// ```gleam
/// assert admit_cli.request(["--split"], r) == Error("unknown or incomplete argument --split")
/// ```
///
pub fn request(
  flags: List(String),
  so_far: Request,
) -> Result(Request, String) {
  case flags {
    [] ->
      case
        list.any(
          [
            so_far.split,
            so_far.tasks,
            so_far.plan,
            so_far.session,
            so_far.state,
          ],
          fn(value) { value == "" },
        )
      {
        True ->
          Error("--split, --tasks, --plan, --session and --state are required")
        False -> Ok(so_far)
      }
    ["--split", value, ..rest] -> request(rest, Request(..so_far, split: value))
    ["--tasks", value, ..rest] -> request(rest, Request(..so_far, tasks: value))
    ["--plan", value, ..rest] -> request(rest, Request(..so_far, plan: value))
    ["--session", value, ..rest] ->
      request(rest, Request(..so_far, session: value))
    ["--state", value, ..rest] -> request(rest, Request(..so_far, state: value))
    ["--loomd", value, ..rest] -> request(rest, Request(..so_far, loomd: value))
    [flag, ..] -> Error("unknown or incomplete argument " <> flag)
  }
}

/// Performs the admission through `runner` and answers the summary. The seal
/// is applied before the plan or the tasks are read.
///
/// ## Examples
///
/// ```gleam
/// // admit_cli.run(request, secrets.host_runner())
/// ```
///
pub fn run(asked: Request, runner: secrets.Runner) -> Result(String, String) {
  use wanted <- result.try(admit.parse_split(asked.split))
  use _sealed <- result.try(admit.seal(wanted))
  use loaded <- result.try(plan.load(asked.plan))
  use pool <- result.try(load_tasks(asked.tasks))
  use admission <- result.try(admit.prepare(pool, wanted, loaded.split_salt))
  use answer <- result.try(admit.submit(admission, door(asked, runner)))

  Ok(
    "admitted "
    <> int.to_string(list.length(admission.admitted))
    <> " tasks of the "
    <> asked.split
    <> " split ("
    <> int.to_string(list.length(admission.skipped))
    <> " skipped): "
    <> string.trim(answer)
    <> skipped_lines(admission.skipped),
  )
}

fn skipped_lines(skipped: List(admit.Skipped)) -> String {
  list.map(skipped, fn(each) {
    "\nskipped " <> each.task_id <> ": " <> each.reason
  })
  |> string.join("")
}

/// The door that writes the payload beside the state, runs the daemon's
/// admission command on it and removes the file on every path.
fn door(asked: Request, runner: secrets.Runner) -> admit.Door {
  let #(state, loomd, session) = #(asked.state, asked.loomd, asked.session)

  fn(payload) {
    let args =
      state
      <> "/eval-admit-"
      <> int.to_string(ffi_os.unique_positive_integer())
      <> ".json"

    use Nil <- result.try(
      simplifile.write(args, json.to_string(payload))
      |> result.map_error(fn(error) {
        "cannot write " <> args <> ": " <> simplifile.describe_error(error)
      }),
    )
    let ran = runner(admit.door_argv(loomd, state, session, args), 60_000)
    let _removed = simplifile.delete(args)

    // Status zero is the door's acknowledgement; anything else carries its reason.
    case ran {
      Ok(secrets.Capture(status: 0, output:)) -> Ok(output)
      Ok(secrets.Capture(status:, output:)) ->
        Error(
          "the operator door refused (status "
          <> int.to_string(status)
          <> "): "
          <> string.trim(output),
        )
      Error(reason) -> Error(reason)
    }
  }
}

/// Loads every `*.json` file of a directory as a task, in name order.
fn load_tasks(directory: String) -> Result(List(Task), String) {
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      "cannot read " <> directory <> ": " <> simplifile.describe_error(error)
    }),
  )

  names
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
  |> list.try_map(fn(name) { task.load(directory <> "/" <> name) })
}
