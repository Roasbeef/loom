//// The `todo` tool: a strand's phased task list, one operation per call.
////
//// The list is the operator's view of what the agent is doing. The TUI
//// pins it above the composer, and the parent of a subagent can read it
//// off the blackboard, so the tool's job is to keep one small, accurate
//// board current with as little ceremony per update as possible.
////
//// ## Where the board lives, and why that is not a new store
////
//// The board is an ordinary blackboard cell, `agent/{strand}/todo`,
//// holding the JSON `core/todo_list.encode` produces. Keeping it on the
//// blackboard buys three things that a new store would have to rebuild:
//// the cell is durable and survives restart, the run-start notes digest
//// and the compaction snapshot already carry a strand's own cells forward
//// (so the list outlives a compacted context), and peers and parents read
//// it through `agent_notes` with no new door. `agent_note` refuses the
//// `todo` key, so this tool is the only writer and every stored board has
//// passed `todo_list.validate`.
////
//// ## Why the update is a function handed across the seam
////
//// An operation is a read-modify-write: `done` needs the current board to
//// know what to close. Two `todo` calls in one parallel batch would lose
//// one update under a blind last-write-wins cell, and declaring the tool
//// `Exclusive` would fence every batch it appears in, which defeats the
//// point of sending todo updates alongside real work. So the Agency's
//// `todo` slot takes the pure step below and runs it under a
//// compare-and-set on the cell's sequence, retrying on a conflict. The
//// tool stays `Concurrent` and no update is lost.
////
//// ## Replay
////
//// The tool is `replay: Safe`, which obliges every operation to be
//// harmless when re-run with the same arguments after it already landed.
//// Each one is written to its postcondition rather than to a delta:
//// `done` on a done task is a no-op, `append` skips items already in the
//// phase, and `remove` of a task that is already gone succeeds with
//// nothing to remove.

import broker/policy.{type SandboxPolicy}
import core/corruption
import core/json.{type JsonValue}
import core/todo_list.{
  type Board, type Phase, type Status, type Task, Active, Blocked, Board, Done,
  Dropped, Pending, Phase, Task,
}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The name the model calls the tool by.
pub const tool_name = "todo"

/// The blackboard key, relative to the strand's own namespace, that holds
/// the board. `agent_note` refuses it so that this tool is the only writer.
pub const note_key = "todo"

/// The phase name a flat `init` or an `append` with no phase uses.
pub const default_phase = "Tasks"

/// The most open tasks an error message lists when a task is not found.
const max_suggestions = 8

/// Which tasks an operation applies to.
pub type Target {
  /// Every task on the board.
  Everything

  /// Every task in the named phase.
  WholePhase(name: String)

  /// The one task with this text.
  OneTask(text: String)
}

