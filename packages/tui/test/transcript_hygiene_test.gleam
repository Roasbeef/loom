//// Repeats in the transcript, read off whole frames at 120 and 80 columns.
////
//// A poll that answers the same thing fifteen times, or a provider error
//// returned on every retry, used to draw one identical row per occurrence
//// until the screen held nothing else. Compact history now folds each such
//// run into one counted row. These tests pin the fold, and pin what must
//// not fold: different calls, a call whose detail a reader may want, and
//// anything the operator or the model actually said twice.

import core/json
import etui/backend
import frame_scene
import gleam/int
import gleam/list
import gleam/string
import tui
import tui/frame

fn waits(from: Int, count: Int) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    let n = from + index * 2
    let id = "wait-" <> int.to_string(index)
    [
      frame_scene.assistant(n, "", [
        frame_scene.call(id, "agent_wait", [
          #(
            "handles",
            json.Array([
              json.String("sub:main/review-48f3a1b2c3d4e5f6#op1"),
              json.String("sub:main/docs-9e21bb44aa00cc11#op2"),
            ]),
          ),
        ]),
      ]),
      frame_scene.result(
        n + 1,
        id,
        "agent_wait",
        "both still working after 30s",
        frame_scene.Succeeded,
      ),
    ]
  })
  |> list.flatten
}

fn errors(from: Int, count: Int) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    frame_scene.provider_error(from + index, "provider returned http 429")
  })
}

fn scene() {
  frame_scene.attach(
    frame_scene.model(),
    "fix readme badge",
    list.flatten([
      [frame_scene.user(1, "Review the herdr update.")],
      waits(10, 15),
      errors(50, 20),
      [frame_scene.user(80, "Carry on once they finish.")],
    ]),
  )
}

fn lines(model, width: Int, height: Int) -> List(String) {
  frame_scene.screen(model, width, height) |> frame.buffer_to_lines
}

fn count(lines: List(String), needle: String) -> Int {
  list.count(lines, string.contains(_, needle))
}

pub fn a_repeated_poll_folds_into_one_counted_row_test() {
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let shown = lines(scene(), size.0, size.1)
    assert count(shown, "agent_wait") == 1
    assert count(shown, "✓ agent_wait · 2 subagents ×15") == 1
    assert count(shown, "tools · 15 calls") == 1
  })
}

pub fn a_repeated_provider_error_folds_and_keeps_its_gap_test() {
  let shown = lines(scene(), 120, 40)
  assert count(shown, "http 429") == 1
  assert count(shown, "provider returned http 429 ×20") == 1

  // The error is its own entry, so it sits a blank row below the last
  // call rather than welded to it.
  let assert Ok(#(at, _)) =
    shown
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, "http 429") })
    as "the error row is drawn"
  let assert [above, ..] = list.drop(shown, at - 1)
    as "a row sits above the error"
  assert string.trim(above) == ""
}

pub fn the_expanded_view_still_shows_every_occurrence_test() {
  let model = scene() |> tui.update(backend.Resize(120, 200), _)
  let expanded = tui.update(backend.KeyPress("ctrl+g"), model)
  let shown = lines(expanded, 120, 200)
  assert count(shown, "×15") == 0
  assert count(shown, "×20") == 0
}

pub fn different_calls_and_repeated_prompts_do_not_fold_test() {
  let model =
    frame_scene.attach(frame_scene.model(), "fix readme badge", [
      frame_scene.user(1, "again"),
      frame_scene.user(2, "again"),
      frame_scene.assistant(3, "", [
        frame_scene.call("a", "fs_read", [#("path", json.String("a.gleam"))]),
      ]),
      frame_scene.result(4, "a", "fs_read", "ok", frame_scene.Succeeded),
      frame_scene.assistant(5, "", [
        frame_scene.call("b", "fs_read", [#("path", json.String("b.gleam"))]),
      ]),
      frame_scene.result(6, "b", "fs_read", "ok", frame_scene.Succeeded),
    ])
  let shown = lines(model, 120, 40)
  assert count(shown, "again") == 2
  assert count(shown, "a.gleam") == 1
  assert count(shown, "b.gleam") == 1
  assert count(shown, "×") == 0
}
