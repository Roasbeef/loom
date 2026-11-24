//// The comparison the offline ordering test exists to make
//// (`docs/design-notes/insight-triage.md`, section 8.3).
////
//// Two orderings of the same rows are scored against the owner's labels.
//// The baseline is newest first, which is the classifier alone. The
//// candidate is the triage order: rows sorted by the model's weight, with the
//// classifier's own order breaking ties, so a model that labels every row
//// `normal` reproduces the baseline exactly.
////
//// ## What a session scores
////
//// A session passes an ordering when at least one row the owner marked "open
//// first" is among its top three. That is the pass-or-fail outcome
//// `evalstat` reads. The share of the top three that are "open first" is
//// scored beside it as the reward, because it has more resolution than the
//// outcome and is what separates two orderings that both pass.
////
//// ## Flow
////
//// `report` → `judge_session` → `trial_pair` → `evalstat.paired_verdict` →
//// `render`
////
//// 1. `judge_session` orders one session both ways and counts the hits.
//// 2. `trial_pair` states the two results as the paired trials the
////    instrument reads, one task per session, one trial each, on the arms
////    named newest_first and triage.
//// 3. `report` asks the instrument's decision rule for the verdict over the
////    plan of all sessions, and `render` prints the minimum detectable effect
////    before anything else, because a verdict on thirty sessions is read
////    against what thirty sessions could have shown.
////
//// The verdict reads its improvement the instrument's way: a positive effect
//// is the triage order passing in more sessions. An `Underpowered` or
//// `Indistinguishable` verdict means the note's answer is "do not build".

import client/insight/answer.{type Label, type Weight}
import evalstat
import evalstat/pairing
import evalstat/trial.{type Trial}
import evalstat/verdict.{type Verdict}
import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// How many rows count as the top of an ordering.
pub const top = 3

/// The arm of the classifier's own order.
pub const baseline_arm = "newest_first"

/// The arm of the triage order.
pub const candidate_arm = "triage"

/// One row of a session, as the owner marked it and as the model weighed it.
pub type Ranked {
  Ranked(
    /// The row's number in the request, from one, newest first.
    row: Int,
    /// Whether the owner marked the row "open first".
    open_first: OpenFirst,
    /// The model's weight for the row. A row the answer did not label is
    /// `Normal`.
    weight: Weight,
  )
}

/// The owner's mark on a row.
pub type OpenFirst {
  /// The owner would open this row first.
  OpenFirst

  /// The owner would skip this row.
  FineToSkip
}

/// One session's rows, newest first, with the session's identity.
pub type Judged {
  Judged(
    /// The session's identity, which the report names it by.
    session: String,
    /// The rows the request asked about, newest first.
    rows: List(Ranked),
  )
}

/// How one session fared under both orderings.
pub type Outcome {
  Outcome(
    /// The session's identity.
    session: String,
    /// "Open first" rows among the newest-first top three.
    baseline_hits: Int,
    /// "Open first" rows among the triage top three.
    candidate_hits: Int,
    /// How many rows the top three could hold, which is fewer than three for
    /// a session with fewer rows.
    slots: Int,
  )
}

/// The whole comparison.
pub type Report {
  Report(
    /// Each session's outcome, in the order they were given.
    outcomes: List(Outcome),
    /// The instrument's verdict over the paired outcomes.
    verdict: Verdict,
    /// How many `high` rows the model gave across all sessions.
    high_rows: Int,
    /// How many of those the owner marked "fine to skip".
    high_skipped: Int,
    /// The positions, from one, of the sessions with no "open first" row.
    /// Such a session passes neither ordering, so it may be one the owner
    /// never marked.
    unmarked: List(Int),
    /// The positions of the sessions with `crowded_from` or more "open first"
    /// rows. Newest first passes such a session by construction.
    crowded: List(Int),
  )
}

/// How many "open first" rows make a session pass newest first whatever the
/// model does: six rows leave at most two of eight skippable, so any three
/// rows include one.
pub const crowded_from = 6

/// The rows of a session as the owner marked them and the model weighed
/// them, newest first.
///
/// `asked` is how many rows the request numbered, `labels` the model's parsed
/// answer, and `opened` the numbers of the rows the owner ticked. A row the
/// model did not label is `Normal`, so a session with no answer scores both
/// orderings alike.
///
/// ## Examples
///
/// ```gleam
/// assert score.rank(2, [answer.Label(2, answer.High, "x")], [2])
///   == [score.Ranked(1, score.FineToSkip, answer.Normal), score.Ranked(2, score.OpenFirst, answer.High)]
/// ```
pub fn rank(
  asked: Int,
  labels: List(Label),
  opened: List(Int),
) -> List(Ranked) {
  list.repeat(Nil, asked)
  |> list.index_map(fn(_, index) {
    let row = index + 1

    Ranked(
      row:,
      open_first: case list.contains(opened, row) {
        True -> OpenFirst
        False -> FineToSkip
      },
      weight: case list.find(labels, fn(label) { label.row == row }) {
        Ok(label) -> label.weight
        Error(Nil) -> answer.Normal
      },
    )
  })
}

