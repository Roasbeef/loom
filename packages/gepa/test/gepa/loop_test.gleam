//// The loop as a host runs it: the planted improvement is found and
//// confirmed, and over random designs and budgets the search never spends
//// past its budget, always pays for the confirm run it owes, replays to
//// the state it ended in, and resumes from any prefix of its log to the
//// same log.

import gepa
import gepa/budget.{Costs, Limits}
import gepa/judge
import gepa/log
import gepa/prompt
import gepa/verdict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import support/world

fn tasks(prefix: String, count: Int) -> List(String) {
  list.index_map(list.repeat(Nil, count), fn(_, i) {
    prefix <> int.to_string(i)
  })
}

fn config() -> gepa.Config {
  gepa.Config(
    id: "search",
    objective: "be better",
    background: [],
    evidence: gepa.feedback_evidence,
    tune: tasks("u", 4),
    validate: tasks("v", 6),
    k: 2,
    k_tune: 1,
    minibatch: 2,
    slots: ["a", "b"],
    proposals: 1,
    hidden: [],
    limits: Limits(
      budget: 1000.0,
      max_steps: 2,
      max_reflections: 5,
      max_candidates: 5,
    ),
    costs: Costs(trial: 1.0, attempts: 2, reflection: 1.0),
    judge: judge.sign_test,
  )
}

pub fn the_planted_improvement_is_found_and_confirmed_test() {
  let #(state, events) = world.search(config(), world.planted())

  assert state.stopped == Some(budget.Steps)
  assert state.step == 2
  assert gepa.children(state) == 2
  let assert Some(gepa.Confirmation(
    best:,
    acceptance: Some(verdict.Improved),
    ..,
  )) = state.confirmation
  assert best != "seed" && state.incumbent == best

  // Step 1 minted the planted child and it became the incumbent; step 2's
  // child changed nothing and was not shown better, so it joined the
  // Pareto tier at most.
  let dispositions =
    list.filter_map(events, fn(event) {
      case event {
        gepa.Judged(disposition:, basis: verdict.OnValidate, ..) ->
          Ok(disposition)
        _ -> Error(Nil)
      }
    })
  let assert [verdict.Incumbent, ..] = dispositions
  assert gepa.replay(events) == Ok(state)
  assert gepa.replay_checked(events, config()) == Ok(state)
  assert log.parse(log.render(events)) == Ok(events)
}

/// A row that is not the answer to the request before it is refused by
/// the checked fold and named, whatever the per-event fold thinks of it.
pub fn the_checked_fold_refuses_a_row_the_search_did_not_ask_for_test() {
  let #(_, events) = world.search(config(), world.planted())
  let refused = fn(mutated: List(gepa.Event), naming: String) {
    let assert Error(reason) = gepa.replay_checked(mutated, config())
    assert string.contains(reason, naming)
  }
  let at = fn(wanted: fn(gepa.Event) -> Bool) {
    let before = list.take_while(events, fn(event) { !wanted(event) })
    let assert [found, ..] = list.drop(events, list.length(before))
    #(before, found)
  }

  // An evaluation under another cap, or of other tasks.
  let #(before, found) =
    at(fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ChildMinibatch, ..) -> True
        _ -> False
      }
    })
  let assert gepa.Evaluated(cap:, tasks:, ..) = found
  refused(
    list.append(before, [gepa.Evaluated(..found, cap: cap +. 1.0)]),
    "not the one asked for",
  )
  refused(
    list.append(before, [gepa.Evaluated(..found, tasks: list.reverse(tasks))]),
    "not the one asked for",
  )
  refused(
    list.append(before, [gepa.Evaluated(..found, cost: cap +. 0.5)]),
    "spent past its cap",
  )

  // Validate before the screen: the child's validate run where its
  // minibatch was asked for.
  let #(_, validate) =
    at(fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.Validate, step: 1, ..) -> True
        _ -> False
      }
    })
  refused(list.append(before, [validate]), "not the one asked for")

  // A reflection charged above its worst case, and a child in the wrong
  // slot.
  let #(before_reflect, reflected) =
    at(fn(event) {
      case event {
        gepa.Reflected(..) -> True
        _ -> False
      }
    })
  let assert gepa.Reflected(cost:, ..) = reflected
  refused(
    list.append(before_reflect, [gepa.Reflected(..reflected, cost: cost +. 1.0)]),
    "more than its worst case",
  )
  let #(before_mint, minted) =
    at(fn(event) {
      case event {
        gepa.Minted(..) -> True
        _ -> False
      }
    })
  let assert gepa.Minted(..) = minted
  refused(
    list.append(before_mint, [gepa.Minted(..minted, slot: "b")]),
    "not minted from the parent and slot asked for",
  )

  // A judgement the search did not decide, and a stop it did not reach.
  let #(before_judged, judged) =
    at(fn(event) {
      case event {
        gepa.Judged(basis: verdict.OnValidate, ..) -> True
        _ -> False
      }
    })
  let assert gepa.Judged(..) = judged
  refused(
    list.append(before_judged, [
      gepa.Judged(
        ..judged,
        acceptance: verdict.Inconclusive,
        disposition: verdict.ParetoOnly,
      ),
    ]),
    "did not decide this row",
  )
  refused(
    list.append(before_judged, [gepa.Stopped(budget.Steps)]),
    "did not decide this row",
  )

  // A stop with the confirm run evaluated and not judged.
  let #(before_confirm_judged, _) =
    at(fn(event) {
      case event {
        gepa.Judged(basis: verdict.OnConfirm, ..) -> True
        _ -> False
      }
    })
  refused(
    list.append(before_confirm_judged, [gepa.Stopped(budget.Steps)]),
    "did not decide this row",
  )
}

