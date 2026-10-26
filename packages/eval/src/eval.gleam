//// The instrument's command line. Wave one has a single verb,
//// `eval validate <file>`, which answers whether a task, arm, plan or ledger
//// file would be accepted by the code that will later act on it.
////
//// The point of a verb this small is that it runs the same total decoders
//// the runner will, so a file that validates here is a file the runner
//// cannot choke on, and a person editing a task by hand learns at their
//// desk that the digest no longer matches rather than in the middle of a
//// run. The file's kind is read from its extension and shape: `.jsonl` is a
//// ledger; otherwise the keys that only one kind carries decide.

import argv
import client/internal/ffi_os
import core/json
import eval/arm
import eval/ledger
import eval/plan
import eval/task
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Dispatches argv. A failure prints its reason on standard error and exits
/// with status 1; success prints a one-line verdict.
///
/// ## Examples
///
/// ```gleam
/// // eval validate tasks/3f9a….json
/// // ok task 3f9a…
/// ```
///
pub fn main() -> Nil {
  // Exactly one verb with exactly one path is a request; anything else is
  // a usage error, reported with a distinct status so scripts can tell the
  // difference between a refused file and a mistyped command.
  case argv.load().arguments {
    ["validate", path] ->
      case validate(path) {
        Ok(verdict) -> io.println(verdict)
        Error(reason) -> {
          io.println_error("eval validate: " <> reason)
          ffi_os.halt(1)
        }
      }
    _ -> {
      io.println_error("usage: eval validate <file>")
      ffi_os.halt(2)
    }
  }
}

/// Validates one file and returns the one-line verdict, or the reason it
/// would be refused.
///
/// ## Examples
///
/// ```gleam
/// // eval.validate("plan.json") == Ok("ok plan <id>: 24 rows")
/// ```
///
pub fn validate(path: String) -> Result(String, String) {
  case string.ends_with(path, ".jsonl") {
    True -> validate_ledger(path)
    False -> validate_document(path)
  }
}

fn validate_ledger(path: String) -> Result(String, String) {
  use body <- result.try(read(path))
  use rows <- result.map(ledger.parse(body))

  "ok ledger: " <> int.to_string(list.length(rows)) <> " rows"
}

/// Decides among task, plan and arm by the keys only one of them has.
fn validate_document(path: String) -> Result(String, String) {
  use body <- result.try(read(path))
  use value <- result.try(
    json.parse(body)
    |> result.map_error(fn(_) { path <> ": not valid JSON" }),
  )

  // The two keys below are the only ones a task and a plan do not share, so
  // they decide the kind without a separate tag in the file.
  case value {
    json.Object(fields) ->
      case
        list.key_find(fields, "workspace"),
        list.key_find(fields, "task_ids")
      {
        Ok(_), _ -> validate_task(path)
        _, Ok(_) -> validate_plan(path)
        _, _ -> validate_arm(value)
      }
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(path <> ": expected a JSON object")
  }
}

fn validate_task(path: String) -> Result(String, String) {
  use loaded <- result.map(task.load(path))

  "ok task " <> loaded.id
}

fn validate_plan(path: String) -> Result(String, String) {
  use loaded <- result.map(plan.load(path))
  let owed = int.to_string(list.length(plan.rows(loaded)))

  "ok plan " <> loaded.id <> ": " <> owed <> " rows"
}

fn validate_arm(value: json.JsonValue) -> Result(String, String) {
  use decoded <- result.try(arm.decode(value))
  use verified <- result.map(arm.verify_id(decoded))

  "ok arm " <> verified.id
}

fn read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(reason) {
    "cannot read " <> path <> ": " <> simplifile.describe_error(reason)
  })
}
