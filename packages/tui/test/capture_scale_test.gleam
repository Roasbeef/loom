//// What one capture costs as the session's strand count grows.
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
//// Scheduler reductions are read from the runtime rather than a clock, so
//// unrelated host load cannot turn a complexity regression into a timing
//// failure. The reductions are deterministic enough that the measured ratio
//// moves by about a hundredth between runs.
////
//// The fixture is `tui_agents_dev.scale_model`, the same cut the
//// `scripts/tui_perf.sh scale` benchmark measures. The decoder bounds a cut
//// at 1024 cells, so the larger size stays beneath that.

import gleam/erlang/process
import gleam/option.{Some}
import session_view/shared_set
import tui/model as tui_model
import tui_agents_dev

// Scheduler accounting has no pure Gleam equivalent; the shared test probe
// reads OTP's own reductions for one process.
@external(erlang, "tui_probe_ffi", "reductions")
fn reductions(pid: process.Pid) -> Int

const small = 40

const large = 160

// Four times the strands may cost about four times the work. The decode and
// the fold each measure about 3.8 times, below four because a part of the
// cost is fixed. A scan of the cut for each strand measured about 6.3 times
// before the roster was indexed, so the bound of five sits between the two
// with room for the fixed cost both sizes share.
fn within_linear(small_cost: Int, large_cost: Int) -> Bool {
  large_cost < small_cost * 5
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

// Reductions the lane fold spends adopting a changed cut over a model that
// already holds the previous one, as it does on each pushed notice.
fn fold_reductions(strands: Int) -> Int {
  fold_model_reductions(tui_agents_dev.scale_model(strands), strands)
}

fn fold_model_reductions(model: tui_model.Model, strands: Int) -> Int {
  let assert Some(#(previous, _)) = model.shared.captured
    as "the scale model must already hold a cut"
  let captured = tui_agents_dev.scale_capture(strands, 1)
  let view = tui_agents_dev.scale_decode(captured)
  assert previous.next_seq != captured.next_seq
  let before = reductions(process.self())
  let folded = tui_agents_dev.scale_apply(model, captured, view)
  let used = reductions(process.self()) - before

  // The fold must have adopted the new cut, or it measured a refusal.
  let assert Some(#(adopted, _)) = folded.shared.captured
    as "the fold must keep the cut it adopted"
  assert adopted.next_seq == captured.next_seq
  used
}

pub fn folding_a_cut_grows_linearly_with_its_strands_test() {
  assert within_linear(fold_reductions(small), fold_reductions(large))
    as "the roster projection must not scan the cut for each strand"
}

// The model with the streaming tails of its live agents removed, so the cost
// of retiring them can be read as the difference between the two folds.
fn without_tails(model: tui_model.Model) -> tui_model.Model {
  tui_model.Model(
    shared: shared_set.tool_tails(model.shared, []),
    view: model.view,
  )
}

// Every live agent carries a streaming tail, and each tail asks whether the
// cut holds its call's result. That answer reads the window and the cells, and
// each tail used to rebuild both, which cost a tenth of the whole fold at the
// large size. Indexed once for the cut, retiring all of them costs about one
// percent, so the bound of four percent separates the two with room.
pub fn retiring_every_tail_is_a_small_part_of_the_fold_test() {
  let model = tui_agents_dev.scale_model(large)
  let with_tails = fold_model_reductions(model, large)
  let base = fold_model_reductions(without_tails(model), large)
  assert with_tails > base
    as "the fixture must carry tails for the fold to test"
  assert { with_tails - base } * 100 < base * 4
    as "retiring a tail must not rebuild the window or scan the cells"
}
