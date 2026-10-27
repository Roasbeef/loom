import core/json
import eval/arm.{type Arm}
import eval/ledger.{type Row, Row}
import eval/plan.{type Plan, RowKey}
import eval/report
import eval/split
import eval/task.{type Task}
import eval/trial
import evalstat/bootstrap
import evalstat/pairing
import gleam/int
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
  report.Inputs(frozen, tasks(), arms(), None, None)
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

// --- the gap, intervals, pass@k and dominance ----------------------------------------

// Forty hand-written tasks: enough that every split of the fixed salt holds
// several, which `split_sizes_are_usable_test` checks rather than assumes.
fn many_tasks() -> List(Task) {
  list.index_map(list.repeat(Nil, 40), fn(_, position) {
    scripted.task_named("g" <> int.to_string(position), "a", "a")
  })
}

fn many_plan() -> Plan {
  scripted.plan_of(many_tasks(), arms(), 2, 2, 10.0, 1000)
}

fn many_inputs() -> report.Inputs {
  report.Inputs(many_plan(), many_tasks(), arms(), None, None)
}

fn split_of(found: Task) -> split.Split {
  split.assign(many_plan().split_salt, split.family(found))
}

// The position of a task among the tasks of its own split, so a rule can
// vary an effect from task to task and give the interval something to measure.
fn ordinal(found: Task) -> Int {
  let same =
    list.filter(many_tasks(), fn(each) { split_of(each) == split_of(found) })

  list.length(list.take_while(same, fn(each) { each.id != found.id }))
}

// A whole ledger whose passes the caller decides cell by cell.
fn ledger_where(
  frozen: Plan,
  tasks: List(Task),
  passes: fn(Task, String, Int) -> Bool,
) -> List(Row) {
  list.map(plan.rows(frozen), fn(key) {
    let assert Ok(found) = list.find(tasks, fn(each) { each.id == key.task })
      as "the plan names a task the fixture holds"
    let passing = passes(found, key.arm, key.index)
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
    )
  })
}

pub fn split_sizes_are_usable_test() {
  let sizes =
    list.map([split.Tune, split.Validate, split.Holdout], fn(wanted) {
      list.count(many_tasks(), fn(each) { split_of(each) == wanted })
    })

  assert list.all(sizes, fn(size) { size >= 4 })
}

// The candidate gains on every validate task and on no holdout task, and the
// baseline's own passes vary from task to task so the interval has a width.
fn gain_on_validate_only(found: Task, arm: String, index: Int) -> Bool {
  case arm == scripted.suffixed().id {
    True -> True
    False ->
      split_of(found) != split.Validate && index == 0 || ordinal(found) % 2 == 0
  }
}

pub fn report_prints_the_holdout_gap_test() {
  let rows =
    ledger_where(many_plan(), many_tasks(), fn(found, arm, index) {
      case split_of(found) {
        split.Holdout -> True
        split.Validate | split.Tune -> gain_on_validate_only(found, arm, index)
      }
    })

  let rendered = report.render(many_inputs(), rows)

  // A gain that is on the tuned-against split and not on the holdout is the
  // thing the gap exists to name.
  assert string.contains(rendered.markdown, "## Validate minus holdout")
  assert string.contains(rendered.markdown, "suffixed: validate effect ")
  assert string.contains(rendered.markdown, "holdout effect 0.0")
  assert string.contains(rendered.markdown, "memorised (")
  assert string.contains(rendered.json |> json.to_string, "\"memorised\":true")
}

pub fn a_gap_within_its_interval_is_not_called_memorised_test() {
  // The same gain everywhere: validate and holdout move together.
  let alike =
    ledger_where(many_plan(), many_tasks(), fn(found, arm, _index) {
      arm == scripted.suffixed().id || ordinal(found) % 2 == 0
    })
  let alike_text = report.render(many_inputs(), alike).markdown

  // The gain is on the holdout and not on validate: the gap is negative.
  let reversed =
    ledger_where(many_plan(), many_tasks(), fn(found, arm, index) {
      case split_of(found) {
        split.Validate -> True
        split.Holdout | split.Tune -> gain_on_validate_only(found, arm, index)
      }
    })
  let reversed_text = report.render(many_inputs(), reversed).markdown

  assert string.contains(alike_text, "no gap beyond its interval")
  assert !string.contains(alike_text, "memorised")
  assert string.contains(reversed_text, "no gap beyond its interval")
  assert !string.contains(reversed_text, "memorised")
}

pub fn a_gap_that_cannot_be_formed_says_why_test() {
  // A short ledger cannot be reconciled, so the gap is unavailable with the
  // ledger's own reason, not a number made from the cells that happen to exist.
  let rows = ledger_where(many_plan(), many_tasks(), fn(_, _, _) { True })
  let assert [_, ..short] = rows

  let text = report.render(many_inputs(), short).markdown

  assert string.contains(text, "suffixed: unavailable (plan row missing")
}