/// One `todo` call, parsed.
pub type Op {
  /// Replaces the board with these phases, every task pending.
  Init(phases: List(#(String, List(String))))

  /// Makes one task the active one.
  Start(text: String)

  /// Marks the targeted tasks done.
  Finish(target: Target)

  /// Marks the targeted tasks dropped.
  Drop(target: Target)

  /// Marks the targeted open tasks blocked.
  Block(target: Target, reason: Option(String))

  /// Returns the targeted blocked tasks to pending.
  Unblock(target: Target)

  /// Adds tasks to a phase, creating the phase at the end if it is new.
  Append(phase: String, items: List(String))

  /// Deletes the targeted tasks, or a whole phase.
  Remove(target: Target)

  /// Changes nothing and reports the board.
  View
}

/// The `todo` tool over an update door.
///
/// `update` runs a pure step against the stored cell and commits what it
/// returns, answering the committed value or a reason it could not. The
/// Agency supplies it (`agent.tools`), bound to the calling strand.
///
/// ## Examples
///
/// ```gleam
/// // todos.tool(fn(ctx, step) { agency_todo(agent.caller(ctx), step) })
/// ```
pub fn tool(
  update: fn(Ctx, fn(Option(JsonValue)) -> Result(JsonValue, String)) ->
    Result(JsonValue, String),
) -> Tool {
  tool.Tool(
    name: tool_name,
    description: description,
    prompt_snippet: Some(
      "`todo` keeps your phased task list, which the operator sees pinned "
      <> "above their input.",
    ),
    schema: schema(),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: no_requirements,
    run: fn(ctx, args) { run(update, ctx, args) },
  )
}

const description = "Keep a phased todo list for work with three or more steps, and keep it current as you go. The operator sees it pinned above their input, and it is how they follow your progress. One op per call.\n\n`init` replaces the list: pass `phases` as [{name, items}], or a flat `items` list for a single phase. Refer to a task by its exact text, never by a number. `start` makes one task the active one. `done` or `drop` closes a `task`, a whole `phase`, or everything when you give neither. `block` marks a task or phase you cannot act on (waiting on the operator, another agent, or an outside service), with an optional `reason`; `unblock` reopens it. `append` adds `items` to a `phase`, creating the phase if it is new. `remove` deletes a task, a phase, or everything. `view` shows the list. After every change, the first open task becomes active if none is.\n\nWrite each task as a short label of 5 to 10 words saying what, not how, and name phases with short nouns and no numbering. Mark a task done as soon as it is finished. Send todo calls in the same batch as the work they describe, not alone. When the operator gives you a list of steps or items, put every one on the list instead of a summary. The list is kept with your notes, so it survives compaction; `view` recovers the exact task text."

fn schema() -> JsonValue {
  let phases =
    json.Object([
      #("type", json.String("array")),
      #(
        "description",
        json.String("for `init`: the phases in order, each with its tasks"),
      ),
      #(
        "items",
        tool.object_schema(
          [
            #("name", tool.string_property("a short phase name")),
            #("items", tool.string_array_property("the phase's tasks")),
          ],
          ["name", "items"],
        ),
      ),
    ])

  tool.object_schema(
    [
      #(
        "op",
        tool.enum_property(
          [
            "init", "start", "done", "drop", "block", "unblock", "append",
            "remove", "view",
          ],
          "the operation",
        ),
      ),
      #("phases", phases),
      #(
        "items",
        tool.string_array_property(
          "tasks to add with `append`, or a single-phase `init`",
        ),
      ),
      #(
        "phase",
        tool.string_property(
          "a phase name: the target of `append`, or of a phase-wide op",
        ),
      ),
      #(
        "task",
        tool.string_property(
          "a task's exact text. REQUIRED for `start`; `block` and `unblock` "
          <> "need it or a `phase`; `done`, `drop` and `remove` act on "
          <> "everything when neither is given",
        ),
      ),
      #("reason", tool.string_property("for `block`: what the task waits on")),
    ],
    ["op"],
  )
}

fn run(
  update: fn(Ctx, fn(Option(JsonValue)) -> Result(JsonValue, String)) ->
    Result(JsonValue, String),
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use op <- tool.with_arg(parse(args))
  let committed = update(ctx, fn(stored) { step(stored, op) })

  // The committed value is decoded again rather than threaded out of the
  // step, because the step may have run more than once under a
  // compare-and-set retry and only the value that landed is the truth.
  let landed =
    result.try(committed, fn(value) {
      todo_list.decode(value) |> result.map_error(corruption.describe)
    })
  case landed {
    Error(reason) ->
      tool.failure("todo: " <> reason)
      |> tool.with_details(
        json.Object([
          #("error", json.String("todo_refused")),
          #("reason", json.String(reason)),
        ]),
      )
    Ok(board) ->
      tool.success(render(board))
      |> tool.with_details(
        json.Object([
          #("op", json.String(op_name(op))),
          #("todo", todo_list.encode(board)),
        ]),
      )
  }
}

/// Applies one operation to a stored cell and answers the value to store.
///
/// A stored cell that does not decode is refused for every operation but
/// `init`, which replaces it: the model can always recover by laying the
/// list out again, and nothing else should build on a board it cannot
/// read.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(value) = todos.step(option.None, todos.Init([#("Build", ["a"])]))
/// ```
pub fn step(stored: Option(JsonValue), op: Op) -> Result(JsonValue, String) {
  use board <- result.try(current(stored, op))
  use board <- result.map(apply(board, op))
  todo_list.encode(board)
}

fn current(stored: Option(JsonValue), op: Op) -> Result(Board, String) {
  case stored, op {
    None, _ -> Ok(todo_list.empty())
    Some(_), Init(_) -> Ok(todo_list.empty())
    Some(value), _ ->
      todo_list.decode(value)
      |> result.map_error(fn(report) {
        "the stored list is unreadable ("
        <> corruption.describe(report)
        <> "); `init` replaces it"
      })
  }
}

