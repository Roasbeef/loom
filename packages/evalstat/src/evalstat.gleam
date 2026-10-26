//// The decision rule: paired trial rows in, a `Verdict` out, with the
//// sequential futility check that lets a run stop early without ever
//// over-claiming.
////
//// Everything below is a composition of the package's estimators in one
//// fixed order, and the order is the design. The plan is checked first
//// (`pairing`), because a missing row must become `Incomplete` before any
//// number is formed from the rows that did arrive; a plan whose every pair
//// was lost to `Infrastructure` is `Incomplete` too, since it produced no
//// evidence. The spread between tasks is checked next: fewer than two
//// tasks, or tasks that all moved by the same amount, leave the observed
//// variance saying nothing about the error, and the verdict is
//// `Underpowered` with the binomial plug-in floor (`paired.plugin_variance`)
//// standing in for the variance the data could not show, never a zero
//// minimum detectable effect that would make any result look powered.
//// Only then are the effect, the interval, the task-level sign test and
//// the minimum detectable effect computed.
////
//// A direction is claimed only when every clause agrees: the effect is on
//// that side of zero, the clustered interval is wholly on that side, more
//// tasks moved that way than the other, the exact task-level sign test has
//// `p < α`, and the effect is at least half the minimum detectable effect.
//// Every clause weights tasks equally. A pair-level test would not, and
//// ten one-pair tasks the candidate won against one hundred-pair task it
//// lost would then be "significant" in the candidate's favour by pairs
//// while the clustered interval said the opposite
//// (`one_heavy_task_cannot_flip_the_verdict_test`). The pair-level
//// McNemar count stays available to reports through `mcnemar.discordant`.
//// Under the clustered interval the last clause (`1.4 · SE`) is implied by
//// the interval clause (`1.96 · SE`); it binds under `Bootstrap`.
////
//// A result that is neither improved nor harmed is `Indistinguishable`
//// only if the design could have seen the policy's target effect;
//// otherwise it is `Underpowered`, with the task count that would have
//// sufficed. At the design's own scale (T = 30, K = 3, target 0.10) the
//// minimum detectable effect is about 0.19, so undecided plans there land
//// in `Underpowered`; `Indistinguishable` is reserved for a plan large
//// enough to have seen the target.
////
//// `α` is fixed at 0.05 because the interval's `1.96` is; the cut list
//// excludes the z table another level would need. The governed caller maps
//// `Improved → Passed`, `Harmed | Indistinguishable → Failed`, the rest to
//// `Inconclusive`, so only a demonstrated improvement spends a selection.
////
//// # Sequential stopping
////
//// A plan fixes `K` and runs task-pair rounds. After each round `futility`
//// asks one deterministic question of the task signs so far and the pairs
//// still to run: could the best possible allocation of those pairs bring
//// the task-level sign test below `α` in either direction? One remaining
//// pair can at most add one task to a side (a new task, or a tied one
//// tipped) or neutralise one task on the other side (a strictly negative
//// `d_t` cannot cross zero on a single pair, only reach it), so the bound
//// searches every split of the remaining pairs between those two uses and
//// stops only when none reaches `α`. There is no early *decision*: a
//// verdict also needs the clustered interval, which the remaining pairs
//// can still move, so stopping with a verdict could contradict the full
//// run. The check therefore only ever under-claims, and there is no
//// stopping on "looks good".

import evalstat/bootstrap
import evalstat/mcnemar.{type Signs, Signs}
import evalstat/paired
import evalstat/pairing.{type Paired}
import evalstat/trial.{type Trial}
import evalstat/verdict.{type Policy, type Stop, type Verdict}
import gleam/bool
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/result

/// The significance level, fixed by the interval's `z_alpha`.
pub const alpha = 0.05

