//// The exact sign test against hand-computed binomial tails.

import evalstat/binomial
import evalstat/mcnemar.{Discordant}
import gleam/float

/// Five `(b, c)` pairs whose two-sided exact p-values were computed by hand
/// from `Σ_{i ≤ min(b,c)} C(b+c, i) / 2^(b+c)`:
///
/// | b | c  | tail        | p             |
/// |---|----|-------------|---------------|
/// | 0 | 5  | 1/32        | 0.0625        |
/// | 1 | 7  | 9/256       | 0.0703125     |
/// | 2 | 10 | 79/4096     | 0.03857421875 |
/// | 3 | 3  | 42/64       | 1 (clamped)   |
/// | 4 | 12 | 2517/65536  | 0.0768127...  |
pub fn mcnemar_exact_matches_binomial_table_test() {
  assert close(mcnemar.p_value(Discordant(0, 5)), 0.0625)
  assert close(mcnemar.p_value(Discordant(1, 7)), 0.0703125)
  assert close(mcnemar.p_value(Discordant(2, 10)), 0.03857421875)
  assert close(mcnemar.p_value(Discordant(3, 3)), 1.0)
  assert close(mcnemar.p_value(Discordant(4, 12)), 0.076812744140625)
}

/// The test is symmetric in its two counts and gives `p = 1` with no
/// discordant pair at all.
pub fn mcnemar_is_symmetric_and_total_test() {
  assert mcnemar.p_value(Discordant(0, 0)) == 1.0
  assert mcnemar.p_value(Discordant(7, 1)) == mcnemar.p_value(Discordant(1, 7))
}

/// `log_choose` agrees with small coefficients and refuses an undefined one.
pub fn log_choose_matches_small_coefficients_test() {
  assert binomial.log_choose(5, 2) == Ok(2.302585092994046)
  assert binomial.log_choose(5, 0) == Ok(0.0)
  assert binomial.log_choose(5, 5) == Ok(0.0)
  assert binomial.log_choose(3, 4) == Error(Nil)
  assert binomial.log_choose(3, -1) == Error(Nil)
  let ok = case binomial.log_choose(1000, 500) {
    Ok(x) -> close(x, 689.4672615678512)
    Error(Nil) -> False
  }
  assert ok
}

/// The half-binomial tail at its edges.
pub fn half_cdf_edges_test() {
  assert binomial.half_cdf(2, 0) == 0.25
  assert binomial.half_cdf(4, 4) == 1.0
  assert binomial.half_cdf(4, -1) == 0.0
  assert close(binomial.half_cdf(4, 2), 0.6875)
}

fn close(actual: Float, expected: Float) -> Bool {
  float.loosely_equals(actual, expected, 0.000000001)
}
