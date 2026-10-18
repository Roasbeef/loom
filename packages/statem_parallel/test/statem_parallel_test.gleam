//// Tests for the parallel layer, against a counter served by an actor.
////
//// The counter is correct when an increment is one message and racy when it
//// is a read and a write. Each test breaks one thing and names what it
//// expects, so a failure says which part of the layer moved.

import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/yielder
import gleeunit
import statem
import statem/linearize
import statem_parallel.{type Case, type Config, Case, Failure}
import statem_parallel/internal/interleave
import support/counter.{
  Atomic, Decrement, Guarded, Increment, Intermittent, Read, ReadThenWrite,
  Unguarded,
}

pub fn main() -> Nil {
  gleeunit.main()
}

/// The seed every test below checks from. A fixed seed makes the cases the
/// same on every machine; only the interleaving, which no seed fixes, varies.
const seed = 41

/// A seed whose first case has a non-empty prefix, for the tests that need a
/// failure to surface there.
const prefix_seed = 5

fn config() -> Config {
  statem_parallel.default_config(seed: seed)
}

/// The run numbers `0..count - 1`.
fn runs(count: Int) -> List(Int) {
  yielder.range(0, count - 1) |> yielder.to_list
}

fn all_commands() -> List(counter.Cmd) {
  [Increment, Read]
}

// --- a correct system -------------------------------------------------------

pub fn a_correct_counter_is_linearizable_test() {
  let spec =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )

  case
    statem_parallel.check(
      spec,
      config() |> statem_parallel.with_test_count(100),
    )
  {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem_parallel.report(failure, counter.describe)
  }
}

pub fn three_branches_of_a_correct_counter_are_linearizable_test() {
  let spec =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let three =
    config()
    |> statem_parallel.with_branches(3)
    |> statem_parallel.with_test_count(30)

  case statem_parallel.check(spec, three) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem_parallel.report(failure, counter.describe)
  }
}

// --- a racy system ----------------------------------------------------------

pub fn a_racy_counter_is_found_and_shrunk_test() {
  let spec =
    counter.spec(
      service: ReadThenWrite,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )

  let assert Error(failure) = statem_parallel.check(spec, config())

  // The report is shown here so a reader can see what a failure looks like.
  io.println_error(statem_parallel.report(failure, counter.describe))

  assert failure.violation.tag == statem_parallel.not_linearizable_tag
  assert failure.seed == seed

  // Two increments, each alone in its branch, is the whole bug.
  assert failure.shrunk
    == Case(prefix: [], branches: [[Increment], [Increment]])

  let assert statem_parallel.Raced(histories, Some(explanation)) =
    failure.evidence
  assert list.length(histories) == 2
  assert list.length(explanation.placed) == 1
}

pub fn the_report_names_the_case_the_history_and_the_stuck_point_test() {
  let spec =
    counter.spec(
      service: ReadThenWrite,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let assert Error(failure) = statem_parallel.check(spec, config())
  let text = statem_parallel.report(failure, counter.describe)

  assert string.contains(text, "seed 41")
  assert string.contains(text, "[statem.not_linearizable]")
  assert string.contains(text, "branch 0:")
  assert string.contains(text, "branch 1:")
  assert string.contains(text, "failing history")
  assert string.contains(text, "Increment -> Value(1)")
  assert string.contains(text, "longest order found")
  assert string.contains(text, "violated [counter]")
}

// --- a system that is faulty only on some of its lives -----------------------

/// The counter, but every third system built is the racy one. The racy lives
/// fail every case that overlaps two increments, and the others never do, so
/// whether one execution of a candidate shows the bug depends only on which
/// life it landed on, which is a count and not a coin.
fn intermittent_spec() -> statem_parallel.Spec(
  Int,
  counter.Cmd,
  process.Subject(counter.Message),
  counter.Response,
) {
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: Intermittent,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )

  statem_parallel.Spec(..base, new_sut: fn() {
    counter.note(tally, "built")
    let sut = base.new_sut()

    case counter.count(tally, "built") % 3 {
      0 -> process.send(sut, counter.Configure(ReadThenWrite))
      _ -> Nil
    }

    sut
  })
}

