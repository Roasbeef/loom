//// The report: what a run's ledger, held to its plan, says.
////
//// The plan is the denominator. `ledger.reconcile` returns one finished row
//// per cell the plan owes, or names the first cell that is missing. When it
//// names one, nothing is estimated from the partial ledger: every comparison
//// reads `Incomplete` with that reason, because dropping the cells that
//// never ran is the easiest way for a comparison to flatter itself. Whether
//// a cell is missing because the budget ended the run or because a process
//// died, the report cannot tell, and says only what is true.
////
//// When the ledger is whole, each arm after the first is compared with the
//// first through `evalstat.paired_verdict`, over the whole plan and again
//// over each split of the tasks (`eval/split`, by the plan's salt and each
//// task's family). The first line of the report is the minimum detectable
//// effect, so nobody reads a four point difference without the size of
//// difference the design could have seen. Beside the clustered interval
//// the report prints the bootstrap one, seeded by the plan id so the same
//// ledger always renders the same interval. Cold start (`timing.prepare`) is
//// summed apart from agent time, and the header names the lane and the claim
//// it can and cannot support: a replay run proves only that the harness
//// still makes the same requests.
////
//// Four more views read the same ledger. The validate-minus-holdout gap
//// is the difference between the candidate's per-task effect on the two
//// splits, with its own interval; when it is positive beyond that interval
//// the report says the candidate was memorised, because a gain that appears
//// on the tasks that were tuned against and not on the ones that were not
//// is what tuning on the benchmark looks like. pass@k and pass^k say how an
//// arm does when it gets several tries and when it must succeed every
//// time. Dominance ranks a candidate against the baseline on the outcome
//// verdict first and the score vector second. A futility stop is recorded
//// in the header, because the cells it skipped are the reason a verdict is
//// `Incomplete`.
////
//// `render` is pure: it takes the ledger's rows and returns the Markdown and
//// the JSON. `write_run` is the one place that touches the disk.
////
//// ## Flow
////
//// - `lane_statement`: the claim a lane supports
//// - `to_stat`: a ledger row as the statistics package's row
//// - `render`: rows to Markdown and JSON
//// - `write_run`: read a run directory, render, write the Markdown and JSON files

import core/json.{type JsonValue}
import eval/arm.{type Arm}
import eval/ledger.{type Row}
import eval/plan.{type Plan, RowKey}
import eval/split.{type Split}
import eval/task.{type Task}
import evalstat
import evalstat/bootstrap
import evalstat/dominance.{type Dominance}
import evalstat/paired
import evalstat/pairing
import evalstat/passk
import evalstat/trial as stat
import evalstat/verdict.{type Verdict}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// What the report is built from, besides the ledger's rows.
pub type Inputs {
  Inputs(
    /// The plan, the denominator.
    plan: Plan,
    /// The tasks, for names, tags and splits.
    tasks: List(Task),
    /// The arms, in plan order: the first is the baseline.
    arms: List(Arm),
    /// A note about the run that is not a row, such as the budget stop.
    budget_note: Option(String),
    /// The sentence recording that futility stopped admission, if it did.
    futility_note: Option(String),
  )
}

/// A rendered report.
pub type Rendered {
  Rendered(
    /// The report as Markdown, its first line the minimum detectable effect.
    markdown: String,
    /// The report as JSON.
    json: JsonValue,
  )
}

// One comparison of a candidate with the baseline: the verdict under the
// clustered interval, the same comparison under the bootstrap one, and the
// bootstrap interval itself, which a verdict without a direction does not carry.
type Comparison {
  Comparison(
    baseline: Arm,
    candidate: Arm,
    verdict: Verdict,
    bootstrap: Option(Bootstrapped),
  )
}

// The comparison again under the bootstrap interval: its verdict, and the
// interval itself with the mean per-task effect it surrounds, which a verdict
// without a direction does not carry. Only the whole-plan comparisons have it;
// the per-split panels keep to the verdict, and the resampling is not free.
type Bootstrapped {
  Bootstrapped(verdict: Verdict, resampled: Option(Resampled))
}

type Resampled {
  Resampled(effect: Float, low: Float, high: Float)
}

// Whether a comparison is worth the resampling.
type Depth {
  WholePlan
  SplitPanel
}

/// The claim a lane supports, which the report header states.
///
/// ## Examples
///
/// ```gleam
/// // report.lane_statement(plan.Replay)
/// // == "replay lane: proves harness regressions only, no model quality claim"
/// ```
///
pub fn lane_statement(lane: plan.Lane) -> String {
  case lane {
    plan.Replay ->
      "replay lane: proves harness regressions only, no model quality claim"
    plan.Live ->
      "live lane: real model, real spend; a claim about this model on these tasks"
  }
}

/// Reads `<directory>/trials.jsonl` (an absent file is an empty ledger),
/// renders the report and writes `report.md` and `report.json` beside it.
///
/// ## Examples
///
/// ```gleam
/// // report.write_run("runs/<plan id>", inputs) == Ok(Nil)
/// ```
///
pub fn write_run(directory: String, inputs: Inputs) -> Result(Nil, String) {
  use rows <- result.try(read_ledger(directory))

  let rendered = render(inputs, rows)

  use Nil <- result.try(
    simplifile.write(directory <> "/report.md", rendered.markdown)
    |> result.map_error(simplifile.describe_error),
  )

  simplifile.write(directory <> "/report.json", json.to_string(rendered.json))
  |> result.map_error(simplifile.describe_error)
}

