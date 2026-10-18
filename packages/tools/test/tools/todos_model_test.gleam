//// Model-based test of the `todo` tool's pure semantics, `todos.apply`.
////
//// `todos_test` pins the tool with worked examples. This module adds the
//// other half: a generated sequence of operations, run against the real
//// `apply` and against an independent reference of what the module doc and
//// `packages/tools/CLAUDE.md` say the board does, with the board's stated
//// rules checked after every step. `statem` generates and shrinks the
//// sequences, so a failure is reported as the few operations that break a
//// rule rather than a thirty-operation transcript.
////
//// ## What is checked, and where it is stated
////
//// Each rule has its own `Violation` tag, because shrinking keeps a failure
//// to the tag it started with and two different bugs must not be able to
//// trade places. The first six are properties of every board `apply`
//// answers, and are checked before the reference is consulted so that they
//// fail by their own name rather than as a generic disagreement:
////
//// - `todos.valid` — "every stored board has passed `todo_list.validate`"
////   (todos module doc, "Where the board lives").
//// - `todos.single_active` — "Exactly one task on a board is `Active`
////   whenever any task is open and unblocked" (`core/todo_list.Status`),
////   so never more than one.
//// - `todos.promotion` — `settle`: when none is active "the first pending
////   task in board order becomes active"; a blocked task never is. So a
////   board with a pending task has an active one.
//// - `todos.distinct` — `distinct_loosely`: no two tasks are equal under the
////   case- and spacing-insensitive match, which is what keeps a replayed
////   `remove` from deleting the wrong task.
//// - `todos.replay` — "`replay: Safe` ... obliges every operation to be
////   harmless when re-run with the same arguments after it already landed":
////   applying the same operation to its own result answers the same board.
//// - `todos.step` — the stored-cell path (`step`, as the Agency runs it
////   under compare-and-set) answers `encode` of what `apply` answered, and
////   refuses exactly when `apply` does.
////
//// Then `todos.codec` (`decode` reads back what `encode` wrote), `todos.view`
//// ("`View` changes nothing") and `todos.model`, the differential against
//// the reference below, which covers targeting, loose matching, append's
//// skipping and refusing, and the bounds.
////
//// ## Commands name tasks by index
////
//// A command refers to a task or a phase by an index taken modulo the
//// model's collection size, or by a spelling of the task text (exact or
//// loosened in case and spacing), so deleting earlier commands while
//// shrinking leaves later ones meaningful. Every command is admissible in
//// every model: a command that names nothing that exists is a command the
//// tool must refuse, and refusing is behaviour under test. The generator
//// reads only the model, never the system under test.
////
//// ## Reading the model and the system
////
//// The model is the board the reference says the sequence has produced. The
//// system under test is the board `apply` has produced. They are equal after
//// every passing step, which `todos.model` asserts, so a drift names the
//// operation that caused it.

import core/todo_list.{
  type Board, type Phase, type Task, Active, Blocked, Board, Done, Dropped,
  Pending, Phase, Task,
}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem.{type Spec, type Violation, Admit, Spec, Violation}
import tools/todos

// --- configuration -----------------------------------------------------------

/// Fixed so a red gate is the same red gate on every machine; changing it
/// re-draws every sequence.
const seed = 20_261_017

/// How many generated sequences the main property runs.
const test_count = 250

/// The longest sequence. Greedy shrinking is quadratic in this, and twenty
/// operations is enough to build a board, close part of it and replay.
const max_commands = 20

// --- commands ----------------------------------------------------------------

/// How a command spells a task's text.
type Spelling {
  /// The stored text, byte for byte.
  Exact

  /// Upper-cased with every space doubled, which only the loose match
  /// accepts.
  Loose
}

/// Which task a command means.
type Pick {
  /// The task at this position in board order, modulo the task count. A
  /// board with no tasks yields a text that matches nothing.
  TaskAt(index: Int, spelling: Spelling)

  /// Exactly this text, whether or not any task carries it.
  TaskNamed(text: String)
}

/// Which phase a command means.
type Where {
  /// The phase at this position, modulo the phase count. A board with no
  /// phase yields a name that matches nothing.
  PhaseAt(index: Int)

  /// This name, whether or not any phase carries it.
  PhaseNamed(name: String)
}

