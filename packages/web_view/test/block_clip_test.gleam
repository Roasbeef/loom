//// Where a quoted message is cut: only between blocks, never inside a fence,
//// and never so that the cut leaves Markdown the reader sees broken.

import gleam/int
import gleam/list
import gleam/string
import session_view/markdown
import web_view/block_clip

pub fn text_that_fits_is_unchanged_test() {
  assert block_clip.clip("one\n\ntwo\n- a\n- b", 100) == "one\n\ntwo\n- a\n- b"
}

pub fn a_cut_falls_between_blocks_test() {
  assert block_clip.clip("one\n\ntwo\n\nthree\n\nfour", 16) == "one\n\ntwo\n\n…"
}

pub fn newlines_inside_a_block_are_kept_test() {
  assert block_clip.clip("- a\n- b\n\nlater text that is dropped", 12)
    == "- a\n- b\n\n…"
}

pub fn a_blank_line_inside_a_fence_is_not_a_boundary_test() {
  let text = "intro\n\n```\nfirst\n\nsecond\n```\n\ntail"

  // The budget holds the intro but not the whole fence, so the fence goes.
  assert block_clip.clip(text, 20) == "intro\n\n…"

  // A budget that holds the fence keeps all of it, closing line included.
  assert block_clip.clip(text, 33) == "intro\n\n```\nfirst\n\nsecond\n```\n\n…"
}

pub fn a_first_block_that_is_too_long_becomes_one_cut_line_test() {
  let long = "**bold " <> string.repeat("word ", 100) <> "end**"
  let clipped = block_clip.clip(long, 60)

  assert string.byte_size(clipped) <= 60
  assert string.ends_with(clipped, "…")
}

// Whatever the cut, no result holds an unclosed fence, which would swallow the
// rest of the pane.
pub fn no_cut_leaves_a_fence_open_test() {
  let text =
    "a\n\n```gleam\nlet x = 1\n\nlet y = 2\n```\n\nb\n\n```\ncode\n```\n\nc"

  int.range(from: 8, to: 81, with: [], run: fn(all, budget) { [budget, ..all] })
  |> list.each(fn(budget) {
    let clipped = block_clip.clip(text, budget)
    let fences =
      list.length(
        list.filter(string.split(clipped, "\n"), fn(line) {
          string.starts_with(line, "```")
        }),
      )

    assert fences % 2 == 0
    assert string.byte_size(clipped) <= budget
    assert markdown.parse(clipped) != []
  })
}

pub fn a_tilde_fence_is_kept_or_dropped_whole_test() {
  let text = "a\n\n~~~\nfirst\n\nsecond\n~~~\n\nbbbbbbbbbb"

  assert block_clip.clip(text, 14) == "a\n\n…"
  assert block_clip.clip(text, 30) == "a\n\n~~~\nfirst\n\nsecond\n~~~\n\n…"
}

pub fn a_long_tight_list_keeps_whole_items_test() {
  let items =
    list.index_map(list.repeat("", 40), fn(_, n) {
      "- item number " <> int.to_string(n + 1)
    })
  let clipped = block_clip.clip(string.join(items, "\n"), 100)

  assert string.byte_size(clipped) <= 100
  assert string.ends_with(clipped, "\n\n…")

  // Every line before the ellipsis is a whole item.
  let lines = string.split(clipped, "\n")
  assert list.all(list.take(lines, list.length(lines) - 2), fn(line) {
    string.starts_with(line, "- item number ")
  })
}

pub fn an_oversized_fence_keeps_whole_code_lines_and_closes_test() {
  let code =
    list.index_map(list.repeat("", 30), fn(_, n) {
      "let x" <> int.to_string(n + 1)
    })
  let text = "```gleam\n" <> string.join(code, "\n") <> "\n```"
  let clipped = block_clip.clip(text, 60)

  assert string.byte_size(clipped) <= 60
  assert string.starts_with(clipped, "```gleam\nlet x1\n")
  assert string.ends_with(clipped, "\n```\n\n…")
}