// The bootstrap interval for the rows, computed here from the statistics
// package directly, the way the plan's id seeds it.
fn expected_bootstrap(frozen: Plan, rows: List(Row)) -> #(Float, Float) {
  let ids = list.map(many_tasks(), fn(each) { each.id })
  let assert Ok(together) =
    pairing.pair(
      list.map(rows, report.to_stat),
      scripted.baseline().id,
      scripted.suffixed().id,
      pairing.plan(ids, frozen.trials_per_cell),
    )
    as "a whole ledger pairs"
  let assert Ok(interval) = bootstrap.interval(together, 2000, frozen.id)
    as "the bootstrap has tasks to resample"

  interval
}

fn bootstrap_bounds(rendered: report.Rendered) -> #(Float, Float) {
  let assert json.Object(top) = rendered.json as "the report is an object"
  let assert Ok(json.Array([json.Object(first), ..])) =
    list.key_find(top, "comparisons")
    as "there is a comparison"
  let assert Ok(json.Object(found)) = list.key_find(first, "bootstrap")
    as "the comparison carries its bootstrap"
  let assert Ok(json.Float(low)) = list.key_find(found, "ci_low")
    as "the bootstrap has a lower bound"
  let assert Ok(json.Float(high)) = list.key_find(found, "ci_high")
    as "the bootstrap has an upper bound"

  #(low, high)
}

pub fn bootstrap_interval_is_reproducible_from_the_plan_test() {
  let rows =
    ledger_where(many_plan(), many_tasks(), fn(found, arm, index) {
      case arm == scripted.suffixed().id {
        True -> ordinal(found) % 3 != 0 || index == 0
        False -> ordinal(found) % 2 == 0
      }
    })
  let frozen = many_plan()

  let first = report.render(many_inputs(), rows)
  let again = report.render(many_inputs(), rows)
  let reseeded =
    report.render(
      report.Inputs(..many_inputs(), plan: plan.Plan(..frozen, id: "other")),
      list.map(rows, fn(row) { Row(..row, plan: "other") }),
    )

  // The same plan and ledger render the same interval, and it is the one the
  // statistics package computes from the plan id; another seed draws another.
  assert first.markdown == again.markdown
  assert bootstrap_bounds(first) == expected_bootstrap(frozen, rows)
  assert bootstrap_bounds(reseeded) != bootstrap_bounds(first)
  assert string.contains(first.markdown, "bootstrap (2000 resamples")
}

pub fn report_carries_pass_at_k_and_dominance_test() {
  // The candidate passes both of its trials on odd tasks and one on even
  // ones; the baseline passes none.
  let better =
    ledger_where(many_plan(), many_tasks(), fn(found, arm, index) {
      arm == scripted.suffixed().id && { ordinal(found) % 2 == 1 || index == 0 }
    })
  let worse =
    ledger_where(many_plan(), many_tasks(), fn(found, arm, index) {
      arm != scripted.suffixed().id && { ordinal(found) % 2 == 1 || index == 0 }
    })

  let good = report.render(many_inputs(), better).markdown
  let bad = report.render(many_inputs(), worse).markdown

  // Both estimates run from one to K for each arm; k = 1 is the pass rate.
  assert string.contains(
    good,
    "- baseline: pass@1 0.0, pass@2 0.0; pass^1 0.0, pass^2 0.0",
  )
  assert string.contains(
    good,
    "- suffixed: pass@1 0.738, pass@2 1.0; pass^1 0.738, pass^2 0.475",
  )

  // The outcome verdict ranks before any score: a harmed candidate is dominated.
  assert string.contains(good, "- suffixed vs baseline: dominates (outcome)")
  assert string.contains(bad, "- suffixed vs baseline: dominated (outcome)")
}

pub fn dominance_reads_the_score_vector_when_the_outcome_is_not_harmful_test() {
  let frozen = plan_in(plan.Live)
  let rows =
    list.map(plan.rows(frozen), fn(key) {
      let cheap = key.arm == scripted.suffixed().id
      let blank = trial.infra_row(frozen.id, key, 1, "")

      // The arms pass alike, so the outcome is undecided and the scores speak:
      // the candidate costs less and scores lower on the verifier's own measure.
      Row(
        ..blank,
        state: ledger.Scored,
        outcome: Some(ledger.Passed),
        reward: 1.0,
        scores: [
          #("f2p", case cheap {
            True -> 0.5
            False -> 1.0
          }),
        ],
        usage: ledger.Usage(
          0,
          0,
          0,
          0,
          case cheap {
            True -> 0.1
            False -> 1.0
          },
          ledger.Complete,
        ),
      )
    })

  let text = report.render(inputs(frozen), rows).markdown

  assert string.contains(text, "- suffixed vs baseline: trade-off (better on")
  assert string.contains(text, "worse on f2p")
}

pub fn a_futility_stop_is_in_the_header_test() {
  let frozen = plan_in(plan.Live)
  let stopped =
    report.Inputs(
      ..inputs(frozen),
      futility_note: Some("stopped for futility after 3 pairs"),
    )

  let rendered = report.render(stopped, [])

  assert string.contains(
    rendered.markdown,
    "Futility: stopped for futility after 3 pairs",
  )
  assert string.contains(
    json.to_string(rendered.json),
    "\"futility_note\":\"stopped for futility after 3 pairs\"",
  )
}
