//// Preprocessing belongs behind the condition that needs its result.
////
//// Successful and pending steps preserve their transcript rows without
//// assembling a refusal. A settled reasoning preview checks for whitespace
//// only when its leaf memo changes. These tests carry Lustre's real cache
//// and count OTP trim calls, which survive the compiler's local inlining.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import page_fixture
import session_view/step_words
import session_view/transcript_line.{type Line, Line}
import session_view/transcript_lines
import session_view/turns
import web_view/component
import web_view/view/fold_row
import web_view/view/lane

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

@external(erlang, "lane_memo_ffi", "patch_text")
fn patch(
  cache: Cache,
  old: Element(message),
  new: Element(message),
) -> #(String, Cache)

@external(erlang, "render_memo_ffi", "work_counted")
fn counted(run: fn() -> value) -> #(value, Int, Int)

pub fn successful_and_pending_steps_keep_rows_without_refusal_work_test() {
  let rows = [
    Line(transcript_line.ToolResult, "  result <b>λ</b>\n"),
    Line(transcript_line.ToolFailure, "fs_read\nrefused `path`"),
    Line(transcript_line.ToolPatch, "@@ -1 +1 @@"),
  ]
  let draw = fn(line: Line) { element.text(line.text) }
  let expected =
    rows
    |> list.map(fold_row.line_row(_, draw))
    |> element.fragment
    |> element.to_string

  list.each([turns.Done, turns.Pending], fn(standing) {
    let #(body, trims, _) =
      counted(fn() {
        fold_row.step_body(
          standing,
          step_words.Words("Read", step_words.Unnamed, None),
          rows,
          draw,
        )
        |> element.fragment
        |> element.to_string
      })
    assert body == expected
    assert trims == 0
  })
}

fn reasoning(text: String) -> Element(Nil) {
  let block =
    transcript_lines.Block("thought", transcript_lines.FromSpacer, [
      #("thought:0", Line(transcript_line.ReasoningDigest, text)),
    ])
  lane.rows(
    [
      turns.Work(
        "work",
        turns.Worked(None, 0, 0, 0, turns.Finished),
        [turns.Narrated(block, dict.new(), None)],
        turns.Unfolded(0),
        None,
      ),
    ],
    [],
    element.none(),
    fn(line) { element.text(line.text) },
    lane.NoReplies,
    lane.no_marks(),
    lane.NoFolds,
    "",
  )
}

pub fn unchanged_reasoning_preview_does_no_trim_or_markdown_work_test() {
  let text = "\n**Check** `λ` <b>now</b>\nthen done"
  let view = reasoning(text)
  let #(cache, trims, parses) = counted(fn() { first(view) })
  assert trims > 0
  assert parses > 0

  let #(#(_, cache), trims, parses) =
    counted(fn() { patch(cache, view, reasoning(text)) })
  assert trims == 0
  assert parses == 0

  let #(#(_, cache), trims, parses) =
    counted(fn() { patch(cache, view, reasoning(text)) })
  assert trims == 0
  assert parses == 0

  let next = reasoning("**Changed** <b>still text</b>")
  let #(#(text, _), trims, parses) = counted(fn() { patch(cache, view, next) })
  assert trims > 0
  assert parses > 0
  assert string.contains(text, "Changed")
  assert string.contains(
    element.to_string(next),
    "&lt;b&gt;still text&lt;/b&gt;",
  )
  assert !string.contains(element.to_string(next), "<b>")
}

pub fn blank_reasoning_preview_refreshes_to_text_and_back_test() {
  let blank = reasoning("\t\n\u{200e}\u{2029}")
  assert !string.contains(element.to_string(blank), "subject preview")
  let cache = first(blank)
  let #(#(_, cache), trims, parses) =
    counted(fn() { patch(cache, blank, reasoning("\t\n\u{200e}\u{2029}")) })
  assert trims == 0
  assert parses == 0

  let words = reasoning("**Ready**")
  let #(changed, cache) = patch(cache, blank, words)
  assert string.contains(changed, "Ready")
  let #(changed, _) = patch(cache, words, blank)
  assert !string.contains(changed, "Ready")
  assert !string.contains(element.to_string(blank), "subject preview")
}

fn failed(words: step_words.Words, rows: List(Line)) -> Element(Nil) {
  fold_row.step_body(turns.Failed, words, rows, fn(line) {
    element.text(line.text)
  })
  |> element.fragment
}

