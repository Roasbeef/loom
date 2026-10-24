//// Counting and checking the interleavings of parallel branches.
////
//// A parallel case is only a fair test if every command is meaningful in the
//// model it will actually meet. A branch's commands are drawn against the
//// model after the prefix, as if the branch ran alone, but at run time the
//// other branches' commands may land between them. A command that was
//// admissible alone can find, say, an empty queue because a sibling branch
//// got there first, and a case that can do that tests the harness's own
//// preconditions instead of the system. So a case is admissible only if every
//// command's precondition holds in EVERY interleaving that keeps each
//// branch's order. This module counts those interleavings, so a caller can
//// refuse to enumerate an astronomical number, and walks them.
////
//// `count` is the multinomial coefficient, built from `choose`'s binomials, which `choose_loop` multiplies out.
////
//// The module is pure and knows nothing of `Spec` or `Case`: it takes the two
//// model functions and the branches as plain lists, so it can be tested
//// without a system and reused by the generator and the shrinker alike.

import gleam/list
import statem.{type Admission, Admit, Reject}

/// How many interleavings branches of these lengths have, keeping each
/// branch's own order: the multinomial coefficient. Branches of length 4 and
/// 4 give 70, and 4, 4 and 4 give 34650.
///
/// ## Examples
///
/// ```gleam
/// interleave.count([2, 2])
/// // 6
/// ```
pub fn count(lengths: List(Int)) -> Int {
  count_loop(lengths, 0, 1)
}

/// Fold the lengths in one at a time: adding a branch of `n` commands to
/// `total` already-placed ones multiplies the count by `choose(total + n, n)`,
/// the ways to pick which of the combined slots the new branch takes.
fn count_loop(lengths: List(Int), total: Int, product: Int) -> Int {
  case lengths {
    [] -> product
    [length, ..rest] ->
      count_loop(rest, total + length, product * choose(total + length, length))
  }
}

/// `n` choose `k`, computed multiplicatively so every intermediate value is
/// itself a binomial coefficient and the division is exact.
fn choose(n: Int, k: Int) -> Int {
  choose_loop(n, k, 1, 1)
}

/// Multiply in factor `i` of `k`: after `i` steps `acc` is `choose(n - k + i,
/// i)`, which is why the division by `i` is always exact.
fn choose_loop(n: Int, k: Int, i: Int, acc: Int) -> Int {
  case i > k {
    True -> acc
    False -> choose_loop(n, k, i + 1, acc * { n - k + i } / i)
  }
}

/// Whether every command's precondition holds in every interleaving of the
/// branches that starts from `model`. The first interleaving to break one
/// answers `Reject`. The walk threads the model through each choice of which
/// branch goes next, so a shared prefix of two interleavings is evaluated
/// once; its cost is still the number of interleavings, which is why callers
/// bound `count` first.
///
/// ## Examples
///
/// ```gleam
/// interleave.admissible(precondition, next_model, model, [[Pop], [Pop]])
/// ```
pub fn admissible(
  precondition: fn(model, cmd) -> Admission,
  next_model: fn(model, cmd) -> model,
  model: model,
  branches: List(List(cmd)),
) -> Admission {
  let live = list.filter(branches, fn(branch) { branch != [] })

  // Check whether any live branches remain to test for admissibility.
  case live {
    [] -> Admit
    _ -> any_head(precondition, next_model, model, live, [])
  }
}

/// Try each branch's head as the next command, with the branches that have
/// already been tried held in `before` so the others can be put back in their
/// original order. Every head must be admissible and every continuation must
/// be too.
fn any_head(
  precondition: fn(model, cmd) -> Admission,
  next_model: fn(model, cmd) -> model,
  model: model,
  after: List(List(cmd)),
  before: List(List(cmd)),
) -> Admission {
  case after {
    [] -> Admit

    [[head, ..tail], ..others] ->
      case precondition(model, head) {
        Reject -> Reject

        Admit ->
          case
            admissible(
              precondition,
              next_model,
              next_model(model, head),
              list.append(list.reverse(before), [tail, ..others]),
            )
          {
            Reject -> Reject

            Admit ->
              any_head(precondition, next_model, model, others, [
                [head, ..tail],
                ..before
              ])
          }
      }

    // A live branch is never empty, so this arm only keeps the match total.
    [[], ..others] -> any_head(precondition, next_model, model, others, before)
  }
}