/// Which tasks a command applies to.
type Aim {
  /// Every task on the board.
  AllTasks

  /// Every task of one phase.
  InPhase(phase: Where)

  /// One task.
  One(task: Pick)
}

/// One `todo` call, with its targets named relative to the model.
type Cmd {
  /// A valid layout, `phases` phases of `per_phase` tasks each, so boards
  /// are usually non-empty. Large values cross the phase and task bounds.
  Lay(phases: Int, per_phase: Int)

  /// An arbitrary `init`, free to be refused (empty, blank, duplicated).
  InitRaw(phases: List(#(String, List(String))))

  /// `start`.
  StartTask(task: Pick)

  /// `done`.
  FinishAim(aim: Aim)

  /// `drop`.
  DropAim(aim: Aim)

  /// `block`; the tool refuses to parse one with no target, so `aim` is
  /// never `AllTasks` here.
  BlockAim(aim: Aim, reason: Option(String))

  /// `unblock`, likewise never `AllTasks`.
  UnblockAim(aim: Aim)

  /// `append`.
  AppendTo(phase: Where, items: List(String))

  /// `remove`.
  RemoveAim(aim: Aim)

  /// `view`.
  ViewBoard
}

fn describe(cmd: Cmd) -> String {
  string.inspect(cmd)
}

// --- generators --------------------------------------------------------------

fn choose(first: a, rest: List(a)) -> qcheck.Generator(a) {
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

// A small pool so that duplicates, loose duplicates and blanks all happen
// within a sequence; most draws are plain distinct words.
fn text_gen() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(#(6, choose("alpha", ["beta", "gamma"])), [
    #(2, choose("Alpha", ["delta  x", "Delta x", "epsilon"])),
    #(1, qcheck.return("")),
  ])
}

fn phase_name_gen() -> qcheck.Generator(String) {
  choose("P1", ["P2", "P3", "Tasks"])
}

fn spelling_gen() -> qcheck.Generator(Spelling) {
  qcheck.from_weighted_generators(#(3, qcheck.return(Exact)), [
    #(1, qcheck.return(Loose)),
  ])
}

fn pick_gen() -> qcheck.Generator(Pick) {
  qcheck.from_weighted_generators(
    #(
      6,
      qcheck.map2(qcheck.bounded_int(from: 0, to: 7), spelling_gen(), TaskAt),
    ),
    [#(1, qcheck.map(text_gen(), TaskNamed))],
  )
}

fn where_gen() -> qcheck.Generator(Where) {
  qcheck.from_weighted_generators(
    #(3, qcheck.map(qcheck.bounded_int(from: 0, to: 3), PhaseAt)),
    [#(1, qcheck.map(phase_name_gen(), PhaseNamed))],
  )
}

fn targeted_gen() -> qcheck.Generator(Aim) {
  qcheck.from_weighted_generators(#(2, qcheck.map(where_gen(), InPhase)), [
    #(5, qcheck.map(pick_gen(), One)),
  ])
}

fn aim_gen() -> qcheck.Generator(Aim) {
  qcheck.from_weighted_generators(#(1, qcheck.return(AllTasks)), [
    #(7, targeted_gen()),
  ])
}

fn reason_gen() -> qcheck.Generator(Option(String)) {
  choose(None, [Some("waiting on ops"), Some("two\nlines"), Some("  ")])
}

