//// `cap/git` — common git operations as typed calls.
////
//// ## Design choice: git rides `cap/proc`
////
//// Rather than a parallel family of broker capabilities (`git.status`,
//// `git.diff`, …), this module builds `git` command lines and runs them
//// through `cap/proc`, parsing the output into typed values. So git needs
//// no broker support beyond `proc.run`, inherits the same jail and pooled
//// budget, and a program that imports `cap/git` transitively holds only
//// the process capability — visible in the vetting closure. The tradeoff
//// is that parsing porcelain output lives here; git's `--porcelain` and
//// plumbing formats are stable contracts, so that is a safe place for it.

import cap/proc
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Why a git operation failed.
pub type GitError {
  /// The git process ran but exited non-zero.
  CommandFailed(exit_code: Int, stderr: String)

  /// The underlying `cap/proc` call failed (denial, spawn, channel).
  ProcessError(error: proc.ProcError)

  /// Git's output could not be parsed into the expected shape.
  ParseError(message: String)
}

/// One line of `git status --porcelain`: the two-character status code
/// and the path it refers to.
pub type StatusEntry {
  StatusEntry(code: String, path: String)
}

/// One commit from `git log`.
pub type Commit {
  Commit(sha: String, subject: String)
}

/// The current branch name (`git rev-parse --abbrev-ref HEAD`).
pub fn current_branch() -> Result(String, GitError) {
  use output <- result.try(run(["rev-parse", "--abbrev-ref", "HEAD"]))
  Ok(string.trim(output.stdout))
}

/// The working-tree status as porcelain entries.
pub fn status() -> Result(List(StatusEntry), GitError) {
  use output <- result.try(run(["status", "--porcelain"]))
  output.stdout
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.map(parse_status_line)
  |> result.all
}

/// The unified diff of the working tree (optionally staged).
pub fn diff(staged staged: Bool) -> Result(String, GitError) {
  let argv = case staged {
    True -> ["diff", "--cached"]
    False -> ["diff"]
  }
  use output <- result.try(run(argv))
  Ok(output.stdout)
}

/// The most recent commits, newest first, at most `limit`.
pub fn log(limit limit: Int) -> Result(List(Commit), GitError) {
  let argv = [
    "log",
    "--max-count=" <> int.to_string(limit),
    "--pretty=format:%H %s",
  ]
  use output <- result.try(run(argv))
  output.stdout
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.map(parse_log_line)
  |> result.all
}

/// Stages the given paths (`git add`).
pub fn add(paths: List(String)) -> Result(Nil, GitError) {
  use _ <- result.try(run(list.append(["add", "--"], paths)))
  Ok(Nil)
}

/// Commits the staged changes with `message` and returns the new commit
/// sha.
pub fn commit(message: String) -> Result(String, GitError) {
  use _ <- result.try(run(["commit", "--message", message]))
  current_sha()
}

fn current_sha() -> Result(String, GitError) {
  use output <- result.try(run(["rev-parse", "HEAD"]))
  Ok(string.trim(output.stdout))
}

// Runs `git ARGV`, mapping a non-zero exit and any proc failure into a
// typed `GitError`. Success guarantees exit code 0.
fn run(argv: List(String)) -> Result(proc.Output, GitError) {
  use output <- result.try(
    proc.run(proc.command(["git", ..argv]))
    |> result.map_error(ProcessError),
  )
  case output.exit_code {
    0 -> Ok(output)
    code -> Error(CommandFailed(exit_code: code, stderr: output.stderr))
  }
}

fn parse_status_line(line: String) -> Result(StatusEntry, GitError) {
  // Porcelain v1: two status chars, a space, then the path.
  case string.length(line) >= 4 {
    True ->
      Ok(StatusEntry(
        code: string.slice(line, 0, 2),
        path: string.trim(string.drop_start(line, 3)),
      ))
    False -> Error(ParseError("short status line: " <> line))
  }
}

fn parse_log_line(line: String) -> Result(Commit, GitError) {
  case string.split_once(line, " ") {
    Ok(#(sha, subject)) -> Ok(Commit(sha:, subject:))
    Error(Nil) -> Error(ParseError("malformed log line: " <> line))
  }
}
