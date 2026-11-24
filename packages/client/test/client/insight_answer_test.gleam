//// The parser for a triage model's answer is total: it returns labels or a
//// refusal, never a crash, and never a label for a row the request did not
//// issue.

import client/insight/answer
import gleam/int
import gleam/list
import gleam/string
import qcheck

// The fixed seed every generated case in this file replays from.
const answer_seed = 20_261_124

pub fn a_well_formed_answer_is_read_line_by_line_test() {
  let text = "1 high The same host failed three times.\n2 low Nothing to do."

  assert answer.parse(text, 2)
    == Ok([
      answer.Label(1, answer.High, "The same host failed three times."),
      answer.Label(2, answer.Low, "Nothing to do."),
    ])
}

pub fn a_numbering_and_a_weight_with_punctuation_is_still_read_test() {
  assert answer.parse("1. HIGH: it broke", 1)
    == Ok([answer.Label(1, answer.High, "it broke")])
  assert answer.parse("2) Normal - routine", 2)
    == Ok([answer.Label(2, answer.Normal, "routine")])
}

pub fn a_code_fence_around_the_answer_is_ignored_test() {
  assert answer.parse("```\n1 low skip it\n```", 1)
    == Ok([answer.Label(1, answer.Low, "skip it")])
}

pub fn a_weight_outside_the_three_refuses_the_whole_answer_test() {
  assert answer.parse("1 high fine\n2 urgent look now", 2)
    == Error(answer.BadWeight("urgent"))
}

pub fn a_line_that_is_not_in_the_form_refuses_the_whole_answer_test() {
  assert answer.parse("Here are my labels:\n1 high fine", 1)
    == Error(answer.BadLine("Here are my labels:"))
}

pub fn a_control_character_in_a_reason_refuses_the_whole_answer_test() {
  assert answer.parse("1 high bad\u{7}bell", 1)
    == Error(answer.ControlCharacter("1 high bad\u{7}bell"))
}

pub fn a_number_the_request_did_not_issue_is_dropped_test() {
  assert answer.parse("1 high ok\n9 high not asked\n0 low also not", 2)
    == Ok([answer.Label(1, answer.High, "ok")])
  assert answer.parse("9 high not asked", 2) == Error(answer.NoLabels)
}

pub fn the_first_line_for_a_row_is_the_label_test() {
  assert answer.parse("1 high first\n1 low second", 1)
    == Ok([answer.Label(1, answer.High, "first")])
}

pub fn an_empty_answer_has_no_labels_test() {
  assert answer.parse("", 3) == Error(answer.NoLabels)
  assert answer.parse("  \n\n", 3) == Error(answer.NoLabels)
}

pub fn a_long_reason_is_cut_to_the_head_limit_with_an_ellipsis_test() {
  let long = string.repeat("é", 300)
  let assert Ok([label]) = answer.parse("1 high " <> long, 1)
    as "a long reason is cut, not refused"

  assert string.length(label.why) == 120
  assert string.ends_with(label.why, "…")
}

// A weight and a reason, chosen by the generator from small closed sets so a
// round trip is exact: the parser trims the reason, so none begins or ends
// with a space.
fn reason_of(choice: Int) -> String {
  case choice % 4 {
    0 -> "It failed three times."
    1 -> "Reports no change."
    2 -> "A child result."
    _ -> "Nothing"
  }
}

fn weight_of(choice: Int) -> answer.Weight {
  case choice % 3 {
    0 -> answer.High
    1 -> answer.Normal
    _ -> answer.Low
  }
}

pub fn a_rendered_answer_parses_back_to_its_labels_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(answer_seed))
  let choices =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(0, 11),
      length_from: qcheck.bounded_int(1, 8),
    )

  qcheck.run(config, choices, fn(generated) {
    let labels =
      list.index_map(generated, fn(choice, index) {
        answer.Label(index + 1, weight_of(choice), reason_of(choice))
      })
    let text =
      list.map(labels, fn(label) {
        int.to_string(label.row)
        <> " "
        <> answer.weight_word(label.weight)
        <> " "
        <> label.why
      })
      |> string.join("\n")

    assert answer.parse(text, list.length(labels)) == Ok(labels)
  })
}

pub fn any_text_is_read_or_refused_and_never_labels_a_row_not_issued_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(answer_seed))

  qcheck.run(config, qcheck.string(), fn(text) {
    let issued = case answer.parse(text, 4) {
      Ok(labels) ->
        list.all(labels, fn(label) { label.row >= 1 && label.row <= 4 })
      Error(_) -> True
    }

    assert issued
  })
}
