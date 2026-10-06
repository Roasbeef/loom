//// Code-mode programs in the transcript, as whole frames.
////
//// A program that completed is a block in the success colour with the
//// opening lines of the program and a preview of its value. A program that
//// failed to compile is a block in the danger colour with the compiler's
//// heading, the line it names and the source it quotes. A program the
//// client has no result for yet is a block in the live colour with the
//// opening lines of the program and a `RESULT · none yet` row. These tests
//// paint whole frames at 120 and 80 columns, and check that the rows each
//// result joins to its call are paired with durable anchors one for one,
//// since a result that its call now draws contributes no rows of its own.

import core/json
import etui/backend
import etui/buffer.{type Buffer}
import etui/geometry.{Position}
import frame_scene
import gleam/list
import gleam/string
import tui
import tui/frame
import tui/model as tui_model
import tui/theme

const probe =
  "import cap/fs\n\npub fn main() {\n  Ok(fs.read(\"calc.gleam\"))\n}\n"

const ranged =
  "import gleam/list\n\npub fn main() {\n  let numbers =\n    list.rang(1, 10)\n  Ok(numbers)\n}\n"

const checking =
  "import cap/fs\nimport cap/proc\n\npub fn main() {\n  let src = fs.read(\"calc.gleam\")\n  let out = proc.run(\"gleam\", [\"test\"])\n  Ok(#(src, out))\n}\n"

const diagnostics =
  "error: Unknown module value\n  ┌─ /scratch/src/program.gleam:5:10\n  │\n5 │     list.rang(1, 10)\n  │          ^^^^ Did you mean `range`?\n\nThe module `gleam/list` does not have a `rang` value.\n"

fn program(id: String, source: String, extra) {
  frame_scene.call(id, "code_mode", [#("program", json.String(source)), ..extra])
}

fn outcome(n: Int, id: String, details, ending) {
  frame_scene.result_with(n, id, "code_mode", "program output", details, ending)
}

// Each program follows prose, so each response is narrative and each
// result arrives as an entry of its own, which the call's row then draws.
fn scene() -> tui_model.Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Check the subtract change."),
    frame_scene.assistant(2, "I will check it with a small program.", [
      program("c1", probe, []),
    ]),
    outcome(
      3,
      "c1",
      json.Object([
        #("status", json.String("completed")),
        #("value", json.Object([#("ok", json.Bool(True))])),
      ]),
      frame_scene.Succeeded,
    ),
    frame_scene.assistant(4, "That did not compile; trying again.", [
      program("c2", ranged, []),
    ]),
    outcome(
      5,
      "c2",
      json.Object([
        #("status", json.String("compile_failed")),
        #("kind", json.String("build_rejected")),
        #("detail", json.String(diagnostics)),
      ]),
      frame_scene.Errored,
    ),
    frame_scene.assistant(6, "Now the tests.", [
      program("c3", checking, [#("within_ms", json.Int(30_000))]),
    ]),
  ])
}

fn painted(width: Int, height: Int) -> #(Buffer, List(String)) {
  let shown = frame_scene.screen(scene(), width, height)
  #(shown, frame.buffer_to_lines(shown))
}