/// The rows ordered by weight, the classifier's order breaking ties.
///
/// ## Examples
///
/// ```gleam
/// assert score.triage_order([score.Ranked(1, score.FineToSkip, answer.Low), score.Ranked(2, score.OpenFirst, answer.High)])
///   == [score.Ranked(2, score.OpenFirst, answer.High), score.Ranked(1, score.FineToSkip, answer.Low)]
/// ```
pub fn triage_order(rows: List(Ranked)) -> List(Ranked) {
  list.index_map(rows, fn(ranked, index) {
    #(position(ranked.weight), index, ranked)
  })
  |> list.sort(fn(left, right) {
    case int.compare(left.0, right.0) {
      order.Eq -> int.compare(left.1, right.1)
      other -> other
    }
  })
  |> list.map(fn(entry) { entry.2 })
}

/// A weight as the position it sorts at.
fn position(weight: Weight) -> Int {
  case weight {
    answer.High -> 0
    answer.Normal -> 1
    answer.Low -> 2
  }
}

/// How many "open first" rows are among the first `top` of an ordering.
///
/// ## Examples
///
/// ```gleam
/// assert score.hits([score.Ranked(1, score.OpenFirst, answer.Normal)]) == 1
/// ```
pub fn hits(order: List(Ranked)) -> Int {
  list.take(order, top)
  |> list.count(fn(ranked) { ranked.open_first == OpenFirst })
}

/// Scores one session under both orderings.
///
/// ## Examples
///
/// ```gleam
/// assert score.judge_session(score.Judged("s", [])).slots == 0
/// ```
pub fn judge_session(judged: Judged) -> Outcome {
  Outcome(
    session: judged.session,
    baseline_hits: hits(judged.rows),
    candidate_hits: hits(triage_order(judged.rows)),
    slots: int.min(top, list.length(judged.rows)),
  )
}

/// The two paired trials of one session: its outcome under each arm.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(score.trial_pair(score.Outcome("s", 0, 1, 3))) == 2
/// ```
pub fn trial_pair(outcome: Outcome) -> List(Trial) {
  [
    one_trial(outcome, baseline_arm, outcome.baseline_hits),
    one_trial(outcome, candidate_arm, outcome.candidate_hits),
  ]
}

/// One arm's trial: a pass when the top three held an "open first" row, with
/// the share of the top three that were as its reward.
fn one_trial(outcome: Outcome, arm: String, found: Int) -> Trial {
  // The instrument reads the outcome, and the share rides along as the reward.
  let passed = case found > 0 {
    True -> trial.Passed
    False -> trial.VerifierFailed
  }

  trial.Trial(
    task: outcome.session,
    arm:,
    index: 0,
    reward: share(found, outcome.slots),
    scores: [],
    outcome: passed,
    cost: trial.Cost(0, 0.0, 0, 0, 0),
  )
}

/// A part of a whole as a fraction, nothing for an empty whole.
fn share(part: Int, whole: Int) -> Float {
  case whole {
    0 -> 0.0
    _ -> int.to_float(part) /. int.to_float(whole)
  }
}

/// The comparison over every session.
///
/// ## Examples
///
/// ```gleam
/// assert score.report([]).outcomes == []
/// ```
pub fn report(sessions: List(Judged)) -> Report {
  let outcomes = list.map(sessions, judge_session)
  let rows = list.flat_map(outcomes, trial_pair)
  let tasks = list.map(outcomes, fn(outcome) { outcome.session })
  let decided =
    evalstat.paired_verdict(
      rows,
      baseline_arm,
      candidate_arm,
      pairing.plan(tasks, 1),
      verdict.default_policy(),
    )
  let high =
    list.flat_map(sessions, fn(judged) { judged.rows })
    |> list.filter(fn(ranked) { ranked.weight == answer.High })

  Report(
    outcomes:,
    verdict: decided,
    high_rows: list.length(high),
    high_skipped: list.count(high, fn(ranked) {
      ranked.open_first == FineToSkip
    }),
    unmarked: positions(sessions, fn(opened) { opened == 0 }),
    crowded: positions(sessions, fn(opened) { opened >= crowded_from }),
  )
}

/// The positions, from one, of the sessions whose count of "open first" rows
/// satisfies `wanted`.
fn positions(sessions: List(Judged), wanted: fn(Int) -> Bool) -> List(Int) {
  list.index_map(sessions, fn(judged, index) {
    #(index + 1, list.count(judged.rows, fn(r) { r.open_first == OpenFirst }))
  })
  |> list.filter(fn(entry) { wanted(entry.1) })
  |> list.map(fn(entry) { entry.0 })
}

/// The minimum detectable effect a verdict was read against, when the plan
/// was complete enough to have one.
///
/// ## Examples
///
/// ```gleam
/// assert score.mde(verdict.Incomplete("no counted trials")) == Error(Nil)
/// ```
pub fn mde(decided: Verdict) -> Result(Float, Nil) {
  case decided {
    verdict.Improved(mde:, ..)
    | verdict.Harmed(mde:, ..)
    | verdict.Indistinguishable(mde:, ..)
    | verdict.Underpowered(mde:, ..) -> Ok(mde)
    verdict.Incomplete(..) -> Error(Nil)
  }
}

