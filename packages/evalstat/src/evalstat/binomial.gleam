//// Exact binomial arithmetic for the sign test and the pass@k estimators.
////
//// Both callers need `C(n, k)` for `n` up to a thousand, where the raw
//// coefficient overflows a double long before `n` does. Everything is
//// therefore computed in logarithms, as a sum of `ln((n − k + i) / i)`
//// terms, which is exact to a few units in the last place for the sizes
//// the instrument produces and needs no gamma-function approximation. The
//// alternative, a normal approximation to the binomial, is what the design
//// rules out for the sign test: the discordant count is tens, not
//// thousands, and the approximation is worst exactly there.
////
//// Every ratio whose logarithm is taken is above zero, so
//// `float.logarithm` cannot fail; its `Result` is collapsed by
//// `result_or_zero` rather than threaded through callers that could never
//// observe the `Error`.

import gleam/float
import gleam/int

/// `ln 2`, the per-trial log-probability of a fair coin.
const ln2 = 0.6931471805599453

/// `ln C(n, k)`, or `Error` when the coefficient is undefined (`k < 0` or
/// `k > n`). Linear in `min(k, n − k)`.
///
/// ## Examples
///
/// ```gleam
/// assert binomial.log_choose(5, 2) == Ok(2.302585092994046)
/// ```
///
/// ```gleam
/// assert binomial.log_choose(3, 4) == Error(Nil)
/// ```
pub fn log_choose(n: Int, k: Int) -> Result(Float, Nil) {
  case k < 0 || k > n {
    True -> Error(Nil)
    False -> Ok(log_choose_in_range(n, k))
  }
}

/// `P[X ≤ m]` for `X ~ Binomial(n, ½)`: the tail the exact sign test
/// reads. Below zero the mass is nothing; at or above `n` it is everything.
///
/// ## Examples
///
/// ```gleam
/// assert binomial.half_cdf(2, 0) == 0.25
/// ```
///
/// ```gleam
/// assert binomial.half_cdf(4, 4) == 1.0
/// ```
pub fn half_cdf(n: Int, m: Int) -> Float {
  case m < 0, m >= n {
    True, _ -> 0.0
    False, True -> 1.0

    // Each term is C(n, i) / 2^n, summed in probability space after the
    // coefficient is formed in log space; rounding can carry the sum a
    // hair over one, which the clamp removes so a p-value never exceeds
    // its own definition.
    False, False ->
      int.range(0, m + 1, 0.0, fn(sum, i) {
        sum
        +. float.exponential(
          log_choose_in_range(n, i) -. int.to_float(n) *. ln2,
        )
      })
      |> float.min(1.0)
  }
}

/// `ln C(n, k)` for `0 ≤ k ≤ n`, folded over the shorter side of the
/// symmetry so the sum is never longer than `n / 2` terms. Each term's
/// logarithm is of a ratio above zero, so `float.logarithm` cannot fail
/// here, and the fallback it is given is never reached.
fn log_choose_in_range(n: Int, k: Int) -> Float {
  let k = int.min(k, n - k)
  int.range(1, k + 1, 0.0, fn(sum, i) {
    let ratio = int.to_float(n - k + i) /. int.to_float(i)
    sum +. result_or_zero(float.logarithm(ratio))
  })
}

/// Collapses the impossible `Error` of a logarithm over a positive ratio.
fn result_or_zero(value: Result(Float, Nil)) -> Float {
  case value {
    Ok(x) -> x
    Error(Nil) -> 0.0
  }
}
