//// Runs the benchmark's actual memory workload and shutdown path.

import register_read_bench

/// Runs the benchmark's memory workload and checks its teardown.
///
/// ## Examples
///
/// ```gleam
/// // Run with `gleam run -m register_read_bench_smoke`.
/// ```
pub fn main() {
  register_read_bench.smoke()
}
