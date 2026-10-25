//// The decision rule end to end: the A/A requirement, the planted
//// degradation, the failure ruling, the plan as denominator, and the
//// sequential futility check.

import evalstat
import evalstat/dominance
import evalstat/mcnemar.{Discordant}
import evalstat/pairing
import evalstat/trial.{type Fate, Fail, Pass}
import evalstat/verdict.{type Verdict}
import gleam/int
import gleam/list
import qcheck
import support/fixture

/// How many synthetic plans each verdict property draws, their shape, and
/// the qcheck seeds they are drawn from. Fixed so the gate is deterministic.
const plan_count = 500

const tasks_per_plan = 30

const trials_per_task = 3

const aa_seed = 2024

const degradation_seed = 2025

/// One synthetic task: its per-arm pass probabilities and, per trial, the
/// two uniforms that are compared against them.
type SyntheticTask {
  SyntheticTask(
    baseline_p: Float,
    candidate_p: Float,
    draws: List(#(Float, Float)),
  )
}

/// Both arms drawn from one Bernoulli(p_t) per task, with p_t varying
/// across tasks: the rule must not call a difference more than α of the
/// time in either direction. The bound is 0.06 rather than 0.05 to leave
/// room for the sampling error of 500 plans.
pub fn verdict_never_improves_under_aa_test() {
  let verdicts =
    plans(aa_seed, qcheck.bounded_float(0.1, 0.9), fn(p) { p })
    |> list.map(verdict_of)
  let improved = list.count(verdicts, is_improved)
  let harmed = list.count(verdicts, is_harmed)
  assert improved <= 30
  assert harmed <= 30
}

/// Arm B is arm A with thirty points removed from every task's pass
/// probability, T = 30, K = 3: the rule must say `Harmed` on at least 95 %
/// of seeds.
pub fn verdict_flags_planted_degradation_test() {
  let verdicts =
    plans(degradation_seed, qcheck.bounded_float(0.35, 0.95), fn(p) { p -. 0.3 })
    |> list.map(verdict_of)
  assert list.count(verdicts, is_harmed) >= 475
}

/// A timeout or a refusal is a failure of the arm, counted in `n`: the
/// verdict over timed-out candidate rows is the verdict over failed ones,
/// and the pairs are all still there.
pub fn timeouts_are_failures_not_excluded_test() {
  let failed = degraded_rows(trial.VerifierFailed)
  let timed_out = degraded_rows(trial.AgentTimeout)
  let refused = degraded_rows(trial.SafetyRefusal)
  let plan = pairing.plan(task_names(6), 3)
  let policy = verdict.default_policy()
  let expected = evalstat.paired_verdict(failed, "a", "b", plan, policy)
  assert is_harmed(expected)
  assert evalstat.paired_verdict(timed_out, "a", "b", plan, policy) == expected
  assert evalstat.paired_verdict(refused, "a", "b", plan, policy) == expected

  // Every planned pair survives: nothing was excluded.
  let assert Ok(paired) = pairing.pair(timed_out, "a", "b", plan)
    as "timed-out rows pair over the plan"
  assert pairing.pair_count(paired) == 18
  assert paired.dropped_pairs == 0
}

/// A planned row that never ran is `Incomplete`, whatever the other rows
/// say; so is a duplicate, and so is a row the plan never declared.
pub fn missing_plan_row_is_incomplete_test() {
  let rows = degraded_rows(trial.VerifierFailed)
  let plan = pairing.plan(task_names(6), 3)
  let policy = verdict.default_policy()
  assert is_harmed(evalstat.paired_verdict(rows, "a", "b", plan, policy))

  // Drop one candidate row: the plan still names it.
  let short =
    list.filter(rows, fn(r) {
      !{ r.arm == "b" && r.task == "t3" && r.index == 1 }
    })
  assert evalstat.paired_verdict(short, "a", "b", plan, policy)
    == verdict.Incomplete("plan row (t3, 1) has no trial on arm b")

  // A plan larger than the rows is the same defect from the other side.
  let wider = pairing.plan(task_names(7), 3)
  assert evalstat.paired_verdict(rows, "a", "b", wider, policy)
    == verdict.Incomplete("plan row (t6, 0) has no trial on arm a")

  // Twice the same coordinate, or a coordinate outside the plan.
  let doubled = [fixture.row("t0", "a", 0, trial.Passed), ..rows]
  assert evalstat.paired_verdict(doubled, "a", "b", plan, policy)
    == verdict.Incomplete("plan row (t0, 0) has two trials on arm a")
  let extra = [fixture.row("t0", "a", 3, trial.Passed), ..rows]
  assert evalstat.paired_verdict(extra, "a", "b", plan, policy)
    == verdict.Incomplete("trial (t0, 3) on arm a is not in the plan")

  // Rows of a third arm are not this comparison's business.
  let other = [fixture.row("t0", "c", 0, trial.Passed), ..rows]
  assert is_harmed(evalstat.paired_verdict(other, "a", "b", plan, policy))
}

/// An `Infrastructure` row removes its pair from `n`, is counted, and does
/// not make the plan incomplete: the row exists, it just is not evidence.
pub fn infrastructure_rows_are_excluded_and_counted_test() {
  let rows =
    degraded_rows(trial.VerifierFailed)
    |> list.map(fn(r) {
      case r.arm == "b" && r.task == "t2" && r.index == 0 {
        True -> fixture.row(r.task, r.arm, r.index, trial.Infrastructure)
        False -> r
      }
    })
  let plan = pairing.plan(task_names(6), 3)
  let assert Ok(paired) = pairing.pair(rows, "a", "b", plan)
    as "infrastructure rows still pair"
  assert paired.infrastructure_rows == 1
  assert paired.dropped_pairs == 1
  assert pairing.pair_count(paired) == 17
  assert is_harmed(evalstat.decide(paired, verdict.default_policy()))

  // A whole task lost to infrastructure leaves the cluster out, and below
  // two clusters the verdict is the no-variance `Underpowered`.
  let two_tasks =
    degraded_rows(trial.VerifierFailed)
    |> list.filter(fn(r) { r.task == "t0" || r.task == "t1" })
  let broken =
    list.map(two_tasks, fn(r) {
      case r.task == "t1" && r.arm == "a" {
        True -> fixture.row(r.task, r.arm, r.index, trial.Infrastructure)
        False -> r
      }
    })
  let small_plan = pairing.plan(task_names(2), 3)
  assert evalstat.paired_verdict(
      broken,
      "a",
      "b",
      small_plan,
      verdict.default_policy(),
    )
    == verdict.Underpowered(mde: 2.0, needed_tasks: 2)
}

/// The sign test pools pairs across tasks while the interval is clustered
/// on tasks, so one task with many discordant pairs can make `p` tiny
/// while the task-level interval still covers zero. The rule needs all its
/// clauses, and a significant `p` alone must not become `Harmed`.
pub fn significant_sign_test_alone_is_not_a_verdict_test() {
  let tasks = [
    #("t0", list.repeat(#(Pass, Fail), 20)),
    ..list.map(task_names(9), fn(name) {
      #(name <> "x", list.repeat(#(Pass, Pass), 3))
    })
  ]
  let rows = fixture.rows_of(tasks)
  let plan = fixture.plan_of(tasks)
  let result =
    evalstat.paired_verdict(rows, "a", "b", plan, verdict.default_policy())
  assert !is_harmed(result)
  assert !is_improved(result)
  assert case result {
    verdict.Underpowered(mde, _) -> mde >. 0.1
    _ -> False
  }
}

/// Undecided results split on whether the design could have seen the
/// target effect.
pub fn undecided_is_underpowered_when_mde_exceeds_target_test() {
  // d_t = 1/3, -1/3, 0, 0: no effect, b = c = 1, and a real spread.
  let tasks = [
    #("t0", [#(Fail, Pass), #(Pass, Pass), #(Pass, Pass)]),
    #("t1", [#(Pass, Fail), #(Pass, Pass), #(Pass, Pass)]),
    #("t2", [#(Pass, Pass), #(Pass, Pass), #(Pass, Pass)]),
    #("t3", [#(Fail, Fail), #(Fail, Fail), #(Fail, Fail)]),
  ]
  let rows = fixture.rows_of(tasks)
  let plan = fixture.plan_of(tasks)
  let tight = verdict.Policy(target_effect: 0.01, interval: verdict.Clustered)
  assert case evalstat.paired_verdict(rows, "a", "b", plan, tight) {
    verdict.Underpowered(mde, needed) -> mde >. 0.3 && needed > 1000
    _ -> False
  }
  let loose = verdict.Policy(target_effect: 0.5, interval: verdict.Clustered)
  assert case evalstat.paired_verdict(rows, "a", "b", plan, loose) {
    verdict.Indistinguishable(0.0, _, 1.0, _) -> True
    _ -> False
  }
}

/// The bootstrap interval reaches the verdict when the policy asks for it.
pub fn bootstrap_policy_forms_the_interval_test() {
  let rows = degraded_rows(trial.VerifierFailed)
  let plan = pairing.plan(task_names(6), 3)
  let policy =
    verdict.Policy(
      target_effect: 0.1,
      interval: verdict.Bootstrap(resamples: 400, seed: "plan"),
    )
  let clustered =
    evalstat.paired_verdict(rows, "a", "b", plan, verdict.default_policy())
  let booted = evalstat.paired_verdict(rows, "a", "b", plan, policy)
  assert is_harmed(booted)
  assert booted != clustered
}

/// Both futility bounds on counts, at the edges the module doc works out.
pub fn futility_bounds_test() {
  assert evalstat.futility_from_counts(Discordant(0, 0), 3)
    == verdict.StopIndistinguishable
  assert evalstat.futility_from_counts(Discordant(0, 0), 6) == verdict.Continue
  assert evalstat.futility_from_counts(Discordant(0, 9), 9) == verdict.Continue
  assert evalstat.futility_from_counts(Discordant(0, 12), 2)
    == verdict.StopDecided
  assert evalstat.futility_from_counts(Discordant(5, 5), 2)
    == verdict.StopIndistinguishable
  assert evalstat.futility_from_counts(Discordant(0, 12), 0)
    == verdict.StopDecided
  assert evalstat.futility_from_counts(Discordant(3, 3), 0)
    == verdict.StopIndistinguishable
}

/// Over rows: only pairs with both arms completed count, and the rest are
/// the caller's `remaining_pairs`.
pub fn futility_over_rows_counts_completed_pairs_test() {
  let rows = degraded_rows(trial.VerifierFailed)
  assert evalstat.futility(rows, "a", "b", 0) == verdict.StopDecided
  assert evalstat.futility([], "a", "b", 3) == verdict.StopIndistinguishable

  // Only the baseline half of the ledger has run: nothing is paired yet,
  // and eighteen remaining pairs could still decide it.
  let half = list.filter(rows, fn(r) { r.arm == "a" })
  assert evalstat.futility(half, "a", "b", 18) == verdict.Continue
}

/// Outcome first, then Pareto on scores.
pub fn dominance_is_outcome_first_then_pareto_test() {
  let harmed = verdict.Harmed(-0.3, #(-0.4, -0.2), 0.001, 0.1)
  let improved = verdict.Improved(0.3, #(0.2, 0.4), 0.001, 0.1)
  let same = verdict.Indistinguishable(0.0, #(-0.1, 0.1), 1.0, 0.1)
  let cheap = [#("cost_inv", 0.9), #("turns_inv", 0.5)]
  let dear = [#("cost_inv", 0.5), #("turns_inv", 0.5)]
  assert dominance.compare(harmed, cheap, dear)
    == dominance.Dominated(dominance.Outcome)
  assert dominance.compare(improved, dear, cheap)
    == dominance.Dominates(dominance.Outcome)
  assert dominance.compare(same, cheap, dear)
    == dominance.Dominates(dominance.Scores)
  assert dominance.compare(same, dear, cheap)
    == dominance.Dominated(dominance.Scores)
  assert dominance.compare(same, dear, dear) == dominance.Tie
  assert dominance.compare(same, [#("a", 1.0), #("b", 0.0)], [
      #("a", 0.0),
      #("b", 1.0),
    ])
    == dominance.Tradeoff(better: ["a"], worse: ["b"])
  assert dominance.compare(verdict.Underpowered(0.3, 90), cheap, dear)
    == dominance.Undecided
  assert dominance.compare(verdict.Incomplete("x"), cheap, dear)
    == dominance.Undecided
  assert dominance.pareto([#("only_here", 1.0)], [#("only_there", 1.0)])
    == dominance.Tie
}

/// Draws `plan_count` synthetic plans: each task's baseline probability from
/// `baseline_p`, the candidate's by `shift`, and the trials' uniforms.
fn plans(
  seed: Int,
  baseline_p: qcheck.Generator(Float),
  shift: fn(Float) -> Float,
) -> List(List(SyntheticTask)) {
  let unit = qcheck.bounded_float(0.0, 1.0)
  let task =
    qcheck.map2(
      baseline_p,
      qcheck.fixed_length_list_from(qcheck.tuple2(unit, unit), trials_per_task),
      fn(p, draws) { SyntheticTask(p, shift(p), draws) },
    )
  let plan = qcheck.fixed_length_list_from(task, tasks_per_plan)
  let #(plans, _) = qcheck.generate(plan, plan_count, qcheck.seed(seed))
  plans
}

/// Realises a synthetic plan as rows and runs the decision rule on it.
fn verdict_of(plan: List(SyntheticTask)) -> Verdict {
  let named = list.zip(task_names(tasks_per_plan), plan)
  let tasks =
    list.map(named, fn(entry) {
      let #(name, task) = entry
      let fates =
        list.map(task.draws, fn(draw) {
          #(
            bernoulli(draw.0, task.baseline_p),
            bernoulli(draw.1, task.candidate_p),
          )
        })
      #(name, fates)
    })
  evalstat.paired_verdict(
    fixture.rows_of(tasks),
    "a",
    "b",
    fixture.plan_of(tasks),
    verdict.default_policy(),
  )
}

fn bernoulli(uniform: Float, p: Float) -> Fate {
  case uniform <. p {
    True -> Pass
    False -> Fail
  }
}

/// Six tasks, three pairs each, in which the baseline passes everything and
/// the candidate fails two of three on every task, with the candidate's
/// failures spelled as `failure`.
fn degraded_rows(failure: trial.Outcome) -> List(trial.Trial) {
  list.flat_map(task_names(6), fn(name) {
    [
      fixture.row(name, "a", 0, trial.Passed),
      fixture.row(name, "a", 1, trial.Passed),
      fixture.row(name, "a", 2, trial.Passed),
      fixture.row(name, "b", 0, failure),
      fixture.row(name, "b", 1, failure),
      fixture.row(name, "b", 2, trial.Passed),
    ]
  })
}

fn task_names(count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, i) { "t" <> int.to_string(i) })
}

fn is_improved(v: Verdict) -> Bool {
  case v {
    verdict.Improved(..) -> True
    _ -> False
  }
}

fn is_harmed(v: Verdict) -> Bool {
  case v {
    verdict.Harmed(..) -> True
    _ -> False
  }
}