/// The smallest case that shows a lost update.
fn two_increments() -> Case(counter.Cmd) {
  Case(prefix: [], branches: [[Increment], [Increment]])
}

pub fn an_intermittent_bug_shrinks_when_candidates_are_retried_test() {
  // Three executions per candidate always include a faulty life, so every
  // candidate that really contains the race is accepted, and the shrink
  // reaches the two-increment case.
  let patient =
    config()
    |> statem_parallel.with_repeat(3)
    |> statem_parallel.with_shrink_retries(3)

  let assert Error(failure) =
    statem_parallel.check(intermittent_spec(), patient)

  assert failure.shrunk == two_increments()
  assert failure.shrink_end == statem.ShrinkConverged
}

pub fn without_retries_an_intermittent_bug_stalls_the_shrink_test() {
  // One execution per candidate lands on a faulty life one time in three, so
  // candidates that do contain the race are usually refuted and the shrink
  // stops well short of the minimum. The same bug, the same seed.
  let impatient =
    config()
    |> statem_parallel.with_repeat(3)
    |> statem_parallel.with_shrink_retries(1)

  let assert Error(failure) =
    statem_parallel.check(intermittent_spec(), impatient)

  assert failure.shrunk != two_increments()
}

// --- a model that is wrong sequentially -------------------------------------

pub fn a_wrong_model_is_caught_in_the_prefix_test() {
  // The model thinks an increment adds two. Whatever the system does, the
  // first increment of the prefix disagrees, before anything races.
  let spec =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 2,
      guard: Unguarded,
    )
  let config =
    statem_parallel.default_config(seed: prefix_seed)
    |> statem_parallel.with_max_prefix(3)

  // The first run of this seed has a prefix. Without one the first
  // increment would sit in a branch and fail the check there instead.
  assert statem_parallel.generate_case(spec, config, 0).prefix != []

  let assert Error(failure) = statem_parallel.check(spec, config)

  assert failure.violation.tag == "counter"
  assert failure.shrunk == Case(prefix: [Increment], branches: [])

  let assert statem_parallel.InPrefix(0) = failure.evidence
}

// --- admissibility ----------------------------------------------------------

/// Every interleaving of the branches, each keeping its own order, as the
/// list of commands in the order they would run.
fn interleavings(branches: List(List(a))) -> List(List(a)) {
  case list.filter(branches, fn(branch) { branch != [] }) {
    [] -> [[]]

    live ->
      list.index_map(live, fn(branch, index) {
        let assert [head, ..tail] = branch
        let others =
          list.index_map(live, fn(other, position) {
            case position == index {
              True -> tail
              False -> other
            }
          })

        list.map(interleavings(others), fn(rest) { [head, ..rest] })
      })
      |> list.flatten
  }
}

/// Whether a sequence of commands never decrements at zero.
fn never_underflows(commands: List(counter.Cmd), count: Int) -> Bool {
  case commands {
    [] -> True

    [Decrement, ..rest] ->
      case count > 0 {
        True -> never_underflows(rest, count - 1)
        False -> False
      }

    [Increment, ..rest] -> never_underflows(rest, count + 1)
    [Read, ..rest] -> never_underflows(rest, count)
  }
}

fn guarded_spec() -> statem_parallel.Spec(
  Int,
  counter.Cmd,
  process.Subject(counter.Message),
  counter.Response,
) {
  counter.spec(
    service: Atomic,
    commands: [Decrement, Decrement, Increment, Read],
    step: 1,
    guard: Guarded,
  )
}

pub fn a_generated_case_is_admissible_in_every_interleaving_test() {
  let spec = guarded_spec()
  let config =
    config()
    |> statem_parallel.with_branches(3)
    |> statem_parallel.with_max_branch(3)
    |> statem_parallel.with_max_prefix(4)

  let cases =
    list.map(runs(200), statem_parallel.generate_case(spec, config, _))

  // The generator reaches the interesting commands, or the test is vacuous.
  assert list.any(cases, fn(generated) {
    list.any(generated.branches, list.contains(_, Decrement))
  })

  list.each(cases, fn(generated) {
    let Case(prefix, branches) = generated
    let after =
      list.fold(prefix, 0, fn(count, cmd) { counter_next(count, cmd) })

    assert never_underflows(prefix, 0)
    assert list.all(interleavings(branches), never_underflows(_, after))
  })
}