fn find(lines: List(String), needle: String) -> Result(#(Int, Int), Nil) {
  lines
  |> list.index_map(fn(line, y) { #(line, y) })
  |> list.find_map(fn(pair) {
    case string.split_once(pair.0, needle) {
      Ok(#(before, _)) -> Ok(#(pair.1, string.length(before)))
      Error(Nil) -> Error(Nil)
    }
  })
}

pub fn a_completed_program_is_a_success_block_with_its_value_test() {
  [#(120, 60), #(80, 60)]
  |> list.each(fn(size) {
    let #(shown, lines) = painted(size.0, size.1)
    let assert Ok(#(top, x)) = find(lines, "╭─ ✓ code_mode · completed")
      as "the settled block's title"
    assert x == 3
    assert buffer.get_cell(shown, Position(x, top)).style.fg == theme.added

    // The block keeps the program lines its running form showed, and says
    // what the value is instead of printing it cut at a column.
    let below = list.drop(lines, top)
    let assert Ok(#(count, _)) = find(below, "PROGRAM · 5 lines, 4 shown")
      as "the program's size"
    assert count == 1
    let assert Ok(#(first, _)) = find(below, "1 │ import cap/fs") as "line one"
    assert first == 2
    let assert Ok(_) = find(below, "RESULT · object · 1 key")
      as "the value's kind"
    let assert Ok(_) = find(below, "ok: true") as "the key and its hint"
    assert !list.any(lines, string.contains(_, "result {"))

    // The result is drawn by its call, so no result row of its own follows.
    assert !list.any(lines, string.contains(_, "└ code_mode"))
    assert !list.any(lines, string.contains(_, "program output"))
  })
}

pub fn a_compile_error_is_a_danger_block_naming_its_line_test() {
  [#(120, 60), #(80, 60)]
  |> list.each(fn(size) {
    let #(shown, lines) = painted(size.0, size.1)
    let assert Ok(#(top, x)) = find(lines, "╭─ × code_mode · compile error")
      as "the block's title"
    assert x == 3
    assert buffer.get_cell(shown, Position(x, top)).style.fg == theme.danger
    let assert Ok(#(heading, _)) =
      find(lines, "error: Unknown module value · line 5")
      as "the compiler's heading gains the line it names"
    assert heading == top + 1
    let assert Ok(#(quoted, _)) = find(lines, "list.rang(1, 10)")
      as "the quoted source"
    assert quoted == top + 2
    let assert Ok(#(foot, _)) = find(lines, "the program did not run · 7 lines")
      as "the foot says how much more there is"
    assert foot == top + 4

    // The right edge sits one cell short of the pane's own.
    let assert Ok(top_row) = list.drop(lines, top) |> list.first
      as "the top rule"
    assert string.ends_with(string.trim_end(top_row), "╮")
    assert string.length(string.trim_end(top_row)) == size.0 - 2
  })
}

pub fn a_program_awaiting_its_result_shows_its_opening_lines_test() {
  [#(120, 60), #(80, 60)]
  |> list.each(fn(size) {
    let #(shown, lines) = painted(size.0, size.1)
    let assert Ok(#(top, x)) =
      find(lines, "╭─ ◐ code_mode · awaiting its result")
      as "the running block's title"
    assert buffer.get_cell(shown, Position(x, top)).style.fg == theme.current

    // The earlier programs in the scene have blocks of their own, so the
    // rows are looked for below this block's title.
    let below = list.drop(lines, top)
    let assert Ok(#(count, _)) = find(below, "PROGRAM · 8 lines, 4 shown")
      as "the program's size"
    assert count == 1
    let assert Ok(#(first, _)) = find(below, "1 │ import cap/fs") as "line one"
    let assert Ok(#(fifth, _)) = find(below, "5 │   let src = fs.read")
      as "the blank line is skipped, the numbering is not"
    assert fifth == first + 3
    let assert Ok(#(result, _)) =
      find(
        below,
        "RESULT · none yet · the result arrives when the program ends",
      )
      as "the result row"
    let assert Ok(#(foot, _)) = find(below, "budget 30s")
      as "the foot names the budget the call asked for"
    assert foot == result + 1
  })
}

// Every row drawn from the durable records has its anchor, including the
// rows a joined result changes and none for the result it absorbs.
pub fn joined_results_keep_rows_and_anchors_paired_test() {
  let resized =
    tui.update(backend.Resize(120, 30), scene())
    |> tui.update(backend.MouseScroll(5, 5, True), _)
  assert resized.view.rendered_anchors != []
  assert list.length(resized.view.rendered_anchors)
    == list.length(resized.view.caches.record_rows)
}

// A program the deadline stopped names, on the block's foot, the budget
// the call asked for.
pub fn a_stopped_program_names_its_budget_test() {
  let model =
    frame_scene.attach(frame_scene.model(), "fix readme badge", [
      frame_scene.user(1, "Run the tests."),
      frame_scene.assistant(2, "Running them.", [
        program("c1", checking, [#("within_ms", json.Int(30_000))]),
      ]),
      outcome(
        3,
        "c1",
        json.Object([
          #("status", json.String("run_failed")),
          #("kind", json.String("deadline_exceeded")),
          #("detail", json.String("the wall deadline passed")),
        ]),
        frame_scene.Errored,
      ),
    ])
  let lines = frame_scene.screen(model, 120, 40) |> frame.buffer_to_lines
  let assert Ok(_) = find(lines, "the program was stopped · budget 30s")
    as "the foot names the budget"
}
