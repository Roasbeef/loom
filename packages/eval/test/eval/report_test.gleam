import eval/arm.{type Arm}
import eval/ledger.{type Row, Row}
import eval/plan.{type Plan, RowKey}
import eval/report
import eval/task.{type Task}
import eval/trial
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/scripted

fn tasks() -> List(Task) {
  [
    scripted.task_named("first", "a", "a"),
    scripted.task_named("second", "b", "b"),
  ]
}

fn arms() -> List(Arm) {
  [scripted.baseline(), scripted.suffixed()]
}

fn plan_in(lane: plan.Lane) -> Plan {
  let frozen = scripted.plan_of(tasks(), arms(), 2, 2, 10.0, 1000)

  plan.mint(plan.Plan(..frozen, lane:))
}

fn inputs(frozen: Plan) -> report.Inputs {
  report.Inputs(frozen, tasks(), arms(), None)
}

// A scored row for every cell of the plan: passing on the candidate and
// failing on the baseline, each with a cold start of five milliseconds.
fn whole_ledger(frozen: Plan, candidate_id: String) -> List(Row) {
  list.map(plan.rows(frozen), fn(key) {
    let passing = key.arm == candidate_id
    let blank = trial.infra_row(frozen.id, key, 1, "")

    Row(
      ..blank,
      state: ledger.Scored,
      outcome: case passing {
        True -> Some(ledger.Passed)
        False -> Some(ledger.VerifierFailed)
      },
      reward: case passing {
        True -> 1.0
        False -> 0.0
      },
      timing: ledger.Timing(5, 7, 0, 0),
    )
  })
}

pub fn report_names_the_lane_test() {
  let replay = report.render(inputs(plan_in(plan.Replay)), [])
  let live = report.render(inputs(plan_in(plan.Live)), [])

  assert string.contains(
    replay.markdown,
    "replay lane: proves harness regressions only, no model quality claim",
  )
  assert !string.contains(replay.markdown, "live lane")
  assert string.contains(live.markdown, "live lane")
  assert !string.contains(live.markdown, "proves harness regressions only")
  assert string.contains(
    report.lane_statement(plan.Replay),
    "no model quality claim",
  )
}

pub fn a_missing_cell_makes_every_verdict_incomplete_test() {
  let frozen = plan_in(plan.Live)
  let candidate = scripted.suffixed()
  let assert [_, ..short] = whole_ledger(frozen, candidate.id)

  let rendered = report.render(inputs(frozen), short)

  assert string.contains(rendered.markdown, "INCOMPLETE: plan row missing")
  assert string.contains(rendered.markdown, "Incomplete: plan row missing")
  assert string.contains(rendered.markdown, "unavailable (incomplete)")
}

pub fn the_first_line_is_the_minimum_detectable_effect_test() {
  let frozen = plan_in(plan.Live)
  let rows = whole_ledger(frozen, scripted.suffixed().id)

  let rendered = report.render(inputs(frozen), rows)
  let assert [first, ..] = string.split(rendered.markdown, "\n")

  assert string.starts_with(first, "Minimum detectable effect")
  assert string.contains(first, "suffixed vs baseline: ")
  assert !string.contains(rendered.markdown, "INCOMPLETE")
}

pub fn panels_tags_and_cold_start_are_reported_apart_from_agent_time_test() {
  let frozen = plan_in(plan.Live)
  let rows = whole_ledger(frozen, scripted.suffixed().id)

  let markdown = report.render(inputs(frozen), rows).markdown

  assert string.contains(markdown, "### tune")
  assert string.contains(markdown, "### validate")
  assert string.contains(markdown, "### holdout")
  assert string.contains(markdown, "kind:write / suffixed: 1.0 (4/4)")
  assert string.contains(markdown, "kind:write / baseline: 0.0 (0/4)")
  assert string.contains(markdown, "cold start total 20 ms, agent total 28 ms")
}

pub fn a_retried_cell_reports_its_latest_attempt_and_counts_every_cold_start_test() {
  let frozen = plan_in(plan.Live)
  let candidate = scripted.suffixed()
  let rows = whole_ledger(frozen, candidate.id)
  let assert [first, ..rest] = rows
  let key = RowKey(first.task, first.arm, first.index)
  let interrupted =
    Row(
      ..trial.infra_row(frozen.id, key, 1, "killed"),
      timing: ledger.Timing(100, 0, 0, 0),
    )
  let retried = Row(..first, attempt: 2)

  let rendered = report.render(inputs(frozen), [interrupted, retried, ..rest])

  assert !string.contains(rendered.markdown, "INCOMPLETE")
  assert string.contains(rendered.markdown, "cold start total 120 ms")
}
