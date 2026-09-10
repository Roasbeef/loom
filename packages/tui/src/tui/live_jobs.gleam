//// Live jobs are an explicit current read, independent of a completed run.
//// Missing or refused observations stay unavailable instead of becoming zero.

import core/json
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tui/text_hygiene

/// One bounded currently nonterminal job.
pub type Job {
  Job(
    /// Stable job identity.
    id: String,
    /// Starting, running, or draining at observation time.
    state: String,
    /// Operation which started this job, possibly an earlier run.
    started_by: String,
    /// Bounded command excerpt, never inferred from old history.
    command: String,
    /// Observed elapsed age in milliseconds.
    age_ms: Int,
    /// Absolute deadline in the same server clock domain.
    deadline_ms: Int,
  )
}

/// A timestamped current roster with explicit omission accounting.
pub type Board {
  Board(
    /// Strand whose live jobs were read.
    strand: String,
    /// Server clock when the roster was observed.
    observed_at_ms: Int,
    /// At most sixty-four retained live jobs.
    jobs: List(Job),
    /// Total live jobs before omission.
    total: Int,
    /// Omitted live rows.
    omitted: Int,
  )
}

/// Validates current live-job observations without retaining historical jobs.
///
/// ## Examples
///
/// ```gleam
/// // live_jobs.decode(board)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > 48_000,
    Error("oversized live jobs observation"),
  )
  use fields <- result.try(object(value))
  use strand <- result.try(text(fields, "strand"))
  use observed <- result.try(number(fields, "observed_at_ms"))
  use total <- result.try(number(fields, "total"))
  use omitted <- result.try(number(fields, "omitted"))
  use raw <- result.try(case list.key_find(fields, "jobs") {
    Ok(json.Array(rows)) -> Ok(rows)
    _ -> Error("missing live jobs")
  })
  use <- bool.guard(list.drop(raw, 64) != [], Error("too many live jobs"))
  use jobs <- result.try(list.try_map(raw, decode_job))
  let ids = dict.from_list(list.map(jobs, fn(job) { #(job.id, Nil) }))
  use <- bool.guard(
    total < 0
      || omitted < 0
      || total != list.length(jobs) + omitted
      || dict.size(ids) != list.length(jobs),
    Error("inconsistent live jobs observation"),
  )
  Ok(Board(strand, observed, jobs, total, omitted))
}

fn decode_job(value) {
  use fields <- result.try(object(value))
  use id <- result.try(text(fields, "id"))
  use state <- result.try(text(fields, "state"))
  use started_by <- result.try(text(fields, "started_by"))
  use command <- result.try(text(fields, "command_excerpt"))
  use age <- result.try(number(fields, "age_ms"))
  use deadline <- result.try(number(fields, "deadline_ms"))
  use <- bool.guard(
    id == ""
      || started_by == ""
      || age < 0
      || string.byte_size(command) > 512
      || !list.contains(["starting", "running", "draining"], state),
    Error("invalid live job"),
  )
  Ok(Job(id, state, started_by, command, age, deadline))
}

/// Describes only the observed roster and identifies its separate timestamp.
///
/// ## Examples
///
/// ```gleam
/// // live_jobs.lines(board)
/// ```
pub fn lines(board: Board) -> List(String) {
  [
    "Live jobs: "
      <> int.to_string(board.total)
      <> " · observed at "
      <> int.to_string(board.observed_at_ms)
      <> " ms",
    ..list.map(board.jobs, fn(job) {
      text_hygiene.single_line(
        job.id
        <> " · "
        <> job.state
        <> " · started by "
        <> job.started_by
        <> " · "
        <> job.command,
      )
      <> " · age "
      <> int.to_string(job.age_ms)
      <> " ms · deadline "
      <> int.to_string(job.deadline_ms)
      <> " ms"
    })
  ]
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected live jobs object")
  }
}

fn text(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing live jobs text: " <> name)
  }
}

fn number(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error("invalid live jobs number: " <> name)
  }
}
