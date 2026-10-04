//// The `todo` tool: its operations as pure transitions, the single active
//// task they preserve, the idempotence `replay: Safe` promises, and the
//// shell's parsing and rendering.
////
//// Most tests drive `todos.apply` directly, because the transitions are
//// the whole of the tool's semantics and need no seam. The shell tests
//// hand `todos.tool` an update door that applies the step to a fixed
//// stored value, which is exactly what the Agency's compare-and-set does
//// on an uncontended cell.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/message
import core/todo_list.{
  type Board, Active, Blocked, Board, Done, Dropped, Pending, Phase, Task,
}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tools/agent
import tools/directory_access
import tools/todos
import tools/tool.{type Ctx}

// --- fixtures ----------------------------------------------------------------

fn build() -> Board {
  let assert Ok(board) =
    todos.apply(
      todo_list.empty(),
      todos.Init([
        #("Extract", ["Extract test units", "Build judge states"]),
        #("Judge", ["Pilot the questions", "Judge every unit"]),
      ]),
    )
    as "the fixture list initializes"
  board
}

fn statuses(board: Board) -> List(#(String, todo_list.Status)) {
  list.flat_map(board.phases, fn(phase) {
    list.map(phase.tasks, fn(task) { #(task.text, task.status) })
  })
}

fn active_text(board: Board) -> Option(String) {
  todo_list.active(board) |> option.map(fn(found) { { found.1 }.text })
}

fn ok(board: Board, op: todos.Op) -> Board {
  let assert Ok(next) = todos.apply(board, op) as "the operation applies"
  next
}

// --- init and the active task ------------------------------------------------

pub fn init_makes_the_first_task_active_test() {
  assert statuses(build())
    == [
      #("Extract test units", Active),
      #("Build judge states", Pending),
      #("Pilot the questions", Pending),
      #("Judge every unit", Pending),
    ]
}

pub fn finishing_the_active_task_advances_to_the_next_test() {
  let board = build() |> ok(todos.Finish(todos.OneTask("Extract test units")))
  assert active_text(board) == Some("Build judge states")
}

pub fn finishing_a_phase_advances_into_the_next_phase_test() {
  let board = build() |> ok(todos.Finish(todos.WholePhase("Extract")))
  assert active_text(board) == Some("Pilot the questions")
}

pub fn start_demotes_the_previous_active_task_test() {
  let board = build() |> ok(todos.Start("Judge every unit"))
  assert active_text(board) == Some("Judge every unit")
  assert list.count(statuses(board), fn(entry) { entry.1 == Active }) == 1
  assert list.key_find(statuses(board), "Extract test units") == Ok(Pending)
}

// A blocked task is never promoted, so the next open task becomes active
// and a board of only blocked work has no active task at all.
pub fn a_blocked_task_is_never_promoted_test() {
  let board =
    build()
    |> ok(todos.Block(todos.OneTask("Extract test units"), Some("need input\n")))
  assert list.key_find(statuses(board), "Extract test units")
    == Ok(Blocked(Some("need input")))
  assert active_text(board) == Some("Build judge states")

  let stuck = build() |> ok(todos.Block(todos.Everything, None))
  assert active_text(stuck) == None
  let assert Ok(stuck) =
    todos.apply(stuck, todos.Unblock(todos.WholePhase("Judge")))
    as "unblock reopens a phase"
  assert active_text(stuck) == Some("Pilot the questions")
}

pub fn block_leaves_closed_tasks_closed_test() {
  let board =
    build()
    |> ok(todos.Finish(todos.OneTask("Extract test units")))
    |> ok(todos.Block(todos.WholePhase("Extract"), None))
  assert list.key_find(statuses(board), "Extract test units") == Ok(Done)
  assert list.key_find(statuses(board), "Build judge states")
    == Ok(Blocked(None))
}

pub fn drop_closes_without_finishing_test() {
  let board = build() |> ok(todos.Drop(todos.OneTask("Build judge states")))
  assert list.key_find(statuses(board), "Build judge states") == Ok(Dropped)
  assert todo_list.count(board) == #(1, 4)
}

// --- idempotence under replay ------------------------------------------------

pub fn every_operation_is_idempotent_test() {
  let board = build()
  [
    todos.Init([#("Only", ["one", "two"])]),
    todos.Start("Judge every unit"),
    todos.Finish(todos.OneTask("Extract test units")),
    todos.Drop(todos.WholePhase("Judge")),
    todos.Block(todos.OneTask("Build judge states"), Some("waiting")),
    todos.Unblock(todos.Everything),
    todos.Append("Verify", ["Run the suite"]),
    todos.Remove(todos.OneTask("Pilot the questions")),
    todos.View,
  ]
  |> list.each(fn(op) {
    let once = ok(board, op)
    assert ok(once, op) == once
  })
}

pub fn append_creates_a_phase_and_skips_items_already_present_test() {
  let board =
    build()
    |> ok(todos.Append("Verify", ["Run the suite", "Run the suite"]))
    |> ok(todos.Append("Verify", ["Run the suite", "Read the lint"]))
  let assert Ok(verify) =
    list.find(board.phases, fn(phase) { phase.name == "Verify" })
    as "append created the phase"
  assert list.map(verify.tasks, fn(task) { task.text })
    == ["Run the suite", "Read the lint"]
}

pub fn append_refuses_a_task_from_another_phase_test() {
  let assert Error(reason) =
    todos.apply(build(), todos.Append("Verify", ["Judge every unit"]))
  assert string.contains(reason, "already in another phase")
}

pub fn remove_deletes_a_phase_and_ignores_what_is_gone_test() {
  let board = build() |> ok(todos.Remove(todos.WholePhase("Extract")))
  assert list.map(board.phases, fn(phase) { phase.name }) == ["Judge"]
  assert active_text(board) == Some("Pilot the questions")
  assert ok(board, todos.Remove(todos.OneTask("never existed"))) == board
  assert ok(board, todos.Remove(todos.Everything)) == todo_list.empty()
}

// --- targeting ---------------------------------------------------------------

pub fn a_task_is_found_despite_case_and_spacing_test() {
  assert todos.resolve(build(), "judge  EVERY unit") == Ok("Judge every unit")
}

pub fn a_missing_task_names_the_open_tasks_test() {
  let assert Error(reason) =
    todos.apply(build(), todos.Finish(todos.OneTask("task-3")))
  assert string.contains(reason, "no task \"task-3\"")
  assert string.contains(reason, "\"Pilot the questions\"")
}

pub fn a_missing_phase_names_the_phases_test() {
  let assert Error(reason) =
    todos.apply(build(), todos.Finish(todos.WholePhase("Deploy")))
  assert string.contains(reason, "phases: \"Extract\", \"Judge\"")
}

pub fn init_refuses_duplicates_and_empty_phases_test() {
  let assert Error(_) = todos.apply(todo_list.empty(), todos.Init([]))
  let assert Error(_) =
    todos.apply(todo_list.empty(), todos.Init([#("Empty", [])]))
  let assert Error(reason) =
    todos.apply(todo_list.empty(), todos.Init([#("P", ["same", "same"])]))
  assert string.contains(reason, "duplicate task")
}

// --- the stored cell ---------------------------------------------------------

pub fn a_corrupt_cell_is_refused_except_by_init_test() {
  let corrupt = Some(json.String("not a board"))
  let assert Error(reason) = todos.step(corrupt, todos.View)
  assert string.contains(reason, "`init` replaces it")
  let assert Ok(value) = todos.step(corrupt, todos.Init([#("P", ["a"])]))
    as "init replaces an unreadable cell"
  let assert Ok(board) = todo_list.decode(value) as "init stored a board"
  assert active_text(board) == Some("a")
}

// --- parsing -----------------------------------------------------------------

fn args(fields: List(#(String, JsonValue))) -> JsonValue {
  json.Object(fields)
}

pub fn parse_reads_each_operation_test() {
  assert todos.parse(args([#("op", json.String("view"))])) == Ok(todos.View)
  assert todos.parse(
      args([
        #("op", json.String("init")),
        #("items", json.Array([json.String("a"), json.String("b")])),
      ]),
    )
    == Ok(todos.Init([#(todos.default_phase, ["a", "b"])]))
  assert todos.parse(
      args([
        #("op", json.String("init")),
        #(
          "phases",
          json.Array([
            json.Object([
              #("name", json.String("Build")),
              #("items", json.Array([json.String("a")])),
            ]),
          ]),
        ),
      ]),
    )
    == Ok(todos.Init([#("Build", ["a"])]))
  assert todos.parse(args([#("op", json.String("done"))]))
    == Ok(todos.Finish(todos.Everything))
  assert todos.parse(
      args([#("op", json.String("done")), #("phase", json.String("Build"))]),
    )
    == Ok(todos.Finish(todos.WholePhase("Build")))
  assert todos.parse(
      args([
        #("op", json.String("block")),
        #("task", json.String("a")),
        #("reason", json.String("waiting")),
      ]),
    )
    == Ok(todos.Block(todos.OneTask("a"), Some("waiting")))
}

pub fn parse_refuses_ambiguous_and_incomplete_calls_test() {
  let assert Error(_) =
    todos.parse(
      args([
        #("op", json.String("done")),
        #("task", json.String("a")),
        #("phase", json.String("P")),
      ]),
    )
  let assert Error(_) = todos.parse(args([#("op", json.String("block"))]))
  let assert Error(_) = todos.parse(args([#("op", json.String("start"))]))
  let assert Error(_) =
    todos.parse(
      args([#("op", json.String("append")), #("items", json.Array([]))]),
    )
  let assert Error(_) = todos.parse(args([#("op", json.String("undo"))]))
}

// --- the shell ---------------------------------------------------------------

fn run(stored: Option(JsonValue), call: JsonValue) -> tool.ToolOutcome {
  let door = fn(_ctx, step: fn(Option(JsonValue)) -> Result(JsonValue, String)) {
    step(stored)
  }
  todos.tool(door).run(a_ctx(), call)
}

pub fn a_call_answers_the_board_as_text_and_details_test() {
  let outcome =
    run(
      None,
      args([
        #("op", json.String("init")),
        #(
          "items",
          json.Array([json.String("Write it"), json.String("Test it")]),
        ),
      ]),
    )
  assert !outcome.is_error
  let text = text_of(outcome)
  assert string.contains(text, "0/2 closed; active: Write it (Tasks)")
  assert string.contains(text, "[>] Write it")
  assert string.contains(text, "[ ] Test it")
  let assert Some(json.Object(fields)) = outcome.details as "details present"
  assert list.key_find(fields, "op") == Ok(json.String("init"))
  let assert Ok(board) = list.key_find(fields, "todo") as "the board is there"
  let assert Ok(decoded) = todo_list.decode(board) as "the board decodes"
  assert active_text(decoded) == Some("Write it")
}

pub fn a_refused_call_is_an_in_band_failure_test() {
  let outcome =
    run(
      Some(todo_list.encode(build())),
      args([#("op", json.String("start")), #("task", json.String("nope"))]),
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "no task \"nope\"")
}

// The call GLM-5.3 sent in session 01a10e0f: a `phases` payload and no
// `op`. The refusal must list the ops and show a call that would work.
pub fn a_call_without_an_op_is_refused_with_the_ops_and_an_example_test() {
  let call =
    args([
      #(
        "phases",
        json.Array([
          json.Object([
            #("name", json.String("Survey")),
            #("items", json.Array([json.String("Read README.md")])),
          ]),
        ]),
      ),
    ])
  let outcome = run(None, call)
  assert outcome.is_error
  let text = text_of(outcome)
  assert string.starts_with(
    text,
    "invalid arguments: `op` is required; use one of init, start,",
  )
  assert string.contains(
    text,
    "append, remove, view, e.g. {\"op\":\"init\",\"phases\":",
  )
  assert todos.parse(args([])) == todos.parse(call)
}

fn init_with(phases: List(JsonValue)) -> JsonValue {
  args([#("op", json.String("init")), #("phases", json.Array(phases))])
}

fn task_object(text: String) -> JsonValue {
  json.Object([#("task", json.String(text))])
}

// Call 4 of session 01a10e0f: a phase with `items` and no `name`, the
// items sent as objects that also carry a `name`.
pub fn a_phase_without_a_name_shows_a_correct_phase_test() {
  let call =
    init_with([
      json.Object([
        #(
          "items",
          json.Array([
            json.Object([
              #("name", json.String("Survey")),
              #("task", json.String("Read README.md")),
            ]),
          ]),
        ),
      ]),
    ])
  let assert Error(reason) = todos.parse(call)
  assert reason
    == "`items` must be an array of strings, e.g. [\"Write the parser\",\"Add tests\"]; got an array containing an object"
  let nameless =
    init_with([
      json.Object([
        #("items", json.Array([json.String("Read README.md")])),
      ]),
    ])
  assert todos.parse(nameless)
    == Error(
      "a phase needs a `name`, e.g. {\"name\":\"Build\",\"items\":[\"Write the parser\"]}",
    )
}

// Calls 3 and 5: tasks sent as `{"task": text}`. The one-field object is
// read as the text, so the first try lands.
pub fn items_sent_as_task_objects_are_read_as_their_text_test() {
  let call =
    init_with([
      json.Object([
        #("name", json.String("Survey")),
        #(
          "items",
          json.Array([task_object("Read README.md"), task_object("Open PR")]),
        ),
      ]),
    ])
  assert todos.parse(call)
    == Ok(todos.Init([#("Survey", ["Read README.md", "Open PR"])]))
}

pub fn items_that_are_not_strings_say_what_was_received_test() {
  let wrong = fn(items) {
    todos.parse(args([#("op", json.String("append")), #("items", items)]))
  }
  let assert Error(single) = wrong(json.String("one task"))
  assert string.ends_with(single, "; got a string")
  let assert Error(titled) =
    wrong(
      json.Array([
        json.Object([
          #("title", json.String("a")),
          #("status", json.String("pending")),
        ]),
      ]),
    )
  assert string.ends_with(titled, "; got an array containing an object")
  assert !string.contains(titled, "pending")
}

pub fn every_missing_field_refusal_shows_a_call_for_that_op_test() {
  assert todos.parse(args([#("op", json.String("start"))]))
    == Error(
      "`start` needs a `task`, e.g. {\"op\":\"start\",\"task\":\"Write the parser\"}",
    )
  assert todos.parse(args([#("op", json.String("block"))]))
    == Error(
      "`block` needs a `task` or a `phase`, e.g. {\"op\":\"block\",\"task\":\"Write the parser\"}",
    )
  assert todos.parse(args([#("op", json.String("init"))]))
    == Error(
      "`init` needs a non-empty `items` list, e.g. {\"op\":\"init\",\"items\":[\"Write the parser\",\"Add tests\"]}",
    )
}

pub fn an_unknown_op_lists_the_known_ops_test() {
  let assert Error(reason) = todos.parse(args([#("op", json.String("undo"))]))
  assert string.starts_with(reason, "unknown op \"undo\"; use one of init,")
}

pub fn the_agency_registers_todo_and_reports_its_refusals_test() {
  let assert Ok(found) =
    agent.tools(refusing_agency())
    |> list.find(fn(each) { each.name == todos.tool_name })
    as "the agent family registers the todo tool"
  assert found.execution_mode == tool.Concurrent
  assert found.replay == tool.Safe
  let outcome = found.run(a_ctx(), args([#("op", json.String("view"))]))
  assert outcome.is_error
  assert string.contains(
    text_of(outcome),
    agent.describe(agent.AgencyUnavailable),
  )
}

pub fn render_marks_every_status_test() {
  let board =
    Board([
      Phase("P", [
        Task("a", Done),
        Task("b", Dropped),
        Task("c", Active),
        Task("d", Blocked(Some("operator"))),
        Task("e", Pending),
      ]),
    ])
  assert todos.render(board)
    == "2/5 closed; active: c (P)\n## P 2/5\n[x] a\n[-] b\n[>] c\n[!] d (blocked: operator)\n[ ] e"
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn refusing_agency() -> agent.Agency {
  agent.Agency(
    spawn: fn(_, _) { Error(agent.AgencyUnavailable) },
    send: fn(_, _, _, _) { Error(agent.AgencyUnavailable) },
    wait: fn(_, _, _) { Error(agent.AgencyUnavailable) },
    note: fn(_, _, _) { Error(agent.AgencyUnavailable) },
    notes: fn(_, _) { Error(agent.AgencyUnavailable) },
    todos: fn(_, _) { Error(agent.AgencyUnavailable) },
    roster: fn(_) { Error(agent.AgencyUnavailable) },
    max_wait_ms: 1000,
    model_names: [],
    holds: fn(_caller, _tool) { Ok(Nil) },
  )
}

fn a_ctx() -> Ctx {
  let workspace = "/nonexistent/loom-todo-test"
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace: tool.LocalWorkspace(
      workspace,
      tool.FileSystem(
        read: fn(path) { Error(tool.FsNotFound(path:)) },
        write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
        create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
        is_file: fn(_path) { Ok(False) },
        read_link: fn(_path) { Ok(tool.LinkMissing) },
        rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
      ),
    ),
    strand: "main",
    op_id: op,
    step_id: "turn",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(at: 1000),
    owner_blobs: tool.OwnerBlobs(
      workspace <> "/.blobs",
      tool.FileSystem(
        read: fn(path) { Error(tool.FsNotFound(path:)) },
        write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
        create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
        is_file: fn(_path) { Ok(False) },
        read_link: fn(_path) { Ok(tool.LinkMissing) },
        rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
      ),
    ),
    clear_call: dead_broker,
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn dead_broker(
  _spec: CallSpec,
  _events: Subject(CallEvent),
) -> Result(tool.RunningCall, Refusal) {
  Error(broker.BrokerUnavailable)
}

// Loose resolution must never have two candidates, or a replayed remove
// whose exact target is gone would delete the other one.
pub fn tasks_that_differ_only_in_case_are_refused_test() {
  let assert Error(reason) =
    todos.apply(build(), todos.Append("Verify", ["judge EVERY unit"]))
  assert string.contains(reason, "differ only in case or spacing")
  let assert Error(_) =
    todos.apply(
      todo_list.empty(),
      todos.Init([#("P", ["Ship it", "ship  it"])]),
    )
}

pub fn a_blank_block_reason_is_no_reason_test() {
  let board =
    build()
    |> ok(todos.Block(todos.OneTask("Extract test units"), Some(" \n ")))
  assert list.key_find(statuses(board), "Extract test units")
    == Ok(Blocked(None))
}
