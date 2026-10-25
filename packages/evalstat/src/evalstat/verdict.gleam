//// The decision rule's vocabulary: what a comparison may conclude, and the
//// policy a caller sets before asking.
////
//// The types live apart from the rule so a consumer that only reads
//// verdicts (`dominance`, a report renderer, the governed
//// `rollout.verdict` mapping) can depend on this module and nothing else in
//// the package. A verdict carries every number a reader needs to check it:
//// the effect, the interval, the p-value and the minimum detectable effect
//// always travel together, so a report can never print a significant
//// effect without the size the design would have needed to trust it.

/// How the confidence interval is formed.
pub type Interval {
  /// `d̄ ± 1.96 · SE_paired` from the task-clustered standard error. The
  /// default: deterministic, closed-form, and what the mutation proofs
  /// exercise.
  Clustered

  /// The nested bootstrap's percentile interval over `resamples` draws,
  /// seeded from `seed` (the plan id). Reproducible; slower.
  Bootstrap(resamples: Int, seed: String)
}

/// What the caller decides before the data is read.
pub type Policy {
  Policy(
    /// The effect size the plan is meant to detect. A result the data
    /// cannot decide is `Underpowered` when the minimum detectable effect
    /// exceeds this, and `Indistinguishable` only when the design could
    /// have seen an effect of this size and did not.
    target_effect: Float,
    /// How the interval in the verdict is formed.
    interval: Interval,
  )
}

/// The outcome of comparing a candidate arm against a baseline. The effect
/// is always `candidate − baseline` in pass rate, so a positive number is
/// the candidate passing more.
pub type Verdict {
  /// `p < α`, the interval excludes zero on the positive side, and the
  /// effect is at least half the minimum detectable effect.
  Improved(effect: Float, ci: #(Float, Float), p: Float, mde: Float)

  /// The mirror of `Improved`: significant, interval below zero, and at
  /// least half the minimum detectable effect in the harmful direction.
  Harmed(effect: Float, ci: #(Float, Float), p: Float, mde: Float)

  /// Neither, and the design was powered to see the target effect: the
  /// arms are the same as far as this plan can tell.
  Indistinguishable(effect: Float, ci: #(Float, Float), p: Float, mde: Float)

  /// Neither, and the design could not have seen the target effect; or
  /// fewer than two tasks, where no variance exists. `needed_tasks` is the
  /// task count at which the observed variance would make the target
  /// visible.
  Underpowered(mde: Float, needed_tasks: Int)

  /// The plan's rows are not all present, or are present twice, or a row
  /// exists the plan never declared. The reason names the first such row.
  Incomplete(reason: String)
}

/// Whether the sequential futility check lets the run continue.
pub type Stop {
  /// The remaining pairs could still move the sign test across `α` in
  /// either direction.
  Continue

  /// Even if every remaining pair favoured the leading arm, `p` could not
  /// fall below `α`: the plan can only end `Indistinguishable` or
  /// `Underpowered`, so the remaining spend buys nothing.
  StopIndistinguishable

  /// Even if every remaining pair went against the leading arm, `p` could
  /// not rise to `α`: the sign test is settled and the verdict can be
  /// formed now.
  StopDecided
}

/// The default policy: a ten-point target effect and the clustered
/// interval.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.default_policy().target_effect == 0.1
/// ```
pub fn default_policy() -> Policy {
  Policy(target_effect: 0.1, interval: Clustered)
}
