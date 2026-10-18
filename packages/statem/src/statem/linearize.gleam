//// A linearizability checker: is there one sequential story for what several
//// concurrent callers saw?
////
//// A concurrent test cannot say which of the possible orders a system took.
//// What it can record is each caller's own history: the calls one caller
//// made, in the order it made them, with the response each got and the
//// instants it invoked and returned. A system is linearizable when those
//// histories can be merged into a single sequence in which every call takes
//// effect at one point between its invocation and its return, and every
//// response is the one the sequential model gives at that point. This module
//// searches for such a sequence. It is the oracle half of the parallel layer
//// in `statem_parallel`, and it is pure: it runs nothing, reads no clock, and
//// holds no `@external`, so it is tested on both targets and obeys R6 like
//// the rest of `statem`.
////
//// ## What a merge must respect
////
//// Three rules decide whether a total order is a valid story. Calls of one
//// branch keep their order, because a caller issues its next call only after
//// the previous one returned. Real time is honoured: a call that returned
//// strictly before another was invoked must come first, because a caller who
//// saw the first finish cannot have it take effect later. And at its position
//// every call's postcondition must hold against the model the calls before it
//// produced. The first rule is why a history is a list of branches, the second
//// is why every `Event` carries two instants, and the third is the model.
////
//// The instants are plain integers in any unit the caller likes, so long as
//// they come from one monotonic clock. A call whose return instant equals
//// another's invocation instant is treated as overlapping it, never as
//// preceding it, which is the safe reading for a coarse clock: it admits more
//// orders, so a coarse clock can hide a bug but never invent one.
////
//// ## The search
////
//// The search is a depth-first walk over the choice of which branch's next
//// call takes effect next. Only the first unplaced call of each branch is a
//// candidate, so the branching factor is the number of branches. A candidate
//// is skipped without evaluating anything when another branch's first
//// unplaced call returned before it was invoked, since that call must go
//// first. Otherwise its postcondition is evaluated against the current model,
//// which is the unit of work the node budget counts. A state is identified by
//// where each branch stands plus the model, and a state that has failed once
//// is remembered, so two different orders that reach the same state share one
//// refutation. That is sound because both rules and the model's evolution
//// depend on nothing else.
////
//// ## Three answers
////
//// `Linearizable` carries the order found. `NotLinearizable` carries an
//// `Explanation` built from the deepest dead end the search reached, meaning
//// the longest prefix of the history that could be placed, and what stopped
//// each branch from continuing there. `Undecided` means the node budget ran
//// out first: the search neither found an order nor exhausted the space, and
//// a caller must treat it as a failure rather than a pass, because a budget
//// that quietly passed would make a deep history untestable by accident.
////
//// ## Flow
////
//// `check` → `search` → `attempt` → `blocked_by`
////
//// 1. `check` turns each branch's events into a `Lane` and starts `search`
////    from the empty order and the initial model.
//// 2. `search` stops when every lane is empty, answers from the failed-state
////    memory if it can, and otherwise tries the lanes' heads through
////    `attempt`.
//// 3. `attempt` asks `blocked_by` whether real time forbids a head, then the
////    postcondition whether the model allows it, and recurses on success.
//// 4. A state with no placeable head is a dead end; `record_dead_end` keeps
////    the deepest one for the explanation.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import statem.{type Violation}

// --- the question ---------------------------------------------------------

/// One call as one caller saw it.
pub type Event(cmd, response) {
  Event(
    /// What was asked.
    cmd: cmd,
    /// What came back.
    response: response,
    /// The instant the caller invoked the call, on a monotonic clock.
    invoked_at: Int,
    /// The instant the call returned to the caller, on the same clock. Never
    /// before `invoked_at`.
    returned_at: Int,
  )
}

/// The sequential model the histories are checked against.
pub type Machine(model, cmd, response) {
  Machine(
    /// The model after a command. Pure.
    next_model: fn(model, cmd) -> model,
    /// Whether `response` is acceptable for `cmd` in the model as it was
    /// BEFORE the command. An `Error` names the rule it broke.
    postcondition: fn(model, cmd, response) -> Result(Nil, Violation),
  )
}

/// The most postcondition evaluations a search may spend before it gives up
/// and answers `Undecided`.
pub const default_budget = 100_000