fn counter_next(count: Int, cmd: counter.Cmd) -> Int {
  case cmd {
    Increment -> count + 1
    Decrement -> count - 1
    Read -> count
  }
}

pub fn an_admissible_generation_never_underflows_the_real_counter_test() {
  // The counter answers `Underflow` to a decrement at zero and the
  // postcondition calls that a violation, so this passes only if no
  // interleaving of any generated case decrements at zero.
  case
    statem_parallel.check(
      guarded_spec(),
      config() |> statem_parallel.with_test_count(60),
    )
  {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem_parallel.report(failure, counter.describe)
  }
}

pub fn without_the_precondition_underflow_is_reached_test() {
  let unguarded =
    counter.spec(
      service: Atomic,
      commands: [Decrement, Decrement, Increment, Read],
      step: 1,
      guard: Unguarded,
    )

  let assert Error(failure) =
    statem_parallel.check(
      unguarded,
      config() |> statem_parallel.with_test_count(60),
    )

  // A decrement at zero lands in a branch, so the checker reports the
  // history as unorderable and names the underflow as the rule that blocked it.
  assert failure.violation.tag == statem_parallel.not_linearizable_tag

  let assert statem_parallel.Raced(_, Some(explanation)) = failure.evidence

  assert list.any(explanation.blocked, fn(blocked) {
    case blocked.obstacle {
      linearize.Violated(violation) -> violation.tag == "underflow"
      linearize.Overtaken(..) -> False
    }
  })
}

// --- determinism ------------------------------------------------------------

pub fn a_case_is_a_function_of_the_seed_and_the_run_test() {
  let spec = guarded_spec()

  let first = statem_parallel.generate_case(spec, config(), 3)
  let again = statem_parallel.generate_case(spec, config(), 3)
  let other_run = statem_parallel.generate_case(spec, config(), 4)

  // Test count and the shrink knobs do not enter the draw.
  let reconfigured =
    config()
    |> statem_parallel.with_test_count(7)
    |> statem_parallel.with_repeat(9)
    |> statem_parallel.with_max_shrinks(3)

  assert first == again
  assert first == statem_parallel.generate_case(spec, reconfigured, 3)
  assert first != other_run
}

pub fn generation_respects_the_configured_shape_test() {
  let spec = guarded_spec()
  let config =
    config()
    |> statem_parallel.with_branches(3)
    |> statem_parallel.with_max_branch(2)
    |> statem_parallel.with_max_prefix(1)

  list.each(runs(50), fn(run) {
    let Case(prefix, branches) =
      statem_parallel.generate_case(spec, config, run)

    assert list.length(prefix) <= 1
    assert list.length(branches) <= 3
    assert list.all(branches, fn(branch) {
      branch != [] && list.length(branch) <= 2
    })
  })
}

pub fn generation_keeps_the_interleavings_enumerable_test() {
  // Three branches of up to six commands have as many as seventeen million
  // interleavings, far past what admissibility can enumerate, so the
  // generator trims the longest branches until the count fits.
  let spec =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let wide =
    config()
    |> statem_parallel.with_branches(3)
    |> statem_parallel.with_max_branch(6)

  let counts =
    list.map(runs(100), fn(run) {
      let Case(_, branches) = statem_parallel.generate_case(spec, wide, run)

      interleave.count(list.map(branches, list.length))
    })

  assert list.all(counts, fn(count) {
    count <= statem_parallel.max_interleavings
  })

  // The bound bites: without it some draws would exceed it. A draw of three
  // branches of four or more commands already has more than 34,000.
  assert list.any(counts, fn(count) { count > 1000 })
}

// --- timeouts, crashes, undecided -------------------------------------------

