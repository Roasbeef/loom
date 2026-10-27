//// Native fixtures give each rollout a private workspace and a fixed criterion.
////
//// Operator admission validates and hashes these paths before this boundary.
//// Installation happens before any authored code starts. Scoring happens only
//// after witnessed native retirement, so no trial worker can replace a path
//// between the no-link inventory and the bounded read. Expected bytes stay in
//// the host; the model receives only the initial workspace and task prompt.
//// The grade is the exact-byte verifier's: a reward of one when every expected
//// file matches and zero otherwise, with the first differing path as the only
//// side information, so an optimizer learns where a trial fell short and
//// never what the expected bytes were.

import client/evolution/rollout
import client/evolution/tasks
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

/// What one expected path looked like in the retired workspace.
type Comparison {
  /// The regular file held exactly the expected bytes.
  Matches

  /// The path was missing, linked, special, oversized or differed in content.
  Differs(path: String)
}

/// Grades fixed expected files after all trial workers have retired.
/// Missing, linked, special or oversized files fail the criterion. Other native
/// read failures remain inconclusive rather than inventing a model-quality score.
/// The grade names the first differing path and never returns captured file
/// contents or follows a symbolic link.
///
/// ## Examples
///
/// ```gleam
/// // fixture.score(admitted, fixed_task, retired_workspace)
/// // -> Ok(rollout.Grade(1.0, [], "", rollout.ExpectedFiles))
/// ```
pub fn score(
  admitted: tasks.TaskSet,
  task: rollout.Task,
  workspace: String,
) -> Result(rollout.Grade, String) {
  use fixture <- result.try(find(admitted, task))
  use comparisons <- result.try(
    list.try_map(fixture.expected, fn(expected) {
      compare(workspace, expected.0, expected.1)
    }),
  )

  // One differing path fails the whole criterion; the first in admitted order
  // is the diagnostic, which keeps the side information bounded by one path.
  let first =
    list.find(comparisons, fn(comparison) { comparison != Matches })
    |> result.unwrap(Matches)

  // A full match is the only passing grade; anything else fails at zero.
  case first {
    Matches -> Ok(rollout.Grade(1.0, [], "", rollout.ExpectedFiles))
    Differs(path) ->
      Ok(rollout.Grade(
        0.0,
        [],
        "expected file differs: " <> path,
        rollout.ExpectedFiles,
      ))
  }
}

/// Evaluates one expected file against the candidate workspace, verifying regular
/// file attributes, size limits, and exact byte content equality.
fn compare(
  workspace: String,
  relative: String,
  expected: String,
) -> Result(Comparison, String) {
  use admitted <- result.try(regular_path(
    workspace,
    string.split(relative, "/"),
  ))

  // Reject immediately if path traversal or symlinks violate regular file invariants.
  case admitted {
    False -> Ok(Differs(relative))
    True -> {
      let limit = bit_array.byte_size(bit_array.from_string(expected))

      // Read content within byte budget and check exact match against expectation.
      case bootstrap.read_bounded(workspace <> "/" <> relative, limit) {
        Ok(bytes) ->
          case bytes == bit_array.from_string(expected) {
            True -> Ok(Matches)
            False -> Ok(Differs(relative))
          }
        Error("file exceeds the bounded read limit") -> Ok(Differs(relative))
        Error(reason) -> Error("independent fixture read failed: " <> reason)
      }
    }
  }
}

/// Traverses a path component by component, ensuring intermediate components are
/// actual directories and the leaf is a regular non-symlink file.
fn regular_path(root: String, pieces: List(String)) -> Result(Bool, String) {
  // Check the remaining path components.
  case pieces {
    [] -> Ok(False)
    [name, ..rest] -> {
      let path = root <> "/" <> name

      // Inspect link info to refuse symlinks and verify component types.
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