// --- the answers ----------------------------------------------------------

/// An event and where it came from.
pub type Placed(cmd, response) {
  Placed(
    /// The branch the event belongs to, counting from zero in the order the
    /// branches were given to `check`.
    branch: Int,
    /// The event's position within its branch, counting from zero.
    index: Int,
    /// The event itself.
    event: Event(cmd, response),
  )
}

/// Why one call could not take effect next.
pub type Obstacle {
  /// Its postcondition failed against the model at that position.
  Violated(
    /// The rule it broke, as the postcondition reported it.
    violation: Violation,
  )

  /// Real time forbids it: another branch's next call had already returned
  /// before this one was invoked, so that call must take effect first.
  Overtaken(
    /// The branch whose next call must go first.
    branch: Int,
    /// That call's position within its branch.
    index: Int,
  )
}

/// A call that could not be placed next, and why.
pub type Blocked(cmd, response) {
  Blocked(
    /// The call that was tried.
    placed: Placed(cmd, response),
    /// What stopped it.
    obstacle: Obstacle,
  )
}

/// Where the best attempt at ordering the history got stuck.
pub type Explanation(cmd, response) {
  Explanation(
    /// The longest prefix of the history the search managed to order, in
    /// order. Empty when no call could even go first.
    placed: List(Placed(cmd, response)),
    /// The first unplaced call of every branch that still had one, with the
    /// reason it could not take effect after `placed`. Every entry is
    /// blocked: if one could have gone, the prefix would have been longer.
    blocked: List(Blocked(cmd, response)),
  )
}

/// What `check` found.
pub type Verdict(cmd, response) {
  /// An order exists. Every event appears once, branch order is preserved,
  /// real time is respected, and every postcondition held.
  Linearizable(
    /// The events in the order they took effect.
    order: List(Placed(cmd, response)),
  )

  /// The search exhausted every order and none works.
  NotLinearizable(
    /// The deepest dead end, which names what to look at.
    explanation: Explanation(cmd, response),
  )

  /// The node budget ran out before the search could decide.
  Undecided(
    /// The postcondition evaluations spent, equal to the budget.
    nodes: Int,
  )
}

// --- the search -----------------------------------------------------------

/// A branch with some of its events still unplaced.
type Lane(cmd, response) {
  Lane(
    /// The branch's number, as given to `check`.
    branch: Int,
    /// How many of the branch's events are already placed.
    index: Int,
    /// The events not yet placed, never empty while the lane is live.
    events: List(Event(cmd, response)),
  )
}

