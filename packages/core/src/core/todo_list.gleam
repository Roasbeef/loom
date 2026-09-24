//// A strand's todo board: its shape, its bounds, and its one total codec.
////
//// The board is written by the `todo` tool (`tools/todos`), stored as an
//// ordinary blackboard cell under `agent/{strand}/todo`, carried to clients
//// in the tool result's `details`, and read back by the TUI to draw the
//// pinned progress panel. Those are three readers on two sides of a wire,
//// so the shape lives here, in the package every one of them already
//// depends on, and each of them decodes it through `decode` rather than
//// through a private reading of the JSON.
////
//// The stored cell is not trusted to be well formed. It is durable data,
//// and a cell written by an older build, or by a future one, must come
//// back as an `Error` naming what is wrong rather than as a crash or a
//// silently emptied board. `decode` is total for that reason.
////
//// Tasks are identified by their text, not by a minted id. A model
//// refers back to a task by quoting it, and a quoted phrase survives
//// compaction and a context reset in a way that `task-7` does not. The
//// cost is that text must be unique across the board, which `validate`
//// enforces for every board that is ever written.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string

/// The most phases one board may hold.
pub const max_phases = 12

/// The most tasks one board may hold, across every phase.
pub const max_tasks = 48

/// The longest a task's text may be, in bytes.
pub const max_text_bytes = 160

/// The longest a phase name may be, in bytes.
pub const max_phase_bytes = 48

/// The longest a blocked task's reason may be, in bytes.
pub const max_reason_bytes = 200

/// Where one task stands.
///
/// Exactly one task on a board is `Active` whenever any task is open and
/// unblocked; `tools/todos.settle` restores that after every change, so a
/// reader can treat "the active task" as the answer to "what is the agent
/// doing now" without searching for a tie-break.
pub type Status {
  /// Not started yet.
  Pending

  /// The one task being worked on now.
  Active

  /// Finished.
  Done

  /// Abandoned on purpose; closed, but not finished.
  Dropped

  /// Waiting on something the agent cannot act on, such as an operator's
  /// decision or another strand's result.
  Blocked(reason: Option(String))
}

/// One task.
pub type Task {
  Task(
    /// The task's text, which is also its identity on the board.
    text: String,
    /// Where the task stands.
    status: Status,
  )
}

/// A named group of tasks, worked through in order.
pub type Phase {
  Phase(
    /// The phase's name, unique on the board.
    name: String,
    /// The phase's tasks, in the order the agent means to do them.
    tasks: List(Task),
  )
}

/// The whole board, phases in order. An empty list is an empty board.
pub type Board {
  Board(phases: List(Phase))
}

/// An empty board.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.count(todo_list.empty()) == #(0, 0)
/// ```
pub fn empty() -> Board {
  Board(phases: [])
}

/// Whether a task is still open: pending, active or blocked.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.is_open(todo_list.Task("Ship it", todo_list.Pending))
/// ```
pub fn is_open(task: Task) -> Bool {
  case task.status {
    Pending | Active | Blocked(_) -> True
    Done | Dropped -> False
  }
}

/// Closed and total task counts for a list of tasks. A dropped task counts
/// as closed, because the question the count answers is how much of the
/// list is still ahead.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.tally([todo_list.Task("a", todo_list.Done), todo_list.Task("b", todo_list.Pending)])
///   == #(1, 2)
/// ```
pub fn tally(tasks: List(Task)) -> #(Int, Int) {
  let closed = list.count(tasks, fn(task) { !is_open(task) })
  #(closed, list.length(tasks))
}

/// Closed and total task counts across the whole board.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.count(todo_list.empty()) == #(0, 0)
/// ```
pub fn count(board: Board) -> #(Int, Int) {
  tally(list.flat_map(board.phases, fn(phase) { phase.tasks }))
}