fn lay_gen() -> qcheck.Generator(Cmd) {
  let small =
    qcheck.map2(
      qcheck.bounded_int(from: 1, to: 3),
      qcheck.bounded_int(from: 1, to: 4),
      Lay,
    )
  let large =
    qcheck.map2(
      qcheck.bounded_int(from: 11, to: 14),
      qcheck.bounded_int(from: 3, to: 5),
      Lay,
    )
  qcheck.from_weighted_generators(#(12, small), [#(1, large)])
}

fn init_raw_gen() -> qcheck.Generator(Cmd) {
  let phase =
    qcheck.tuple2(
      phase_name_gen(),
      qcheck.generic_list(
        elements_from: text_gen(),
        length_from: qcheck.bounded_int(from: 0, to: 3),
      ),
    )
  qcheck.map(
    qcheck.generic_list(
      elements_from: phase,
      length_from: qcheck.bounded_int(from: 0, to: 3),
    ),
    InitRaw,
  )
}

fn command(_model: Board) -> qcheck.Generator(Cmd) {
  qcheck.from_weighted_generators(#(3, lay_gen()), [
    #(1, init_raw_gen()),
    #(4, qcheck.map(pick_gen(), StartTask)),
    #(5, qcheck.map(aim_gen(), FinishAim)),
    #(3, qcheck.map(aim_gen(), DropAim)),
    #(3, qcheck.map2(targeted_gen(), reason_gen(), BlockAim)),
    #(3, qcheck.map(targeted_gen(), UnblockAim)),
    #(
      5,
      qcheck.map2(
        where_gen(),
        qcheck.generic_list(
          elements_from: text_gen(),
          length_from: qcheck.bounded_int(from: 0, to: 3),
        ),
        AppendTo,
      ),
    ),
    #(3, qcheck.map(aim_gen(), RemoveAim)),
    #(1, qcheck.return(ViewBoard)),
  ])
}

// --- from a command to an operation ------------------------------------------

fn all_tasks(board: Board) -> List(Task) {
  list.flat_map(board.phases, fn(phase) { phase.tasks })
}

fn all_texts(board: Board) -> List(String) {
  list.map(all_tasks(board), fn(task) { task.text })
}

// The element at `index` modulo the length, or nothing for an empty list.
fn nth(items: List(a), index: Int) -> Result(a, Nil) {
  case list.length(items) {
    0 -> Error(Nil)
    size -> {
      let assert Ok(position) = int.modulo(index, size)
        as "the size is positive"
      items |> list.drop(position) |> list.first
    }
  }
}

fn spell(text: String, spelling: Spelling) -> String {
  case spelling {
    Exact -> text
    Loose -> text |> string.uppercase |> string.replace(" ", "  ")
  }
}

fn pick_text(model: Board, pick: Pick) -> String {
  case pick {
    TaskNamed(text) -> text
    TaskAt(index, spelling) ->
      case nth(all_texts(model), index) {
        Ok(text) -> spell(text, spelling)
        Error(Nil) -> "ghost task"
      }
  }
}

fn phase_name(model: Board, where: Where) -> String {
  case where {
    PhaseNamed(name) -> name
    PhaseAt(index) ->
      case nth(model.phases, index) {
        Ok(phase) -> phase.name
        Error(Nil) -> "ghost phase"
      }
  }
}

fn target(model: Board, aim: Aim) -> todos.Target {
  case aim {
    AllTasks -> todos.Everything
    InPhase(where) -> todos.WholePhase(phase_name(model, where))
    One(pick) -> todos.OneTask(pick_text(model, pick))
  }
}

// `from..to` ascending and inclusive; empty when `to` is below `from`.
fn counting(from: Int, to: Int) -> List(Int) {
  list.repeat(Nil, int.max(to - from + 1, 0))
  |> list.index_map(fn(_, offset) { from + offset })
}

fn laid_out(phases: Int, per_phase: Int) -> List(#(String, List(String))) {
  counting(1, phases)
  |> list.map(fn(phase) {
    let name = "P" <> int.to_string(phase)
    let items =
      counting(1, per_phase)
      |> list.map(fn(item) {
        "t" <> int.to_string(phase) <> "." <> int.to_string(item)
      })
    #(name, items)
  })
}

fn to_op(model: Board, cmd: Cmd) -> todos.Op {
  case cmd {
    Lay(phases, per_phase) -> todos.Init(laid_out(phases, per_phase))
    InitRaw(phases) -> todos.Init(phases)
    StartTask(pick) -> todos.Start(pick_text(model, pick))
    FinishAim(aim) -> todos.Finish(target(model, aim))
    DropAim(aim) -> todos.Drop(target(model, aim))
    BlockAim(aim, reason) -> todos.Block(target(model, aim), reason)
    UnblockAim(aim) -> todos.Unblock(target(model, aim))
    AppendTo(where, items) -> todos.Append(phase_name(model, where), items)
    RemoveAim(aim) -> todos.Remove(target(model, aim))
    ViewBoard -> todos.View
  }
}

// --- the reference -----------------------------------------------------------
//
// A second statement of the board's rules, written from the docs and not
// from `todos`: tasks are named by text, matched exactly and then by a
// unique match under case and spacing; an operation is written to its
// postcondition; then one active task is restored and every bound checked.
// It answers `Error(Nil)` where the tool must refuse.

