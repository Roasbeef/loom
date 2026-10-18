//// Tests for counting and walking interleavings.

import statem.{Admit, Reject}
import statem_parallel/internal/interleave

pub fn the_count_is_the_multinomial_test() {
  assert interleave.count([]) == 1
  assert interleave.count([3]) == 1
  assert interleave.count([1, 1]) == 2
  assert interleave.count([2, 2]) == 6
  assert interleave.count([4, 4]) == 70
  assert interleave.count([1, 1, 1]) == 6
  assert interleave.count([4, 4, 4]) == 34_650
  assert interleave.count([6, 6, 6]) == 17_153_136
}

pub fn an_empty_branch_changes_nothing_test() {
  assert interleave.count([0, 3, 2]) == interleave.count([3, 2])
}

/// A model that is the count of `Take` commands so far; `Take` is only
/// admissible while the count is below `limit`.
type Cmd {
  Take
  Give
}

fn limited(limit: Int) -> fn(Int, Cmd) -> statem.Admission {
  fn(count, cmd) {
    case cmd {
      Give -> Admit
      Take ->
        case count < limit {
          True -> Admit
          False -> Reject
        }
    }
  }
}

fn next(count: Int, cmd: Cmd) -> Int {
  case cmd {
    Take -> count + 1
    Give -> count
  }
}

pub fn no_branches_are_admissible_test() {
  assert interleave.admissible(limited(0), next, 0, []) == Admit
  assert interleave.admissible(limited(0), next, 0, [[], []]) == Admit
}

pub fn a_command_must_hold_in_every_interleaving_test() {
  // Each branch is one Take. Alone either is fine under a limit of one, but
  // whichever goes second sees a count of one and is rejected.
  assert interleave.admissible(limited(1), next, 0, [[Take], [Take]]) == Reject
  assert interleave.admissible(limited(2), next, 0, [[Take], [Take]]) == Admit
}

pub fn a_late_command_is_checked_against_the_other_branchs_effect_test() {
  // Branch 0 is Give then Take; branch 1 is Take. Under a limit of one, the
  // order [branch 1, Give, Take] rejects the last Take, though in branch 0
  // alone it was fine.
  assert interleave.admissible(limited(1), next, 0, [[Give, Take], [Take]])
    == Reject
}

pub fn branch_order_is_kept_test() {
  // Give-before-Take is the only order branch 0 allows, so a limit that only
  // the first Take can meet is met by every interleaving that has it first.
  assert interleave.admissible(limited(1), next, 0, [[Take, Give, Give]])
    == Admit
}