/// Reads a run's ledger. A missing file is an empty ledger: a run that has
/// not started still has a report to write.
fn read_ledger(directory: String) -> Result(List(Row), String) {
  // Only an absent file is benign; any other read fault must not look like an empty run.
  case simplifile.read(directory <> "/trials.jsonl") {
    Ok(text) -> ledger.parse(text)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

/// Renders the report for a plan and the rows of its ledger.
///
/// ## Examples
///
/// ```gleam
/// // report.render(inputs, []).markdown contains "Incomplete: plan row missing"
/// ```
///
pub fn render(inputs: Inputs, rows: List(Row)) -> Rendered {
  let reconciled = ledger.reconcile(inputs.plan, rows)
  let comparisons = compare(inputs, reconciled, inputs.tasks, WholePlan)
  let latest = latest_rows(rows)
  let arm_lines =
    list.map(inputs.arms, fn(each) { arm_line(each, latest, rows) })
  let facts =
    Facts(
      reconciled:,
      comparisons:,
      panels: list.map([split.Tune, split.Validate, split.Holdout], fn(each) {
        let members = tasks_in(inputs, each)

        #(
          each,
          list.length(members),
          compare(inputs, reconciled, members, SplitPanel),
        )
      }),
      gaps: gaps(inputs, reconciled),
      pass_ks: list.map(inputs.arms, fn(each) { pass_k(inputs, latest, each) }),
      dominances: dominances(comparisons, arm_lines),
      arm_lines:,
      tag_lines: tag_rates(inputs, latest),
      served: served_models(latest),
      rows: list.length(rows),
    )

  Rendered(markdown: markdown(inputs, facts), json: to_json(inputs, facts))
}

// Everything the two renderings share, computed once from the ledger.
type Facts {
  Facts(
    reconciled: Result(List(Row), String),
    comparisons: List(Comparison),
    panels: List(#(Split, Int, List(Comparison))),
    gaps: List(Gap),
    pass_ks: List(PassK),
    dominances: List(Ruling),
    arm_lines: List(ArmLine),
    tag_lines: List(TagRate),
    served: List(String),
    rows: Int,
  )
}

// --- comparisons ------------------------------------------------------------------

fn tasks_in(inputs: Inputs, wanted: Split) -> List(Task) {
  list.filter(inputs.tasks, fn(each) {
    split.assign(inputs.plan.split_salt, split.family(each)) == wanted
  })
}

/// Every candidate against the first arm. A ledger that does not reconcile
/// makes every verdict `Incomplete` with the reconciliation's own reason.
fn compare(
  inputs: Inputs,
  reconciled: Result(List(Row), String),
  members: List(Task),
  depth: Depth,
) -> List(Comparison) {
  case inputs.arms {
    [] -> []
    [baseline, ..candidates] ->
      list.map(candidates, fn(candidate) {
        compare_pair(inputs, reconciled, members, depth, baseline, candidate)
      })
  }
}

/// One pair over the given tasks under both intervals, `Incomplete` when the ledger did not reconcile.
fn compare_pair(
  inputs: Inputs,
  reconciled: Result(List(Row), String),
  members: List(Task),
  depth: Depth,
  baseline: Arm,
  candidate: Arm,
) -> Comparison {
  // A ledger that does not reconcile decides nothing; a whole one is compared pair by pair.
  case reconciled {
    Error(reason) ->
      Comparison(
        baseline:,
        candidate:,
        verdict: verdict.Incomplete(reason),
        bootstrap: case depth {
          WholePlan -> Some(Bootstrapped(verdict.Incomplete(reason), None))
          SplitPanel -> None
        },
      )

    Ok(final) -> {
      let ids = list.map(members, fn(each) { each.id })
      let trials =
        final
        |> list.filter(fn(row) { list.contains(ids, row.task) })
        |> list.map(to_stat)
      let expected = pairing.plan(ids, inputs.plan.trials_per_cell)
      let #(baseline_id, candidate_id) = #(baseline.id, candidate.id)
      let verdict_under = fn(policy) {
        evalstat.paired_verdict(
          trials,
          baseline_id,
          candidate_id,
          expected,
          policy,
        )
      }

      Comparison(
        baseline:,
        candidate:,
        verdict: verdict_under(verdict.default_policy()),
        bootstrap: case depth {
          WholePlan ->
            Some(Bootstrapped(
              verdict: verdict_under(bootstrap_policy(inputs.plan)),
              resampled: resample(
                inputs.plan,
                trials,
                baseline,
                candidate,
                expected,
              ),
            ))
          SplitPanel -> None
        },
      )
    }
  }
}

/// The default policy with the interval swapped for the bootstrap, seeded by
/// the plan id so a report is reproducible from the plan alone.
fn bootstrap_policy(frozen: Plan) -> verdict.Policy {
  verdict.Policy(
    ..verdict.default_policy(),
    interval: verdict.Bootstrap(
      resamples: bootstrap.default_resamples,
      seed: frozen.id,
    ),
  )
}

/// The bootstrap interval of a pair, for the cases where the verdict under it
/// carries none (an `Underpowered` or `Incomplete` verdict has no interval).
fn resample(
  frozen: Plan,
  trials: List(stat.Trial),
  baseline: Arm,
  candidate: Arm,
  expected: List(#(String, Int)),
) -> Option(Resampled) {
  // Rows that do not pair are the verdict's `Incomplete`; there is no interval to resample.
  case pairing.pair(trials, baseline.id, candidate.id, expected) {
    Error(_) -> None

    Ok(together) -> {
      let effect = paired.mean(paired.differences(together))

      // An interval needs at least one task and one resample, which a paired plan has.
      case
        bootstrap.interval(together, bootstrap.default_resamples, frozen.id)
      {
        Ok(#(low, high)) -> Some(Resampled(effect:, low:, high:))
        Error(Nil) -> None
      }
    }
  }
}

/// Converts a finished ledger row to the statistics package's row, which is
/// what `eval/run` feeds the futility check as well.
///
/// ## Examples
///
/// ```gleam
/// // report.to_stat(row).arm == row.arm
/// ```
///
pub fn to_stat(row: Row) -> stat.Trial {
  stat.Trial(
    task: row.task,
    arm: row.arm,
    index: row.index,
    reward: row.reward,
    scores: row.scores,
    outcome: case row.outcome {
      Some(ledger.Passed) -> stat.Passed
      Some(ledger.VerifierFailed) -> stat.VerifierFailed
      Some(ledger.AgentTimeout) -> stat.AgentTimeout
      Some(ledger.SafetyRefusal) -> stat.SafetyRefusal
      Some(ledger.Infrastructure) | None -> stat.Infrastructure
    },
    cost: stat.Cost(
      tokens: row.usage.input + row.usage.output,
      dollars: row.usage.dollars,
      turns: row.turns,
      tool_errors: row.tool_errors,
      wall_ms: row.timing.agent + row.timing.verifier,
    ),
  )
}

// --- tables -------------------------------------------------------------------------

type ArmLine {
  ArmLine(
    arm: Arm,
    counted: Int,
    passed: Int,
    refused: Int,
    infra: Int,
    mean_dollars: Float,
    mean_turns: Float,
    mean_tool_errors: Float,
    mean_scores: List(#(String, Float)),
    cold_total_ms: Int,
    agent_total_ms: Int,
  )
}

/// The final row of each cell present in the file, whether or not the plan is
/// whole: tables describe what happened even when the verdict cannot.
fn latest_rows(rows: List(Row)) -> List(Row) {
  rows
  |> list.fold(dict.new(), fn(held, row) {
    dict.insert(held, RowKey(row.task, row.arm, row.index), row)
  })
  |> dict.values
  |> list.filter(fn(row) { row.state != ledger.Running })
}

/// Summarises one arm's rows: counts, means and time totals.
fn arm_line(each: Arm, latest: List(Row), every: List(Row)) -> ArmLine {
  let mine = list.filter(latest, fn(row) { row.arm == each.id })
  let counted =
    list.filter(mine, fn(row) { row.outcome != Some(ledger.Infrastructure) })
  let all_attempts = list.filter(every, fn(row) { row.arm == each.id })

  ArmLine(
    arm: each,
    counted: list.length(counted),
    passed: list.count(counted, fn(row) { row.outcome == Some(ledger.Passed) }),
    refused: list.count(counted, fn(row) {
      row.outcome == Some(ledger.SafetyRefusal)
    }),
    infra: list.length(mine) - list.length(counted),
    mean_dollars: mean(counted, fn(row) { row.usage.dollars }),
    mean_turns: mean(counted, fn(row) { int.to_float(row.turns) }),
    mean_tool_errors: mean(counted, fn(row) { int.to_float(row.tool_errors) }),
    mean_scores: mean_scores(counted),
    cold_total_ms: sum_ms(all_attempts, fn(row) { row.timing.prepare }),
    agent_total_ms: sum_ms(all_attempts, fn(row) { row.timing.agent }),
  )
}

/// The mean of a value over rows, zero for none.
fn mean(rows: List(Row), value: fn(Row) -> Float) -> Float {
  case rows {
    [] -> 0.0
    _ ->
      list.fold(rows, 0.0, fn(total, row) { total +. value(row) })
      /. int.to_float(list.length(rows))
  }
}

fn sum_ms(rows: List(Row), value: fn(Row) -> Int) -> Int {
  list.fold(rows, 0, fn(total, row) { total + value(row) })
}

/// The mean of each score the rows carry, over every row: a row that has no
/// such score (a timeout is never graded) counts as zero, since abandoned
/// work is a failure of the verifier's own measure and must not leave the
/// average by omission.
fn mean_scores(rows: List(Row)) -> List(#(String, Float)) {
  rows
  |> list.flat_map(fn(row) { list.map(row.scores, fn(score) { score.0 }) })
  |> list.unique
  |> list.sort(string.compare)
  |> list.map(fn(name) {
    #(
      name,
      mean(rows, fn(row) { result.unwrap(list.key_find(row.scores, name), 0.0) }),
    )
  })
}

type TagRate {
  TagRate(tag: String, arm: Arm, passed: Int, counted: Int)
}

/// The pass rate of each arm on the tasks carrying each tag.
fn tag_rates(inputs: Inputs, latest: List(Row)) -> List(TagRate) {
  let tags =
    inputs.tasks
    |> list.flat_map(fn(each) { each.tags })
    |> list.unique
    |> list.sort(string.compare)

  use tag <- list.flat_map(tags)
  let ids =
    inputs.tasks
    |> list.filter(fn(each) { list.contains(each.tags, tag) })
    |> list.map(fn(each) { each.id })

  use each <- list.map(inputs.arms)
  let counted =
    list.filter(latest, fn(row) {
      row.arm == each.id
      && list.contains(ids, row.task)
      && row.outcome != Some(ledger.Infrastructure)
    })

  TagRate(
    tag:,
    arm: each,
    passed: list.count(counted, fn(row) { row.outcome == Some(ledger.Passed) }),
    counted: list.length(counted),
  )
}

/// The distinct models that answered, sorted.
fn served_models(latest: List(Row)) -> List(String) {
  latest
  |> list.flat_map(fn(row) { row.served })
  |> list.map(fn(each) {
    each.provider <> "/" <> each.model <> " (" <> each.api <> ")"
  })
  |> list.unique
  |> list.sort(string.compare)
}

// --- the gap, pass@k, dominance --------------------------------------------------------

// How a candidate's gain on the validate split compares with its gain on the holdout.
type Gap {
  Gap(candidate: Arm, reading: GapReading)
}

type GapReading {
  // Both splits had a spread to measure.
  Measured(
    validate: Float,
    holdout: Float,
    gap: Float,
    ci: #(Float, Float),
    finding: Finding,
  )

  // The gap could not be formed, and why.
  Unmeasured(reason: String)
}

// What the interval around the gap allows the report to say.
type Finding {
  // The gap is positive and its whole interval is above zero.
  Memorised

  // The interval reaches zero or below.
  WithinNoise
}

/// The validate-minus-holdout gap of each candidate. The splits hold different
/// tasks, so the two mean effects are independent estimates and their
/// difference has the two clustered variances added; the interval is the
/// usual normal one around it.
fn gaps(inputs: Inputs, reconciled: Result(List(Row), String)) -> List(Gap) {
  case inputs.arms {
    [] -> []
    [baseline, ..candidates] ->
      list.map(candidates, fn(candidate) {
        Gap(
          candidate:,
          reading: gap_reading(inputs, reconciled, baseline, candidate),
        )
      })
  }
}

/// One candidate's gap, `Unmeasured` for a ledger that does not reconcile or a split too thin to have a spread.
fn gap_reading(
  inputs: Inputs,
  reconciled: Result(List(Row), String),
  baseline: Arm,
  candidate: Arm,
) -> GapReading {
  let measured = {
    use final <- result.try(reconciled)
    use validate <- result.try(effects_in(
      inputs,
      final,
      split.Validate,
      baseline,
      candidate,
    ))
    use holdout <- result.try(effects_in(
      inputs,
      final,
      split.Holdout,
      baseline,
      candidate,
    ))

    form_gap(validate, holdout)
  }

  // Whatever stopped the gap from forming becomes the reading's own reason.
  case measured {
    Ok(reading) -> reading
    Error(reason) -> Unmeasured(reason)
  }
}

/// The per-task effects of a candidate over one split's tasks.
fn effects_in(
  inputs: Inputs,
  final: List(Row),
  wanted: Split,
  baseline: Arm,
  candidate: Arm,
) -> Result(List(Float), String) {
  let ids = list.map(tasks_in(inputs, wanted), fn(each) { each.id })
  let trials =
    final
    |> list.filter(fn(row) { list.contains(ids, row.task) })
    |> list.map(to_stat)
  let expected = pairing.plan(ids, inputs.plan.trials_per_cell)

  use together <- result.map(
    pairing.pair(trials, baseline.id, candidate.id, expected)
    |> result.map_error(fn(error) {
      split_name(wanted) <> ": " <> pairing.describe(error)
    }),
  )

  paired.differences(together)
}

/// The gap between two splits' per-task effects, with the spread each has.
fn form_gap(
  validate: List(Float),
  holdout: List(Float),
) -> Result(GapReading, String) {
  use validate_se <- result.try(
    paired.clustered_se(validate)
    |> result.replace_error("validate has fewer than two tasks"),
  )
  use holdout_se <- result.try(
    paired.clustered_se(holdout)
    |> result.replace_error("holdout has fewer than two tasks"),
  )
  let se =
    float.square_root(validate_se *. validate_se +. holdout_se *. holdout_se)
    |> result.unwrap(0.0)

  // With no spread in either split the interval would collapse to a point and any positive difference would read as proof.
  case se >. 0.0 {
    False -> Error("no spread between tasks in either split")
    True -> {
      let validate_effect = paired.mean(validate)
      let holdout_effect = paired.mean(holdout)
      let gap = validate_effect -. holdout_effect
      let ci = paired.interval(gap, se)

      Ok(
        Measured(
          validate: validate_effect,
          holdout: holdout_effect,
          gap:,
          ci:,
          finding: case gap >. 0.0 && ci.0 >. 0.0 {
            True -> Memorised
            False -> WithinNoise
          },
        ),
      )
    }
  }
}

// One arm's pass@k and pass^k for k from one to the plan's K.
type PassK {
  PassK(arm: Arm, at: List(#(Int, String)), pow: List(#(Int, String)))
}

/// pass@k and pass^k for k = 1..K, per task and then averaged. An estimate the
/// ledger cannot support (a task with fewer than k counted trials) says why
/// instead of printing a number.
fn pass_k(inputs: Inputs, latest: List(Row), each: Arm) -> PassK {
  let trials = list.map(latest, to_stat)
  let ks =
    list.index_map(
      list.repeat(Nil, int.max(1, inputs.plan.trials_per_cell)),
      fn(_, position) { position + 1 },
    )
  let estimate = fn(measure) {
    list.map(ks, fn(k) {
      // An estimate the ledger cannot support names the defect instead of printing zero.
      let shown = case measure(trials, each.id, k) {
        Ok(value) -> fmt(value)
        Error(reason) -> "n/a (" <> passk_reason(reason) <> ")"
      }

      #(k, shown)
    })
  }

  PassK(
    arm: each,
    at: estimate(passk.arm_pass_at_k),
    pow: estimate(passk.arm_pass_pow_k),
  )
}

/// The defect of a question `evalstat/passk` refused, in words for a table cell.
fn passk_reason(error: passk.PassKError) -> String {
  // One phrase per way the estimate can be refused.
  case error {
    passk.KNotPositive(..) -> "k below one"
    passk.KExceedsTrials(n:, k:) ->
      "a task has "
      <> int.to_string(n)
      <> " counted trials, fewer than "
      <> int.to_string(k)
    passk.PassesOutOfRange(..) -> "passes out of range"
    passk.NoTasks -> "no counted trials"
  }
}

// A candidate's standing against the baseline across outcome and scores.
type Ruling {
  Ruling(candidate: Arm, baseline: Arm, dominance: Dominance)
}

/// Each comparison's dominance: the outcome verdict first, then the arms'
/// score vectors, which the verifier's scores and the cost measures complete,
/// every one oriented so that higher is better.
fn dominances(
  comparisons: List(Comparison),
  arm_lines: List(ArmLine),
) -> List(Ruling) {
  list.map(comparisons, fn(each) {
    Ruling(
      candidate: each.candidate,
      baseline: each.baseline,
      dominance: dominance.compare(
        each.verdict,
        score_vector(each.candidate, arm_lines),
        score_vector(each.baseline, arm_lines),
      ),
    )
  })
}

/// An arm's scores: the verifier's, then cost, turns and tool errors turned
/// into higher-is-better as `1 / (1 + mean)`.
fn score_vector(each: Arm, arm_lines: List(ArmLine)) -> List(#(String, Float)) {
  case list.find(arm_lines, fn(line) { line.arm.id == each.id }) {
    Error(Nil) -> []
    Ok(line) ->
      list.append(line.mean_scores, [
        #("cost_inv", 1.0 /. { 1.0 +. line.mean_dollars }),
        #("turns_inv", 1.0 /. { 1.0 +. line.mean_turns }),
        #("tool_errors_inv", 1.0 /. { 1.0 +. line.mean_tool_errors }),
      ])
  }
}

// --- text ----------------------------------------------------------------------------

fn fmt(value: Float) -> String {
  float.to_string(float.to_precision(value, 3))
}

fn rate(passed: Int, counted: Int) -> String {
  case counted {
    0 -> "n/a"
    _ -> fmt(int.to_float(passed) /. int.to_float(counted))
  }
}

/// The minimum detectable effect a verdict carries, if it has one.
fn mde_of(found: Verdict) -> Option(Float) {
  case found {
    verdict.Improved(mde:, ..)
    | verdict.Harmed(mde:, ..)
    | verdict.Indistinguishable(mde:, ..)
    | verdict.Underpowered(mde:, ..) -> Some(mde)
    verdict.Incomplete(..) -> None
  }
}

/// A verdict as one line of text.
fn describe(found: Verdict) -> String {
  case found {
    verdict.Improved(effect:, ci:, p:, mde:) ->
      "Improved: " <> detail(effect, ci, p, mde)
    verdict.Harmed(effect:, ci:, p:, mde:) ->
      "Harmed: " <> detail(effect, ci, p, mde)
    verdict.Indistinguishable(effect:, ci:, p:, mde:) ->
      "Indistinguishable: " <> detail(effect, ci, p, mde)
    verdict.Underpowered(mde:, needed_tasks:, reason:) ->
      "Underpowered: MDE "
      <> fmt(mde)
      <> ", about "
      <> int.to_string(needed_tasks)
      <> " tasks needed ("
      <> reason
      <> ")"
    verdict.Incomplete(reason:) -> "Incomplete: " <> reason
  }
}

/// The numbers behind a directed verdict.
fn detail(effect: Float, ci: #(Float, Float), p: Float, mde: Float) -> String {
  "effect "
  <> fmt(effect)
  <> " (95% CI "
  <> fmt(ci.0)
  <> " to "
  <> fmt(ci.1)
  <> "), p "
  <> fmt(p)
  <> ", MDE "
  <> fmt(mde)
}

/// The first line of the report: the minimum detectable effect of each comparison, so a difference is never read without the size the design could see.
fn mde_line(comparisons: List(Comparison)) -> String {
  let parts =
    list.map(comparisons, fn(each) {
      case mde_of(each.verdict) {
        Some(mde) ->
          each.candidate.name
          <> " vs "
          <> each.baseline.name
          <> ": "
          <> fmt(mde)
        None ->
          each.candidate.name
          <> " vs "
          <> each.baseline.name
          <> ": unavailable (incomplete)"
      }
    })

  "Minimum detectable effect (pass-rate difference this design can see): "
  <> case parts {
    [] -> "none (a single arm has no comparison)"
    _ -> string.join(parts, "; ")
  }
}

/// Lays the report out as Markdown, the minimum detectable effect first.
fn markdown(inputs: Inputs, facts: Facts) -> String {
  let header = [
    mde_line(facts.comparisons),
    "",
    "# Run " <> inputs.plan.id,
    "",
    "Lane: " <> lane_statement(inputs.plan.lane),
    "Profile: "
      <> case inputs.plan.profile {
      plan.Quick -> "quick"
      plan.Full -> "full"
    },
    "Harness: " <> inputs.plan.harness.git_commit,
    "Rows in ledger: "
      <> int.to_string(facts.rows)
      <> ", cells owed: "
      <> int.to_string(list.length(plan.rows(inputs.plan))),
    ..list.flatten([
      note_line("Budget", inputs.budget_note),
      note_line("Futility", inputs.futility_note),
    ])
  ]

  // A whole ledger adds nothing to the header; an unreconciled one says why the verdicts are `Incomplete`.
  let status = case facts.reconciled {
    Ok(_) -> []
    Error(reason) -> ["", "INCOMPLETE: " <> reason]
  }

  string.join(
    list.flatten([
      header,
      status,
      ["", "## Comparisons", ""],
      comparison_lines(facts.comparisons, Detailed),
      ["", "## Splits", ""],
      list.flat_map(facts.panels, fn(panel) {
        [
          "### "
            <> split_name(panel.0)
            <> " ("
            <> int.to_string(panel.1)
            <> " tasks)",
          ..comparison_lines(panel.2, Brief)
        ]
      }),
      ["", "## Validate minus holdout", ""],
      list.map(facts.gaps, gap_text),
      ["", "## pass@k and pass^k", ""],
      list.map(facts.pass_ks, pass_k_text),
      ["", "## Dominance", ""],
      list.map(facts.dominances, ruling_text),
      ["", "## Arms", ""],
      list.map(facts.arm_lines, arm_text),
      ["", "## Pass rate by tag", ""],
      list.map(facts.tag_lines, fn(each) {
        "- "
        <> each.tag
        <> " / "
        <> each.arm.name
        <> ": "
        <> rate(each.passed, each.counted)
        <> " ("
        <> int.to_string(each.passed)
        <> "/"
        <> int.to_string(each.counted)
        <> ")"
      }),
      ["", "## Served models", ""],
      list.map(facts.served, fn(each) { "- " <> each }),
      [""],
    ]),
    "\n",
  )
}

/// A header line for a note about the run, or nothing when there is none.
fn note_line(label: String, note: Option(String)) -> List(String) {
  case note {
    Some(text) -> [label <> ": " <> text]
    None -> []
  }
}

// How much a comparison line says: the panels per split keep to the verdict.
type Detail {
  Detailed
  Brief
}

/// One bullet per comparison, and under it the bootstrap interval when asked.
fn comparison_lines(
  comparisons: List(Comparison),
  detail: Detail,
) -> List(String) {
  list.flat_map(comparisons, fn(each) {
    let line =
      "- "
      <> each.candidate.name
      <> " vs baseline "
      <> each.baseline.name
      <> " — "
      <> describe(each.verdict)

    // The panels per split keep to the verdict; the whole-plan table adds the bootstrap.
    case detail, each.bootstrap {
      Detailed, Some(found) -> [line, bootstrap_text(found)]
      Detailed, None | Brief, _ -> [line]
    }
  })
}

/// The bootstrap's interval and the verdict it would reach, indented under its comparison.
fn bootstrap_text(each: Bootstrapped) -> String {
  "  - bootstrap ("
  <> int.to_string(bootstrap.default_resamples)
  <> " resamples, seed = plan id): "
  <> case each.resampled {
    Some(Resampled(effect:, low:, high:)) ->
      "effect "
      <> fmt(effect)
      <> " (95% CI "
      <> fmt(low)
      <> " to "
      <> fmt(high)
      <> "); verdict "
    None -> "no interval; verdict "
  }
  <> describe(each.verdict)
}

/// One candidate's validate-minus-holdout gap as a bullet.
fn gap_text(each: Gap) -> String {
  "- "
  <> each.candidate.name
  <> ": "
  <> case each.reading {
    Unmeasured(reason:) -> "unavailable (" <> reason <> ")"
    Measured(validate:, holdout:, gap:, ci:, finding:) ->
      "validate effect "
      <> fmt(validate)
      <> ", holdout effect "
      <> fmt(holdout)
      <> ", gap "
      <> fmt(gap)
      <> " (95% CI "
      <> fmt(ci.0)
      <> " to "
      <> fmt(ci.1)
      <> "): "
      <> case finding {
        Memorised ->
          "memorised (the gain on the validate tasks is not there on the holdout)"
        WithinNoise -> "no gap beyond its interval"
      }
  }
}

/// One arm's pass@k and pass^k as a bullet.
fn pass_k_text(each: PassK) -> String {
  let listed = fn(label: String, found: List(#(Int, String))) {
    string.join(
      list.map(found, fn(one) { label <> int.to_string(one.0) <> " " <> one.1 }),
      ", ",
    )
  }

  "- "
  <> each.arm.name
  <> ": "
  <> listed("pass@", each.at)
  <> "; "
  <> listed("pass^", each.pow)
}

/// One candidate's dominance ruling as a bullet.
fn ruling_text(each: Ruling) -> String {
  "- "
  <> each.candidate.name
  <> " vs baseline: "
  <> dominance_text(each.dominance)
}

/// A dominance ruling in words, with the ground it was reached on.
fn dominance_text(found: Dominance) -> String {
  case found {
    dominance.Dominates(ground) -> "dominates (" <> ground_text(ground) <> ")"
    dominance.Dominated(ground) -> "dominated (" <> ground_text(ground) <> ")"
    dominance.Tie -> "tie (outcome not harmful, every shared score equal)"
    dominance.Tradeoff(better:, worse:) ->
      "trade-off (better on "
      <> string.join(better, ", ")
      <> "; worse on "
      <> string.join(worse, ", ")
      <> ")"
    dominance.Undecided -> "undecided (nothing to compare)"
  }
}

fn ground_text(ground: dominance.Ground) -> String {
  case ground {
    dominance.Outcome -> "outcome"
    dominance.Scores -> "scores"
  }
}

/// One arm's table row as a bullet.
fn arm_text(line: ArmLine) -> String {
  "- "
  <> line.arm.name
  <> ": pass rate "
  <> rate(line.passed, line.counted)
  <> " ("
  <> int.to_string(line.passed)
  <> "/"
  <> int.to_string(line.counted)
  <> "), refusals "
  <> int.to_string(line.refused)
  <> ", infra "
  <> int.to_string(line.infra)
  <> ", mean $"
  <> fmt(line.mean_dollars)
  <> ", turns "
  <> fmt(line.mean_turns)
  <> ", tool errors "
  <> fmt(line.mean_tool_errors)
  <> "; cold start total "
  <> int.to_string(line.cold_total_ms)
  <> " ms, agent total "
  <> int.to_string(line.agent_total_ms)
  <> " ms"
}

/// A split's name as the report spells it.
fn split_name(each: Split) -> String {
  case each {
    split.Tune -> "tune"
    split.Validate -> "validate"
    split.Holdout -> "holdout"
  }
}

// --- json ----------------------------------------------------------------------------

/// The report as JSON, with the same figures as the Markdown.
fn to_json(inputs: Inputs, facts: Facts) -> JsonValue {
  json.Object([
    #("v", json.Int(3)),
    #("plan", json.String(inputs.plan.id)),
    #("lane", json.String(lane_statement(inputs.plan.lane))),
    #("mde_line", json.String(mde_line(facts.comparisons))),
    #("complete", case facts.reconciled {
      Ok(_) -> json.Bool(True)
      Error(_) -> json.Bool(False)
    }),
    #("incomplete_reason", case facts.reconciled {
      Ok(_) -> json.Null
      Error(reason) -> json.String(reason)
    }),
    #("budget_note", optional_text(inputs.budget_note)),
    #("futility_note", optional_text(inputs.futility_note)),
    #("comparisons", comparisons_json(facts.comparisons)),
    #(
      "splits",
      json.Array(
        list.map(facts.panels, fn(panel) {
          json.Object([
            #("split", json.String(split_name(panel.0))),
            #("tasks", json.Int(panel.1)),
            #("comparisons", comparisons_json(panel.2)),
          ])
        }),
      ),
    ),
    #("gaps", json.Array(list.map(facts.gaps, gap_json))),
    #("pass_k", json.Array(list.map(facts.pass_ks, pass_k_json))),
    #(
      "dominance",
      json.Array(
        list.map(facts.dominances, fn(each) {
          json.Object([
            #("baseline", json.String(each.baseline.id)),
            #("candidate", json.String(each.candidate.id)),
            #("ruling", json.String(dominance_text(each.dominance))),
          ])
        }),
      ),
    ),
    #("arms", json.Array(list.map(facts.arm_lines, arm_json))),
    #(
      "tags",
      json.Array(
        list.map(facts.tag_lines, fn(each) {
          json.Object([
            #("tag", json.String(each.tag)),
            #("arm", json.String(each.arm.id)),
            #("passed", json.Int(each.passed)),
            #("counted", json.Int(each.counted)),
          ])
        }),
      ),
    ),
    #("served", json.Array(list.map(facts.served, json.String))),
  ])
}