fn normalize(text: String) -> String {
  text
  |> string.lowercase
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
}

fn loosely_distinct(board: Board) -> Bool {
  let keys = list.map(all_texts(board), normalize)
  list.length(list.unique(keys)) == list.length(keys)
}

fn ref_resolve(board: Board, text: String) -> Result(String, Nil) {
  let texts = all_texts(board)
  use <- bool.guard(when: list.contains(texts, text), return: Ok(text))
  let wanted = normalize(text)
  case list.filter(texts, fn(candidate) { normalize(candidate) == wanted }) {
    [only] -> Ok(only)
    [] | [_, _, ..] -> Error(Nil)
  }
}

fn retask(board: Board, with: fn(Phase, Task) -> Task) -> Board {
  Board(
    list.map(board.phases, fn(phase) {
      Phase(
        ..phase,
        tasks: list.map(phase.tasks, fn(task) { with(phase, task) }),
      )
    }),
  )
}

// Which tasks a target covers, or a refusal when it names nothing.
fn ref_select(
  board: Board,
  target: todos.Target,
) -> Result(fn(Phase, Task) -> Bool, Nil) {
  case target {
    todos.Everything -> Ok(fn(_, _) { True })
    todos.WholePhase(name) ->
      case list.any(board.phases, fn(phase) { phase.name == name }) {
        True -> Ok(fn(phase: Phase, _) { phase.name == name })
        False -> Error(Nil)
      }
    todos.OneTask(text) ->
      ref_resolve(board, text)
      |> result.map(fn(found) { fn(_, task: Task) { task.text == found } })
  }
}

fn ref_restatus(
  board: Board,
  target: todos.Target,
  status: fn(Task) -> todo_list.Status,
) -> Result(Board, Nil) {
  use covered <- result.map(ref_select(board, target))
  retask(board, fn(phase, task) {
    case covered(phase, task) {
      True -> Task(..task, status: status(task))
      False -> task
    }
  })
}

// A blank reason is no reason, and a reason is one line.
fn clean_reason(reason: Option(String)) -> Option(String) {
  let flat =
    option.map(reason, fn(text) {
      text
      |> string.replace("\n", " ")
      |> string.replace("\r", " ")
      |> string.trim
    })
  case flat {
    Some("") | None -> None
    Some(text) -> Some(text)
  }
}

fn dedupe(items: List(String)) -> List(String) {
  list.fold(items, [], fn(kept, item) {
    case list.contains(kept, item) {
      True -> kept
      False -> list.append(kept, [item])
    }
  })
}

