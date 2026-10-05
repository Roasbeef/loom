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

// A failed call opens on one plain sentence in place of the tool's name, with
// the engine's text under it, and a backtick pair in that text is a code span
// so that no backtick is drawn.
pub fn a_failed_step_opens_on_a_sentence_and_draws_no_backtick_test() {
  let failed =
    step(Words("Edit", Mono("test_calc.py"), None), turns.Failed, [
      Line(
        transcript_line.ToolFailure,
        "fs_edit\ninvalid arguments: `from` is required for this hunk op",
      ),
    ])
  let html = drawn([work([failed])])

  assert string.contains(
    html,
    "<p class=\"step-error-sentence\">The edit was rejected: &quot;from&quot; is required for this hunk op.</p>",
  )
  assert string.contains(
    html,
    "<code class=\"step-error-code\">from</code> is required for this hunk op",
  )
  assert !string.contains(html, "`")
  assert !string.contains(html, "class=\"line tool-failure\"")

  // A failed step with no refusal row keeps its own rows, as a rejected
  // program's carry their own reason.
  let program =
    step(Words("code_mode", Unnamed, None), turns.Failed, [
      Line(transcript_line.ProgramFailure, "× code_mode · refused by vetting"),
    ])
  let kept = drawn([work([program])])
  assert string.contains(kept, "refused by vetting")
  assert !string.contains(kept, "step-error")
}

// The engine's text is session text: a backtick span that holds markup is a
// code span of escaped text, and no tag it spells is drawn.
pub fn hostile_engine_text_in_a_backtick_span_stays_escaped_test() {
  let html =
    drawn([
      work([
        step(Words("Ran", Mono("make"), None), turns.Failed, [
          Line(transcript_line.ToolResult, "bad `</code><img onerror=x>` input"),
        ]),
      ]),
    ])
  assert string.contains(
    html,
    "<code class=\"step-error-code\">&lt;/code&gt;&lt;img onerror=x&gt;</code>",
  )
  assert !string.contains(html, "<img")
}

// An unmatched backtick is left as the engine wrote it, so the text is never
// cut short by a pair that was not one.
pub fn an_unmatched_backtick_is_left_alone_test() {
  let html =
    drawn([
      work([
        step(Words("Ran", Mono("make"), None), turns.Failed, [
          Line(transcript_line.ToolResult, "it said `oops"),
        ]),
      ]),
    ])
  assert string.contains(html, "it said `oops")
  assert !string.contains(html, "step-error-code")
}

// A sub-agent's finished row shows its report's first line as Markdown, bold
// and code kept and no asterisks, and a report whose breaks arrived as the two
// characters `\n` is two lines behind the chevron, not a backslash on screen.
pub fn a_reports_line_renders_markdown_and_never_a_literal_break_test() {
  let html =
    drawn([
      turns.Returned(
        "6.0/0/0",
        "sub:main/review-readme-d799cf20a6964d72",
        "completed",
        "**Current content:** `# calc` \\n Tiny calculator.",
        turns.Sub(0),
      ),
    ])
  assert string.contains(
    html,
    "<span class=\"subject\"><strong>Current content:</strong> <code class=\"md-code-span\"># calc</code></span>",
  )
  assert string.contains(html, "<loom-expand")
  assert string.contains(html, "Tiny calculator.")
  assert !string.contains(html, "**")
  assert !string.contains(html, "\\n")
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
    "<span class=\"verb\">Reasoning</span><span class=\"figure\">· 2 lines · 4s</span>",
  )

  // Each opens to its body from its own line; the reasoning's body is the
  // full form when the page holds one.
  assert count(html, "<loom-expand") == 2
  assert string.contains(html, "then do it")
  assert !string.contains(html, "[Ctrl+G to expand]")
}