/// Compares `candidate` against `baseline` over the plan's `(task, index)`
/// set (`pairing.plan`), under `policy`.
///
/// ## Examples
///
/// ```gleam
/// // One planned row never ran: the plan, not the rows, is the denominator.
/// let rows = [row("t", "a", 0, trial.Passed)]
/// assert evalstat.paired_verdict(rows, "a", "b", pairing.plan(["t"], 1), verdict.default_policy())
///   == verdict.Incomplete("plan row (t, 0) has no trial on arm b")
/// ```
pub fn paired_verdict(
  rows: List(Trial),
  baseline: String,
  candidate: String,
  expected: List(#(String, Int)),
  policy: Policy,
) -> Verdict {
  case pairing.pair(rows, baseline, candidate, expected) {
    Error(reason) -> verdict.Incomplete(pairing.describe(reason))
    Ok(paired) -> decide(paired, policy)
  }
}

/// The verdict over an already-paired plan, for callers that paired the
/// rows themselves to report on them as well.
///
/// ## Examples
///
/// ```gleam
/// assert evalstat.decide(Paired([], 0, 0), verdict.default_policy())
///   == verdict.Incomplete("no counted trials")
/// ```
pub fn decide(paired: Paired, policy: Policy) -> Verdict {
  use <- bool.guard(
    when: paired.tasks == [],
    return: verdict.Incomplete("no counted trials"),
  )
  let differences = paired.differences(paired)
  let effect = paired.mean(differences)

  // Below two clusters, or with no spread between them, the observed
  // variance cannot stand for the error; the guard is here rather than
  // inside each estimator so one verdict says so.
  case paired.clustered_se(differences) {
    Error(Nil) -> underpowered_by_floor(paired, policy, "fewer than two tasks")
    Ok(se) if se <=. 0.0 ->
      underpowered_by_floor(paired, policy, "no spread between tasks")
    Ok(se) -> {
      let mde = paired.mde(se)
      let ci = interval_for(paired, policy, effect, se)
      let signs = mcnemar.task_signs(differences)
      classify(effect, ci, signs, mde, differences, policy)
    }
  }
}

/// `Underpowered` from the binomial plug-in floor, for the cases where the
/// observed variance is undefined or zero. The plug-in is what a Bernoulli
/// outcome's variance cannot fall below, so the minimum detectable effect
/// and the task count it implies are the most optimistic honest numbers.
fn underpowered_by_floor(
  paired: Paired,
  policy: Policy,
  why: String,
) -> Verdict {
  let variance = paired.plugin_variance(paired)
  let tasks = int.to_float(list.length(paired.tasks))
  let se = result.unwrap(float.square_root(variance /. tasks), 0.0)
  verdict.Underpowered(
    mde: paired.mde(se),
    needed_tasks: paired.needed_tasks_for_variance(
      variance,
      policy.target_effect,
    ),
    reason: why <> ": error floored at the binomial plug-in",
  )
}

/// Which interval the policy asked for. The bootstrap cannot fail once a
/// task exists and the resample count is positive; if a policy asks for
/// zero resamples the clustered interval stands in, so a verdict is always
/// formed.
fn interval_for(
  paired: Paired,
  policy: Policy,
  effect: Float,
  se: Float,
) -> #(Float, Float) {
  case policy.interval {
    verdict.Clustered -> paired.interval(effect, se)
    verdict.Bootstrap(resamples, seed) ->
      bootstrap.interval(paired, resamples, seed)
      |> result.lazy_unwrap(fn() { paired.interval(effect, se) })
  }
}

/// The five-clause direction test, then the power question for whatever
/// it leaves undecided.
fn classify(
  effect: Float,
  ci: #(Float, Float),
  signs: Signs,
  mde: Float,
  differences: List(Float),
  policy: Policy,
) -> Verdict {
  let p = mcnemar.sign_p_value(signs)
  let significant = p <. alpha
  let half = mde /. 2.0
  let Signs(positive, negative) = signs
  use <- bool.guard(
    when: effect >. 0.0
      && ci.0 >. 0.0
      && positive > negative
      && significant
      && effect >=. half,
    return: verdict.Improved(effect:, ci:, p:, mde:),
  )
  use <- bool.guard(
    when: effect <. 0.0
      && ci.1 <. 0.0
      && negative > positive
      && significant
      && effect <=. 0.0 -. half,
    return: verdict.Harmed(effect:, ci:, p:, mde:),
  )

  // Undecided. Whether that is a finding or a failure of the design turns
  // on whether this many tasks could have shown the target effect at all.
  case mde >. policy.target_effect {
    True ->
      verdict.Underpowered(
        mde:,
        needed_tasks: paired.needed_tasks(differences, policy.target_effect),
        reason: "minimum detectable effect above the target",
      )
    False -> verdict.Indistinguishable(effect:, ci:, p:, mde:)
  }
}

