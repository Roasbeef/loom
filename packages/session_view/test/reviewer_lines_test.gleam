//// The reviewer band's lines say what each reviewer is for, never the prompt
//// the harness composed for it.

import gleam/list
import gleam/string
import session_view/reviewer_status.{Row}

const feed =
  "[advisor feed: what the primary did since your last review] user: Write the single line and then keep going for a long while"

pub fn the_advisor_row_never_prints_its_feed_test() {
  let lines =
    reviewer_status.lines(
      [
        Row(
          "advisor",
          "op-1",
          feed,
          "assistant",
          "1 received, awaiting delivery",
        ),
      ],
      "main",
    )
  assert lines
    == [
      "Reviewer advisor · assistant · 1 received, awaiting delivery",
      "  Task: watching main",
    ]
  assert !list.any(lines, string.contains(_, "advisor feed"))
}

pub fn a_sub_agent_row_is_the_first_sentence_of_its_brief_test() {
  let brief =
    "You are working in the workspace /Users/me/proj. There is a tiny Python calculator project there: add power()."
  let lines =
    reviewer_status.lines(
      [Row("sub:tests", "op-2", brief, "bash", "no pending input")],
      "main",
    )
  assert lines
    == [
      "Sub-agent tests · bash · no pending input",
      "  Task: You are working in the workspace /Users/me/proj.",
    ]
}

// A minted sub-agent identity carries its parent and a suffix. The band names
// the agent by the slug its parent chose and by what it is, a sub-agent, and
// never as a reviewer or by the raw handle.
pub fn a_minted_sub_agent_shows_its_slug_and_no_suffix_test() {
  let lines =
    reviewer_status.lines(
      [
        Row(
          "sub:main/slow-worker-fbb94c37026b490e",
          "op-3",
          "Think about it.",
          "assistant",
          "no pending input",
        ),
      ],
      "main",
    )
  assert lines
    == [
      "Sub-agent slow-worker · assistant · no pending input",
      "  Task: Think about it.",
    ]
}

pub fn a_brief_with_no_sentence_end_is_cut_at_the_bound_test() {
  let brief = string.repeat("word ", 40)
  let assert [_, task] =
    reviewer_status.lines(
      [Row("sub:tests", "op-2", brief, "bash", "no pending input")],
      "main",
    )
  assert string.length(task) <= string.length("  Task: ") + 100
  assert string.ends_with(task, "…")
}

pub fn an_idle_advisor_has_no_row_on_a_page_test() {
  let idle = Row("advisor", "op-1", feed, "assistant", "no pending input")
  let waiting =
    Row("advisor", "op-1", feed, "assistant", "1 received, awaiting delivery")
  let sub = Row("sub:tests", "op-2", "Review it.", "bash", "no pending input")
  assert reviewer_status.without_idle_advisor([idle, sub]) == [sub]
  assert reviewer_status.without_idle_advisor([waiting]) == [waiting]
}
