//// What decoding a capture costs as the session's strand count grows.
////
//// A pushed notice makes the lane read a fresh cut and fold it, so the cost
//// of one cut is paid on every commit while a session streams. Decoding the
//// cut and projecting its roster used to look each strand's registers up by
//// scanning every cell of the cut, which made both quadratic in the number
//// of strands: decoding a cut of 150 strands cost 65 times what decoding 6
//// did, where a per-strand cost would be 25 times.
////
//// The assertions compare two sizes of the same fixture and never an
//// absolute figure. Quadrupling the strands is allowed to cost about four
//// times as much; the bound is generous enough to ignore the fixed part of
//// a fold and tight enough that a scan of the cut per strand fails it.
//// Scheduler reductions
//// are read from the runtime rather than a clock, so unrelated host load
//// cannot turn a complexity regression into a timing failure.
////
//// The fixture is `tui_agents_dev.scale_model`, the same cut the
//// `scripts/tui_perf.sh scale` benchmark measures. The decoder bounds a cut
//// at 1024 cells, so the larger size stays beneath that.

import gleam/erlang/process
import tui_agents_dev

// Scheduler accounting has no pure Gleam equivalent; the shared test probe
// reads OTP's own reductions for one process.
@external(erlang, "tui_probe_ffi", "reductions")
fn reductions(pid: process.Pid) -> Int

const small = 40

const large = 160

// Four times the strands may cost about four times the work. A fold that
// scans the cut for each strand costs about sixteen times, so the bound sits
// between the two with room for the fixed cost both sizes share.
fn within_linear(small_cost: Int, large_cost: Int) -> Bool {
  large_cost < small_cost * 6
}

// Reductions the shipped decoder spends on a cut of this many strands.
fn decode_reductions(strands: Int) -> Int {
  let captured = tui_agents_dev.scale_capture(strands, 1)
  let before = reductions(process.self())
  let view = tui_agents_dev.scale_decode(captured)
  let used = reductions(process.self()) - before
  assert view.strands != []
  used
}

pub fn decoding_a_cut_grows_linearly_with_its_strands_test() {
  assert within_linear(decode_reductions(small), decode_reductions(large))
    as "decoding a cut must not scan every cell for each strand"
}