pub fn a_reasoning_row_with_no_more_to_open_is_its_heading_and_its_line_test() {
  let thought =
    Block("2.0", FromSpacer, [
      #("2.0:0", Line(transcript_line.ReasoningDigest, "plan the edit")),
    ])
  let html = drawn([work([turns.Narrated(thought, dict.new(), None)])])
  assert string.contains(html, "<span class=\"verb\">Reasoning</span>")
  assert string.contains(
    html,
    "<span class=\"subject preview\">plan the edit</span>",
  )

  // Nothing is behind the line, so it has no chevron and no line count.
  assert count(html, "<loom-expand") == 0
  assert !string.contains(html, "lines")
}

pub fn a_closed_reasoning_row_previews_the_first_line_cut_as_markdown_test() {
  let thought =
    Block("2.0", FromSpacer, [
      #("2.0:0", Line(transcript_line.ReasoningDigest, "Check 7")),
    ])
  let full = [
    Line(
      transcript_line.Reasoning,
      "\n**Check** `7` <b>now</b>\nthen 13\nthen done",
    ),
  ]
  let html =
    drawn([
      work([
        turns.Narrated(thought, dict.from_list([#("2.0:0", full)]), None),
      ]),
    ])

  // The preview is the first non-empty line with its Markdown drawn, in the
  // head slot, and the model's markup is escaped text.
  assert string.contains(html, "<span class=\"subject preview\">")
  assert string.contains(html, "<strong>Check</strong>")
  assert string.contains(html, "&lt;b&gt;now&lt;/b&gt;")
  assert !string.contains(html, "<b>")
  assert string.contains(html, "· 4 lines</span>")

  // The row that replaces a live one is marked, so an open live row is
  // carried over to it in the browser.
  assert string.contains(html, "kind=\"settled\"")
}

// Only the newest settled reasoning row of the lane may take an open live
// row's state, so only it carries `handoff="yes"`; an older row, such as one
// Load older brings in, says `no`. The mark is a fixed word, never model text.
pub fn only_the_newest_reasoning_row_is_marked_to_take_the_handoff_test() {
  let thought = fn(key, text) {
    turns.Narrated(
      Block(key, FromSpacer, [
        #(key <> ":0", Line(transcript_line.ReasoningDigest, text)),
      ]),
      dict.new(),
      None,
    )
  }
  let html =
    drawn([
      work([thought("2.0", "older <b>idea</b>"), thought("3.0", "newest idea")]),
    ])
  assert count(html, "handoff=\"yes\"") == 1
  assert count(html, "handoff=\"no\"") == 1

  // The older row comes first in the lane, so its `no` precedes the `yes`.
  let assert Ok(#(before, after)) = string.split_once(html, "handoff=\"yes\"")
    as "one row is marked"
  assert string.contains(before, "handoff=\"no\"")
  assert !string.contains(after, "handoff=\"no\"")
  assert !string.contains(html, "<b>")
}

pub fn every_speaker_shape_of_a_reasoning_block_closes_to_a_heading_and_a_preview_test() {
  let one = fn(speaker, text) {
    drawn([
      work([
        turns.Narrated(
          Block("2.0", FromSpacer, [#("2.0:0", Line(speaker, text))]),
          dict.new(),
          Some(69_000),
        ),
      ]),
    ])
  }

  // A digest alone has nothing to open: heading, time, preview, no chevron.
  let digest =
    one(transcript_line.ReasoningDigest, "The `int` import is unused")
  assert string.contains(digest, "<span class=\"verb\">Reasoning</span>")
  assert string.contains(digest, "· 1m 9s</span>")
  assert string.contains(
    digest,
    "<span class=\"subject preview\">The <code class=\"md-code-span\">int</code> import is unused</span>",
  )
  assert count(digest, "<loom-expand") == 0

  // The whole text on the row: the same heading and preview of its first
  // line, a line count, and a chevron to the rest.
  let raw = one(transcript_line.Reasoning, "First idea\nsecond idea")
  assert string.contains(raw, "<span class=\"verb\">Reasoning</span>")
  assert string.contains(raw, "· 2 lines · 1m 9s</span>")
  assert string.contains(
    raw,
    "<span class=\"subject preview\">First idea</span>",
  )
  assert count(raw, "<loom-expand") == 1

  // A provider's summary: the verb names it, the terminal's header line is
  // not drawn, and the preview is the summary's first line.
  let summary =
    one(
      transcript_line.SummarizedReasoning,
      "  [Ctrl+G to expand]\nFound it.\nSecond line",
    )
  assert string.contains(
    summary,
    "<span class=\"verb\">Reasoning (summarized)</span>",
  )
  assert string.contains(summary, "· 2 lines · 1m 9s</span>")
  assert string.contains(
    summary,
    "<span class=\"subject preview\">Found it.</span>",
  )
  assert !string.contains(summary, "Ctrl+G")
  assert count(summary, "<loom-expand") == 1

  // Each is marked as a settled reasoning row, whatever its speaker.
  assert string.contains(digest, "kind=\"settled\"")
  assert string.contains(raw, "kind=\"settled\"")
  assert string.contains(summary, "kind=\"settled\"")
}

pub fn a_reasoning_row_opens_to_the_whole_text_as_markdown_test() {
  let thought =
    Block("2.0", FromSpacer, [
      #("2.0:0", Line(transcript_line.ReasoningDigest, "Plan")),
    ])
  let full = [Line(transcript_line.Reasoning, "# Plan\n- one\n- two")]
  let html =
    drawn([
      work([
        turns.Narrated(thought, dict.from_list([#("2.0:0", full)]), None),
      ]),
    ])
  assert string.contains(html, "slot=\"body\"")
  assert string.contains(html, "md-heading")
  assert string.contains(html, "md-list")
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

  // The role is the same word whether or not the host holds an attachment for
  // the sender, so a message reads alike on every page and in every turn.
  let other = drawn([prompt(None)])
  assert string.contains(
    other,
    "<span class=\"who-name\">Owner</span> · operator</p>",
  )
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

// A collapsed result cut at a word boundary ends with the ellipsis inside its
// line, which the stylesheet keeps to one row; the ellipsis is never a row of
// its own, and the cut leaves no half word before it.
pub fn a_cut_result_line_ends_with_an_inline_ellipsis_test() {
  let report = string.repeat("alpha ", 40) <> "\n\nthe rest of the report"
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
  let assert Ok(#(_, after)) = string.split_once(html, "class=\"subject\">")
  let assert Ok(#(line, _)) = string.split_once(after, "</span>")

  assert string.ends_with(line, "alpha…")
  assert string.length(line) <= 141
  assert !string.contains(line, "alph…")
}

// The terminal words a collapsed row with its `Ctrl+G` hint; the page has no
// such key, so no row it draws carries the hint.
pub fn no_row_names_the_terminals_key_test() {
  let feed =
    Block("4.0", FromSpacer, [
      #(
        "4.0:0",
        Line(transcript_line.System, "advisor feed: user:  [Ctrl+G to expand]"),
      ),
      #(
        "4.0:1",
        Line(
          transcript_line.User,
          "start of a paste  [~500 tokens · Ctrl+G to expand]",
        ),
      ),
    ])
  let html = drawn([turns.Plain(feed, dict.new(), None)])

  assert !string.contains(string.lowercase(html), "ctrl+g")
  assert string.contains(html, "advisor feed: user:")
  assert string.contains(html, "[~500 tokens]")
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
    "<div class=\"diff-row diff-removed\"><span class=\"diff-gutter\"><span class=\"diff-num\">5</span><span class=\"diff-num\"></span><span class=\"diff-sign\">−</span></span><span class=\"diff-text\">old</span></div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-added\"><span class=\"diff-gutter\"><span class=\"diff-num\"></span><span class=\"diff-num\">5</span><span class=\"diff-sign\">+</span></span><span class=\"diff-text\">new</span></div>",
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
    "<span class=\"subject\"><strong>bold</strong> start</span>",
  )
  assert string.contains(
    head("- a list item\nmore"),
    "<span class=\"subject\">a list item</span>",
  )
}