/// Applies one operation, then restores the single-active-task rule and
/// checks every bound. Pure, and the whole of the tool's semantics.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(board) = todos.apply(todo_list.empty(), todos.Init([#("Build", ["a", "b"])]))
/// assert todo_list.active(board) != option.None
/// ```
pub fn apply(board: Board, op: Op) -> Result(Board, String) {
  use changed <- result.try(change(board, op))
  use board <- result.try(settle(changed) |> todo_list.validate)
  distinct_loosely(board)
}

// `resolve` falls back to a match that ignores case and spacing, so two
// tasks equal under that match would let a replayed `remove`, whose exact
// target is gone, delete the other one. Refusing such a pair when it is
// written keeps the loose match to at most one candidate.
fn distinct_loosely(board: Board) -> Result(Board, String) {
  let texts =
    list.flat_map(board.phases, fn(phase) {
      list.map(phase.tasks, fn(task) { task.text })
    })
  let outcome =
    list.try_fold(texts, dict.new(), fn(seen, text) {
      let key = normalize(text)
      case dict.get(seen, key) {
        Ok(other) -> Error(#(other, text))
        Error(Nil) -> Ok(dict.insert(seen, key, text))
      }
    })
  case outcome {
    Ok(_) -> Ok(board)
    Error(#(first, second)) ->
      Error(
        "tasks "
        <> string.inspect(first)
        <> " and "
        <> string.inspect(second)
        <> " differ only in case or spacing; task text must be distinct",
      )
  }
}

fn change(board: Board, op: Op) -> Result(Board, String) {
  case op {
    View -> Ok(board)
    Init(phases) -> init(phases)
    Start(text) -> start(board, text)
    Finish(target) -> restatus(board, target, fn(_) { Done })
    Drop(target) -> restatus(board, target, fn(_) { Dropped })
    Block(target, reason) ->
      restatus(board, target, fn(task) {
        case todo_list.is_open(task) {
          True -> Blocked(blocker(reason))
          False -> task.status
        }
      })
    Unblock(target) ->
      restatus(board, target, fn(task) {
        case task.status {
          Blocked(_) -> Pending
          Pending | Active | Done | Dropped -> task.status
        }
      })
    Append(phase, items) -> append(board, phase, items)
    Remove(target) -> remove(board, target)
  }
}

fn init(phases: List(#(String, List(String)))) -> Result(Board, String) {
  use <- guard_empty(phases, fn() { "`init` needs at least one phase" })
  list.try_map(phases, fn(entry) {
    let #(name, items) = entry
    use <- guard_empty(items, fn() {
      "phase " <> string.inspect(name) <> " has no items"
    })
    Ok(Phase(
      name:,
      tasks: list.map(items, fn(text) { Task(text:, status: Pending) }),
    ))
  })
  |> result.map(Board)
}

// Starting a task demotes whichever task was active, so the board keeps
// its single active task without the model having to close the old one
// first.
fn start(board: Board, text: String) -> Result(Board, String) {
  use text <- result.map(resolve(board, text))
  map_tasks(board, fn(_, task) {
    case task.text == text, task.status {
      True, _ -> Task(..task, status: Active)
      False, Active -> Task(..task, status: Pending)
      False, _ -> task
    }
  })
}

fn restatus(
  board: Board,
  target: Target,
  status: fn(Task) -> Status,
) -> Result(Board, String) {
  use matches <- result.map(matcher(board, target))
  map_tasks(board, fn(phase, task) {
    case matches(phase, task) {
      True -> Task(..task, status: status(task))
      False -> task
    }
  })
}

// Items already in the target phase are skipped, which is what makes a
// replayed append harmless. An item that exists in a different phase is
// refused, because task text is the task's identity and a second copy
// would make every later reference to it ambiguous.
fn append(
  board: Board,
  phase: String,
  items: List(String),
) -> Result(Board, String) {
  use <- guard_empty(items, fn() { "`append` needs at least one item" })
  let existing = find_phase(board, phase)
  let here = case existing {
    Some(found) -> list.map(found.tasks, fn(task) { task.text })
    None -> []
  }
  let elsewhere =
    board.phases
    |> list.filter(fn(other) { other.name != phase })
    |> list.flat_map(fn(other) { other.tasks })
    |> list.map(fn(task) { task.text })
  use Nil <- result.try(
    list.try_each(items, fn(item) {
      case list.contains(elsewhere, item) {
        True ->
          Error(
            "task "
            <> string.inspect(item)
            <> " is already in another phase; task text must be unique",
          )
        False -> Ok(Nil)
      }
    }),
  )

  let fresh =
    items
    |> list.unique
    |> list.filter(fn(item) { !list.contains(here, item) })
    |> list.map(fn(text) { Task(text:, status: Pending) })
  case existing {
    None ->
      Ok(Board(list.append(board.phases, [Phase(name: phase, tasks: fresh)])))
    Some(_) ->
      Ok(
        Board(
          list.map(board.phases, fn(other) {
            case other.name == phase {
              True -> Phase(..other, tasks: list.append(other.tasks, fresh))
              False -> other
            }
          }),
        ),
      )
  }
}

// Removal answers to its postcondition: a task or phase that is already
// absent is not an error, so a replayed remove succeeds. Removing a phase
// deletes the phase itself, not just its tasks, since an empty phase has
// nothing left to show.
fn remove(board: Board, target: Target) -> Result(Board, String) {
  case target {
    Everything -> Ok(todo_list.empty())
    WholePhase(name) ->
      Ok(Board(list.filter(board.phases, fn(phase) { phase.name != name })))
    OneTask(text) ->
      case resolve(board, text) {
        Error(_) -> Ok(board)
        Ok(text) ->
          Ok(
            Board(
              list.map(board.phases, fn(phase) {
                Phase(
                  ..phase,
                  tasks: list.filter(phase.tasks, fn(task) { task.text != text }),
                )
              }),
            ),
          )
      }
  }
}

/// Restores the single-active-task rule: when several tasks are active
/// only the first stays so, and when none is, the first pending task in
/// board order becomes active. A blocked task is never promoted, so a
/// board whose open work is all blocked has no active task, which is the
/// truthful answer.
///
/// ## Examples
///
/// ```gleam
/// let board = todo_list.Board([todo_list.Phase("P", [todo_list.Task("a", todo_list.Pending)])])
/// assert todo_list.active(todos.settle(board)) != option.None
/// ```
pub fn settle(board: Board) -> Board {
  case todo_list.active(board) {
    Some(_) -> keep_first_active(board)
    None -> promote_first_pending(board)
  }
}

// The flag threaded through both passes is whether the board's one active
// slot has been taken by an earlier task in board order.
fn keep_first_active(board: Board) -> Board {
  fold_tasks(board, fn(taken, task) {
    case task.status, taken {
      Active, False -> #(True, task)
      Active, True -> #(True, Task(..task, status: Pending))
      Pending, _ | Done, _ | Dropped, _ | Blocked(_), _ -> #(taken, task)
    }
  })
}

fn promote_first_pending(board: Board) -> Board {
  fold_tasks(board, fn(taken, task) {
    case task.status, taken {
      Pending, False -> #(True, Task(..task, status: Active))
      Pending, True | Active, _ | Done, _ | Dropped, _ | Blocked(_), _ -> #(
        taken,
        task,
      )
    }
  })
}

fn fold_tasks(board: Board, with: fn(Bool, Task) -> #(Bool, Task)) -> Board {
  let #(_, phases) =
    list.map_fold(board.phases, False, fn(taken, phase) {
      let #(taken, tasks) = list.map_fold(phase.tasks, taken, with)
      #(taken, Phase(..phase, tasks:))
    })
  Board(phases)
}

// --- targeting ---------------------------------------------------------------

// A target is checked against the board before anything changes, so a
// misspelled task is an error naming the open tasks rather than a silent
// no-op.
fn matcher(
  board: Board,
  target: Target,
) -> Result(fn(Phase, Task) -> Bool, String) {
  case target {
    Everything -> Ok(fn(_, _) { True })
    WholePhase(name) ->
      case find_phase(board, name) {
        Some(_) -> Ok(fn(phase: Phase, _) { phase.name == name })
        None -> Error(missing_phase(board, name))
      }
    OneTask(text) -> {
      use text <- result.map(resolve(board, text))
      fn(_, task: Task) { task.text == text }
    }
  }
}

/// Finds the stored text of the task a model named. An exact match wins;
/// failing that, a single match that differs only in case and spacing is
/// accepted, because a model quoting a task back from memory most often
/// gets exactly that wrong. Anything else is an error listing the open
/// tasks, which is the list the model needs to correct itself.
///
/// ## Examples
///
/// ```gleam
/// let board = todo_list.Board([todo_list.Phase("P", [todo_list.Task("Ship it", todo_list.Pending)])])
/// assert todos.resolve(board, "ship  it") == Ok("Ship it")
/// ```
pub fn resolve(board: Board, text: String) -> Result(String, String) {
  let tasks = list.flat_map(board.phases, fn(phase) { phase.tasks })
  let exact = list.find(tasks, fn(task) { task.text == text })
  let loose = fn() {
    let wanted = normalize(text)
    case list.filter(tasks, fn(task) { normalize(task.text) == wanted }) {
      [only] -> Ok(only)
      [] | [_, _, ..] -> Error(Nil)
    }
  }
  exact
  |> result.lazy_or(loose)
  |> result.map(fn(task) { task.text })
  |> result.map_error(fn(_) { missing_task(tasks, text) })
}

fn normalize(text: String) -> String {
  text
  |> string.lowercase
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
}

fn missing_task(tasks: List(Task), text: String) -> String {
  let open =
    tasks
    |> list.filter(todo_list.is_open)
    |> list.take(max_suggestions)
    |> list.map(fn(task) { string.inspect(task.text) })
  "no task "
  <> string.inspect(text)
  <> " on the list"
  <> case open {
    [] -> ""
    _ -> "; open tasks: " <> string.join(open, ", ")
  }
}

fn missing_phase(board: Board, name: String) -> String {
  let names = list.map(board.phases, fn(phase) { string.inspect(phase.name) })
  "no phase "
  <> string.inspect(name)
  <> " on the list"
  <> case names {
    [] -> ""
    _ -> "; phases: " <> string.join(names, ", ")
  }
}

fn find_phase(board: Board, name: String) -> Option(Phase) {
  list.find(board.phases, fn(phase) { phase.name == name })
  |> option.from_result
}

fn map_tasks(board: Board, with: fn(Phase, Task) -> Task) -> Board {
  Board(
    list.map(board.phases, fn(phase) {
      Phase(
        ..phase,
        tasks: list.map(phase.tasks, fn(task) { with(phase, task) }),
      )
    }),
  )
}

// The reason is a thunk because one of them is built from a phase name,
// and it is needed only on the path that refuses.
fn guard_empty(
  items: List(a),
  reason: fn() -> String,
  continue: fn() -> Result(b, String),
) -> Result(b, String) {
  case items {
    [] -> Error(reason())
    [_, ..] -> continue()
  }
}

// A reason that is blank once flattened is no reason, rather than a board
// that fails validation for a blank field the model never meant to set.
fn blocker(reason: Option(String)) -> Option(String) {
  case option.map(reason, one_line) {
    Some("") | None -> None
    Some(text) -> Some(text)
  }
}

fn one_line(text: String) -> String {
  text
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> string.trim
}

// --- parsing -----------------------------------------------------------------

/// Parses a call's arguments into an operation.
///
/// ## Examples
///
/// ```gleam
/// assert todos.parse(json.Object([#("op", json.String("view"))])) == Ok(todos.View)
/// ```
pub fn parse(args: JsonValue) -> Result(Op, String) {
  use op <- result.try(tool.required_string(args, "op"))
  case op {
    "view" -> Ok(View)
    "init" -> parse_init(args)
    "start" -> tool.required_string(args, "task") |> result.map(Start)
    "done" -> target(args, Everything) |> result.map(Finish)
    "drop" -> target(args, Everything) |> result.map(Drop)
    "remove" -> target(args, Everything) |> result.map(Remove)
    "block" -> {
      use target <- result.try(required_target(args, "block"))
      use reason <- result.map(tool.optional_string(args, "reason"))
      Block(target:, reason:)
    }
    "unblock" -> required_target(args, "unblock") |> result.map(Unblock)
    "append" -> {
      use phase <- result.try(tool.optional_string(args, "phase"))
      use items <- result.map(required_items(args, "append"))
      Append(phase: option.unwrap(phase, default_phase), items:)
    }
    other -> Error("unknown op " <> string.inspect(other))
  }
}

fn parse_init(args: JsonValue) -> Result(Op, String) {
  use phases <- result.try(tool.optional_value(args, "phases"))
  case phases {
    Some(json.Array(entries)) ->
      list.try_map(entries, parse_phase) |> result.map(Init)
    Some(json.Null) | None -> {
      use phase <- result.try(tool.optional_string(args, "phase"))
      use items <- result.map(required_items(args, "init"))
      Init([#(option.unwrap(phase, default_phase), items)])
    }
    Some(_) -> Error("`phases` must be an array of {name, items}")
  }
}

fn parse_phase(entry: JsonValue) -> Result(#(String, List(String)), String) {
  use name <- result.try(tool.required_string(entry, "name"))
  use items <- result.try(tool.optional_string_list(entry, "items"))
  case items {
    Some(items) -> Ok(#(name, items))
    None -> Error("phase " <> string.inspect(name) <> " needs `items`")
  }
}

fn required_items(args: JsonValue, op: String) -> Result(List(String), String) {
  use items <- result.try(tool.optional_string_list(args, "items"))
  case items {
    Some([_, ..] as items) -> Ok(items)
    Some([]) | None -> Error("`" <> op <> "` needs a non-empty `items` list")
  }
}

// A call naming both a task and a phase is refused rather than guessed
// at: whichever one the tool picked, the model meant the other half the
// time.
fn target(args: JsonValue, fallback: Target) -> Result(Target, String) {
  use task <- result.try(tool.optional_string(args, "task"))
  use phase <- result.try(tool.optional_string(args, "phase"))
  case task, phase {
    Some(_), Some(_) -> Error("give either `task` or `phase`, not both")
    Some(text), None -> Ok(OneTask(text))
    None, Some(name) -> Ok(WholePhase(name))
    None, None -> Ok(fallback)
  }
}

fn required_target(args: JsonValue, op: String) -> Result(Target, String) {
  use found <- result.try(target(args, Everything))
  case found {
    Everything -> Error("`" <> op <> "` needs a `task` or a `phase`")
    WholePhase(_) | OneTask(_) -> Ok(found)
  }
}

fn op_name(op: Op) -> String {
  case op {
    Init(_) -> "init"
    Start(_) -> "start"
    Finish(_) -> "done"
    Drop(_) -> "drop"
    Block(..) -> "block"
    Unblock(_) -> "unblock"
    Append(..) -> "append"
    Remove(_) -> "remove"
    View -> "view"
  }
}

// --- rendering ---------------------------------------------------------------

/// Renders the board as the text the model reads back: a one-line
/// summary, then each phase with its tally and a checklist. The marks are
/// plain ASCII so the text reads the same in any transcript.
///
/// ## Examples
///
/// ```gleam
/// assert todos.render(todo_list.empty()) == "todo list is empty"
/// ```
pub fn render(board: Board) -> String {
  case board.phases {
    [] -> "todo list is empty"
    [_, ..] ->
      [summary(board), ..list.map(board.phases, render_phase)]
      |> string.join("\n")
  }
}

fn summary(board: Board) -> String {
  let #(closed, total) = todo_list.count(board)
  let tally = int.to_string(closed) <> "/" <> int.to_string(total) <> " closed"
  case todo_list.active(board), closed == total {
    Some(#(phase, task)), _ ->
      tally <> "; active: " <> task.text <> " (" <> phase.name <> ")"
    None, True -> tally <> "; every task is closed"
    None, False -> tally <> "; no active task: the open work is blocked"
  }
}

fn render_phase(phase: Phase) -> String {
  let #(closed, total) = todo_list.tally(phase.tasks)
  let heading =
    "## "
    <> phase.name
    <> " "
    <> int.to_string(closed)
    <> "/"
    <> int.to_string(total)
  [heading, ..list.map(phase.tasks, render_task)]
  |> string.join("\n")
}

fn render_task(task: Task) -> String {
  let mark = case task.status {
    Pending -> "[ ]"
    Active -> "[>]"
    Done -> "[x]"
    Dropped -> "[-]"
    Blocked(_) -> "[!]"
  }
  let reason = case task.status {
    Blocked(Some(reason)) -> " (blocked: " <> reason <> ")"
    Blocked(None) | Pending | Active | Done | Dropped -> ""
  }
  mark <> " " <> task.text <> reason
}

// The tool touches no filesystem and spawns no process, so it asks the
// broker for nothing and composes with any session base.
fn no_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
