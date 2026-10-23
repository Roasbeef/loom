//// Native fixtures give each rollout a private workspace and a fixed criterion.
////
//// Operator admission validates and hashes these paths before this boundary.
//// Installation happens before any authored code starts. Scoring happens only
//// after witnessed native retirement, so no trial worker can replace a path
//// between the no-link inventory and the bounded read. Expected bytes stay in
//// the host; the model receives only the initial workspace and task prompt.

import client/evolution/rollout
import client/evolution/tasks
import client/evolution/trace
import filepath
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// Finds the exact task admitted independently of a candidate's prompt.
///
/// ## Examples
///
/// ```gleam
/// // fixture.find(admitted, requested_task)
/// ```
pub fn find(
  admitted: tasks.TaskSet,
  requested: rollout.Task,
) -> Result(tasks.Fixture, String) {
  list.find(admitted.tasks, fn(fixture) { fixture.task == requested })
  |> result.replace_error("the rollout task differs from its admitted fixture")
}

/// Installs immutable operator bytes before the isolated runtime is opened.
/// The caller supplies a new private directory, never a live author's workspace.
///
/// ## Examples
///
/// ```gleam
/// // fixture.install(captured, fresh_workspace)
/// ```
pub fn install(
  fixture: tasks.Fixture,
  workspace: String,
) -> Result(Nil, String) {
  use Nil <- result.try(bootstrap.ensure_private_directory(workspace))
  list.try_each(fixture.files, fn(file) {
    let path = workspace <> "/" <> file.0
    use Nil <- result.try(
      simplifile.create_directory_all(filepath.directory_name(path))
      |> result.map_error(simplifile.describe_error),
    )
    simplifile.write(path, file.1)
    |> result.map_error(simplifile.describe_error)
  })
}

/// Compares fixed expected files after all trial workers have retired.
/// Missing, linked, special or oversized files fail the criterion. Other native
/// read failures remain inconclusive rather than inventing a model-quality score.
/// The scorer never returns captured file contents or follows a symbolic link.
///
/// ## Examples
///
/// ```gleam
/// // fixture.score(admitted, fixed_task, retired_workspace)
/// ```
pub fn score(
  admitted: tasks.TaskSet,
  task: rollout.Task,
  workspace: String,
) -> Result(trace.Outcome, String) {
  use fixture <- result.try(find(admitted, task))
  use results <- result.try(
    list.try_map(fixture.expected, fn(expected) {
      compare(workspace, expected.0, expected.1)
    }),
  )
  case list.all(results, fn(outcome) { outcome == trace.Succeeded }) {
    True -> Ok(trace.Succeeded)
    False -> Ok(trace.Failed)
  }
}

fn compare(
  workspace: String,
  relative: String,
  expected: String,
) -> Result(trace.Outcome, String) {
  use admitted <- result.try(regular_path(
    workspace,
    string.split(relative, "/"),
  ))
  case admitted {
    False -> Ok(trace.Failed)
    True -> {
      let limit = bit_array.byte_size(bit_array.from_string(expected))
      case bootstrap.read_bounded(workspace <> "/" <> relative, limit) {
        Ok(bytes) ->
          case bytes == bit_array.from_string(expected) {
            True -> Ok(trace.Succeeded)
            False -> Ok(trace.Failed)
          }
        Error("file exceeds the bounded read limit") -> Ok(trace.Failed)
        Error(reason) -> Error("independent fixture read failed: " <> reason)
      }
    }
  }
}

// No trial process remains when this walk begins. Every parent must be a real
// directory and the final component a regular file before opening its bytes.
fn regular_path(root: String, pieces: List(String)) -> Result(Bool, String) {
  case pieces {
    [] -> Ok(False)
    [name, ..rest] -> {
      let path = root <> "/" <> name
      case simplifile.link_info(path) {
        Error(simplifile.Enoent) -> Ok(False)
        Error(error) -> Error(simplifile.describe_error(error))
        Ok(info) ->
          case rest, simplifile.file_info_type(info) {
            [], simplifile.File -> Ok(True)
            [_, ..], simplifile.Directory -> regular_path(path, rest)
            _, _ -> Ok(False)
          }
      }
    }
  }
}
