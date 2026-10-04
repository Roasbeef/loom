//// Closed Git observations retain their projection and structured refusals.
////
//// Comparison revisions pass the full-object-ID constructor, never revision
//// expression parsing. Status and log inventories reject repeated logical
//// identities. Command clearance and execution errors keep their nested fields
//// on the separate broker-error boundaries; no argv is part of this schema.

import core/msgpack
import gleam/result
import tools/workspace
import tools/workspace_codec/broker_errors
import tools/workspace_codec/execution_errors
import tools/workspace_codec/value as v

/// Converts the closed workspace.DiffComparison shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn comparison_value(
  value: workspace.DiffComparison,
) -> msgpack.MsgPackValue {
  case value {
    workspace.WorkingTree -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.Staged -> msgpack.ArrayValue([msgpack.IntValue(1)])
    workspace.SinceRevision(revision) ->
      msgpack.ArrayValue([msgpack.IntValue(2), v.revision_value(revision)])
  }
}

/// Converts the closed workspace.DiffComparison shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_comparison(
  value: msgpack.MsgPackValue,
) -> Result(workspace.DiffComparison, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.WorkingTree)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.Staged)
    }
    msgpack.ArrayValue([msgpack.IntValue(2), revision]) -> {
      use revision <- result.try(v.revision(revision))
      Ok(workspace.SinceRevision(revision))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GitQuery shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn query_value(value: workspace.GitQuery) -> msgpack.MsgPackValue {
  case value {
    workspace.CurrentBranch -> msgpack.ArrayValue([msgpack.IntValue(0)])
    workspace.CurrentRevision -> msgpack.ArrayValue([msgpack.IntValue(1)])
    workspace.Status -> msgpack.ArrayValue([msgpack.IntValue(2)])
    workspace.Diff(comparison) ->
      msgpack.ArrayValue([msgpack.IntValue(3), comparison_value(comparison)])
    workspace.Log(limit) ->
      msgpack.ArrayValue([msgpack.IntValue(4), msgpack.IntValue(limit)])
  }
}

/// Converts the closed workspace.GitQuery shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_query(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GitQuery, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> {
      Ok(workspace.CurrentBranch)
    }
    msgpack.ArrayValue([msgpack.IntValue(1)]) -> {
      Ok(workspace.CurrentRevision)
    }
    msgpack.ArrayValue([msgpack.IntValue(2)]) -> {
      Ok(workspace.Status)
    }
    msgpack.ArrayValue([msgpack.IntValue(3), comparison]) -> {
      use comparison <- result.try(parse_comparison(comparison))
      Ok(workspace.Diff(comparison))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), limit]) -> {
      use limit <- result.try(fn(x) { v.range(x, 1, 1000) }(limit))
      Ok(workspace.Log(limit))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GitStatusEntry shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn status_entry_value(
  value: workspace.GitStatusEntry,
) -> msgpack.MsgPackValue {
  case value {
    workspace.GitStatusEntry(code, path) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(code),
        msgpack.StringValue(path),
      ])
  }
}

/// Converts the closed workspace.GitStatusEntry shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_status_entry(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GitStatusEntry, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), code, path]) -> {
      use code <- result.try(v.status_code(code))
      use path <- result.try(v.text(path))
      Ok(workspace.GitStatusEntry(code, path))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GitCommit shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn commit_value(value: workspace.GitCommit) -> msgpack.MsgPackValue {
  case value {
    workspace.GitCommit(sha, subject) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue(sha),
        msgpack.StringValue(subject),
      ])
  }
}

/// Converts the closed workspace.GitCommit shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_commit(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GitCommit, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), sha, subject]) -> {
      use sha <- result.try(v.revision_text(sha))
      use subject <- result.try(v.text(subject))
      Ok(workspace.GitCommit(sha, subject))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GitResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn git_result_value(value: workspace.GitResult) -> msgpack.MsgPackValue {
  case value {
    workspace.BranchObserved(branch) ->
      msgpack.ArrayValue([msgpack.IntValue(0), msgpack.StringValue(branch)])
    workspace.RevisionObserved(revision) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        fn(x) { v.option_value(x, v.revision_value) }(revision),
      ])
    workspace.StatusObserved(entries) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        fn(xs) { v.array(xs, status_entry_value) }(entries),
      ])
    workspace.DiffObserved(diff) ->
      msgpack.ArrayValue([msgpack.IntValue(3), msgpack.StringValue(diff)])
    workspace.LogObserved(commits) ->
      msgpack.ArrayValue([
        msgpack.IntValue(4),
        fn(xs) { v.array(xs, commit_value) }(commits),
      ])
  }
}

/// Converts the closed workspace.GitResult shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_git_result(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GitResult, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), branch]) -> {
      use branch <- result.try(v.text(branch))
      Ok(workspace.BranchObserved(branch))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), revision]) -> {
      use revision <- result.try(fn(x) { v.option_field(x, v.revision) }(
        revision,
      ))
      Ok(workspace.RevisionObserved(revision))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), entries]) -> {
      use entries <- result.try(fn(x) {
        v.inventory(x, 8192, parse_status_entry)
      }(entries))
      use Nil <- result.try(v.unique_keys(entries, fn(entry) { entry.path }))
      Ok(workspace.StatusObserved(entries))
    }
    msgpack.ArrayValue([msgpack.IntValue(3), diff]) -> {
      use diff <- result.try(v.content(diff))
      Ok(workspace.DiffObserved(diff))
    }
    msgpack.ArrayValue([msgpack.IntValue(4), commits]) -> {
      use commits <- result.try(fn(x) { v.inventory(x, 1000, parse_commit) }(
        commits,
      ))
      use Nil <- result.try(v.unique_keys(commits, fn(commit) { commit.sha }))
      Ok(workspace.LogObserved(commits))
    }
    _ -> Error(Nil)
  }
}

/// Converts the closed workspace.GitError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn git_error_value(value: workspace.GitError) -> msgpack.MsgPackValue {
  case value {
    workspace.CommandRefused(refusal) ->
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        broker_errors.refusal_value(refusal),
      ])
    workspace.ExecutionFailed(failure) ->
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        execution_errors.failure_value(failure),
      ])
    workspace.CommandFailed(exit_code, stderr) ->
      msgpack.ArrayValue([
        msgpack.IntValue(2),
        msgpack.IntValue(exit_code),
        msgpack.StringValue(stderr),
      ])
    workspace.InvalidObservation -> msgpack.ArrayValue([msgpack.IntValue(3)])
  }
}

/// Converts the closed workspace.GitError shape in the positional workspace schema.
///
/// ## Examples
///
/// The enclosing workspace codec validates this value before accepting bytes.
@internal
pub fn parse_git_error(
  value: msgpack.MsgPackValue,
) -> Result(workspace.GitError, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), refusal]) -> {
      use refusal <- result.try(broker_errors.parse_refusal(refusal))
      Ok(workspace.CommandRefused(refusal))
    }
    msgpack.ArrayValue([msgpack.IntValue(1), failure]) -> {
      use failure <- result.try(execution_errors.parse_failure(failure))
      Ok(workspace.ExecutionFailed(failure))
    }
    msgpack.ArrayValue([msgpack.IntValue(2), exit_code, stderr]) -> {
      use exit_code <- result.try(v.integer(exit_code))
      use stderr <- result.try(v.diagnostic(stderr))
      Ok(workspace.CommandFailed(exit_code, stderr))
    }
    msgpack.ArrayValue([msgpack.IntValue(3)]) -> {
      Ok(workspace.InvalidObservation)
    }
    _ -> Error(Nil)
  }
}
