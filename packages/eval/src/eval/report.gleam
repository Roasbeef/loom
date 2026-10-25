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
//// difference the design could have seen. Cold start (`timing.prepare`) is
//// summed apart from agent time, and the header names the lane and the claim
//// it can and cannot support: a replay run proves only that the harness
//// still makes the same requests.
////
//// `render` is pure: it takes the ledger's rows and returns the Markdown and
//// the JSON. `write_run` is the one place that touches the disk.
////
//// ## Flow
////
//// - `lane_statement`: the claim a lane supports
//// - `render`: rows to Markdown and JSON
//// - `write_run`: read a run directory, render, write the Markdown and JSON files

import core/json.{type JsonValue}
import eval/arm.{type Arm}
import eval/ledger.{type Row}
import eval/plan.{type Plan, RowKey}
import eval/split.{type Split}
import eval/task.{type Task}
import evalstat
import evalstat/pairing
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

// One comparison of a candidate with the baseline.
type Comparison {
  Comparison(baseline: Arm, candidate: Arm, verdict: Verdict)
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
  let comparisons = compare(inputs, reconciled, inputs.tasks)
  let panels =
    list.map([split.Tune, split.Validate, split.Holdout], fn(each) {
      let members = tasks_in(inputs, each)

      #(each, list.length(members), compare(inputs, reconciled, members))
    })
  let latest = latest_rows(rows)
  let arm_lines =
    list.map(inputs.arms, fn(each) { arm_line(each, latest, rows) })
  let tag_lines = tag_rates(inputs, latest)
  let served = served_models(latest)

  Rendered(
    markdown: markdown(
      inputs,
      reconciled,
      comparisons,
      panels,
      arm_lines,
      tag_lines,
      served,
      rows,
    ),
    json: to_json(
      inputs,
      reconciled,
      comparisons,
      panels,
      arm_lines,
      tag_lines,
      served,
    ),
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
) -> List(Comparison) {
  case inputs.arms {
    [] -> []
    [baseline, ..candidates] ->
      list.map(candidates, fn(candidate) {
        Comparison(
          baseline:,
          candidate:,
          verdict: verdict_for(inputs, reconciled, members, baseline, candidate),
        )
      })
  }
}

/// The verdict for one pair over the given tasks, `Incomplete` when the ledger did not reconcile.
fn verdict_for(
  inputs: Inputs,
  reconciled: Result(List(Row), String),
  members: List(Task),
  baseline: Arm,
  candidate: Arm,
) -> Verdict {
  // A ledger that does not reconcile decides nothing; a whole one is compared pair by pair.
  case reconciled {
    Error(reason) -> verdict.Incomplete(reason)

    Ok(final) -> {
      let ids = list.map(members, fn(each) { each.id })
      let trials =
        final
        |> list.filter(fn(row) { list.contains(ids, row.task) })
        |> list.map(to_stat)

      evalstat.paired_verdict(
        trials,
        baseline.id,
        candidate.id,
        pairing.plan(ids, inputs.plan.trials_per_cell),
        verdict.default_policy(),
      )
    }
  }
}

/// Converts a finished ledger row to the statistics package's row.
fn to_stat(row: Row) -> stat.Trial {
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
    infra: Int,
    mean_dollars: Float,
    mean_turns: Float,
    mean_tool_errors: Float,
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
    infra: list.length(mine) - list.length(counted),
    mean_dollars: mean(counted, fn(row) { row.usage.dollars }),
    mean_turns: mean(counted, fn(row) { int.to_float(row.turns) }),
    mean_tool_errors: mean(counted, fn(row) { int.to_float(row.tool_errors) }),
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
fn markdown(
  inputs: Inputs,
  reconciled: Result(List(Row), String),
  comparisons: List(Comparison),
  panels: List(#(Split, Int, List(Comparison))),
  arm_lines: List(ArmLine),
  tag_lines: List(TagRate),
  served: List(String),
  rows: List(Row),
) -> String {
  let header = [
    mde_line(comparisons),
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
      <> int.to_string(list.length(rows))
      <> ", cells owed: "
      <> int.to_string(list.length(plan.rows(inputs.plan))),
    ..case inputs.budget_note {
      Some(note) -> ["Budget: " <> note]
      None -> []
    }
  ]

  // A whole ledger adds nothing to the header; an unreconciled one says why the verdicts are `Incomplete`.
  let status = case reconciled {
    Ok(_) -> []
    Error(reason) -> ["", "INCOMPLETE: " <> reason]
  }

  string.join(
    list.flatten([
      header,
      status,
      ["", "## Comparisons", ""],
      comparison_lines(comparisons),
      ["", "## Splits", ""],
      list.flat_map(panels, fn(panel) {
        [
          "### "
            <> split_name(panel.0)
            <> " ("
            <> int.to_string(panel.1)
            <> " tasks)",
          ..comparison_lines(panel.2)
        ]
      }),
      ["", "## Arms", ""],
      list.map(arm_lines, arm_text),
      ["", "## Pass rate by tag", ""],
      list.map(tag_lines, fn(each) {
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
      list.map(served, fn(each) { "- " <> each }),
      [""],
    ]),
    "\n",
  )
}

/// One bullet per comparison.
fn comparison_lines(comparisons: List(Comparison)) -> List(String) {
  list.map(comparisons, fn(each) {
    "- "
    <> each.candidate.name
    <> " vs baseline "
    <> each.baseline.name
    <> " — "
    <> describe(each.verdict)
  })
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
  <> "), infra "
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
fn to_json(
  inputs: Inputs,
  reconciled: Result(List(Row), String),
  comparisons: List(Comparison),
  panels: List(#(Split, Int, List(Comparison))),
  arm_lines: List(ArmLine),
  tag_lines: List(TagRate),
  served: List(String),
) -> JsonValue {
  json.Object([
    #("v", json.Int(2)),
    #("plan", json.String(inputs.plan.id)),
    #("lane", json.String(lane_statement(inputs.plan.lane))),
    #("mde_line", json.String(mde_line(comparisons))),
    #("complete", case reconciled {
      Ok(_) -> json.Bool(True)
      Error(_) -> json.Bool(False)
    }),
    #("incomplete_reason", case reconciled {
      Ok(_) -> json.Null
      Error(reason) -> json.String(reason)
    }),
    #("budget_note", case inputs.budget_note {
      Some(note) -> json.String(note)
      None -> json.Null
    }),
    #("comparisons", comparisons_json(comparisons)),
    #(
      "splits",
      json.Array(
        list.map(panels, fn(panel) {
          json.Object([
            #("split", json.String(split_name(panel.0))),
            #("tasks", json.Int(panel.1)),
            #("comparisons", comparisons_json(panel.2)),
          ])
        }),
      ),
    ),
    #(
      "arms",
      json.Array(
        list.map(arm_lines, fn(line) {
          json.Object([
            #("arm", json.String(line.arm.id)),
            #("name", json.String(line.arm.name)),
            #("counted", json.Int(line.counted)),
            #("passed", json.Int(line.passed)),
            #("infra", json.Int(line.infra)),
            #("mean_dollars", json.Float(line.mean_dollars)),
            #("mean_turns", json.Float(line.mean_turns)),
            #("mean_tool_errors", json.Float(line.mean_tool_errors)),
            #("cold_total_ms", json.Int(line.cold_total_ms)),
            #("agent_total_ms", json.Int(line.agent_total_ms)),
          ])
        }),
      ),
    ),
    #(
      "tags",
      json.Array(
        list.map(tag_lines, fn(each) {
          json.Object([
            #("tag", json.String(each.tag)),
            #("arm", json.String(each.arm.id)),
            #("passed", json.Int(each.passed)),
            #("counted", json.Int(each.counted)),
          ])
        }),
      ),
    ),
    #("served", json.Array(list.map(served, json.String))),
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
      ])
    }),
  )
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