pub fn a_branch_that_does_not_finish_is_a_timeout_test() {
  let owner = process.self()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 1,
      guard: Unguarded,
    )

  // The prefix runs on the test process and has no deadline, so the command
  // hangs only on a branch process.
  let spec =
    statem_parallel.Spec(..base, run: fn(sut, cmd) {
      case process.self() == owner {
        True -> counter.run(Atomic, sut, cmd)

        False -> {
          process.sleep(60_000)
          counter.run(Atomic, sut, cmd)
        }
      }
    })

  let slow =
    config()
    |> statem_parallel.with_deadline(150)
    |> statem_parallel.with_repeat(1)
    |> statem_parallel.with_shrink_retries(1)
    |> statem_parallel.with_max_shrinks(12)

  let assert Error(Failure(violation: violation, evidence: evidence, ..)) =
    statem_parallel.check(spec, slow)

  assert violation.tag == "statem.timeout"
  assert evidence == statem_parallel.Unrecorded
}

pub fn a_crash_inside_a_branch_is_a_crash_violation_test() {
  let owner = process.self()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(..base, run: fn(sut, cmd) {
      case process.self() == owner {
        True -> counter.run(Atomic, sut, cmd)
        False -> panic as "the call blew up"
      }
    })

  let quick =
    config()
    |> statem_parallel.with_repeat(1)
    |> statem_parallel.with_shrink_retries(1)

  let assert Error(failure) = statem_parallel.check(spec, quick)

  assert failure.violation.tag == "statem.crash"
  assert string.contains(failure.violation.detail, "the call blew up")
}

pub fn a_crash_in_new_sut_is_a_crash_violation_test() {
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 1,
      guard: Unguarded,
    )
  let spec = statem_parallel.Spec(..base, new_sut: fn() { panic as "no system" })

  let assert Error(failure) =
    statem_parallel.check(spec, config() |> statem_parallel.with_repeat(1))

  assert failure.violation.tag == "statem.crash"
  assert failure.evidence == statem_parallel.Unrecorded
}

pub fn a_crash_in_a_prefix_call_is_a_crash_in_the_prefix_test() {
  let owner = process.self()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(..base, run: fn(sut, cmd) {
      case process.self() == owner {
        True -> panic as "prefix call blew up"
        False -> counter.run(Atomic, sut, cmd)
      }
    })

  let assert Error(failure) =
    statem_parallel.check(
      spec,
      config()
        |> statem_parallel.with_max_prefix(2)
        |> statem_parallel.with_repeat(1),
    )

  assert failure.violation.tag == "statem.crash"
  assert failure.shrunk == Case(prefix: [Increment], branches: [])
}

pub fn an_exhausted_search_budget_is_a_failure_not_a_pass_test() {
  let spec =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )

  let assert Error(failure) =
    statem_parallel.check(
      spec,
      config() |> statem_parallel.with_search_budget(0),
    )

  assert failure.violation.tag == "statem.undecided"

  let assert statem_parallel.Raced(_, None) = failure.evidence
}

// --- resources --------------------------------------------------------------

pub fn teardown_runs_once_for_every_system_built_test() {
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: ReadThenWrite,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(
      ..base,
      new_sut: fn() {
        counter.note(tally, "built")
        base.new_sut()
      },
      teardown: fn(sut) {
        counter.note(tally, "torn down")
        base.teardown(sut)
      },
    )

  // A racy counter makes the check fail and shrink, which builds many
  // systems on paths that fail, pass, and are retried.
  let assert Error(_) = statem_parallel.check(spec, config())

  let built = counter.count(tally, "built")

  assert built > 1
  assert counter.count(tally, "torn down") == built
}

