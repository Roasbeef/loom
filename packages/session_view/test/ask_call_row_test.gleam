//// How the transcript words an agent's `ask` call: as the questions it puts to
//// the owner, never as the JSON that carried them.

import core/json
import gleam/string
import session_view/transcript_lines

fn question(prompt: String) -> json.JsonValue {
  json.Object([
    #("kind", json.String("confirm")),
    #("prompt", json.String(prompt)),
  ])
}

fn ask(questions: List(json.JsonValue)) -> json.JsonValue {
  json.Object([#("questions", json.Array(questions))])
}

pub fn the_compact_row_counts_the_questions_and_names_the_first_test() {
  assert transcript_lines.tool_call_summary(
      "ask",
      ask([question("Keep the independent parts?")]),
      False,
    )
    == "ask · 1 question: Keep the independent parts?"
  assert transcript_lines.tool_call_summary(
      "ask",
      ask([question("Fold under open ones, or…"), question("Keep them?")]),
      False,
    )
    == "ask · 2 questions: Fold under open ones, or…"
}

pub fn a_long_first_question_is_cut_on_one_line_test() {
  let row =
    transcript_lines.tool_call_summary(
      "ask",
      ask([question(string.repeat("word ", 60) <> "\nsecond line")]),
      False,
    )
  assert !string.contains(row, "\n")
  assert string.ends_with(row, "…")
}

pub fn expanded_details_list_every_question_test() {
  assert transcript_lines.tool_call_summary(
      "ask",
      ask([question("One?"), question("Two?")]),
      True,
    )
    == "ask · 2 questions\n1. One?\n2. Two?"
}

pub fn a_call_with_no_readable_question_keeps_the_generic_row_test() {
  let row = transcript_lines.tool_call_summary("ask", json.Object([]), False)
  assert string.starts_with(row, "ask · ")
  assert transcript_lines.tool_call_summary("ask", json.Null, False)
    != "ask · 0 questions"
}