/// What the search carries between branches of the walk, which is everything
/// that is learned rather than decided.
type Walk(model, cmd, response) {
  Walk(
    /// Postcondition evaluations so far, against the budget.
    nodes: Int,
    /// States already known to have no completion, keyed by where every live
    /// lane stands and the model.
    failed: Set(#(List(#(Int, Int)), model)),
    /// The deepest dead end so far, with how many calls it had placed.
    deepest: Option(#(Int, Explanation(cmd, response))),
  )
}

/// A lane's head, taken apart for placement.
type Head(cmd, response) {
  Head(
    /// The lane the head belongs to, before it advances.
    lane: Lane(cmd, response),
    /// The lanes still to be tried after this one.
    rest: List(Lane(cmd, response)),
    /// The head as a placed event, which is what an order or an obstacle
    /// reports.
    here: Placed(cmd, response),
    /// The lane's events after the head.
    later: List(Event(cmd, response)),
  )
}

/// How one subtree of the walk ended.
type Walked(model, cmd, response) {
  /// The remaining calls were ordered; the list is the whole order.
  Found(order: List(Placed(cmd, response)))

  /// No order completes this state; the walk carries what was learned.
  Dead(walk: Walk(model, cmd, response))

  /// The budget ran out inside this subtree.
  Overspent
}

/// What trying the lanes' heads one after another has seen so far.
type Tried(cmd, response) {
  Tried(
    /// The heads that could not go, newest first.
    blocked: List(Blocked(cmd, response)),
    /// How many heads passed both tests and were descended into. A state
    /// with none is a dead end.
    descended: Int,
  )
}

/// Decide whether the branches' histories can be merged into one valid
/// sequential order, spending at most `budget` postcondition evaluations.
/// `initial` is the model before the first call of any branch; a caller whose
/// branches follow a sequential prefix passes the model after it.
///
/// ## Examples
///
/// ```gleam
/// // Two increments of a counter that both claim to have produced 1.
/// let machine =
///   linearize.Machine(
///     next_model: fn(count, _) { count + 1 },
///     postcondition: fn(count, _, response) {
///       case response == count + 1 {
///         True -> Ok(Nil)
///         False -> Error(statem.Violation("counter", "wrong value"))
///       }
///     },
///   )
/// let one = linearize.Event(cmd: Nil, response: 1, invoked_at: 0, returned_at: 5)
///
/// let assert linearize.NotLinearizable(_) =
///   linearize.check(machine, 0, [[one], [one]], linearize.default_budget)
/// ```
pub fn check(
  machine: Machine(model, cmd, response),
  initial: model,
  branches: List(List(Event(cmd, response))),
  budget: Int,
) -> Verdict(cmd, response) {
  let lanes =
    branches
    |> list.index_map(fn(events, branch) {
      Lane(branch: branch, index: 0, events: events)
    })
    |> list.filter(fn(lane) { lane.events != [] })
  let walk = Walk(nodes: 0, failed: set.new(), deepest: None)

  case search(machine, budget, lanes, initial, [], walk) {
    Found(order) -> Linearizable(order)
    Overspent -> Undecided(budget)
    Dead(walk) -> NotLinearizable(explanation_of(walk))
  }
}

/// Place the next call, or find that no placement completes. Reaching a state
/// with no live lane is success: everything was ordered. A state already known
/// to fail is not walked again, which is the whole reason two interleavings
/// that converge cost one refutation between them.
fn search(
  machine: Machine(model, cmd, response),
  budget: Int,
  lanes: List(Lane(cmd, response)),
  model: model,
  placed: List(Placed(cmd, response)),
  walk: Walk(model, cmd, response),
) -> Walked(model, cmd, response) {
  use <- bool.lazy_guard(lanes == [], fn() { Found(list.reverse(placed)) })

  let key = #(list.map(lanes, fn(lane) { #(lane.branch, lane.index) }), model)
  use <- bool.lazy_guard(set.contains(walk.failed, key), fn() { Dead(walk) })

  let tried = Tried(blocked: [], descended: 0)

  case attempt(machine, budget, lanes, lanes, model, placed, walk, tried) {
    Found(order) -> Found(order)
    Overspent -> Overspent

    // Every way forward from here failed, so the state is remembered as
    // failed; a dead end with nothing placeable is also a candidate for the
    // explanation, since it is a longest-prefix witness.
    Dead(walk) -> Dead(Walk(..walk, failed: set.insert(walk.failed, key)))
  }
}

/// Try each lane's head as the next call to take effect. The head is
/// refused for real time before its postcondition is ever evaluated, because
/// an overtaken call costs nothing and must not spend the budget. A head
/// that passes both is placed and the search continues from the state after
/// it; the first placement that completes wins, which is what makes
/// depth-first search the right order for finding a witness quickly.
fn attempt(
  machine: Machine(model, cmd, response),
  budget: Int,
  lanes: List(Lane(cmd, response)),
  untried: List(Lane(cmd, response)),
  model: model,
  placed: List(Placed(cmd, response)),
  walk: Walk(model, cmd, response),
  tried: Tried(cmd, response),
) -> Walked(model, cmd, response) {
  case untried {
    [] -> {
      let walk = case tried.descended {
        0 -> record_dead_end(walk, placed, list.reverse(tried.blocked))
        _ -> walk
      }

      Dead(walk)
    }

    [lane, ..rest] ->
      case lane.events {
        // A live lane is never empty; the arm exists for totality.
        [] -> attempt(machine, budget, lanes, rest, model, placed, walk, tried)

        [event, ..later] -> {
          let here = Placed(lane.branch, lane.index, event)

          case blocked_by(lanes, lane, event) {
            Some(#(branch, index)) -> {
              let blocked =
                Blocked(placed: here, obstacle: Overtaken(branch, index))
              let tried = Tried(..tried, blocked: [blocked, ..tried.blocked])

              attempt(machine, budget, lanes, rest, model, placed, walk, tried)
            }

            None ->
              place(
                machine,
                budget,
                lanes,
                Head(lane: lane, rest: rest, here: here, later: later),
                model,
                placed,
                walk,
                tried,
              )
          }
        }
      }
  }
}

/// Spend one node on a head real time allows: evaluate its postcondition and,
/// if it holds, descend with the head placed and its lane advanced.
fn place(
  machine: Machine(model, cmd, response),
  budget: Int,
  lanes: List(Lane(cmd, response)),
  head: Head(cmd, response),
  model: model,
  placed: List(Placed(cmd, response)),
  walk: Walk(model, cmd, response),
  tried: Tried(cmd, response),
) -> Walked(model, cmd, response) {
  let Head(lane, rest, here, later) = head
  use <- bool.guard(walk.nodes >= budget, Overspent)

  let walk = Walk(..walk, nodes: walk.nodes + 1)

  case machine.postcondition(model, here.event.cmd, here.event.response) {
    Error(violation) -> {
      let blocked = Blocked(placed: here, obstacle: Violated(violation))
      let tried = Tried(..tried, blocked: [blocked, ..tried.blocked])

      attempt(machine, budget, lanes, rest, model, placed, walk, tried)
    }

    Ok(Nil) -> {
      let advanced = advance(lanes, Lane(lane.branch, lane.index + 1, later))
      let next = machine.next_model(model, here.event.cmd)

      case search(machine, budget, advanced, next, [here, ..placed], walk) {
        Found(order) -> Found(order)
        Overspent -> Overspent

        // The subtree under this head failed, so a sibling head may still
        // work; `descended` records that this state was not itself a dead
        // end, which keeps it out of the explanation.
        Dead(walk) ->
          attempt(
            machine,
            budget,
            lanes,
            rest,
            model,
            placed,
            walk,
            Tried(..tried, descended: tried.descended + 1),
          )
      }
    }
  }
}

/// The lanes after one lane moved on. A lane with nothing left is dropped,
/// so a lane that is present always has a head.
fn advance(
  lanes: List(Lane(cmd, response)),
  moved: Lane(cmd, response),
) -> List(Lane(cmd, response)) {
  list.filter_map(lanes, fn(lane) {
    case lane.branch == moved.branch, moved.events {
      True, [] -> Error(Nil)
      True, [_, ..] -> Ok(moved)
      False, _ -> Ok(lane)
    }
  })
}

/// The branch and position of another lane's head that returned strictly
/// before `event` was invoked, so it must take effect first. `None` means
/// real time allows `event` to go next. Only heads need checking: any later
/// call of a branch returns no earlier than that branch's head did.
fn blocked_by(
  lanes: List(Lane(cmd, response)),
  lane: Lane(cmd, response),
  event: Event(cmd, response),
) -> Option(#(Int, Int)) {
  list.find_map(lanes, fn(other) {
    case other.branch == lane.branch, other.events {
      True, _ -> Error(Nil)
      False, [] -> Error(Nil)

      False, [head, ..] ->
        case head.returned_at < event.invoked_at {
          True -> Ok(#(other.branch, other.index))
          False -> Error(Nil)
        }
    }
  })
  |> option.from_result
}

/// Keep this dead end if it placed more calls than any before it. A tie keeps
/// the earlier one, so the explanation is stable for a given history.
fn record_dead_end(
  walk: Walk(model, cmd, response),
  placed: List(Placed(cmd, response)),
  blocked: List(Blocked(cmd, response)),
) -> Walk(model, cmd, response) {
  let depth = list.length(placed)
  let explanation = Explanation(placed: list.reverse(placed), blocked: blocked)

  case walk.deepest {
    Some(#(best, _)) if best >= depth -> walk
    Some(_) | None -> Walk(..walk, deepest: Some(#(depth, explanation)))
  }
}

/// The explanation for an exhausted search. A history with no calls at all is
/// linearizable, so a dead search always recorded at least one dead end; the
/// empty explanation covers the shape the types cannot rule out.
fn explanation_of(
  walk: Walk(model, cmd, response),
) -> Explanation(cmd, response) {
  case walk.deepest {
    Some(#(_, explanation)) -> explanation
    None -> Explanation(placed: [], blocked: [])
  }
}