pub fn the_seed_is_validated_first_and_a_stop_without_a_best_has_no_confirm_test() {
  let assert Ok(first) = gepa.next(gepa.start("seed", []), config())
  let assert gepa.Evaluate(
    stage: gepa.SeedValidate,
    step: 0,
    candidate: "seed",
    cap:,
    ..,
  ) = first

  // The seed's cap already holds back the confirm run: 2 * 6 * 2 * 2 = 48.
  assert cap == 1000.0 -. 48.0

  // A search allowed no steps stops at once, and with nothing to confirm.
  let none =
    gepa.Config(..config(), limits: Limits(..config().limits, max_steps: 0))
  let #(state, _) = world.search(none, world.planted())
  assert state.stopped == Some(budget.Steps)
  assert state.confirmation == None
  assert state.pool == ["seed"]
}

pub fn an_unaffordable_reflection_writes_a_zero_cost_row_and_a_refusal_test() {
  // Under the cap discipline the reflection is always covered after the
  // parent's minibatch, so the path is reached only by a host that
  // ignores its caps: cells at 0.1, one attempt, a reflection at 30. One
  // step needs 0.2 + 0.2 + 1.2 + 30 = 31.6 and the confirm 2.4; the seed's
  // run charges 36 of 71, the step is taken at 35, the parent's minibatch
  // charges 6, and 29 no longer covers the reflection.
  let dear =
    gepa.Config(
      ..config(),
      costs: Costs(trial: 0.1, attempts: 1, reflection: 30.0),
      limits: Limits(..config().limits, budget: 71.0),
    )
  let #(state, events) = world.search(dear, world.World(world.Unbounded, []))

  assert list.contains(events, gepa.Reflected(1, 0.0, "", gepa.Unknown, 1, 1))
  assert list.contains(
    events,
    gepa.Refused(
      1,
      None,
      "budget: the search cannot cover a reflection's worst case",
    ),
  )
  assert state.reflections == 1
  assert state.stopped == Some(budget.Budget)
  assert float.loosely_equals(gepa.spent(state), 42.0, 1.0e-9)
  assert state.confirmation == None
}