fn optional_text(note: Option(String)) -> JsonValue {
  case note {
    Some(text) -> json.String(text)
    None -> json.Null
  }
}

/// One arm's table row as JSON.
fn arm_json(line: ArmLine) -> JsonValue {
  json.Object([
    #("arm", json.String(line.arm.id)),
    #("name", json.String(line.arm.name)),
    #("counted", json.Int(line.counted)),
    #("passed", json.Int(line.passed)),
    #("refused", json.Int(line.refused)),
    #("infra", json.Int(line.infra)),
    #("mean_dollars", json.Float(line.mean_dollars)),
    #("mean_turns", json.Float(line.mean_turns)),
    #("mean_tool_errors", json.Float(line.mean_tool_errors)),
    #("cold_total_ms", json.Int(line.cold_total_ms)),
    #("agent_total_ms", json.Int(line.agent_total_ms)),
  ])
}

/// One candidate's gap as JSON: the figures when measured, the reason when not.
fn gap_json(each: Gap) -> JsonValue {
  json.Object([
    #("candidate", json.String(each.candidate.id)),
    ..case each.reading {
      Unmeasured(reason:) -> [#("reason", json.String(reason))]
      Measured(validate:, holdout:, gap:, ci:, finding:) -> [
        #("validate_effect", json.Float(validate)),
        #("holdout_effect", json.Float(holdout)),
        #("gap", json.Float(gap)),
        #("ci_low", json.Float(ci.0)),
        #("ci_high", json.Float(ci.1)),
        #("memorised", json.Bool(finding == Memorised)),
      ]
    }
  ])
}

/// One arm's pass@k and pass^k as JSON, each k keyed by its number.
fn pass_k_json(each: PassK) -> JsonValue {
  let keyed = fn(found: List(#(Int, String))) {
    json.Object(
      list.map(found, fn(one) { #(int.to_string(one.0), json.String(one.1)) }),
    )
  }

  json.Object([
    #("arm", json.String(each.arm.id)),
    #("pass_at_k", keyed(each.at)),
    #("pass_pow_k", keyed(each.pow)),
  ])
}

/// The comparisons as a JSON array.
fn comparisons_json(comparisons: List(Comparison)) -> JsonValue {
  json.Array(
    list.map(comparisons, fn(each) {
      json.Object([
        #("baseline", json.String(each.baseline.id)),
        #("candidate", json.String(each.candidate.id)),
        #("verdict", verdict_json(each.verdict)),
        #("bootstrap", case each.bootstrap {
          Some(found) -> bootstrap_json(found)
          None -> json.Null
        }),
      ])
    }),
  )
}

/// The bootstrap's interval and verdict for a comparison.
fn bootstrap_json(each: Bootstrapped) -> JsonValue {
  json.Object([
    #("resamples", json.Int(bootstrap.default_resamples)),
    #("verdict", verdict_json(each.verdict)),
    ..case each.resampled {
      Some(Resampled(effect:, low:, high:)) -> [
        #("effect", json.Float(effect)),
        #("ci_low", json.Float(low)),
        #("ci_high", json.Float(high)),
      ]
      None -> []
    }
  ])
}

/// A verdict as a JSON object tagged by `kind`.
fn verdict_json(found: Verdict) -> JsonValue {
  case found {
    verdict.Improved(effect:, ci:, p:, mde:) ->
      directed("improved", effect, ci, p, mde)
    verdict.Harmed(effect:, ci:, p:, mde:) ->
      directed("harmed", effect, ci, p, mde)
    verdict.Indistinguishable(effect:, ci:, p:, mde:) ->
      directed("indistinguishable", effect, ci, p, mde)
    verdict.Underpowered(mde:, needed_tasks:, reason:) ->
      json.Object([
        #("kind", json.String("underpowered")),
        #("mde", json.Float(mde)),
        #("needed_tasks", json.Int(needed_tasks)),
        #("reason", json.String(reason)),
      ])
    verdict.Incomplete(reason:) ->
      json.Object([
        #("kind", json.String("incomplete")),
        #("reason", json.String(reason)),
      ])
  }
}

/// A verdict that has an effect, an interval and a p-value, as JSON.
fn directed(
  kind: String,
  effect: Float,
  ci: #(Float, Float),
  p: Float,
  mde: Float,
) -> JsonValue {
  json.Object([
    #("kind", json.String(kind)),
    #("effect", json.Float(effect)),
    #("ci_low", json.Float(ci.0)),
    #("ci_high", json.Float(ci.1)),
    #("p", json.Float(p)),
    #("mde", json.Float(mde)),
  ])
}
