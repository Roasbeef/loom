//// A code-mode program's capability calls, as whole frames.
////
//// Protocol-change 060 puts a record of a foreground program's calls on its
//// result. A program that completed says how many calls it made in its
//// block's title and lists them under it. A program that failed lists them in its block, grouped where
//// consecutive calls share a capability and an ending, so a failed call
//// and its error code stand out from the reads around it. A result written
//// before the record existed draws what it always drew.

import core/json
import frame_scene
import gleam/list
import gleam/string
import tui/frame

// One itemised call as the host writes it.
fn call(cap: String, args: String, status: String, error: String) {
  json.Object(
    list.flatten([
      [
        #("cap", json.String(cap)),
        #("args", json.String(args)),
        #("status", json.String(status)),
      ],
      case error {
        "" -> []
        code -> [#("error", json.String(code))]
      },
      [#("start_ms", json.Int(10)), #("duration_ms", json.Int(5))],
    ]),
  )
}

// A record of `items`, with `total` calls counted and `failed` failed.
pub fn record(items, total: Int, failed: Int, unsettled: Int) {
  json.Object([
    #("started_unix_ms", json.Int(1_800_000_000_000)),
    #("elapsed_ms", json.Int(1200)),
    #("total", json.Int(total)),
    #("failed", json.Int(failed)),
    #("cancelled", json.Int(0)),
    #("unsettled", json.Int(unsettled)),
    #("items", json.Array(items)),
  ])
}

pub fn failed_calls() {
  record(
    [
      call("fs.read", "calc.gleam", "ok", ""),
      call("fs.read", "calc_test.gleam", "ok", ""),
      call("fs.read", "README.md", "ok", ""),
      call("proc.run", "gleam format --check", "failed", "exit_status"),
      call("proc.run", "gleam build", "ok", ""),
      call("proc.run", "gleam test", "unsettled", ""),
    ],
    7,
    1,
    1,
  )
}

fn scene() {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Check the subtract change and run the tests."),
    frame_scene.assistant(2, "I will check it with a small program.", [
      frame_scene.call("c1", "code_mode", [
        #("program", json.String("pub fn main() {\n  Ok(True)\n}\n")),
      ]),
    ]),
    frame_scene.result_with(
      3,
      "c1",
      "code_mode",
      "ok",
      json.Object([
        #("status", json.String("completed")),
        #("value", json.Object([#("ok", json.Bool(True))])),
        #(
          "calls",
          record(
            [
              call("fs.read", "calc.gleam", "ok", ""),
              call("fs.read", "README.md", "ok", ""),
            ],
            4,
            0,
            0,
          ),
        ),
      ]),
      frame_scene.Succeeded,
    ),
    frame_scene.assistant(4, "Now the tests.", [
      frame_scene.call("c2", "code_mode", [
        #("program", json.String("pub fn main() {\n  Ok(Nil)\n}\n")),
      ]),
    ]),
    frame_scene.result_with(
      5,
      "c2",
      "code_mode",
      "the program ran past its wall budget",
      json.Object([
        #("status", json.String("run_failed")),
        #("kind", json.String("deadline_exceeded")),
        #("detail", json.String("the wall deadline passed")),
        #("calls", failed_calls()),
      ]),
      frame_scene.Errored,
    ),
  ])
}

fn lines(width: Int) -> List(String) {
  frame_scene.screen(scene(), width, 60) |> frame.buffer_to_lines
}

fn has(lines: List(String), needle: String) -> Bool {
  list.any(lines, string.contains(_, needle))
}

pub fn a_completed_program_counts_its_calls_test() {
  list.each([120, 80], fn(width) {
    assert has(lines(width), "╭─ ✓ code_mode · completed · 4 calls")
    assert has(lines(width), "CALLS · 4 calls · 0 failed")
    assert has(lines(width), "✓ fs.read ×2  calc.gleam · README.md")
    assert has(lines(width), "… 2 more calls")
    assert has(lines(width), "RESULT · object · 1 key")
    assert has(lines(width), "  ok: true")
  })
}

pub fn a_failed_program_lists_its_calls_grouped_test() {
  list.each([120, 80], fn(width) {
    let shown = lines(width)
    assert has(shown, "× code_mode · did not finish")
    assert has(shown, "CALLS · 7 calls · 1 failed · 1 unsettled")
    // The arguments start in one column; a failure names its code in
    // words, and a failed or unsettled call says how long it took.
    assert has(shown, "✓ fs.read ×3  calc.gleam · calc_test.gleam · README.md")
    assert has(
      shown,
      "× proc.run    gleam format --check  failed · exit status · 5ms",
    )
    assert has(shown, "✓ proc.run    gleam build")
    assert has(shown, "◐ proc.run    gleam test  not settled · 5ms")
    assert has(shown, "… 1 more call")
  })
}