fn random_config() -> qcheck.Generator(gepa.Config) {
  use tune <- qcheck.bind(qcheck.bounded_int(1, 5))
  use validate <- qcheck.bind(qcheck.bounded_int(1, 8))
  use k <- qcheck.bind(qcheck.bounded_int(1, 3))
  use k_tune <- qcheck.bind(qcheck.bounded_int(1, 2))
  use minibatch <- qcheck.bind(qcheck.bounded_int(1, 4))
  use trial <- qcheck.bind(qcheck.bounded_float(0.1, 1.0))
  use attempts <- qcheck.bind(qcheck.bounded_int(1, 3))
  use reflection <- qcheck.bind(qcheck.bounded_float(0.0, 2.0))
  use max_steps <- qcheck.bind(qcheck.bounded_int(0, 3))
  use max_reflections <- qcheck.bind(qcheck.bounded_int(0, 4))
  use max_candidates <- qcheck.bind(qcheck.bounded_int(0, 3))
  use proposals <- qcheck.bind(qcheck.bounded_int(1, 3))
  use scale <- qcheck.map(qcheck.bounded_float(0.0, 3.5))
  let costs = Costs(trial:, attempts:, reflection:)
  let design =
    budget.Design(
      validate_tasks: validate,
      minibatch_tasks: int_min(minibatch, tune),
      trials: k,
      tune_trials: k_tune,
      proposals:,
    )
  let unit =
    budget.step_worst_case(costs, design)
    +. budget.confirm_worst_case(costs, design)

  gepa.Config(
    id: "search",
    objective: "be better",
    background: [],
    evidence: gepa.feedback_evidence,
    tune: tasks("u", tune),
    validate: tasks("v", validate),
    k:,
    k_tune:,
    minibatch:,
    slots: ["a", "b"],
    proposals:,
    hidden: [],
    limits: Limits(
      budget: scale *. unit,
      max_steps:,
      max_reflections:,
      max_candidates:,
    ),
    costs:,
    judge: judge.sign_test,
  )
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

fn charge() -> qcheck.Generator(world.Charge) {
  qcheck.from_generators(qcheck.return(world.WorstCase), [
    qcheck.return(world.Greedy),
  ])
}

pub fn the_search_never_spends_past_its_budget_and_always_pays_for_its_confirm_test() {
  use #(config, charge) <- qcheck.given(qcheck.tuple2(random_config(), charge()))
  let #(state, events) =
    world.search(config, world.World(charge, [#(1, "better")]))

  assert state.stopped != None
  assert gepa.spent(state) <=. config.limits.budget +. 1.0e-6

  // Every evaluation stayed within the cap it was handed.
  assert list.all(events, fn(event) {
    case event {
      gepa.Evaluated(cap:, cost:, ..) -> cost <=. cap +. 1.0e-9
      _ -> True
    }
  })

  // A best that is not the seed was always confirmed: the holds kept the
  // confirm run payable whatever the steps spent.
  case state.incumbent == state.seed, state.confirmation {
    True, None -> Nil
    False, Some(gepa.Confirmation(acceptance: Some(_), ..)) -> Nil
    _, _ -> panic as "a best that is not the seed must have been confirmed"
  }
}

pub fn the_log_replays_to_the_final_state_and_resumes_from_any_prefix_test() {
  use #(config, charge) <- qcheck.given(qcheck.tuple2(random_config(), charge()))
  let scripted = world.World(charge, [#(1, "better"), #(2, "even better")])
  let #(state, events) = world.search(config, scripted)

  assert gepa.replay(events) == Ok(state)
  assert gepa.replay_checked(events, config) == Ok(state)
  let assert Ok(parsed) = log.parse(log.render(events))
  assert parsed == events

  // Cut the log after every row, replay what is left, and carry on: the
  // search ends with the same log, byte for byte.
  list.index_map(events, fn(_, i) { i + 1 })
  |> list.each(fn(length) {
    let prefix = list.take(events, length)

    let assert Ok(resumed) = gepa.replay(prefix)
    let #(again, replayed) = world.drive(resumed, prefix, config, scripted)

    // A cut right after a reflection is the one place resume is not a
    // replay: the answer was lost, so the reflection is made again (or
    // refused, when a second one would eat the reservation) and every
    // later cap is smaller by that charge. The budget still holds there.
    case list.last(prefix) {
      Ok(gepa.Reflected(..)) -> {
        assert again.stopped != None
        assert gepa.spent(again) <=. config.limits.budget +. 1.0e-6
        assert gepa.replay_checked(replayed, config) == Ok(again)
        case again.incumbent == again.seed, again.confirmation {
          True, None -> Nil
          False, Some(gepa.Confirmation(acceptance: Some(_), ..)) -> Nil
          _, _ -> panic as "a resumed best that is not the seed was confirmed"
        }
      }
      _ -> {
        assert replayed == events
        assert again == state
      }
    }
  })
}

pub fn a_resumed_reflection_that_would_eat_the_reservation_is_refused_test() {
  // A budget of exactly one step and the confirm, rows at their worst
  // case: after the parent's minibatch what remains is exactly the hold,
  // and the first reflection spends its worst case from it. A crash
  // before the child is minted would reflect again; a second call would
  // leave the confirm run unpayable, so the search refuses it instead.
  let design =
    budget.Design(
      validate_tasks: 6,
      minibatch_tasks: 2,
      trials: 2,
      tune_trials: 1,
      proposals: 1,
    )
  let costs = Costs(trial: 1.0, attempts: 2, reflection: 5.0)
  let tight =
    gepa.Config(
      ..config(),
      costs:,
      limits: Limits(
        budget: budget.cell_worst_case(costs)
          *. 12.0
          +. budget.step_worst_case(costs, design)
          +. budget.confirm_worst_case(costs, design),
        max_steps: 1,
        max_reflections: 5,
        max_candidates: 5,
      ),
    )
  let #(_, events) = world.search(tight, world.planted())
  let cut =
    list.take_while(events, fn(event) {
      case event {
        gepa.Reflected(..) -> False
        _ -> True
      }
    })
  let prefix =
    list.append(cut, [gepa.Reflected(1, 5.0, "", gepa.Complete, 1, 1)])
  let assert Ok(resumed) = gepa.replay(prefix)

  let assert Ok(gepa.Record(gepa.Refused(step: 1, candidate: None, reason:))) =
    gepa.next(resumed, tight)
  assert string.starts_with(reason, "budget:")

  // The resumed search ends within its budget with the seed still best.
  let #(again, _) = world.drive(resumed, prefix, tight, world.planted())
  assert gepa.spent(again) <=. tight.limits.budget
  assert again.incumbent == again.seed && again.stopped != None
}

pub fn draws_are_the_same_from_the_same_seed_test() {
  // Two searches with the same id draw the same parents and minibatches,
  // which is what makes a resumed step find the rows it wrote.
  let #(_, first) = world.search(config(), world.planted())
  let #(_, second) = world.search(config(), world.planted())
  assert first == second

  let other = gepa.Config(..config(), id: "another")
  let #(_, third) = world.search(other, world.planted())
  let minibatches = fn(events) {
    list.filter_map(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, tasks:, ..) -> Ok(tasks)
        _ -> Error(Nil)
      }
    })
  }
  assert minibatches(first) != minibatches(third)
}

/// The prefix of a search's log up to and including the first row `wanted`
/// admits, replayed to a state.
fn replayed_until(
  events: List(gepa.Event),
  wanted: fn(gepa.Event) -> Bool,
) -> gepa.State {
  let before = list.take_while(events, fn(event) { !wanted(event) })
  let prefix = list.take(events, list.length(before) + 1)
  let assert Ok(state) = gepa.replay(prefix)
  state
}

pub fn the_reflector_is_shown_the_slot_s_background_through_the_host_s_view_test() {
  // A slot's background is a note; the evidence view decides a record's
  // fields, and is told which slot it is rendering for.
  let shown =
    gepa.Config(
      ..config(),
      slots: ["a"],
      background: [#("a", "Keep it short [[record]]"), #("b", "unused")],
      evidence: fn(slot: String, score: gepa.Score) {
        [#("slot", slot), #("ran", score.feedback <> "!")]
      },
    )
  let #(_, events) = world.search(shown, world.planted())
  let opened =
    replayed_until(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, step: 1, ..) -> True
        _ -> False
      }
    })

  let assert Ok(gepa.Reflect(request:, ..)) = gepa.next(opened, shown)
  assert request.notes == ["Keep it short [[record]]"]
  let assert [first, ..] = request.records
  assert first.fields == [#("slot", "a"), #("ran", "ran!")]
  assert string.contains(prompt.render(request), "Keep it short ( record )")

  // A slot with no background renders the prompt it always did.
  let bare = gepa.Config(..shown, background: [#("b", "unused")])
  let assert Ok(gepa.Reflect(request: plain, ..)) = gepa.next(opened, bare)
  assert plain.notes == []
}

pub fn the_reflector_is_told_what_this_lineage_already_rejected_test() {
  // Every step rewrites `a`. Step 1's child changes nothing the scorer sees
  // and is screened out; step 2, extending the seed again, is told so.
  let one_slot =
    gepa.Config(
      ..config(),
      slots: ["a"],
      limits: Limits(..config().limits, max_steps: 3),
    )
  let scripted = world.World(world.WorstCase, [#(1, "worse"), #(2, "better")])
  let #(_, events) = world.search(one_slot, scripted)
  let second =
    replayed_until(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, step: 2, ..) -> True
        _ -> False
      }
    })

  let assert Ok(gepa.Reflect(request:, ..)) = gepa.next(second, one_slot)
  assert request.tried == [prompt.Tried(1, "screened_out", "worse")]
  assert string.contains(prompt.render(request), "outcome: screened_out")

  // Step 3 extends step 2's child, whose lineage is the seed's: the digest
  // still names step 1's rejection, and not step 2's kept child.
  let third =
    replayed_until(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, step: 3, ..) -> True
        _ -> False
      }
    })
  let assert Ok(gepa.Reflect(request: later, parent:, ..)) =
    gepa.next(third, one_slot)
  assert parent != "seed"
  assert later.tried == [prompt.Tried(1, "screened_out", "worse")]

  // A different slot's rejections are not this slot's.
  let other = gepa.Config(..one_slot, slots: ["b"])
  let assert Ok(gepa.Reflect(request: unrelated, ..)) = gepa.next(second, other)
  assert unrelated.tried == []
}

pub fn a_parent_perfect_on_its_minibatch_is_not_reflected_on_test() {
  // Step 1 mints a child at the ceiling and it becomes the incumbent, so
  // step 2 draws it, finds every minibatch task at one, and ends the step
  // in a refusal that made no call and spent nothing on reflection.
  let scripted = world.World(world.WorstCase, [#(1, "even better")])
  let #(state, events) = world.search(config(), scripted)

  assert list.contains(
    events,
    gepa.Refused(2, None, gepa.skipped_perfect_reason),
  )
  assert state.reflections == 1
  assert state.step == 2 && gepa.children(state) == 1
  assert state.stopped == Some(budget.Steps)

  // The skipped step cost its parent minibatch and nothing more: the seed's
  // run, two minibatches, one reflection, one child minibatch, one
  // validate run and the confirm run, all at their worst case.
  let cell = budget.cell_worst_case(config().costs)
  let minibatch = 2.0 *. cell
  let validate = 12.0 *. cell
  assert float.loosely_equals(
    gepa.spent(state),
    validate +. 3.0 *. minibatch +. 1.0 +. validate +. 2.0 *. validate,
    1.0e-9,
  )
  assert gepa.replay_checked(events, config()) == Ok(state)

  // The log read back asks for the same refusal where the step was cut.
  let cut =
    replayed_until(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, step: 2, ..) -> True
        _ -> False
      }
    })
  assert gepa.next(cut, config())
    == Ok(gepa.Record(gepa.Refused(2, None, gepa.skipped_perfect_reason)))
}

