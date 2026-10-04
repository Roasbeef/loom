//// The row shapes of a turn's work, and of the rows around it, drawn from
//// pieces built by hand: a step is one line with one chevron and its detail
//// behind it, a row with nothing behind it has no chevron, the memory context
//// and a reasoning block are rows of the same shape, a prompt names its
//// sender on a line of its own, a spawn and a result are lines and not cards,
//// and the advisor's reviews draw no row in the lane at all.
////
//// The tests read the HTML the lane draws (`lane.view`) and never a page, so
//// each states the shape and nothing about the session around it. What the
//// words say is `step_words`' to test; what the browser does with the slots
//// is `<loom-expand>`'s.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import session_view/step_words.{Change, Figure, Mono, Prose, Unnamed, Words}
import session_view/transcript_line.{Line}
import session_view/transcript_lines.{type Block, Block, FromAdvisor, FromSpacer}
import session_view/turns
import web_view/view/lane

fn drawn(pieces: List(turns.Piece)) -> String {
  lane.view(
    pieces,
    [],
    lane.Beginning,
    Nil,
    lane.NoReplies,
    lane.no_marks(),
    "",
  )
  |> element.to_string
}

fn work(items: List(turns.Item)) -> turns.Piece {
  turns.Work(
    "work:1.0",
    turns.Worked(Some(22_000), 2, 1, 0),
    items,
    turns.Folded,
  )
}