pub fn unchanged_failed_step_body_does_no_refusal_work_test() {
  let words = step_words.Words("Read", step_words.Unnamed, None)
  let rows = [
    Line(
      transcript_line.ToolFailure,
      "fs_read\ninvalid arguments: `path` is required",
    ),
    Line(transcript_line.ToolPatch, "patch <b>λ</b>"),
  ]
  let #(#(view, cache), trims, _) =
    counted(fn() {
      let view = failed(words, rows)
      #(view, first(view))
    })
  assert trims > 0

  // A memo hit must preserve its leaf for the next patch as well as this one.
  let #(#(_, cache), trims, _) =
    counted(fn() { patch(cache, view, failed(words, rows)) })
  assert trims == 0
  let #(#(_, cache), trims, _) =
    counted(fn() { patch(cache, view, failed(words, rows)) })
  assert trims == 0

  // Both the sentence and engine text remain dependencies of the leaf.
  let edited = step_words.Words("Edit", step_words.Unnamed, None)
  let next = failed(edited, rows)
  let #(#(changed, cache), trims, _) =
    counted(fn() { patch(cache, view, next) })
  assert trims > 0
  assert string.contains(changed, "The edit was rejected")
  let changed_rows = [Line(transcript_line.ToolResult, "new reason <b>λ</b>")]
  let #(#(changed, _), trims, _) =
    counted(fn() { patch(cache, next, failed(edited, changed_rows)) })
  assert trims > 0
  assert string.contains(changed, "new reason <b>λ</b>")
  let html = element.to_string(failed(edited, changed_rows))
  assert string.contains(html, "new reason &lt;b&gt;λ&lt;/b&gt;")
  assert !string.contains(html, "new reason <b>")
}

pub fn blank_failed_refusal_preserves_original_row_order_test() {
  let words = step_words.Words("Read", step_words.Unnamed, None)
  let rows = [
    Line(transcript_line.ToolFailure, "fs_read\n \t"),
    Line(transcript_line.ToolPatch, "patch <b>λ</b>"),
    Line(transcript_line.ToolResult, " \t"),
  ]
  let expected =
    rows
    |> list.map(fn(row) { element.text(row.text) })
    |> element.fragment
    |> element.to_string
  let actual = element.to_string(failed(words, rows))
  assert without_markers(actual) == without_markers(expected)
}

// Fragment and memo markers describe the virtual tree, not the row content.
fn without_markers(html: String) -> String {
  html
  |> string.replace("<!-- lustre:memo -->", "")
  |> string.replace("<!-- lustre:fragment -->", "")
  |> string.replace("<!-- /lustre:fragment -->", "")
}

pub fn empty_failed_step_has_no_expandable_body_test() {
  let words = step_words.Words("Read", step_words.Unnamed, None)
  let body =
    fold_row.step_body(turns.Failed, words, [], fn(row) {
      element.text(row.text)
    })
  assert list.is_empty(body)
  let html = fold_row.step(turns.Failed, words, None, body) |> element.to_string
  assert !string.contains(html, "loom-expand")
}

// The full source survives a sealed answer even when the drawn row is only a
// digest. Reusing the preview alone must not expand that source again.
pub fn unchanged_stored_reasoning_reuses_its_source_and_body_test() {
  let model =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.reasoned_answers(4, None)])
  let drawn = fn() {
    lane.rows(
      component.pieces(model),
      [],
      element.none(),
      fn(line) { element.text(line.text) },
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  }
  let view = drawn()
  let #(cache, trims, _) = counted(fn() { first(view) })
  assert trims > 0

  let #(#(_, cache), trims, parses) =
    counted(fn() { patch(cache, view, drawn()) })
  assert trims == 0
  assert parses == 0
  let #(#(_, _), trims, parses) = counted(fn() { patch(cache, view, drawn()) })
  assert trims == 0
  assert parses == 0
}

fn held_reasoning(text: String, took: Int) -> turns.Piece {
  turns.Plain(
    transcript_lines.Block("held", transcript_lines.FromSpacer, [
      #(
        "held:0",
        Line(transcript_line.SummarizedReasoning, "Reasoning\nSame summary"),
      ),
    ]),
    dict.from_list([#("held:0", [Line(transcript_line.Reasoning, text)])]),
    Some(took),
  )
}

fn thought_lane(pieces: List(turns.Piece)) -> Element(Nil) {
  lane.rows(
    pieces,
    [],
    element.none(),
    fn(line) { element.text(line.text) },
    lane.NoReplies,
    lane.no_marks(),
    lane.NoFolds,
    "",
  )
}

// A row's label can stay the same while its source body or elapsed figure
// changes. Both remain dependencies, as does its right to inherit live state.
pub fn a_reasoning_leaf_refreshes_body_time_and_handoff_test() {
  let view = thought_lane([held_reasoning("first body\nsecond line", 1000)])
  let cache = first(view)
  let changed = thought_lane([held_reasoning("new body\nsecond\nthird", 2000)])
  let #(text, cache) = patch(cache, view, changed)
  assert string.contains(text, "new body")
  assert string.contains(text, "3 lines")
  assert string.contains(text, "2s")

  let newer =
    turns.Plain(
      transcript_lines.Block("newer", transcript_lines.FromSpacer, [
        #("newer:0", Line(transcript_line.ReasoningDigest, "newer thought")),
      ]),
      dict.new(),
      None,
    )
  let appended =
    thought_lane([
      held_reasoning("new body\nsecond\nthird", 2000),
      newer,
    ])
  let #(text, cache) = patch(cache, changed, appended)
  assert string.contains(text, "handoff")
  assert string.contains(text, "no")
  let #(#(_, _), trims, parses) =
    counted(fn() {
      patch(
        cache,
        appended,
        thought_lane([
          held_reasoning("new body\nsecond\nthird", 2000),
          newer,
        ]),
      )
    })
  assert trims == 0
  assert parses == 0
}
