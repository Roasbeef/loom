//// Tests for the linearizability checker, on hand-built histories.
////
//// The system is a counter: `Inc` returns the new value and `Read` returns
//// the current one. Every history below is written out by hand, with the
//// instants chosen to make one rule decide the answer, so a failure names
//// the rule that broke. The checker is pure, so these run on both targets.

import gleam/int
import gleam/list
import statem.{Violation}
import statem/linearize.{
  type Event, type Explanation, type Verdict, Blocked, Event, Explanation,
  Linearizable, Machine, NotLinearizable, Overtaken, Placed, Undecided, Violated,
}

type Cmd {
  Inc
  Read
}

/// The counter model: the value so far.
fn machine() -> linearize.Machine(Int, Cmd, Int) {
  Machine(
    next_model: fn(count, cmd) {
      case cmd {
        Inc -> count + 1
        Read -> count
      }
    },
    postcondition: fn(count, cmd, response) {
      let expected = case cmd {
        Inc -> count + 1
        Read -> count
      }

      case response == expected {
        True -> Ok(Nil)
        False ->
          Error(Violation(
            tag: "counter",
            detail: "expected "
              <> int.to_string(expected)
              <> " got "
              <> int.to_string(response),
          ))
      }
    },
  )
}

fn event(cmd: Cmd, response: Int, from: Int, to: Int) -> Event(Cmd, Int) {
  Event(cmd: cmd, response: response, invoked_at: from, returned_at: to)
}

fn check(branches: List(List(Event(Cmd, Int)))) -> Verdict(Cmd, Int) {
  linearize.check(machine(), 0, branches, linearize.default_budget)
}

fn explanation_of(verdict: Verdict(Cmd, Int)) -> Explanation(Cmd, Int) {
  case verdict {
    NotLinearizable(explanation) -> explanation
    Linearizable(_) -> panic as "expected NotLinearizable, got Linearizable"
    Undecided(_) -> panic as "expected NotLinearizable, got Undecided"
  }
}

