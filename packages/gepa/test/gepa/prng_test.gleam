//// The generator is one stream on both targets, and the same stream as
//// Loom's `evalstat/prng`: the pinned values below are the ones
//// `evalstat`'s own test pins, so a divergence in either copy fails here.

import gepa/prng
import gleam/list

fn first(state: prng.Prng, count: Int) -> List(Int) {
  list.repeat(Nil, count)
  |> list.map_fold(state, fn(state, _) {
    let #(value, state) = prng.next(state)
    #(state, value)
  })
  |> fn(pair) { pair.1 }
}

pub fn first_outputs_are_fixed_test() {
  assert first(prng.from_string("plan-7"), 5)
    == [3_328_727_011, 854_765_265, 2_031_767_140, 3_591_210_419, 1_381_894_110]
  assert first(prng.from_string(""), 3)
    == [2_134_968_305, 3_299_269_269, 1_556_867_208]
}

pub fn outputs_stay_within_32_bits_test() {
  let outputs = first(prng.from_string("bits"), 10_000)
  assert list.all(outputs, fn(x) { x >= 0 && x < 4_294_967_296 })
}

pub fn below_respects_bound_and_does_not_advance_on_a_degenerate_one_test() {
  let state = prng.from_string("bound")
  let #(after, _) =
    list.repeat(Nil, 1000)
    |> list.map_fold(state, fn(state, _) {
      let #(value, state) = prng.below(state, 7)
      assert value >= 0 && value < 7
      #(state, value)
    })
  assert prng.below(after, 1) == #(0, after)
  assert prng.below(after, 0) == #(0, after)
}

pub fn fnv1a_offset_basis_is_the_empty_hash_test() {
  assert prng.fnv1a("") == 0x811C9DC5
  assert prng.fnv1a("a") != prng.fnv1a("b")
}