fn ref_append(
  board: Board,
  phase: String,
  items: List(String),
) -> Result(Board, Nil) {
  let others =
    board.phases
    |> list.filter(fn(other) { other.name != phase })
    |> list.flat_map(fn(other) { list.map(other.tasks, fn(task) { task.text }) })
  let here =
    board.phases
    |> list.filter(fn(other) { other.name == phase })
    |> list.flat_map(fn(other) { list.map(other.tasks, fn(task) { task.text }) })
  let fresh =
    items
    |> dedupe
    |> list.filter(fn(item) { !list.contains(here, item) })
    |> list.map(fn(text) { Task(text:, status: Pending) })
  let known = list.any(board.phases, fn(other) { other.name == phase })
  case items, list.any(items, fn(item) { list.contains(others, item) }) {
    [], _ -> Error(Nil)
    _, True -> Error(Nil)
    _, False ->
      case known {
        False -> Ok(Board(list.append(board.phases, [Phase(phase, fresh)])))
        True ->
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
}

fn ref_remove(board: Board, target: todos.Target) -> Board {
  case target {
    todos.Everything -> todo_list.empty()
    todos.WholePhase(name) ->
      Board(list.filter(board.phases, fn(phase) { phase.name != name }))
    todos.OneTask(text) ->
      case ref_resolve(board, text) {
        Error(Nil) -> board
        Ok(found) ->
          Board(
            list.map(board.phases, fn(phase) {
              Phase(
                ..phase,
                tasks: list.filter(phase.tasks, fn(task) { task.text != found }),
              )
            }),
          )
      }
  }
}

fn ref_init(phases: List(#(String, List(String)))) -> Result(Board, Nil) {
  case phases, list.any(phases, fn(phase) { phase.1 == [] }) {
    [], _ -> Error(Nil)
    _, True -> Error(Nil)
    _, False ->
      Ok(
        Board(
          list.map(phases, fn(phase) {
            Phase(
              phase.0,
              list.map(phase.1, fn(text) { Task(text:, status: Pending) }),
            )
          }),
        ),
      )
  }
}

fn ref_change(board: Board, op: todos.Op) -> Result(Board, Nil) {
  case op {
    todos.View -> Ok(board)
    todos.Init(phases) -> ref_init(phases)
    todos.Start(text) -> {
      use found <- result.map(ref_resolve(board, text))
      retask(board, fn(_, task) {
        case task.text == found, task.status {
          True, _ -> Task(..task, status: Active)
          False, Active -> Task(..task, status: Pending)
          False, _ -> task
        }
      })
    }
    todos.Finish(target) -> ref_restatus(board, target, fn(_) { Done })
    todos.Drop(target) -> ref_restatus(board, target, fn(_) { Dropped })
    todos.Block(target, reason) ->
      ref_restatus(board, target, fn(task) {
        case todo_list.is_open(task) {
          True -> Blocked(clean_reason(reason))
          False -> task.status
        }
      })
    todos.Unblock(target) ->
      ref_restatus(board, target, fn(task) {
        case task.status {
          Blocked(_) -> Pending
          Pending | Active | Done | Dropped -> task.status
        }
      })
    todos.Append(phase, items) -> ref_append(board, phase, items)
    todos.Remove(target) -> Ok(ref_remove(board, target))
  }
}

/// Whether the board's one active slot has been taken by an earlier task.
type Slot {
  Vacant
  Taken
}

fn ref_settle(board: Board) -> Board {
  let someone_active =
    list.any(all_tasks(board), fn(task) { task.status == Active })
  let #(_, phases) =
    list.map_fold(board.phases, Vacant, fn(slot, phase) {
      let #(slot, tasks) =
        list.map_fold(phase.tasks, slot, fn(slot, task) {
          case someone_active, task.status, slot {
            True, Active, Vacant -> #(Taken, task)
            True, Active, Taken -> #(Taken, Task(..task, status: Pending))
            False, Pending, Vacant -> #(Taken, Task(..task, status: Active))
            _, _, _ -> #(slot, task)
          }
        })
      #(slot, Phase(..phase, tasks:))
    })
  Board(phases)
}

fn ref_apply(board: Board, op: todos.Op) -> Result(Board, Nil) {
  use changed <- result.try(ref_change(board, op))
  let settled = ref_settle(changed)
  use _ <- result.try(result.replace_error(todo_list.validate(settled), Nil))
  case loosely_distinct(settled) {
    True -> Ok(settled)
    False -> Error(Nil)
  }
}

// --- the rules checked on every answer ---------------------------------------

fn broken(tag: String, detail: String) -> Result(Nil, Violation) {
  Error(Violation(tag, detail))
}

fn count_status(board: Board, wanted: todo_list.Status) -> Int {
  list.count(all_tasks(board), fn(task) { task.status == wanted })
}

fn check_valid(board: Board) -> Result(Nil, Violation) {
  case todo_list.validate(board) {
    Ok(_) -> Ok(Nil)
    Error(reason) ->
      broken("todos.valid", "an answered board fails validate: " <> reason)
  }
}

fn check_single_active(board: Board) -> Result(Nil, Violation) {
  use <- bool.guard(when: count_status(board, Active) <= 1, return: Ok(Nil))
  broken(
    "todos.single_active",
    "more than one active task: " <> string.inspect(board),
  )
}

fn check_promotion(board: Board) -> Result(Nil, Violation) {
  let waiting = count_status(board, Pending) + count_status(board, Active)
  use <- bool.guard(
    when: waiting == 0 || count_status(board, Active) == 1,
    return: Ok(Nil),
  )
  broken(
    "todos.promotion",
    "a pending task exists but none is active: " <> string.inspect(board),
  )
}

fn check_distinct(board: Board) -> Result(Nil, Violation) {
  use <- bool.guard(when: loosely_distinct(board), return: Ok(Nil))
  broken(
    "todos.distinct",
    "two tasks match loosely: " <> string.inspect(all_texts(board)),
  )
}

fn check_replay(board: Board, op: todos.Op) -> Result(Nil, Violation) {
  let again = todos.apply(board, op)
  use <- bool.guard(when: again == Ok(board), return: Ok(Nil))
  broken(
    "todos.replay",
    "re-applying "
      <> string.inspect(op)
      <> " answered "
      <> string.inspect(again),
  )
}

// The cell the Agency stores is the encoded board, and `step` is what runs
// against it. An empty board is also what a missing cell means.
fn check_step(
  before: Board,
  op: todos.Op,
  answer: Result(Board, String),
) -> Result(Nil, Violation) {
  let expected = result.map(answer, todo_list.encode)
  let stored = todos.step(Some(todo_list.encode(before)), op)
  let missing = case before == todo_list.empty() {
    True -> todos.step(None, op)
    False -> stored
  }
  use <- bool.guard(
    when: stored == expected && missing == expected,
    return: Ok(Nil),
  )
  broken(
    "todos.step",
    "step disagrees with apply for "
      <> string.inspect(op)
      <> ": "
      <> string.inspect(stored),
  )
}

fn check_codec(board: Board) -> Result(Nil, Violation) {
  use <- bool.guard(
    when: todo_list.decode(todo_list.encode(board)) == Ok(board),
    return: Ok(Nil),
  )
  broken("todos.codec", "decode did not read back what encode wrote")
}

fn check_view(
  before: Board,
  after: Board,
  op: todos.Op,
) -> Result(Nil, Violation) {
  use <- bool.guard(when: op != todos.View || before == after, return: Ok(Nil))
  broken("todos.view", "view changed the board")
}

fn check_model(
  model: Board,
  op: todos.Op,
  answer: Result(Board, String),
) -> Result(Nil, Violation) {
  let expected = ref_apply(model, op)
  case answer, expected {
    Ok(got), Ok(want) if got == want -> Ok(Nil)
    Error(_), Error(Nil) -> Ok(Nil)
    Ok(got), Ok(want) ->
      broken(
        "todos.model",
        "for "
          <> string.inspect(op)
          <> " the tool answered "
          <> string.inspect(got)
          <> " but the reference says "
          <> string.inspect(want),
      )
    Ok(got), Error(Nil) ->
      broken(
        "todos.model",
        "the tool accepted "
          <> string.inspect(op)
          <> " as "
          <> string.inspect(got)
          <> " but the reference refuses it",
      )
    Error(reason), Ok(want) ->
      broken(
        "todos.model",
        "the tool refused "
          <> string.inspect(op)
          <> " ("
          <> reason
          <> ") but the reference gives "
          <> string.inspect(want),
      )
  }
}

fn execute(sut: Board, model: Board, cmd: Cmd) -> Result(Board, Violation) {
  let op = to_op(model, cmd)
  let answer = todos.apply(sut, op)
  use Nil <- result.try(check_step(sut, op, answer))
  case answer {
    Error(_) -> check_model(model, op, answer) |> result.replace(sut)
    Ok(board) -> {
      use Nil <- result.try(check_valid(board))
      use Nil <- result.try(check_single_active(board))
      use Nil <- result.try(check_promotion(board))
      use Nil <- result.try(check_distinct(board))
      use Nil <- result.try(check_replay(board, op))
      use Nil <- result.try(check_codec(board))
      use Nil <- result.try(check_view(sut, board, op))
      use Nil <- result.map(check_model(model, op, answer))
      board
    }
  }
}

fn next_model(model: Board, cmd: Cmd) -> Board {
  case ref_apply(model, to_op(model, cmd)) {
    Ok(board) -> board
    Error(Nil) -> model
  }
}

fn spec() -> Spec(Board, Cmd, Board) {
  Spec(
    initial: todo_list.empty(),
    command: command,
    precondition: fn(_, _) { Admit },
    next_model: next_model,
    new_sut: todo_list.empty,
    execute: execute,
    finish: fn(sut, model) {
      case sut == model {
        True -> Ok(Nil)
        False -> broken("todos.model", "the final boards differ")
      }
    },
    teardown: fn(_) { Nil },
  )
}

fn config() -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(test_count)
  |> statem.with_max_commands(max_commands)
}

// --- the tests ---------------------------------------------------------------

pub fn the_board_keeps_its_rules_under_any_sequence_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, describe)
  }
}