pub fn teardown_runs_when_a_branch_crashes_test() {
  let tally = counter.start_tally()
  let owner = process.self()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(
      ..base,
      new_sut: fn() {
        counter.note(tally, "built")
        base.new_sut()
      },
      run: fn(sut, cmd) {
        case process.self() == owner {
          True -> counter.run(Atomic, sut, cmd)
          False -> panic as "boom"
        }
      },
      teardown: fn(sut) {
        counter.note(tally, "torn down")
        base.teardown(sut)
      },
    )

  let assert Error(_) =
    statem_parallel.check(
      spec,
      config()
        |> statem_parallel.with_repeat(1)
        |> statem_parallel.with_shrink_retries(1),
    )

  let built = counter.count(tally, "built")

  assert built > 0
  assert counter.count(tally, "torn down") == built
}

pub fn teardown_runs_when_next_model_crashes_in_the_prefix_test() {
  // A pure model step that crashes would crash generation first, so the
  // only one that reaches an execution is impure. This one crashes only
  // while a system is live (built but not yet torn down), which is never
  // true during generation or a shrink's admissibility replay. Unrescued in
  // the prefix, that crash would unwind past teardown.
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(
      ..base,
      new_sut: fn() {
        counter.note(tally, "built")
        base.new_sut()
      },
      next_model: fn(model, cmd) {
        let live =
          counter.count(tally, "built") - counter.count(tally, "torn down")

        case live > 0 {
          True -> panic as "model step"
          False -> base.next_model(model, cmd)
        }
      },
      teardown: fn(sut) {
        counter.note(tally, "torn down")
        base.teardown(sut)
      },
    )

  let assert Error(failure) =
    statem_parallel.check(
      spec,
      config()
        |> statem_parallel.with_repeat(1)
        |> statem_parallel.with_shrink_retries(1),
    )

  let built = counter.count(tally, "built")

  assert failure.violation.tag == "statem.crash"
  assert built > 0
  assert counter.count(tally, "torn down") == built
}

pub fn teardown_runs_when_new_sut_crashes_after_a_good_system_test() {
  // A passing check builds and tears down once per run per repeat.
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(
      ..base,
      new_sut: fn() {
        counter.note(tally, "built")
        base.new_sut()
      },
      teardown: fn(sut) {
        counter.note(tally, "torn down")
        base.teardown(sut)
      },
    )

  let assert Ok(Nil) =
    statem_parallel.check(
      spec,
      config()
        |> statem_parallel.with_test_count(5)
        |> statem_parallel.with_repeat(2),
    )

  assert counter.count(tally, "built") == 10
  assert counter.count(tally, "torn down") == 10
}

// --- the shrink bound -------------------------------------------------------

pub fn a_shrink_stop_ends_the_search_at_the_first_candidate_test() {
  let spec =
    counter.spec(
      service: ReadThenWrite,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let stopped =
    config() |> statem_parallel.with_shrink_stop(fn() { statem.StopShrinking })

  let assert Error(failure) = statem_parallel.check(spec, stopped)

  assert failure.shrink_end == statem.ShrinkBoundHit
  assert failure.shrinks == 0
  assert failure.candidates_run == 0
  assert failure.shrunk == failure.original
}

pub fn a_zero_shrink_budget_reports_the_original_case_test() {
  let spec =
    counter.spec(
      service: ReadThenWrite,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )

  let assert Error(failure) =
    statem_parallel.check(spec, config() |> statem_parallel.with_max_shrinks(0))

  assert failure.shrunk == failure.original
  assert failure.shrink_end == statem.ShrinkBoundHit
}

pub fn check_run_reproduces_a_numbered_run_test() {
  let spec =
    counter.spec(
      service: ReadThenWrite,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )

  let assert Error(first) = statem_parallel.check(spec, config())
  let assert Error(again) = statem_parallel.check_run(spec, config(), first.run)

  // The case is the same; the interleaving, which decides how far it shrinks,
  // is not promised to be.
  assert again.original == first.original
  assert again.run == first.run
}

// --- finish -----------------------------------------------------------------

/// The value the counter holds, read through its own mailbox.
fn current(sut: process.Subject(counter.Message)) -> Int {
  let assert counter.Value(value) = counter.run(Atomic, sut, Read)
    as "a read answers with a value"

  value
}

pub fn a_finish_violation_fails_under_its_own_tag_and_shrinks_test() {
  // The counter is correct, so every race has an order. Only the audit at
  // the end can fail, and it does once three increments have landed, which
  // no single response shows.
  let base =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(..base, finish: fn(sut) {
      case current(sut) >= 3 {
        True -> Error(statem.Violation(tag: "audit", detail: "three or more"))
        False -> Ok(Nil)
      }
    })

  let assert Error(failure) = statem_parallel.check(spec, config())

  assert failure.violation.tag == "audit"

  // The audit needs three increments and nothing else, wherever they run,
  // so the shrink keeps exactly those three.
  let Case(prefix, branches) = failure.shrunk
  let commands = list.append(prefix, list.flatten(branches))

  assert commands == [Increment, Increment, Increment]
  assert failure.shrinks > 0

  let assert statem_parallel.AfterRace(_) = failure.evidence
}

pub fn finish_is_not_called_after_a_race_that_failed_test() {
  // The model thinks an increment adds two, and with no prefix every
  // increment races, so every execution fails in the checker. Finish would
  // have nothing left to decide, and must not run.
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Increment],
      step: 2,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(..base, finish: fn(_) {
      counter.note(tally, "finished")
      Ok(Nil)
    })

  let assert Error(failure) =
    statem_parallel.check(
      spec,
      config()
        |> statem_parallel.with_max_prefix(0)
        |> statem_parallel.with_repeat(1)
        |> statem_parallel.with_max_shrinks(0),
    )

  // Shrinking is off: a shrink may try a case with nothing left to race,
  // which is linearizable and so rightly reaches finish.
  assert failure.violation.tag == statem_parallel.not_linearizable_tag
  assert counter.count(tally, "finished") == 0
}

