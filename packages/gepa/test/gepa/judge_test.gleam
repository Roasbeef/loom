//// The default acceptance rule and its pairing.

import gepa/judge.{Pair}
import gepa/verdict
import gleam/float
import gleam/int
import gleam/list

fn tasks(count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, i) { "t" <> int.to_string(i) })
}

pub fn pairs_drop_tasks_missing_on_either_side_test() {
  assert judge.pairs(["a", "b", "c"], [#("a", 0.0), #("b", 0.5)], [
      #("a", 1.0),
      #("c", 1.0),
    ])
    == [Pair("a", 0.0, 1.0)]
  assert judge.pairs([], [], []) == []
}

pub fn the_sign_test_needs_six_unanimous_tasks_at_five_percent_test() {
  let better = fn(n) { list.map(tasks(n), fn(t) { Pair(t, 0.0, 1.0) }) }
  let worse = fn(n) { list.map(tasks(n), fn(t) { Pair(t, 1.0, 0.0) }) }

  assert judge.sign_test(better(6)) == verdict.Improved
  assert judge.sign_test(better(5)) == verdict.Inconclusive
  assert judge.sign_test(worse(6)) == verdict.Harmed
  assert judge.sign_test([]) == verdict.Incomplete

  // All ties: nothing to test, and no direction.
  assert judge.sign_test(list.map(tasks(6), fn(t) { Pair(t, 0.5, 0.5) }))
    == verdict.Inconclusive
}

pub fn the_sign_p_value_is_the_exact_binomial_tail_test() {
  assert judge.sign_p_value(0, 0) == 1.0
  assert float.loosely_equals(judge.sign_p_value(5, 0), 0.0625, 1.0e-12)
  assert float.loosely_equals(judge.sign_p_value(6, 0), 0.03125, 1.0e-12)
  assert float.loosely_equals(judge.sign_p_value(7, 1), 0.0703125, 1.0e-12)
  assert judge.sign_p_value(3, 3) == 1.0
}
