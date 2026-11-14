//// Bounded correctness check for the commit-cost benchmark.

import commit_cost_bench

/// Runs the benchmark's small two-backend correctness workload.
///
/// ## Examples
///
/// `cd packages/runtime && gleam run -m commit_cost_bench_smoke`
pub fn main() -> Nil {
  commit_cost_bench.smoke()
}
