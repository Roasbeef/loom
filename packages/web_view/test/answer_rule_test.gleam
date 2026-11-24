//// The inbox's answer form read back into the daemon's wire object
//// (`web_view/answer_rule`): one fixed control for each question kind, an
//// option named by its position and never by its label, and the daemon's own
//// rule as the last word on validity.

import core/attention
import core/clock
import core/ids
import core/json
import gleam/option.{None, Some}
import web_view/answer_rule

fn anchor() -> attention.Anchor {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  attention.Anchor(operation:, step_id: "step-1", source_index: 1)
}

fn option_of(
  label: String,
  emphasis: attention.Emphasis,
) -> attention.Alternative {
  attention.Alternative(label:, note: Some("what it does"), emphasis:)
}

fn question(
  key: String,
  kind: attention.Kind,
  options: List(attention.Alternative),
) -> attention.Question {
  attention.Question(key:, prompt: "Prompt " <> key, kind:, options:)
}

fn ask_of(questions: List(attention.Question)) -> attention.Ask {
  attention.Ask(
    header: attention.Header(
      id: "ask-0123456789",
      created_at: 10,
      routing: attention.ToOwner,
      anchor: anchor(),
      strand: "main",
      parents: [],
    ),
    why: None,
    questions:,
    state: attention.AskOpen,
  )
}

fn everything() -> attention.Ask {
  ask_of([
    question("q1", attention.Confirm, []),
    question("q2", attention.Choice, [
      option_of("alpha", attention.Recommended),
      option_of("beta", attention.Plain),
    ]),
    question("q3", attention.Multiple(min: 1, max: 2), [
      option_of("a", attention.Plain),
      option_of("b", attention.Plain),
      option_of("c", attention.Plain),
    ]),
    question("q4", attention.Fill(format: attention.Number), []),
  ])
}

pub fn a_complete_form_stages_a_wire_object_and_lines_test() {
  let assert Ok(staged) =
    answer_rule.stage("s1", everything(), 7, [
      #("q1", "yes"),
      #("q2", "1"),
      #("q3", "0"),
      #("q3", "2"),
      #("q4", "12.5"),
    ])
  assert staged.revision == 7
  assert staged.ask == "ask-0123456789"
  assert staged.wire
    == json.Object([
      #(
        "answers",
        json.Object([
          #("q1", json.Bool(True)),
          #("q2", json.String("beta")),
          #("q3", json.Array([json.String("a"), json.String("c")])),
          #("q4", json.String("12.5")),
        ]),
      ),
      #("other", json.Object([])),
    ])
  assert staged.lines
    == [
      "Prompt q1 — Yes",
      "Prompt q2 — beta",
      "Prompt q3 — a, c",
      "Prompt q4 — 12.5",
    ]
}

pub fn other_answers_a_question_with_its_text_test() {
  let ask = ask_of([question("q1", attention.Confirm, [])])
  let assert Ok(staged) =
    answer_rule.stage("s1", ask, 1, [#("q1", "other"), #("q1-other", "maybe")])
  assert staged.lines == ["Prompt q1 — Other: maybe"]
  let assert Ok(_) =
    answer_rule.stage("s1", ask, 1, [#("q1", "other"), #("q1-other", "x")])

  // Other with no text is the daemon's refusal, in its fixed words.
  assert answer_rule.stage("s1", ask, 1, [#("q1", "other"), #("q1-other", " ")])
    == Error(answer_rule.Problem("q1", "Other needs some text"))

  // Text left in the hidden Other field beside another answer is ignored: the
  // answer is Yes, and the wire holds no `other` entry for it.
  let assert Ok(chosen) =
    answer_rule.stage("s1", ask, 1, [#("q1", "yes"), #("q1-other", "maybe")])
  let assert Ok(plain) = answer_rule.stage("s1", ask, 1, [#("q1", "yes")])
  assert chosen.lines == plain.lines
  assert chosen.wire == plain.wire
}

pub fn an_unanswered_question_is_named_test() {
  assert answer_rule.stage("s1", everything(), 7, [#("q1", "no")])
    == Error(answer_rule.Problem("q2", "missing"))
}

pub fn a_multiple_honours_its_bounds_test() {
  let ask =
    ask_of([
      question("q1", attention.Multiple(min: 1, max: 2), [
        option_of("a", attention.Plain),
        option_of("b", attention.Plain),
        option_of("c", attention.Plain),
      ]),
    ])
  assert answer_rule.stage("s", ask, 1, [])
    == Error(answer_rule.Problem("q1", "too few choices"))
  assert answer_rule.stage("s", ask, 1, [
      #("q1", "0"),
      #("q1", "1"),
      #("q1", "2"),
    ])
    == Error(answer_rule.Problem("q1", "too many choices"))
  let assert Ok(_) = answer_rule.stage("s", ask, 1, [#("q1", "1")])
}

pub fn a_checklist_may_be_empty_test() {
  let ask =
    ask_of([
      question("q1", attention.Checklist, [
        option_of("a", attention.Plain),
        option_of("b", attention.Plain),
      ]),
    ])
  let assert Ok(staged) = answer_rule.stage("s", ask, 1, [])
  assert staged.lines == ["Prompt q1 — none"]
}

pub fn a_forged_form_names_only_what_is_drawn_test() {
  // A position past the options, a label in place of a position, a field the
  // form does not have, and a value the kind does not take.
  assert answer_rule.stage("s", everything(), 7, [
      #("q1", "yes"),
      #("q2", "9"),
      #("q3", "0"),
      #("q4", "1"),
    ])
    == Error(answer_rule.Problem("q2", "not one of the options"))
  assert answer_rule.stage("s", everything(), 7, [
      #("q1", "yes"),
      #("q2", "alpha"),
    ])
    == Error(answer_rule.Problem("q2", "not one of the options"))
  assert answer_rule.stage("s", everything(), 7, [#("by", "me")])
    == Error(answer_rule.Problem("form", "no such field"))
  assert answer_rule.stage("s", everything(), 7, [#("q1", "maybe")])
    == Error(answer_rule.Problem("q1", "not a value this question takes"))
}

pub fn a_fill_is_checked_by_its_format_test() {
  let ask = ask_of([question("q1", attention.Fill(attention.Url), [])])
  assert answer_rule.stage("s", ask, 1, [#("q1", "ftp://x")])
    == Error(answer_rule.Problem("q1", "not of the format the question asks"))
  let assert Ok(_) = answer_rule.stage("s", ask, 1, [#("q1", "https://x.dev")])
}

pub fn the_words_of_a_question_number_it_test() {
  assert answer_rule.number("q3") == "Question 3"
  assert answer_rule.number("form") == "The form"
}
