//// The generator is one stream on both targets: these constants were
//// computed independently (a reference xorshift128 and FNV-1a over code
//// points) and the suite runs under `--target erlang` and
//// `--target javascript`, so a target whose bitwise arithmetic rounded
//// would fail here before any bootstrap could disagree.

import evalstat/prng
import gleam/list

/// `fnv1a` matches the reference hash, offset basis included.
pub fn fnv1a_matches_reference_test() {
  assert prng.fnv1a("") == 0x811C9DC5
  assert prng.fnv1a("a") == 3_826_002_220
  assert prng.fnv1a("plan-7") == 1_426_497_774
}

/// The first outputs for two seeds are pinned, so the stream can never
/// drift between targets or releases without this test saying so.
pub fn prng_first_outputs_are_fixed_test() {
  assert first(prng.from_string("plan-7"), 5)
    == [3_328_727_011, 854_765_265, 2_031_767_140, 3_591_210_419, 1_381_894_110]
  assert first(prng.from_string(""), 3)
    == [2_134_968_305, 3_299_269_269, 1_556_867_208]
}

/// Every output stays inside 32 bits over a long run, which is the
/// invariant the JavaScript exactness argument rests on.
pub fn outputs_stay_within_32_bits_test() {
  let outputs = first(prng.from_string("bits"), 10_000)
  assert list.all(outputs, fn(x) { x >= 0 && x < 4_294_967_296 })
}

/// `below` respects its bound and does not advance on a degenerate bound.
pub fn below_respects_bound_test() {
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

/// `unit` lands in `[0, 1)`.
pub fn unit_is_in_range_test() {
  let #(_, values) =
    list.repeat(Nil, 1000)
    |> list.map_fold(prng.from_string("unit"), fn(state, _) {
      let #(u, state) = prng.unit(state)
      #(state, u)
    })
  assert list.all(values, fn(u) { u >=. 0.0 && u <. 1.0 })
}

fn first(state: prng.Prng, count: Int) -> List(Int) {
  let #(_, values) =
    list.repeat(Nil, count)
    |> list.map_fold(state, fn(state, _) {
      let #(value, state) = prng.next(state)
      #(state, value)
    })
  values
}