fn responses(verdict: Verdict(Cmd, Int)) -> List(#(Int, Int)) {
  case verdict {
    Linearizable(order) ->
      list.map(order, fn(placed) { #(placed.branch, placed.event.response) })
    NotLinearizable(_) -> panic as "expected Linearizable, got NotLinearizable"
    Undecided(_) -> panic as "expected Linearizable, got Undecided"
  }
}

pub fn no_calls_at_all_is_linearizable_test() {
  assert check([]) == Linearizable([])
  assert check([[], []]) == Linearizable([])
}

pub fn one_branch_in_order_is_linearizable_test() {
  let verdict = check([[event(Inc, 1, 0, 1), event(Read, 1, 2, 3)]])

  assert responses(verdict) == [#(0, 1), #(0, 1)]
}

pub fn a_branch_keeps_its_own_order_test() {
  // Inc -> 2 then Inc -> 1 would be fine in the other order. Within a
  // branch it is not allowed, because the caller issued them in sequence.
  let explanation =
    check([[event(Inc, 2, 0, 1), event(Inc, 1, 2, 3)]]) |> explanation_of

  assert explanation.placed == []
  assert list.length(explanation.blocked) == 1
}

pub fn overlapping_calls_may_take_effect_in_either_order_test() {
  // Branch 0 saw 2 and branch 1 saw 1, and the calls overlap, so branch 1's
  // call took effect first. The order found says so.
  let verdict = check([[event(Inc, 2, 0, 10)], [event(Inc, 1, 0, 10)]])

  assert responses(verdict) == [#(1, 1), #(0, 2)]
}

pub fn two_increments_that_both_saw_one_are_not_linearizable_test() {
  let explanation =
    check([[event(Inc, 1, 0, 10)], [event(Inc, 1, 0, 10)]])
    |> explanation_of

  // One of them can go first; the other then has nowhere to go.
  assert list.length(explanation.placed) == 1
  assert list.length(explanation.blocked) == 1

  let assert [Blocked(obstacle: Violated(violation), ..)] = explanation.blocked
  assert violation.tag == "counter"
}

pub fn real_time_forbids_an_order_the_model_would_allow_test() {
  // Branch 0's call returned at 5, before branch 1's call began at 10, so it
  // must take effect first. The model wants branch 1's call (which saw 1)
  // first, so with the clock in play there is no order, while without it
  // there would be one.
  let verdict = check([[event(Inc, 2, 0, 5)], [event(Inc, 1, 10, 15)]])
  let explanation = explanation_of(verdict)

  assert explanation.placed == []

  let reasons =
    list.map(explanation.blocked, fn(blocked) {
      case blocked.obstacle {
        Violated(_) -> "violated"
        Overtaken(branch, index) ->
          "overtaken by "
          <> int.to_string(branch)
          <> "."
          <> int.to_string(index)
      }
    })

  assert reasons == ["violated", "overtaken by 0.0"]
}

pub fn real_time_is_satisfied_by_the_matching_order_test() {
  let verdict = check([[event(Inc, 1, 0, 5)], [event(Inc, 2, 10, 15)]])

  assert responses(verdict) == [#(0, 1), #(1, 2)]
}

pub fn a_shared_instant_counts_as_overlap_test() {
  // Returned at 5 and invoked at 5: a coarse clock cannot say which came
  // first, so the calls are treated as concurrent and the order the model
  // wants is allowed.
  let verdict = check([[event(Inc, 2, 0, 5)], [event(Inc, 1, 5, 9)]])

  assert responses(verdict) == [#(1, 1), #(0, 2)]
}

pub fn three_branches_are_ordered_together_test() {
  let verdict =
    check([
      [event(Inc, 3, 0, 9)],
      [event(Inc, 1, 0, 9)],
      [event(Inc, 2, 0, 9)],
    ])

  assert responses(verdict) == [#(1, 1), #(2, 2), #(0, 3)]
}

pub fn the_explanation_names_the_deepest_dead_end_test() {
  // Branch 0 is Inc -> 1 then Inc -> 2 and branch 1 is a lone Inc -> 1. The
  // best the search manages is both of branch 0's calls, after which the
  // lone call cannot have seen 1. Other orders die at depth 0 or 1.
  let explanation =
    check([
      [event(Inc, 1, 0, 10), event(Inc, 2, 11, 20)],
      [event(Inc, 1, 0, 30)],
    ])
    |> explanation_of

  let Explanation(placed, blocked) = explanation

  assert list.map(placed, fn(p) { #(p.branch, p.index) }) == [#(0, 0), #(0, 1)]
  assert list.map(blocked, fn(b) { #(b.placed.branch, b.placed.index) })
    == [#(1, 0)]
}

pub fn a_violation_carries_the_postconditions_own_tag_test() {
  let verdict = check([[event(Read, 5, 0, 1)]])
  let explanation = explanation_of(verdict)

  let assert [Blocked(placed: Placed(0, 0, _), obstacle: Violated(violation))] =
    explanation.blocked
  assert violation == Violation("counter", "expected 0 got 5")
}

/// Three branches of reads that all agree for six calls and then one read
/// that cannot be right. The interleavings of the good prefix number about
/// seventeen million, but the distinct states number 343, which is what the
/// memory of failed states is for.
fn doomed_branches() -> List(List(Event(Cmd, Int))) {
  let good =
    list.index_map(list.repeat(Nil, 6), fn(_, i) { event(Read, 0, i, i + 100) })
  let bad = event(Read, 7, 6, 106)

  [list.append(good, [bad]), list.append(good, [bad]), list.append(good, [bad])]
}

pub fn failed_states_are_remembered_test() {
  let verdict = linearize.check(machine(), 0, doomed_branches(), 5000)

  let Explanation(placed, _) = explanation_of(verdict)

  assert list.length(placed) == 18
}

pub fn an_exhausted_budget_is_undecided_not_a_pass_test() {
  let verdict = linearize.check(machine(), 0, doomed_branches(), 10)

  assert verdict == Undecided(10)
}

pub fn the_budget_counts_postcondition_evaluations_test() {
  // One call needs exactly one evaluation: a budget of one decides it, a
  // budget of zero cannot.
  let one = [[event(Inc, 1, 0, 1)]]

  assert linearize.check(machine(), 0, one, 1)
    == Linearizable([Placed(0, 0, event(Inc, 1, 0, 1))])
  assert linearize.check(machine(), 0, one, 0) == Undecided(0)
}

pub fn a_branch_may_start_from_a_later_model_test() {
  // The initial model is the model after a sequential prefix.
  let verdict =
    linearize.check(
      machine(),
      4,
      [[event(Inc, 5, 0, 1)]],
      linearize.default_budget,
    )

  assert responses(verdict) == [#(0, 5)]
}