// A property over a generator that never reaches the interesting states is
// a green light that means nothing, so this walks the same sequences and
// asserts the walk meets every status, every operation, refusals and
// acceptances, and a board at its bounds.
pub fn the_generated_sequences_reach_the_states_the_rules_are_about_test() {
  let runs = counting(0, test_count - 1)
  let visits =
    list.flat_map(runs, fn(run) {
      let cmds = statem.commands(spec(), config(), run)
      let #(_, seen) =
        list.fold(cmds, #(todo_list.empty(), []), fn(state, cmd) {
          let #(model, seen) = state
          let op = to_op(model, cmd)
          let outcome = case ref_apply(model, op) {
            Ok(board) -> Some(board)
            Error(Nil) -> None
          }
          let next = option.unwrap(outcome, model)
          #(next, [#(cmd, outcome, next), ..seen])
        })
      seen
    })

  let reached = fn(wanted: fn(#(Cmd, Option(Board), Board)) -> Bool) {
    list.any(visits, wanted)
  }
  let has_status = fn(status: todo_list.Status) {
    fn(visit: #(Cmd, Option(Board), Board)) {
      count_status(visit.2, status) > 0
    }
  }
  let accepted = fn(visit: #(Cmd, Option(Board), Board)) {
    option.is_some(visit.1)
  }
  let refused = fn(visit: #(Cmd, Option(Board), Board)) {
    option.is_none(visit.1)
  }
  let kind = fn(label: String) {
    fn(visit: #(Cmd, Option(Board), Board)) {
      string.starts_with(describe(visit.0), label)
    }
  }

  // Every status is held by some board on the walk, including both kinds
  // of blocked task (with and without a reason).
  assert reached(has_status(Active))
  assert reached(has_status(Pending))
  assert reached(has_status(Done))
  assert reached(has_status(Dropped))
  assert reached(has_status(Blocked(Some("waiting on ops"))))
  assert reached(has_status(Blocked(None)))

  // Both answers occur, and a board gets wide and close to the task bound,
  // where the refusals for size live.
  assert reached(accepted)
  assert reached(refused)
  assert reached(fn(visit) { list.drop({ visit.2 }.phases, 2) != [] })
  assert reached(fn(visit) {
    list.drop(all_tasks(visit.2), todo_list.max_tasks - 10) != []
  })

  // Every constructor is drawn and accepted at least once, and the two
  // whose refusals carry the most rules are refused too: otherwise the
  // differential is only comparing the easy half.
  list.each(
    [
      "Lay", "InitRaw", "StartTask", "FinishAim", "DropAim", "BlockAim",
      "UnblockAim", "AppendTo", "RemoveAim", "ViewBoard",
    ],
    fn(label) {
      assert reached(kind(label))
      assert reached(fn(visit) { kind(label)(visit) && accepted(visit) })
    },
  )
  assert reached(fn(visit) { kind("StartTask")(visit) && refused(visit) })
  assert reached(fn(visit) { kind("AppendTo")(visit) && refused(visit) })
}

// The reference is itself checked against the worked examples in
// `todos_test`, so the differential above is between two readings that
// agree on the cases a person wrote down.
pub fn the_reference_agrees_with_the_documented_examples_test() {
  let laid = laid_out(2, 2)
  let assert Ok(board) = ref_apply(todo_list.empty(), todos.Init(laid))
    as "a layout initializes"
  assert todo_list.active(board)
    == Some(#(
      Phase("P1", [Task("t1.1", Active), Task("t1.2", Pending)]),
      Task("t1.1", Active),
    ))

  let assert Ok(finished) =
    ref_apply(board, todos.Finish(todos.OneTask("t1.1")))
    as "the active task finishes"
  assert {
      todo_list.active(finished) |> option.map(fn(found) { { found.1 }.text })
    }
    == Some("t1.2")

  let assert Ok(loose) = ref_apply(board, todos.Start("T2.1"))
    as "a loose spelling resolves to the one task"
  assert {
      todo_list.active(loose) |> option.map(fn(found) { { found.1 }.text })
    }
    == Some("t2.1")
}
