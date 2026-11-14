//// Runs the pending-read benchmark's real setup, reads and teardown.

import pending_read_bench

/// Checks both backends and a width spanning multiple bounded batches.
///
/// ## Examples
///
/// ```gleam
/// // Run with `gleam run -m pending_read_bench_smoke`.
/// ```
pub fn main() {
  pending_read_bench.smoke()
}
