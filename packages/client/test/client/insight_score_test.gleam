//// The comparison of the two orderings: newest first against the triage
//// order, scored by whether an "open first" row is among the top three, and
//// read by `evalstat`'s paired verdict with its minimum detectable effect
//// printed first.

import client/insight/answer
import client/insight/score
import evalstat/verdict
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import qcheck

// The fixed seed the generated sessions replay from.
const score_seed = 20_261_126

fn row(
  number: Int,
  open_first: score.OpenFirst,
  weight: answer.Weight,
) -> score.Ranked {
  score.Ranked(number, open_first, weight)
}

pub fn triage_order_sorts_by_weight_and_keeps_newest_first_within_one_test() {
  let rows = [
    row(1, score.FineToSkip, answer.Normal),
    row(2, score.OpenFirst, answer.High),
    row(3, score.FineToSkip, answer.Low),
    row(4, score.OpenFirst, answer.High),
    row(5, score.FineToSkip, answer.Normal),
  ]

  assert list.map(score.triage_order(rows), fn(ranked) { ranked.row })
    == [2, 4, 1, 5, 3]
}

pub fn a_model_that_weighs_every_row_alike_reproduces_the_baseline_test() {
  let rows = score.rank(8, [], [3, 5])

  assert score.triage_order(rows) == rows
}

pub fn a_session_passes_when_an_open_first_row_is_in_the_top_three_test() {
  let outcome =
    score.judge_session(score.Judged(
      "s",
      score.rank(8, [answer.Label(7, answer.High, "x")], [7]),
    ))

  assert outcome.baseline_hits == 0
  assert outcome.candidate_hits == 1
  assert outcome.slots == 3
}

pub fn rank_marks_unlabelled_rows_normal_and_unticked_rows_skippable_test() {
  assert score.rank(2, [answer.Label(2, answer.Low, "x")], [1])
    == [
      score.Ranked(1, score.OpenFirst, answer.Normal),
      score.Ranked(2, score.FineToSkip, answer.Low),
    ]
  assert score.rank(0, [], []) == []
}

// Thirty sessions whose open-first row is the seventh, which newest first
// never reaches. In twelve the model puts it first, in sixteen the open-first
// row is the newest and neither order misses it, and in two the model buries
// the newest under three rows it calls high. The instrument asks for spread
// between sessions before it calls a difference real, so a fixture where every
// session moved the same way would be Underpowered.
fn judged_sessions() -> List(score.Judged) {
  list.repeat(Nil, 30)
  |> list.index_map(fn(_, index) {
    let #(labels, opened) = case index {
      index if index < 12 -> #([answer.Label(7, answer.High, "x")], [7])
      index if index < 28 -> #([], [1])
      _ -> #(
        [
          answer.Label(1, answer.Low, "x"),
          answer.Label(4, answer.High, "x"),
          answer.Label(5, answer.High, "x"),
          answer.Label(6, answer.High, "x"),
        ],
        [1],
      )
    }

    score.Judged(
      "session-" <> int.to_string(index),
      score.rank(8, labels, opened),
    )
  })
}

pub fn a_model_that_finds_the_buried_row_often_enough_improves_it_test() {
  let report = score.report(judged_sessions())

  let assert verdict.Improved(effect:, ..) = report.verdict
  assert score.mde(report.verdict) != Error(Nil)
  assert float.loosely_equals(effect, 1.0 /. 3.0, tolerating: 0.001)
  assert report.high_rows == 12 + 2 * 3
  assert report.high_skipped == 2 * 3
}

pub fn a_model_that_labels_nothing_cannot_improve_on_newest_first_test() {
  let unlabelled =
    list.repeat(Nil, 30)
    |> list.index_map(fn(_, index) {
      let opened = case index % 2 {
        0 -> [1]
        _ -> [7]
      }

      score.Judged("s" <> int.to_string(index), score.rank(8, [], opened))
    })
  let report = score.report(unlabelled)

  assert list.all(report.outcomes, fn(outcome) {
    outcome.baseline_hits == outcome.candidate_hits
  })
  let assert verdict.Underpowered(..) = report.verdict
  assert score.report([]).verdict == verdict.Incomplete("no counted trials")
}

pub fn the_report_prints_the_minimum_detectable_effect_first_test() {
  let text = score.render(score.report(judged_sessions()))
  let assert [first, ..] = string.split(text, "\n")

  assert string.starts_with(first, "Minimum detectable effect: ")
  assert string.contains(text, "Verdict: Improved")
  assert string.contains(text, "High rows the owner would skip: 6 of 18")
}

pub fn a_session_with_no_spread_is_underpowered_not_decided_test() {
  let same =
    list.repeat(Nil, 30)
    |> list.index_map(fn(_, index) {
      score.Judged("s" <> int.to_string(index), score.rank(8, [], [1]))
    })

  let assert verdict.Underpowered(..) = score.report(same).verdict
}

pub fn the_triage_order_is_a_permutation_with_a_stable_top_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(score_seed))
  let weights =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(0, 2),
      length_from: qcheck.bounded_int(0, 12),
    )

  qcheck.run(config, weights, fn(generated) {
    let rows =
      list.index_map(generated, fn(weight, index) {
        let held = case weight {
          0 -> answer.High
          1 -> answer.Normal
          _ -> answer.Low
        }
        row(index + 1, score.FineToSkip, held)
      })
    let ordered = score.triage_order(rows)

    // Nothing is added or lost, and a row never moves below a lighter one.
    assert list.sort(list.map(ordered, fn(r) { r.row }), int.compare)
      == list.map(rows, fn(r) { r.row })
    assert score.triage_order(ordered) == ordered
  })
}