pub fn a_truncated_answer_is_refused_however_well_it_reads_test() {
  // The host reports how the answer ended on the `Reflected` row; an
  // answer cut at the output limit is refused by `admit` even when the
  // text passes every other check, and the step ends there.
  let #(_, events) = world.search(config(), world.planted())
  let before =
    list.take_while(events, fn(event) {
      case event {
        gepa.Reflected(..) -> False
        _ -> True
      }
    })
  let truncated =
    list.append(before, [gepa.Reflected(1, 1.0, "", gepa.Truncated, 1, 1)])
  let assert Ok(state) = gepa.replay(truncated)

  assert gepa.admit(state, "a", Ok("better"), gepa.content_id)
    == Ok(gepa.Refused(1, None, gepa.truncated_reason))
  let assert Ok(closed) =
    gepa.apply(state, gepa.Refused(1, None, gepa.truncated_reason))
  assert closed.open == None && gepa.children(closed) == 0

  // A complete or unreported finish mints as before.
  let complete =
    list.append(before, [gepa.Reflected(1, 1.0, "", gepa.Unknown, 1, 1)])
  let assert Ok(state) = gepa.replay(complete)
  let assert Ok(gepa.Minted(..)) =
    gepa.admit(state, "a", Ok("better"), gepa.content_id)
}

