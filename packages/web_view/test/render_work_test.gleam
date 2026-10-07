//// Preprocessing belongs behind the condition that needs its result.
////
//// Successful and pending steps preserve their transcript rows without
//// assembling a refusal. A settled reasoning preview checks for whitespace
//// only when its leaf memo changes. These tests carry Lustre's real cache
//// and count OTP trim calls, which survive the compiler's local inlining.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/element.{type Element}
import session_view/step_words
import session_view/transcript_line.{type Line, Line}
import session_view/transcript_lines
import session_view/turns
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