fn step(
  words: step_words.Words,
  standing: turns.Standing,
  detail: List(transcript_line.Line),
) -> turns.Item {
  turns.Step("2.0/0", standing, words, detail, [], [])
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

pub fn a_step_is_one_line_with_its_words_and_one_chevron_test() {
  let edit =
    step(Words("Edit", Mono("src/calc.py"), Some(Change(3, 1))), turns.Done, [
      Line(transcript_line.ToolPatch, "@@ -1 +1 @@"),
    ])
  let html = drawn([work([edit])])

  // The line is the head slot: a glyph, the verb, the path in code, and the
  // lines the edit changed.
  assert string.contains(
    html,
    "<span class=\"row-head\" slot=\"head\"><span aria-hidden=\"true\" class=\"glyph\">✓</span><span class=\"verb\">Edit</span><span class=\"subject mono\">src/calc.py</span><span class=\"change\"><span class=\"added\">+3</span><span class=\"removed\">−1</span></span><span class=\"sr-only\"> done</span></span>",
  )

  // The detail is the body, and the row is the step's one expander: no
  // "Expand" button of its own, and no state word beside the line.
  assert count(html, "<loom-expand") == 1
  assert string.contains(html, "slot=\"body\"")
  assert string.contains(html, "@@ -1 +1 @@")
  assert !string.contains(html, "Expand")
  assert !string.contains(html, "step-state")
}

pub fn a_step_with_nothing_behind_it_is_its_line_alone_test() {
  let html =
    drawn([
      work([
        step(Words("Read", Mono("calc.py"), None), turns.Done, []),
      ]),
    ])
  assert string.contains(html, "class=\"flat step done\">")
  assert string.contains(html, "<span class=\"verb\">Read</span>")
  assert !string.contains(html, "loom-expand")
  assert !string.contains(html, "slot=\"body\"")
}

pub fn a_step_says_how_it_stands_in_a_glyph_and_for_assistive_technology_test() {
  let html =
    drawn([
      work([
        step(Words("Ran", Mono("make"), None), turns.Pending, []),
        turns.Step(
          "2.0/1",
          turns.Failed,
          Words("Ran", Mono("make"), None),
          [],
          [],
          [],
        ),
      ]),
    ])
  assert string.contains(html, "class=\"glyph\">●</span>")
  assert string.contains(html, "<span class=\"sr-only\"> running</span>")
  assert string.contains(html, "class=\"glyph\">✕</span>")
  assert string.contains(html, "<span class=\"sr-only\"> failed</span>")
}

pub fn a_subject_is_drawn_in_its_kinds_face_and_only_as_text_test() {
  let html =
    drawn([
      work([
        step(Words("Spawned", Prose("scan <b>it</b>"), None), turns.Done, []),
        turns.Step(
          "2.0/1",
          turns.Done,
          Words("Ran", Mono("echo <script>"), None),
          [],
          [],
          [],
        ),
      ]),
    ])
  assert string.contains(
    html,
    "<span class=\"subject\">scan &lt;b&gt;it&lt;/b&gt;</span>",
  )
  assert string.contains(
    html,
    "<span class=\"subject mono\">echo &lt;script&gt;</span>",
  )
  assert !string.contains(html, "<b>")
  assert !string.contains(html, "<script>")
}

pub fn the_memory_context_and_reasoning_are_rows_of_the_same_shape_test() {
  let thought =
    Block("2.0", FromSpacer, [
      #("2.0:0", Line(transcript_line.ReasoningDigest, "plan the edit")),
    ])
  let full = [Line(transcript_line.Reasoning, "plan the edit\nthen do it")]
  let html =
    drawn([
      work([
        turns.Memory("1.0:0", 4, [Line(transcript_line.ToolDetail, "- a note")]),
        turns.Narrated(thought, dict.from_list([#("2.0:0", full)]), Some(4000)),
      ]),
    ])
  assert string.contains(
    html,
    "<span class=\"verb\">Memory</span><span class=\"figure\">· 4 lines</span>",
  )
  assert string.contains(
    html,
    "<span class=\"verb\">Reasoning</span><span class=\"figure\">· 4s</span>",
  )

  // Each opens to its body from its own line; the reasoning's body is the
  // full form when the page holds one.
  assert count(html, "<loom-expand") == 2
  assert string.contains(html, "then do it")
  assert !string.contains(html, "[Ctrl+G to expand]")
}

pub fn a_reasoning_row_with_no_time_and_no_full_form_opens_to_its_line_test() {
  let thought =
    Block("2.0", FromSpacer, [
      #("2.0:0", Line(transcript_line.ReasoningDigest, "plan the edit")),
    ])
  let html = drawn([work([turns.Narrated(thought, dict.new(), None)])])
  assert string.contains(html, "<span class=\"verb\">Reasoning</span></span>")
  assert string.contains(html, "plan the edit")
  assert count(html, "<loom-expand") == 1
}

pub fn a_fold_is_one_collapsed_line_and_no_rule_test() {
  let html =
    drawn([work([step(Words("Read", Mono("a"), None), turns.Done, [])])])
  assert string.contains(
    html,
    "<span class=\"work-divider\" slot=\"summary\">Worked 22s · 2 steps · 1 file</span>",
  )
  assert count(html, "<loom-fold") == 1
}

fn prompt(role) -> turns.Piece {
  turns.Prompt(
    Block("1.0", FromSpacer, [
      #("1.0:0", Line(transcript_line.User, "add a subtract function")),
    ]),
    "principal-1",
    "Owner",
    role,
  )
}

pub fn a_prompt_names_its_sender_above_a_bubble_test() {
  let html = drawn([prompt(Some("operator"))])
  assert string.contains(
    html,
    "<p class=\"who\"><span class=\"who-name\">Owner</span> · operator</p>",
  )
  assert string.contains(
    html,
    "<pre class=\"line user\">add a subtract function</pre>",
  )

  // A sender who is not the reader has a name and no role.
  let other = drawn([prompt(None)])
  assert string.contains(other, "<span class=\"who-name\">Owner</span></p>")
}

pub fn a_spawn_and_a_one_line_result_are_lines_not_cards_test() {
  let html =
    drawn([
      turns.Spawned(
        "2.0/0",
        Some("sub:main/scan-1a2b3c"),
        "scan the repo",
        turns.Sub(0),
        turns.Done,
      ),
      turns.Returned(
        "6.0/0/0",
        "sub:main/scan-1a2b3c",
        "completed",
        "Found two files.",
        turns.Sub(0),
      ),
    ])
  assert string.contains(html, "<p class=\"who spawn hue-2\">Spawned scan")
  assert string.contains(
    html,
    "<span class=\"spawn-purpose\"> · scan the repo</span>",
  )
  assert string.contains(html, "<div class=\"result hue-2\">")
  assert string.contains(html, "scan finished</p>")
  assert string.contains(html, "<p class=\"result-line\">Found two files.</p>")
  assert !string.contains(html, "article")
  assert !string.contains(html, "card-head")
  assert !string.contains(html, "agent_spawn")
}

pub fn a_long_result_is_its_first_line_opened_to_the_report_test() {
  let report = "# Summary\n\nFound two files and fixed one."
  let html =
    drawn([
      turns.Returned(
        "6.0/0/0",
        "sub:main/scan-1a2b3c",
        "completed",
        report,
        turns.Sub(0),
      ),
    ])
  assert string.contains(html, "<span class=\"subject\">Summary</span>")
  assert count(html, "<loom-expand") == 1
  assert string.contains(html, "Found two files and fixed one.")
}

fn review(key: String) -> Block {
  Block(key, FromAdvisor, [
    #(key <> ":0", Line(transcript_line.System, "Advisor · reviewed the plan")),
  ])
}

pub fn the_advisors_reviews_draw_no_row_in_the_lane_test() {
  // The panel's commentary section is the record of every review, so a
  // review, or a run of them, is neither a row nor a dot in the lane.
  let one = drawn([turns.Commentary(review("3.0"), 1)])
  assert !string.contains(one, "commentary-mark")
  assert !string.contains(one, "tl-row")
  assert !string.contains(one, "reviewed the plan")

  let two = drawn([turns.Commentary(review("3.0"), 2)])
  assert !string.contains(two, "commentary-mark")
  assert !string.contains(two, "reviews")
}

pub fn a_figure_and_an_unnamed_subject_draw_no_subject_span_test() {
  let html =
    drawn([
      work([
        step(Words("Checked context", Unnamed, None), turns.Done, []),
        turns.Step(
          "2.0/1",
          turns.Done,
          Words("Memory", Figure("2 lines"), None),
          [],
          [],
          [],
        ),
      ]),
    ])
  assert !string.contains(html, "class=\"subject")
  assert string.contains(html, "<span class=\"figure\">· 2 lines</span>")
  assert string.contains(html, "<span class=\"verb\">Checked context</span>")
  assert !string.contains(html, "None")
}

pub fn an_opened_edit_draws_its_diff_a_line_at_a_time_in_colour_test() {
  let patch =
    Line(
      transcript_line.ToolPatch,
      "@@ -4,2 +4,2 @@\n keep <b>\n-old\n+new\n\\ No newline at end of file",
    )
  let html =
    drawn([
      work([
        step(Words("Edit", Mono("calc.py"), Some(Change(1, 1))), turns.Done, [
          patch,
        ]),
      ]),
    ])
  assert string.contains(html, "<div class=\"diff\">")
  assert string.contains(
    html,
    "<div class=\"diff-row diff-hunk\"><span class=\"diff-text\">@@ -4,2 +4,2 @@</span></div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-removed\"><span class=\"diff-num\">5</span><span class=\"diff-num\"></span><span class=\"diff-sign\">−</span><span class=\"diff-text\">old</span></div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-added\"><span class=\"diff-num\"></span><span class=\"diff-num\">5</span><span class=\"diff-sign\">+</span><span class=\"diff-text\">new</span></div>",
  )
  assert string.contains(html, "diff-row diff-note")

  // The file's own text is a text node, and the patch is not drawn as one
  // preformatted block.
  assert string.contains(html, "keep &lt;b&gt;")
  assert !string.contains(html, "<b>")
  assert !string.contains(html, "tool-patch")
}

pub fn a_diff_past_the_bound_says_how_many_lines_it_left_out_test() {
  let many =
    list.repeat("+x", 430)
    |> string.join("\n")
  let html =
    drawn([
      work([
        step(Words("Wrote", Mono("big.txt"), None), turns.Done, [
          Line(transcript_line.ToolPatch, "@@ -0,0 +1,430 @@\n" <> many),
        ]),
      ]),
    ])
  assert count(html, "diff-row diff-added") == 399
  assert string.contains(
    html,
    "<p class=\"diff-cut\">31 more lines not shown</p>",
  )
}

// A report's first line loses a Markdown marker only when it is one: a marker
// is the sign and its space, so `-1 is wrong` and `**bold**` keep their first
// characters.
pub fn a_reports_first_line_keeps_text_that_only_looks_like_a_marker_test() {
  let head = fn(report) {
    drawn([
      turns.Returned(
        "6.0/0/0",
        "sub:main/scan-1a2b3c",
        "completed",
        report,
        turns.Sub(0),
      ),
    ])
  }
  assert string.contains(
    head("-1 is wrong\nmore"),
    "<span class=\"subject\">-1 is wrong</span>",
  )
  assert string.contains(
    head("**bold** start\nmore"),
    "<span class=\"subject\">**bold** start</span>",
  )
  assert string.contains(
    head("- a list item\nmore"),
    "<span class=\"subject\">a list item</span>",
  )
}