/// The report as text, the minimum detectable effect first, then `notes`, then
/// the sessions the owner may have left unmarked or marked too freely, and then
/// the verdict. Everything that bears on whether the verdict can be trusted
/// comes before it.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(score.render(score.report([]), []), "Minimum detectable effect")
/// ```
pub fn render(report: Report, notes: List(String)) -> String {
  let sessions = list.length(report.outcomes)
  let passed = fn(found: fn(Outcome) -> Int) {
    list.count(report.outcomes, fn(outcome) { found(outcome) > 0 })
  }
  let mean = fn(found: fn(Outcome) -> Int) {
    list.map(report.outcomes, fn(outcome) {
      share(found(outcome), outcome.slots)
    })
    |> mean_of
  }

  [
    minimum_line(report.verdict),
    ..list.append(notes, [
      "Sessions with no open-first row: " <> listed(report.unmarked),
      "Sessions with "
        <> int.to_string(crowded_from)
        <> " or more open-first rows: "
        <> listed(report.crowded),
      "Verdict: " <> describe(report.verdict),
      "Sessions: " <> int.to_string(sessions),
      "Sessions with an open-first row in the top three: newest first "
        <> int.to_string(passed(fn(outcome) { outcome.baseline_hits }))
        <> ", triage "
        <> int.to_string(passed(fn(outcome) { outcome.candidate_hits })),
      "Mean share of the top three that is open first: newest first "
        <> percent(mean(fn(outcome) { outcome.baseline_hits }))
        <> ", triage "
        <> percent(mean(fn(outcome) { outcome.candidate_hits })),
      "High rows the owner would skip: "
        <> int.to_string(report.high_skipped)
        <> " of "
        <> int.to_string(report.high_rows),
      "",
      "Per session (open-first rows in the top three, newest first / triage):",
      ..list.map(report.outcomes, session_line)
    ])
  ]
  |> string.join("\n")
}

/// A count and the session numbers behind it, as `2 (sessions 3, 7)`.
fn listed(positions: List(Int)) -> String {
  case positions {
    [] -> "0"
    _ ->
      int.to_string(list.length(positions))
      <> " (sessions "
      <> string.join(list.map(positions, int.to_string), ", ")
      <> ")"
  }
}

/// The first line of a report: the minimum detectable effect.
fn minimum_line(decided: Verdict) -> String {
  case mde(decided) {
    Ok(effect) ->
      "Minimum detectable effect: "
      <> two_places(effect)
      <> " (a difference in the share of sessions that pass, smaller than this could be missed)"
    Error(Nil) -> "Minimum detectable effect: none, the plan is incomplete"
  }
}

/// A verdict as one sentence.
fn describe(decided: Verdict) -> String {
  case decided {
    verdict.Improved(effect:, p:, ..) ->
      "Improved by "
      <> two_places(effect)
      <> " (p "
      <> two_places(p)
      <> "). The triage order beat newest first. Check the high-rows line below."
    verdict.Harmed(effect:, p:, ..) ->
      "Harmed by "
      <> two_places(effect)
      <> " (p "
      <> two_places(p)
      <> "). The triage order lost to newest first. Do not build."
    verdict.Indistinguishable(effect:, ..) ->
      "Indistinguishable (effect " <> two_places(effect) <> "). Do not build."
    verdict.Underpowered(needed_tasks:, reason:, ..) ->
      "Underpowered, "
      <> reason
      <> ". It would take "
      <> int.to_string(needed_tasks)
      <> " sessions to see the target effect. Do not build."
    verdict.Incomplete(reason:) -> "Incomplete, " <> reason <> "."
  }
}

/// One session's line.
fn session_line(outcome: Outcome) -> String {
  "- "
  <> outcome.session
  <> ": "
  <> int.to_string(outcome.baseline_hits)
  <> " / "
  <> int.to_string(outcome.candidate_hits)
}

/// The mean of a list of fractions, nothing counting as zero.
fn mean_of(values: List(Float)) -> Float {
  case values {
    [] -> 0.0
    [_, ..] -> float.sum(values) /. int.to_float(list.length(values))
  }
}

/// A fraction as a whole-number percentage.
fn percent(fraction: Float) -> String {
  int.to_string(float.round(fraction *. 100.0)) <> "%"
}

/// A number to two decimal places.
fn two_places(value: Float) -> String {
  let hundredths = float.round(float.absolute_value(value) *. 100.0)
  let whole = hundredths / 100
  let part = hundredths % 100

  // A negative value keeps its sign even when it rounds to zero hundredths.
  let sign = case value <. 0.0 {
    True -> "-"
    False -> ""
  }

  // The hundredths are padded so that 5 reads as .05.
  let digits = case part < 10 {
    True -> "0" <> int.to_string(part)
    False -> int.to_string(part)
  }

  sign <> int.to_string(whole) <> "." <> digits
}