/// The sequential futility check over the rows completed so far. A
/// `(task, index)` counts as completed when both arms have a counted row
/// for it; `remaining_pairs` is how many planned pairs have not, which the
/// caller knows from the plan.
///
/// ## Examples
///
/// ```gleam
/// // Nothing has run and three pairs remain: three one-pair tasks all won
/// // by one arm reach p = 0.25 at best, never α.
/// assert evalstat.futility([], "a", "b", 3) == verdict.StopUndecided
/// ```
///
/// ```gleam
/// // Six remaining pairs could become six won tasks and p = 0.03125.
/// assert evalstat.futility([], "a", "b", 6) == verdict.Continue
/// ```
pub fn futility(
  rows_so_far: List(Trial),
  baseline: String,
  candidate: String,
  remaining_pairs: Int,
) -> Stop {
  let completed = completed_pairs(rows_so_far, baseline, candidate)
  let done = set_of(completed)
  let rows =
    list.filter(rows_so_far, fn(row) {
      dict.has_key(done, #(row.task, row.index))
    })

  // Pairing the completed rows over the completed set can fail only on a
  // duplicate row or a same-arm comparison, ledger defects the final
  // verdict will name. The only honest answer then is to keep running:
  // nothing can be claimed from rows that cannot be paired.
  case pairing.pair(rows, baseline, candidate, completed) {
    Ok(paired) ->
      futility_from_signs(
        mcnemar.task_signs(paired.differences(paired)),
        remaining_pairs,
      )
    Error(pairing.MissingRow(..)) -> verdict.Continue
    Error(pairing.DuplicateRow(..)) -> verdict.Continue
    Error(pairing.UnplannedRow(..)) -> verdict.Continue
    Error(pairing.SameArm(..)) -> verdict.Continue
  }
}

/// The futility check on task signs directly, for a caller that keeps its
/// own tally. Deterministic, and it only ever under-claims: the bound is
/// the smallest `p` any allocation of the remaining pairs could reach.
///
/// ## Examples
///
/// ```gleam
/// // 5 vs 5 with two pairs left: at best 7 vs 5 or 6 vs 4, p ≈ 0.77 either way.
/// assert evalstat.futility_from_signs(Signs(5, 5), 2) == verdict.StopUndecided
/// ```
///
/// ```gleam
/// // 4 vs 1 with one pair left: neutralising the loss gives 4 vs 0, p = 0.125;
/// // a fifth win gives 5 vs 1, p ≈ 0.22. Neither reaches α.
/// assert evalstat.futility_from_signs(Signs(4, 1), 1) == verdict.StopUndecided
/// ```
///
/// ```gleam
/// // 5 vs 1 with one pair left: neutralising the loss gives 5 vs 0, p = 0.0625;
/// // 6 vs 1 gives p ≈ 0.125. Still undecided — but with two pairs left,
/// // 6 vs 0 reaches 0.03125.
/// assert evalstat.futility_from_signs(Signs(5, 1), 2) == verdict.Continue
/// ```
pub fn futility_from_signs(so_far: Signs, remaining_pairs: Int) -> Stop {
  let remaining = int.max(0, remaining_pairs)
  let Signs(positive, negative) = so_far

  // Each remaining pair goes to one of two uses for the favoured side:
  // adding a task to it, or removing one from the other side. The best
  // case is the minimum over every split, in either direction.
  let best = fn(mine: Int, theirs: Int) {
    int.range(0, int.min(remaining, theirs) + 1, 1.0, fn(best_p, removed) {
      let added = remaining - removed
      float.min(
        best_p,
        mcnemar.sign_p_value(Signs(mine + added, theirs - removed)),
      )
    })
  }
  let best_p = float.min(best(positive, negative), best(negative, positive))

  // Nothing that could still happen reaches α: the plan cannot end decided.
  case best_p <. alpha {
    True -> verdict.Continue
    False -> verdict.StopUndecided
  }
}

/// The `(task, index)` keys for which both arms hold a row.
fn completed_pairs(
  rows: List(Trial),
  baseline: String,
  candidate: String,
) -> List(#(String, Int)) {
  let keys_of = fn(arm: String) {
    list.filter_map(rows, fn(row) {
      case row.arm == arm {
        True -> Ok(#(row.task, row.index))
        False -> Error(Nil)
      }
    })
  }
  let on_candidate = set_of(keys_of(candidate))
  keys_of(baseline)
  |> list.filter(fn(key) { dict.has_key(on_candidate, key) })
  |> list.unique
}

/// A membership table over `(task, index)` keys.
fn set_of(keys: List(#(String, Int))) -> dict.Dict(#(String, Int), Nil) {
  list.fold(keys, dict.new(), fn(set, key) { dict.insert(set, key, Nil) })
}