/// The active task and the phase holding it, if any task is active.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.active(todo_list.empty()) == option.None
/// ```
pub fn active(board: Board) -> Option(#(Phase, Task)) {
  board.phases
  |> list.find_map(fn(phase) {
    list.find(phase.tasks, fn(task) { task.status == Active })
    |> result.map(fn(task) { #(phase, task) })
  })
  |> option.from_result
}

/// The phase a reader should look at first: the one holding the active
/// task, else the first with open work, else the last phase. An empty
/// board has none.
///
/// A board whose open work is all blocked has no active task, and the
/// phase holding that blocked work is still the one that needs attention,
/// which is why the fallback asks for open work rather than for pending
/// work.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.focus(todo_list.empty()) == option.None
/// ```
pub fn focus(board: Board) -> Option(Phase) {
  case active(board) {
    Some(#(phase, _)) -> Some(phase)
    None ->
      list.find(board.phases, fn(phase) { list.any(phase.tasks, is_open) })
      |> result.lazy_or(fn() { list.last(board.phases) })
      |> option.from_result
  }
}

/// Checks a board against every bound and uniqueness rule. Every board the
/// `todo` tool writes passes through here first, so a stored board that
/// fails it was written by something else.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.validate(todo_list.empty()) == Ok(todo_list.empty())
/// ```
pub fn validate(board: Board) -> Result(Board, String) {
  let tasks = list.flat_map(board.phases, fn(phase) { phase.tasks })
  use Nil <- result.try(at_most(list.length(board.phases), max_phases, "phases"))
  use Nil <- result.try(at_most(list.length(tasks), max_tasks, "tasks"))
  use Nil <- result.try(
    list.try_each(board.phases, fn(phase) {
      text_within(phase.name, max_phase_bytes, "a phase name")
    }),
  )
  use Nil <- result.try(list.try_each(tasks, validate_task))
  use Nil <- result.try(unique(
    list.map(board.phases, fn(phase) { phase.name }),
    "phase",
  ))
  use Nil <- result.map(unique(list.map(tasks, fn(task) { task.text }), "task"))
  board
}

fn validate_task(task: Task) -> Result(Nil, String) {
  use Nil <- result.try(text_within(task.text, max_text_bytes, "a task"))
  case task.status {
    Blocked(Some(reason)) ->
      text_within(reason, max_reason_bytes, "a blocked reason")
    Blocked(None) | Pending | Active | Done | Dropped -> Ok(Nil)
  }
}

fn at_most(count: Int, bound: Int, what: String) -> Result(Nil, String) {
  case count > bound {
    True ->
      Error("a board holds at most " <> int.to_string(bound) <> " " <> what)
    False -> Ok(Nil)
  }
}

fn text_within(text: String, bound: Int, what: String) -> Result(Nil, String) {
  let size = string.byte_size(text)
  case string.trim(text) == "", size > bound {
    True, _ -> Error(what <> " must not be blank")
    False, True ->
      Error(
        what
        <> " must be at most "
        <> int.to_string(bound)
        <> " bytes: "
        <> string.inspect(text),
      )
    False, False -> Ok(Nil)
  }
}

// Duplicates are reported by name, because the model has to find the one
// it repeated and the tool's error is the only place it will learn which.
fn unique(names: List(String), what: String) -> Result(Nil, String) {
  let outcome =
    list.try_fold(names, set.new(), fn(seen, name) {
      case set.contains(seen, name) {
        True -> Error(name)
        False -> Ok(set.insert(seen, name))
      }
    })
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(name) -> Error("duplicate " <> what <> " " <> string.inspect(name))
  }
}

// --- the codec ---------------------------------------------------------------

/// The wire and storage name of a status.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.status_name(todo_list.Active) == "active"
/// ```
pub fn status_name(status: Status) -> String {
  case status {
    Pending -> "pending"
    Active -> "active"
    Done -> "done"
    Dropped -> "dropped"
    Blocked(_) -> "blocked"
  }
}

/// Encodes a board as the JSON stored in its cell and carried in the
/// tool's `details`.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.encode(todo_list.empty())
///   == json.Object([#("phases", json.Array([]))])
/// ```
pub fn encode(board: Board) -> JsonValue {
  json.Object([#("phases", json.Array(list.map(board.phases, encode_phase)))])
}

fn encode_phase(phase: Phase) -> JsonValue {
  json.Object([
    #("name", json.String(phase.name)),
    #("tasks", json.Array(list.map(phase.tasks, encode_task))),
  ])
}

// The reason field appears only on a blocked task that has one, so an
// ordinary task stays two fields wide in the digest a model reads.
fn encode_task(task: Task) -> JsonValue {
  let base = [
    #("text", json.String(task.text)),
    #("status", json.String(status_name(task.status))),
  ]
  case task.status {
    Blocked(Some(reason)) ->
      json.Object(list.append(base, [#("reason", json.String(reason))]))
    Blocked(None) | Pending | Active | Done | Dropped -> json.Object(base)
  }
}

/// Decodes a board. Total: anything that is not a board encoded by
/// `encode` is a `CorruptionReport` naming the first thing wrong with it.
/// Bounds are not re-checked here, so a reader can still show an oversized
/// board that something other than the tool wrote; `validate` is the
/// writer's check.
///
/// ## Examples
///
/// ```gleam
/// assert todo_list.decode(todo_list.encode(todo_list.empty()))
///   == Ok(todo_list.empty())
/// ```
///
/// ```gleam
/// let assert Error(_) = todo_list.decode(json.String("not a board"))
/// ```
pub fn decode(value: JsonValue) -> Result(Board, CorruptionReport) {
  use phases <- result.try(array_field(value, "phases", "board"))
  list.try_map(phases, decode_phase)
  |> result.map(Board)
}

fn decode_phase(value: JsonValue) -> Result(Phase, CorruptionReport) {
  use name <- result.try(string_field(value, "name", "phase"))
  use tasks <- result.try(array_field(value, "tasks", "phase"))
  use tasks <- result.map(list.try_map(tasks, decode_task))
  Phase(name:, tasks:)
}

fn decode_task(value: JsonValue) -> Result(Task, CorruptionReport) {
  use text <- result.try(string_field(value, "text", "task"))
  use status <- result.try(string_field(value, "status", "task"))
  use status <- result.map(decode_status(value, status))
  Task(text:, status:)
}

fn decode_status(
  value: JsonValue,
  name: String,
) -> Result(Status, CorruptionReport) {
  case name {
    "pending" -> Ok(Pending)
    "active" -> Ok(Active)
    "done" -> Ok(Done)
    "dropped" -> Ok(Dropped)
    "blocked" ->
      case field(value, "reason") {
        Ok(json.String(reason)) -> Ok(Blocked(Some(reason)))
        Ok(json.Null) | Error(Nil) -> Ok(Blocked(None))
        Ok(other) -> Error(corrupt("task", "a string `reason`", other))
      }
    other ->
      Error(corrupt(
        "task",
        "a status of pending, active, done, dropped or blocked",
        json.String(other),
      ))
  }
}

fn string_field(
  value: JsonValue,
  key: String,
  subject: String,
) -> Result(String, CorruptionReport) {
  case field(value, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) | Error(Nil) ->
      Error(corrupt(subject, "a string `" <> key <> "` field", value))
  }
}

fn array_field(
  value: JsonValue,
  key: String,
  subject: String,
) -> Result(List(JsonValue), CorruptionReport) {
  case field(value, key) {
    Ok(json.Array(items)) -> Ok(items)
    Ok(_) | Error(Nil) ->
      Error(corrupt(subject, "an array `" <> key <> "` field", value))
  }
}

fn corrupt(
  subject: String,
  expected: String,
  seen: JsonValue,
) -> CorruptionReport {
  corruption.report(
    at: "core/todo_list",
    on: subject,
    expected:,
    context: json.to_string(seen),
  )
}

// The first occurrence wins, matching `core/json`'s documented tiebreak
// for hand-built objects with a repeated key.
fn field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, key)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}