/// The kinds of a log's rows, in order, as short words.
fn shape(events: List(gepa.Event)) -> List(String) {
  list.map(events, fn(event) {
    case event {
      gepa.Seeded(..) -> "seeded"
      gepa.Evaluated(stage:, ..) -> log.stage_name(stage)
      gepa.Reflected(proposal:, of:, ..) ->
        "reflected " <> int.to_string(proposal) <> "/" <> int.to_string(of)
      gepa.Minted(..) -> "minted"
      gepa.Refused(candidate: None, ..) -> "refused"
      gepa.Refused(candidate: Some(_), ..) -> "refused child"
      gepa.Judged(disposition:, ..) -> verdict.disposition_name(disposition)
      gepa.Stopped(..) -> "stopped"
    }
  })
}

fn two_proposals() -> gepa.Config {
  gepa.Config(
    ..config(),
    proposals: 2,
    limits: Limits(..config().limits, max_steps: 1),
  )
}

pub fn a_step_of_two_proposals_screens_both_and_validates_the_winner_test() {
  // The first proposal is good and the second better: both are reflected
  // on in turn, both run the minibatch, the first is screened out as the
  // loser, and only the second is paid a validate run.
  let scripted = world.World(world.WorstCase, [#(1, "better|even better")])
  let #(state, events) = world.search(two_proposals(), scripted)

  assert shape(events)
    == [
      "seeded", "seed_validate", "parent_minibatch", "reflected 1/2", "minted",
      "reflected 2/2", "minted", "child_minibatch", "child_minibatch",
      "screened_out", "validate", "incumbent", "confirm", "confirmed", "stopped",
    ]
  assert gepa.children(state) == 2 && state.reflections == 2
  let assert [_, child_one, child_two] = state.members
  assert child_one.disposition == Some(verdict.ScreenedOut)
  assert child_two.disposition == Some(verdict.Incumbent)
  assert state.incumbent == child_two.candidate

  // Every row is the one the search asked for, and the log round-trips
  // with the width written on each reflection.
  assert gepa.replay_checked(events, two_proposals()) == Ok(state)
  let text = log.render(events)
  assert string.contains(text, "proposal=1 of=2")
    && string.contains(text, "proposal=2 of=2")
  assert log.parse(text) == Ok(events)

  // The second reflection was told what the first proposed.
  let after_first =
    replayed_until(events, fn(event) {
      case event {
        gepa.Minted(..) -> True
        _ -> False
      }
    })
  let assert Ok(gepa.Reflect(proposal: 2, of: 2, request:, ..)) =
    gepa.next(after_first, two_proposals())
  assert request.tried == [prompt.Tried(1, "proposed", "better")]

  // A tie between the children goes to the earliest minted.
  let tied = world.World(world.WorstCase, [#(1, "better|better too")])
  let #(state, _) = world.search(two_proposals(), tied)
  let assert [_, first, second] = state.members
  assert first.disposition == Some(verdict.Incumbent)
  assert second.disposition == Some(verdict.ScreenedOut)
}

pub fn a_refused_proposal_does_not_end_a_step_with_proposals_left_test() {
  // An empty first answer is refused; the step asks for its second
  // proposal, mints it, and carries it alone through the screen.
  let scripted = world.World(world.WorstCase, [#(1, "|better")])
  let #(state, events) = world.search(two_proposals(), scripted)

  assert shape(events)
    == [
      "seeded", "seed_validate", "parent_minibatch", "reflected 1/2", "refused",
      "reflected 2/2", "minted", "child_minibatch", "validate", "incumbent",
      "confirm", "confirmed", "stopped",
    ]
  assert gepa.children(state) == 1
  assert gepa.replay_checked(events, two_proposals()) == Ok(state)

  // Both answers refused: the second refusal closes the step with no child.
  let twice = world.World(world.WorstCase, [#(1, "|")])
  let #(state, events) = world.search(two_proposals(), twice)
  assert shape(events)
    == [
      "seeded", "seed_validate", "parent_minibatch", "reflected 1/2", "refused",
      "reflected 2/2", "refused", "stopped",
    ]
  assert state.pool == ["seed"] && state.open == None
}

pub fn the_log_fixes_a_step_s_width_and_the_checked_fold_holds_rows_to_it_test() {
  let scripted = world.World(world.WorstCase, [#(1, "better|even better")])
  let #(_, events) = world.search(two_proposals(), scripted)
  let after_first =
    replayed_until(events, fn(event) {
      case event {
        gepa.Minted(..) -> True
        _ -> False
      }
    })

  // A resumed search configured for one proposal still owes the second:
  // the width is the log's, not the configuration's.
  let narrowed = gepa.Config(..two_proposals(), proposals: 1)
  let assert Ok(gepa.Reflect(proposal: 2, of: 2, ..)) =
    gepa.next(after_first, narrowed)
  let #(resumed, replayed) =
    world.drive(after_first, list.take(events, 5), narrowed, scripted)
  assert replayed == events && gepa.replay(events) == Ok(resumed)

  // A reflection numbered for another proposal, or claiming another
  // width, is not the one the search asked for.
  let before = list.take(events, 5)
  let assert [gepa.Reflected(..) as second, ..] = list.drop(events, 5)
  let assert gepa.Reflected(proposal: 2, of: 2, ..) = second
  let refused = fn(row: gepa.Event, naming: String) {
    let assert Error(reason) =
      gepa.replay_checked(list.append(before, [row]), two_proposals())
    assert string.contains(reason, naming)
  }
  refused(gepa.Reflected(..second, proposal: 1), "not the one asked for")
  refused(gepa.Reflected(..second, of: 3), "not the one asked for")

  // The plain fold refuses them too, by the step's own width.
  let assert Error(reason) =
    gepa.replay(list.append(before, [gepa.Reflected(..second, of: 3)]))
  assert string.contains(reason, "at the step's width")
}

pub fn a_child_minted_after_a_truncated_or_unpaid_reflection_is_refused_test() {
  // The checked fold holds the child to the live reflection before it: an
  // answer reported truncated owes a refusal, not a child, and so does the
  // plain fold, whatever `admit` was or was not asked.
  let #(_, events) = world.search(config(), world.planted())
  let before =
    list.take_while(events, fn(event) {
      case event {
        gepa.Reflected(..) -> False
        _ -> True
      }
    })
  let assert [gepa.Reflected(..) as reflected, gepa.Minted(..) as minted, ..] =
    list.drop(events, list.length(before))
  let truncated =
    list.append(before, [
      gepa.Reflected(..reflected, finish: gepa.Truncated),
      minted,
    ])
  let assert Error(checked) = gepa.replay_checked(truncated, config())
  assert string.contains(checked, "reported truncated")
  let assert Error(plain) = gepa.replay(truncated)
  assert string.contains(plain, "answer was truncated")

  // A zero-cost reflection the search recorded for want of budget owes
  // nothing: the next row must be the refusal `next` decides, never a
  // child, which a check keyed on "a child after a reflection" rather
  // than on the request let through. Under the caps such a row only
  // follows an overspending host, so the state is folded unchecked and
  // the question put to `expected` with no request pending.
  let dear =
    gepa.Config(
      ..config(),
      costs: Costs(trial: 0.1, attempts: 1, reflection: 30.0),
      limits: Limits(..config().limits, budget: 71.0),
    )
  let #(_, unpaid) = world.search(dear, world.World(world.Unbounded, []))
  let upto =
    list.take_while(unpaid, fn(event) {
      case event {
        gepa.Refused(..) -> False
        _ -> True
      }
    })
  let assert Ok(gepa.Reflected(cost: 0.0, ..)) = list.last(upto)
  let assert Ok(at) = gepa.replay(upto)
  let assert Ok(gepa.Minted(..) as smuggled) =
    gepa.admit(at, "a", Ok("better"), gepa.content_id)
  let assert Error(reason) = gepa.expected(at, dear, None, smuggled)
  assert string.contains(reason, "did not decide this row")

  // The lost-answer resume still replays: a second live reflection in the
  // child's place answers what `next` asks of the state now.
  let again = list.append(before, [reflected, reflected, minted])
  assert gepa.replay_checked(list.take(again, list.length(again)), config())
    |> result.is_ok
}

pub fn an_open_step_is_priced_at_the_log_s_width_and_a_wild_width_is_refused_test() {
  // A two-proposal step resumed under a one-proposal configuration still
  // holds back the second child's minibatch before the first's: the hold
  // is the log's width, not the configuration's.
  let scripted = world.World(world.WorstCase, [#(1, "better|even better")])
  let #(_, events) = world.search(two_proposals(), scripted)
  let assert Ok(after_second) = gepa.replay(list.take(events, 7))
  let assert Some(gepa.Progress(settled: 2, width: 2, ..)) = after_second.open
  let narrowed = gepa.Config(..two_proposals(), proposals: 1)
  let assert Ok(gepa.Evaluate(stage: gepa.ChildMinibatch, cap:, ..)) =
    gepa.next(after_second, narrowed)
  let wide =
    budget.Design(
      validate_tasks: 6,
      minibatch_tasks: 2,
      trials: 2,
      tune_trials: 1,
      proposals: 2,
    )
  let left = narrowed.limits.budget -. gepa.spent(after_second)
  assert cap
    == budget.cap(
      remaining: left,
      hold: budget.held_back(
        narrowed.costs,
        wide,
        budget.BeforeChildMinibatch(later: 1),
      ),
    )

  // The second proposal's reflection is held to the log's width too. With
  // a budget of exactly the seed's run, one two-proposal step and the
  // confirm, the first reflection leaves exactly the second's hold; a
  // first reflection charged one unit more leaves the second unaffordable
  // at width two, though a width-one hold would still be covered.
  let tight =
    gepa.Config(..narrowed, limits: Limits(..narrowed.limits, budget: 110.0))
  let assert [seeded, validated, parent_mb, gepa.Reflected(..) as first, c1, ..] =
    events
  let assert Ok(dear) =
    gepa.replay([
      seeded,
      validated,
      parent_mb,
      gepa.Reflected(..first, cost: first.cost +. 1.0),
      c1,
    ])
  assert gepa.next(dear, tight)
    == Ok(
      gepa.Record(gepa.Reflected(
        step: 1,
        cost: 0.0,
        ref: "",
        finish: gepa.Unknown,
        proposal: 2,
        of: 2,
      )),
    )
  let assert Ok(exact) = gepa.replay([seeded, validated, parent_mb, first, c1])
  let assert Ok(gepa.Reflect(proposal: 2, of: 2, ..)) = gepa.next(exact, tight)

  // A row claiming a thousand proposals is refused by the fold, so a
  // hand-edited log cannot make a resumed search reflect past its ceilings.
  let before =
    list.take_while(events, fn(event) {
      case event {
        gepa.Reflected(..) -> False
        _ -> True
      }
    })
  let assert Error(reason) =
    gepa.replay(
      list.append(before, [gepa.Reflected(1, 1.0, "", gepa.Complete, 1, 1000)]),
    )
  assert string.contains(reason, "n <= " <> int.to_string(gepa.max_proposals))

  // A configuration past the bound is read at the bound.
  let assert Ok(gepa.Reflect(of: of, ..)) =
    gepa.next(
      replayed_until(events, fn(event) {
        case event {
          gepa.Evaluated(stage: gepa.ParentMinibatch, ..) -> True
          _ -> False
        }
      }),
      gepa.Config(..two_proposals(), proposals: 1000),
    )
  assert of == gepa.max_proposals
}

pub fn hidden_ids_are_redacted_from_the_notes_and_the_digest_test() {
  // The records hide a test's name per task; the background and a rejected
  // rewrite are not about one task, so every hidden id is redacted there.
  let hidden =
    gepa.Config(
      ..config(),
      slots: ["a"],
      hidden: [#("u0", ["core.secret_test"]), #("v1", ["core.other_test"])],
      background: [#("a", "Never mention core.secret_test or other_test.")],
    )
  let scripted =
    world.World(world.WorstCase, [#(1, "worse: see core.secret_test")])
  let #(_, events) = world.search(hidden, scripted)
  let second =
    replayed_until(events, fn(event) {
      case event {
        gepa.Evaluated(stage: gepa.ParentMinibatch, step: 2, ..) -> True
        _ -> False
      }
    })

  let assert Ok(gepa.Reflect(request:, ..)) = gepa.next(second, hidden)
  assert request.notes == ["Never mention <test 2> or <test 1>."]
  assert request.tried
    == [prompt.Tried(1, "screened_out", "worse: see <test 2>")]
}