pub fn a_crash_in_finish_is_a_crash_and_teardown_still_runs_test() {
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: Atomic,
      commands: all_commands(),
      step: 1,
      guard: Unguarded,
    )
  let spec =
    statem_parallel.Spec(
      ..base,
      new_sut: fn() {
        counter.note(tally, "built")
        base.new_sut()
      },
      finish: fn(_) { panic as "the audit blew up" },
      teardown: fn(sut) {
        counter.note(tally, "torn down")
        base.teardown(sut)
      },
    )

  let assert Error(failure) =
    statem_parallel.check(
      spec,
      config()
        |> statem_parallel.with_repeat(1)
        |> statem_parallel.with_shrink_retries(1),
    )

  let built = counter.count(tally, "built")

  assert failure.violation.tag == "statem.crash"
  assert string.contains(failure.violation.detail, "finish")
  assert string.contains(failure.violation.detail, "the audit blew up")

  let assert statem_parallel.AfterRace(_) = failure.evidence

  assert built > 0
  assert counter.count(tally, "torn down") == built
}

// --- a case that races nothing ----------------------------------------------

pub fn a_model_with_no_concurrent_pair_fails_as_no_race_test() {
  // From one, a guarded decrement is admissible on its own, but two of them
  // in different branches have an interleaving that decrements at zero. No
  // two branches are ever admissible together, so every case is left with
  // one branch, and the check must say so rather than pass without racing.
  let tally = counter.start_tally()
  let base =
    counter.spec(
      service: Atomic,
      commands: [Decrement],
      step: 1,
      guard: Guarded,
    )
  let spec =
    statem_parallel.Spec(..base, initial: 1, new_sut: fn() {
      counter.note(tally, "built")
      base.new_sut()
    })
  let no_prefix = config() |> statem_parallel.with_max_prefix(0)

  let drawn = statem_parallel.generate_case(spec, no_prefix, 0)

  assert list.length(drawn.branches) < 2

  let assert Error(failure) = statem_parallel.check(spec, no_prefix)

  assert failure.violation.tag == statem_parallel.no_race_tag
  assert failure.run == 0
  assert failure.evidence == statem_parallel.NoRace
  assert failure.shrunk == drawn
  assert failure.candidates_run == 0
  assert counter.count(tally, "built") == 0
  assert string.contains(
    statem_parallel.report(failure, counter.describe),
    "[statem.no_race]",
  )
}
