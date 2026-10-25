//// The decision rule: paired trial rows in, a `Verdict` out, with the
//// sequential futility check that lets a run stop early without ever
//// over-claiming.
////
//// Everything below is a composition of the package's estimators in one
//// fixed order, and the order is the design. The plan is checked first
//// (`pairing`), because a missing row must become `Incomplete` before any
//// number is formed from the rows that did arrive. The cluster count is
//// checked next, because one task has no variance and would otherwise look
//// infinitely precise. Only then are the effect, the interval, the sign
//// test and the minimum detectable effect computed, and a direction is
//// claimed only when all three agree: the exact sign test is significant,
//// the interval excludes zero on that side, and the effect is at least half
//// the minimum detectable effect. The last clause is what turns a lucky
//// two-point "significant" win into `Indistinguishable`, which is what it
//// is. A result that is neither improved nor harmed is `Indistinguishable`
//// only if the design could have seen the policy's target effect;
//// otherwise it is `Underpowered`, with the task count that would have
//// sufficed.
////
//// `α` is fixed at 0.05 because the interval's `1.96` is; the cut list
//// excludes the z table another level would need. The governed caller maps
//// `Improved → Passed`, `Harmed | Indistinguishable → Failed`, the rest to
//// `Inconclusive`, so only a demonstrated improvement spends a selection.
////
//// # Sequential stopping
////
//// A plan fixes `K` and runs task-pair rounds. After each round `futility`
//// asks two deterministic questions of the discordant counts so far and the
//// pairs still to run. If every remaining pair favoured the leading arm and
//// `p` still could not fall below `α`, the plan cannot end decided and the
//// run may stop as `StopIndistinguishable`. If every remaining pair went
//// against the leading arm, or evened the counts, and `p` still could not
//// reach `α`, the sign test is settled and the run may stop as
//// `StopDecided`. Both bounds assume the
//// most extreme allocation of what remains, so neither can claim a result
//// the full run would not have reached; the check only ever under-claims,
//// and there is no stopping on "looks good".

import evalstat/bootstrap
import evalstat/mcnemar.{type Discordant, Discordant}
import evalstat/paired
import evalstat/pairing.{type Paired}
import evalstat/trial.{type Trial}
import evalstat/verdict.{type Policy, type Stop, type Verdict}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/result

/// The significance level, fixed by the interval's `z_alpha`.
pub const alpha = 0.05

/// The verdict a report cannot form below two tasks: no variance exists,
/// so the minimum detectable effect is the whole range of a difference of
/// rates and the task count needed is the least at which an estimate
/// exists at all.
const no_variance = verdict.Underpowered(mde: 2.0, needed_tasks: 2)

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
///   == verdict.Underpowered(mde: 2.0, needed_tasks: 2)
/// ```
pub fn decide(paired: Paired, policy: Policy) -> Verdict {
  let differences = paired.differences(paired)
  let effect = paired.mean(differences)

  // Below two clusters there is nothing to estimate the error from, and the
  // guard is here rather than inside each estimator so one verdict, not
  // three defaults, says so.
  case paired.clustered_se(differences) {
    Error(Nil) -> no_variance
    Ok(se) -> {
      let mde = paired.mde(se)
      let ci = interval_for(paired, policy, effect, se)
      let p = mcnemar.p_value(mcnemar.discordant(paired))
      classify(effect, ci, p, mde, differences, policy)
    }
  }
}

/// Which interval the policy asked for. The bootstrap cannot fail once two
/// tasks exist and the resample count is positive; if a policy asks for
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

/// The three-clause direction test, then the power question for whatever
/// it leaves undecided.
fn classify(
  effect: Float,
  ci: #(Float, Float),
  p: Float,
  mde: Float,
  differences: List(Float),
  policy: Policy,
) -> Verdict {
  let significant = p <. alpha
  let half = mde /. 2.0
  use <- bool.guard(
    when: significant && ci.0 >. 0.0 && effect >=. half,
    return: verdict.Improved(effect:, ci:, p:, mde:),
  )
  use <- bool.guard(
    when: significant && ci.1 <. 0.0 && effect <=. 0.0 -. half,
    return: verdict.Harmed(effect:, ci:, p:, mde:),
  )

  // Undecided. Whether that is a finding or a failure of the design turns
  // on whether this many tasks could have shown the target effect at all.
  case mde >. policy.target_effect {
    True ->
      verdict.Underpowered(
        mde:,
        needed_tasks: paired.needed_tasks(differences, policy.target_effect),
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
/// // Nothing has run and three pairs remain: three discordant pairs could
/// // reach p = 0.25 at best, never α, so the plan is futile already.
/// assert evalstat.futility([], "a", "b", 3) == verdict.StopIndistinguishable
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
  // duplicate row, a ledger defect the final verdict will name. The only
  // honest answer then is to keep running: nothing can be claimed from
  // rows that cannot be paired.
  case pairing.pair(rows, baseline, candidate, completed) {
    Ok(paired) ->
      futility_from_counts(mcnemar.discordant(paired), remaining_pairs)
    Error(pairing.MissingRow(..)) -> verdict.Continue
    Error(pairing.DuplicateRow(..)) -> verdict.Continue
    Error(pairing.UnplannedRow(..)) -> verdict.Continue
  }
}

/// The futility check on discordant counts directly, for a caller that
/// keeps its own tally. Deterministic: both bounds take the most extreme
/// allocation of the remaining pairs, so the answer only ever under-claims.
///
/// ## Examples
///
/// ```gleam
/// // 0 vs 9 so far with nine pairs left: nine more for the candidate reaches
/// // p ≈ 0.00000763, nine against it reaches 9 vs 9 and p = 1. Undecided.
/// assert evalstat.futility_from_counts(Discordant(0, 9), 9) == verdict.Continue
/// ```
///
/// ```gleam
/// // 0 vs 12 with two left: at worst 2 vs 12, p ≈ 0.013 < α. Decided.
/// assert evalstat.futility_from_counts(Discordant(0, 12), 2) == verdict.StopDecided
/// ```
pub fn futility_from_counts(so_far: Discordant, remaining_pairs: Int) -> Stop {
  let Discordant(b, c) = so_far
  let remaining = int.max(0, remaining_pairs)
  let leader = int.max(b, c)
  let trailer = int.min(b, c)

  // Best case for a decision: every remaining pair joins the leader. If
  // that still cannot cross α, no completion of the plan can.
  let best_p = mcnemar.p_value(Discordant(trailer, leader + remaining))
  use <- bool.guard(
    when: best_p >=. alpha,
    return: verdict.StopIndistinguishable,
  )

  let gap = leader - trailer

  // Worst case for a decision: the remaining pairs make the counts as even
  // as they can. If they can close the gap, `p` can reach one and nothing
  // is settled; if they cannot, the most even reachable split is every
  // remaining pair joining the trailer, and if even that stays below α the
  // sign test is settled.
  let worst_p = case remaining >= gap {
    True -> 1.0
    False -> mcnemar.p_value(Discordant(trailer + remaining, leader))
  }

  use <- bool.guard(when: worst_p <. alpha, return: verdict.StopDecided)
  verdict.Continue
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
