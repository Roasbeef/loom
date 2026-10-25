//// The fold: a complete log replays to a stopped search, a cut log to an
//// open step, and a log with a row deleted, contradicted or misplaced is
//// refused at that row.

import gepa.{
  type Event, type Measured, Evaluated, Judged, Measured, Minted, Reflected,
  Refused, Score, Seeded, Stopped,
}
import gepa/budget
import gepa/verdict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const seed = "seed"

const child = "child"

const grandchild = "grandchild"

fn measured(id: String, value: Float) -> List(Measured) {
  [
    Measured(id, [Score("t1", value, ""), Score("t2", value, "")]),
  ]
}

fn run(
  stage: gepa.Stage,
  step: Int,
  id: String,
  ref: String,
  value: Float,
) -> Event {
  Evaluated(
    stage:,
    step:,
    candidate: id,
    tasks: ["t1", "t2"],
    cap: 0.0,
    ref:,
    measured: measured(id, value),
    cost: 0.0,
  )
}

/// A complete one-step search: seed validated, parent minibatch,
/// reflection, child, child minibatch, validate, judgement, confirm run,
/// confirm judgement, stop.
fn one_step() -> List(Event) {
  [
    Seeded(seed, [#("a", "x")]),
    run(gepa.SeedValidate, 0, seed, "a", 0.0),
    run(gepa.ParentMinibatch, 1, seed, "b", 0.0),
    Reflected(1, 0.001, "in/out", gepa.Complete),
    Minted(child, seed, 1, "a", "y"),
    run(gepa.ChildMinibatch, 1, child, "c", 1.0),
    run(gepa.Validate, 1, child, "d", 1.0),
    Judged(
      child,
      seed,
      verdict.OnValidate,
      verdict.Improved,
      verdict.Incumbent,
      "",
    ),
    Evaluated(
      stage: gepa.Confirm,
      step: 1,
      candidate: child,
      tasks: ["t1", "t2"],
      cap: 0.0,
      ref: "e",
      measured: list.append(measured(seed, 0.0), measured(child, 1.0)),
      cost: 0.0,
    ),
    Judged(
      child,
      seed,
      verdict.OnConfirm,
      verdict.Improved,
      verdict.Confirmed,
      "",
    ),
    Stopped(budget.Steps),
  ]
}

pub fn a_complete_log_replays_to_a_stopped_search_test() {
  let assert Ok(state) = gepa.replay(one_step())

  assert state.pool == [seed, child]
  assert state.incumbent == child
  assert state.step == 1
  assert state.open == None
  assert state.stopped == Some(budget.Steps)
  assert state.reflections == 1
  assert gepa.children(state) == 1
  assert gepa.spent(state) == 0.001
  let assert Some(gepa.Confirmation(best:, ref:, acceptance: Some(found))) =
    state.confirmation
  assert best == child && ref == "e" && found == verdict.Improved

  // The child's components are the parent's with the slot replaced.
  let assert Ok(member) =
    list.find(state.members, fn(m) { m.candidate == child })
  assert member.components == [#("a", "y")]
  assert member.validated == Some("d")
  assert gepa.validate_scores(state, child) == [#("t1", 1.0), #("t2", 1.0)]
}

pub fn a_deleted_run_row_refuses_replay_test() {
  // Each evaluation of the step, deleted alone, is caught by the row that
  // presupposes it.
  list.each(["a", "b", "c", "d"], fn(deleted) {
    let rows =
      list.filter(one_step(), fn(row) {
        case row {
          Evaluated(ref:, ..) -> ref != deleted
          _ -> True
        }
      })
    let assert Error(reason) = gepa.replay(rows)
    assert string.contains(reason, "search row missing")
  })

  // The seed's validate run in particular is named.
  let assert Error(reason) =
    gepa.replay(
      list.filter(one_step(), fn(row) {
        row != run(gepa.SeedValidate, 0, seed, "a", 0.0)
      }),
    )
  assert string.contains(reason, "search row missing: the seed's validate run")
}

pub fn a_log_cut_inside_a_step_replays_to_an_open_step_test() {
  let assert Ok(state) = gepa.replay(list.take(one_step(), 6))

  let assert Some(progress) = state.open
  assert progress.step == 1
  assert progress.parent == seed
  assert progress.child == Some(child)
  assert progress.reached == gepa.ChildMeasured
  assert state.pool == [seed]
  assert gepa.minibatch_scores(state, child, 1) == [#("t1", 1.0), #("t2", 1.0)]
}

pub fn a_lax_row_is_refused_test() {
  let prefix = list.take(one_step(), 7)

  // A disposition that does not follow from its acceptance.
  let assert Error(contradiction) =
    gepa.replay(
      list.append(prefix, [
        Judged(
          child,
          seed,
          verdict.OnValidate,
          verdict.Improved,
          verdict.ParetoOnly,
          "",
        ),
      ]),
    )
  assert string.contains(contradiction, "does not follow from its acceptance")

  // A settlement on the minibatch basis.
  let assert Error(wrong_basis) =
    gepa.replay(
      list.append(prefix, [
        Judged(
          child,
          seed,
          verdict.OnMinibatch,
          verdict.Inconclusive,
          verdict.ParetoOnly,
          "",
        ),
      ]),
    )
  assert string.contains(wrong_basis, "does not follow")

  // Two steps: the second child's parent is the seed, which is no longer
  // the incumbent, so an `incumbent` settlement needs the incumbent row,
  // and may carry it only once.
  let two_steps =
    list.flatten([
      list.take(one_step(), 8),
      [
        run(gepa.ParentMinibatch, 2, seed, "b2", 0.0),
        Reflected(2, 0.001, "", gepa.Unknown),
        Minted(grandchild, seed, 2, "a", "z"),
        run(gepa.ChildMinibatch, 2, grandchild, "c2", 1.0),
        run(gepa.Validate, 2, grandchild, "d2", 1.0),
      ],
    ])
  let incumbent_row =
    Judged(
      grandchild,
      child,
      verdict.OnValidate,
      verdict.Inconclusive,
      verdict.Unsettled,
      "",
    )
  let settles =
    Judged(
      grandchild,
      seed,
      verdict.OnValidate,
      verdict.Improved,
      verdict.Incumbent,
      "",
    )
  let assert Error(missing) = gepa.replay(list.append(two_steps, [settles]))
  assert string.contains(
    missing,
    "search row missing: the judgement against the incumbent",
  )
  let assert Error(twice) =
    gepa.replay(list.append(two_steps, [incumbent_row, incumbent_row]))
  assert string.contains(twice, "a second judgement against the incumbent")
  let assert Ok(state) =
    gepa.replay(list.append(two_steps, [incumbent_row, settles]))
  assert state.incumbent == grandchild
  let assert Some(gepa.Confirmation(..)) = {
    let assert Ok(state) = gepa.replay(one_step())
    state.confirmation
  }
}

pub fn a_refusal_closes_the_step_with_or_without_a_child_test() {
  let before_child = list.take(one_step(), 4)
  let assert Ok(state) =
    gepa.replay(list.append(before_child, [Refused(1, None, "nothing")]))
  assert state.open == None && state.pool == [seed]

  // With a child, the child is marked refused.
  let assert Ok(state) =
    gepa.replay(
      list.append(list.take(one_step(), 5), [
        Refused(1, Some(child), "settings"),
      ]),
    )
  let assert Ok(member) =
    list.find(state.members, fn(m) { m.candidate == child })
  assert member.disposition == Some(verdict.Refused)

  // A refusal naming no child after one was minted is misplaced.
  let assert Error(reason) =
    gepa.replay(list.append(list.take(one_step(), 5), [Refused(1, None, "x")]))
  assert string.contains(reason, "names the step's child")
}

pub fn a_lost_answer_is_reflected_again_and_counted_test() {
  let assert Ok(state) =
    gepa.replay(
      list.append(list.take(one_step(), 4), [
        Reflected(1, 0.002, "", gepa.Truncated),
      ]),
    )
  assert state.reflections == 2
  assert state.spent_reflecting == 0.003
}

pub fn a_row_after_the_stop_is_refused_test() {
  let assert Error(reason) =
    gepa.replay(list.append(one_step(), [Stopped(budget.Steps)]))
  assert string.contains(reason, "follows the stop row")
}

pub fn an_empty_log_or_a_wrong_first_row_is_refused_test() {
  assert gepa.replay([]) == Error("search row missing: the seed")
  let assert Error(reason) = gepa.replay([Stopped(budget.Steps)])
  assert string.contains(reason, "begin with the seed")
  let assert Error(twice) = gepa.replay([Seeded(seed, []), Seeded(seed, [])])
  assert string.contains(twice, "second seed")
}

pub fn a_duplicate_candidate_or_a_stranger_is_refused_test() {
  let assert Error(duplicate) =
    gepa.replay(
      list.append(list.take(one_step(), 4), [Minted(seed, seed, 1, "a", "y")]),
    )
  assert string.contains(duplicate, "already introduced")

  let assert Error(stranger) =
    gepa.replay(
      list.append(list.take(one_step(), 2), [
        run(gepa.ParentMinibatch, 1, child, "b", 0.0),
      ]),
    )
  assert string.contains(stranger, "not in the pool")

  // A measurement of a candidate the evaluation is not about.
  let odd =
    Evaluated(
      stage: gepa.Validate,
      step: 1,
      candidate: child,
      tasks: ["t1"],
      cap: 0.0,
      ref: "d",
      measured: measured(seed, 1.0),
      cost: 0.0,
    )
  let assert Error(reason) =
    gepa.replay(list.append(list.take(one_step(), 6), [odd]))
  assert string.contains(reason, "measures only the candidates it is about")
}
