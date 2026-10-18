import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import gleam/yielder
import gleeunit
import qcheck
import qcheck/tree.{Tree}
import statem.{
  type Failure, type Spec, type Violation, Admit, Config, Reject, ShrinkBoundHit,
  ShrinkConverged, Spec, StepFailure, Violation,
}
import statem/internal/retry

pub fn main() -> Nil {
  gleeunit.main()
}

// --- a toy system with injectable bugs ------------------------------------

type Command {
  Push(Int)
  Pop
  Clear
}

/// Which defect the queue under test carries. A constructor parameter
/// rather than a flag so each test names the bug it expects to find.
type Bug {
  NoBug
  /// `Pop` on a queue holding exactly two items returns the newest one.
  /// Needs `Push a, Push b, Pop` with `a != b`, in that order.
  PopWrongAtTwo
  /// `Clear` is ignored once a `Push(9)` has ever happened. Needs a nine
  /// and a later clear, with anything at all between them.
  ClearAfterNine
  BothBugs
}

type Marker {
  NineSeen
  NineNotSeen
}

type Queue {
  Queue(bug: Bug, items: List(Int), marker: Marker, executed: Int)
}

/// The model is the queue's contents and how many commands have run, so a
/// system that survived from an earlier execution is caught at once.
type Model {
  Model(items: List(Int), executed: Int)
}

fn has_pop_bug(bug: Bug) -> Bool {
  bug == PopWrongAtTwo || bug == BothBugs
}

fn has_clear_bug(bug: Bug) -> Bool {
  bug == ClearAfterNine || bug == BothBugs
}

fn new_queue(bug: Bug) -> Queue {
  Queue(bug: bug, items: [], marker: NineNotSeen, executed: 0)
}

fn command_generator(_model: Model) -> qcheck.Generator(Command) {
  qcheck.map2(
    qcheck.bounded_int(from: 0, to: 3),
    qcheck.bounded_int(from: 0, to: 9),
    fn(kind, value) {
      case kind {
        0 | 1 -> Push(value)
        2 -> Pop
        _ -> Clear
      }
    },
  )
}

fn precondition(model: Model, command: Command) -> statem.Admission {
  case command, model.items {
    Pop, [] -> Reject
    _, _ -> Admit
  }
}

fn next_model(model: Model, command: Command) -> Model {
  let executed = model.executed + 1

  case command, model.items {
    Push(value), items -> Model(list.append(items, [value]), executed)
    Pop, [_, ..rest] -> Model(rest, executed)
    Pop, [] -> Model([], executed)
    Clear, _ -> Model([], executed)
  }
}

/// An inadmissible command reaching the system is a panic, not a violation:
/// a violation could be filtered out by the tag check, and the point is that
/// it never happens at all.
fn execute(
  queue: Queue,
  model: Model,
  command: Command,
) -> Result(Queue, Violation) {
  case queue.executed == model.executed {
    False -> Error(Violation("stale", "the system outlived its execution"))
    True ->
      run_command(Queue(..queue, executed: queue.executed + 1), model, command)
  }
}

fn run_command(
  queue: Queue,
  model: Model,
  command: Command,
) -> Result(Queue, Violation) {
  case command, queue.items, model.items {
    Push(value), items, _ -> {
      let marker = case value == 9 {
        True -> NineSeen
        False -> queue.marker
      }
      Ok(Queue(..queue, items: list.append(items, [value]), marker: marker))
    }

    Pop, [head, ..rest], [expected, ..] -> {
      let returned = case has_pop_bug(queue.bug), rest {
        True, [only] -> only
        _, _ -> head
      }
      case returned == expected {
        True -> Ok(Queue(..queue, items: rest))
        False ->
          Error(Violation(
            "fifo",
            "popped "
              <> int.to_string(returned)
              <> ", wanted "
              <> int.to_string(expected),
          ))
      }
    }

    Pop, _, _ -> panic as "a Pop on an empty model reached the system"

    Clear, items, _ -> {
      let kept = case has_clear_bug(queue.bug), queue.marker {
        True, NineSeen -> items
        _, _ -> []
      }
      case kept {
        [] -> Ok(Queue(..queue, items: []))
        _ -> Error(Violation("clear", "clear left items behind"))
      }
    }
  }
}

fn queue_spec(bug: Bug) -> Spec(Model, Command, Queue) {
  Spec(
    initial: Model([], 0),
    command: command_generator,
    precondition: precondition,
    next_model: next_model,
    new_sut: fn() { new_queue(bug) },
    execute: execute,
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn config(seed: Int) -> statem.Config {
  statem.default_config(seed: seed)
  |> statem.with_test_count(200)
  |> statem.with_max_commands(20)
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

fn failure_of(
  spec: Spec(Model, Command, Queue),
  seed: Int,
) -> Failure(Command) {
  case statem.check(spec, config(seed)) {
    Error(failure) -> failure
    Ok(Nil) -> panic as "the injected bug was never found"
  }
}

fn runs(from: Int, to: Int) -> List(Int) {
  yielder.range(from, to) |> yielder.to_list
}

fn seeds() -> List(Int) {
  yielder.range(1, 40) |> yielder.to_list
}

// --- the tests --------------------------------------------------------------

pub fn a_correct_system_passes_test() {
  assert statem.check(queue_spec(NoBug), config(1)) == Ok(Nil)
}

pub fn a_pattern_bug_shrinks_to_the_minimal_sequence_test() {
  let failure = failure_of(queue_spec(PopWrongAtTwo), 2)

  assert failure.shrunk == [Push(0), Push(1), Pop]
  assert failure.violation.tag == "fifo"
  assert failure.step == 2
  assert failure.shrink_end == ShrinkConverged
}

pub fn a_bug_across_noise_shrinks_by_deleting_the_middle_test() {
  let failure = failure_of(queue_spec(ClearAfterNine), 3)

  assert failure.shrunk == [Push(9), Clear]
  assert failure.step == 1

  // The nine and the clear were not adjacent as generated, so the shrink had
  // to remove commands from between them, which a prefix cut cannot do.
  assert list.length(failure.original) > 3
}

pub fn no_executed_list_violates_a_precondition_test() {
  // `execute` panics on an inadmissible command, so surviving a full check
  // that also shrinks proves neither generation nor any shrink candidate
  // executed one. Both bugs make the shrinker run many candidates.
  let both = failure_of(queue_spec(BothBugs), 4)
  let pop = failure_of(queue_spec(PopWrongAtTwo), 5)

  assert both.candidates_run > 0
  assert pop.candidates_run > 0
}

pub fn shrinking_keeps_the_original_tag_test() {
  let spec = queue_spec(BothBugs)
  let failures = list.map(seeds(), fn(seed) { failure_of(spec, seed) })

  // Each shrunk failure has the tag its own original list fails with.
  list.each(failures, fn(failure) {
    let assert Error(StepFailure(violation: original, ..)) =
      statem.replay(spec, failure.original)
      as "the original list must still fail"
    assert original.tag == failure.violation.tag
  })

  // Both bugs were the first failure for some seed, so the filter was
  // genuinely choosing between a longer reproduction and a shorter one of
  // the other bug.
  let tags = list.map(failures, fn(failure) { failure.violation.tag })
  assert list.contains(tags, "fifo")
  assert list.contains(tags, "clear")
}

pub fn the_same_config_gives_the_same_failure_test() {
  let first = statem.check(queue_spec(BothBugs), config(6))
  let second = statem.check(queue_spec(BothBugs), config(6))

  assert first == second
  assert first != Ok(Nil)
}

pub fn a_run_reproduces_from_its_seed_and_index_test() {
  let failure = failure_of(queue_spec(PopWrongAtTwo), 7)

  assert statem.check_run(queue_spec(PopWrongAtTwo), config(7), failure.run)
    == Error(failure)
}

pub fn the_shrink_bound_is_honoured_test() {
  let spec = queue_spec(PopWrongAtTwo)
  let tight = statem.with_max_shrinks(config(2), 3)
  let assert Error(bounded) = statem.check(spec, tight)
    as "the bug must be found"

  assert bounded.candidates_run <= 3
  assert bounded.shrink_end == ShrinkBoundHit

  let none = statem.with_max_shrinks(config(2), 0)
  let assert Error(unshrunk) = statem.check(spec, none)
    as "the bug must be found"

  assert unshrunk.shrunk == unshrunk.original
  assert unshrunk.candidates_run == 0
  assert unshrunk.shrink_end == ShrinkBoundHit
}

fn keep_going() -> statem.ShrinkStop {
  statem.KeepShrinking
}

fn stop_now() -> statem.ShrinkStop {
  statem.StopShrinking
}

pub fn a_stop_that_answers_stop_ends_shrinking_before_any_candidate_test() {
  let spec = queue_spec(PopWrongAtTwo)
  let assert Error(full) = statem.check(spec, config(2))
    as "the bug must be found"
  let assert Error(stopped) =
    statem.check(spec, statem.with_shrink_stop(config(2), stop_now))
    as "the failing run is never gated"

  // The same run fails either way, and it is reported unshrunk, as a bound
  // hit with nothing executed, even though the full search would shrink it.
  assert stopped.run == full.run
  assert stopped.original == full.original
  assert full.shrunk != full.original
  assert stopped.shrunk == stopped.original
  assert stopped.shrinks == 0
  assert stopped.candidates_run == 0
  assert stopped.shrink_end == ShrinkBoundHit
}

pub fn a_stop_that_keeps_shrinking_changes_nothing_test() {
  let spec = queue_spec(PopWrongAtTwo)
  let kept = statem.with_shrink_stop(config(2), keep_going)

  assert statem.check(spec, kept) == statem.check(spec, config(2))
}

pub fn a_rejecting_generator_ends_the_list_early_test() {
  let spec = Spec(..queue_spec(NoBug), precondition: fn(_, _) { Reject })

  assert statem.check(spec, config(8)) == Ok(Nil)
}

pub fn replay_runs_one_exact_list_test() {
  let spec = queue_spec(PopWrongAtTwo)

  assert statem.replay(spec, [Push(0), Push(1), Pop])
    == Error(StepFailure(
      step: 2,
      violation: Violation("fifo", "popped 1, wanted 0"),
    ))
  assert statem.replay(spec, [Push(1), Push(1), Pop]) == Ok(Nil)

  let assert Error(StepFailure(step: 0, violation: rejected)) =
    statem.replay(spec, [Pop])
    as "an inadmissible list is reported, not run"
  assert rejected.tag == "statem.precondition"
}

pub fn finish_failures_report_one_past_the_last_step_test() {
  let spec =
    Spec(..queue_spec(NoBug), finish: fn(_, _) {
      Error(Violation("end", "always"))
    })

  assert statem.replay(spec, [Push(1)])
    == Error(StepFailure(step: 1, violation: Violation("end", "always")))

  let failure = failure_of(spec, 9)
  assert failure.shrunk == []
  assert failure.step == 0
}

pub fn the_report_names_the_seed_run_and_failing_step_test() {
  let failure = failure_of(queue_spec(PopWrongAtTwo), 2)
  let text = statem.report(failure, describe)

  assert string.contains(text, "seed 2")
  assert string.contains(text, "[fifo]")
  assert string.contains(text, "  > 2. Pop")
  assert string.contains(text, "converged")
}

pub fn config_builders_clamp_negative_values_test() {
  let clamped =
    statem.default_config(seed: 1)
    |> statem.with_test_count(-1)
    |> statem.with_max_commands(-1)
    |> statem.with_max_shrinks(-1)
    |> statem.with_shrink_retries(0)

  // The stop predicate is a function, so it is read through its answer
  // rather than compared with `==`.
  assert Config(..clamped, shrink_stop: keep_going)
    == Config(
      test_count: 0,
      seed: 1,
      max_commands: 0,
      max_shrinks: 0,
      shrink_retries: 1,
      shrink_stop: keep_going,
    )
  assert clamped.shrink_stop() == statem.KeepShrinking
  assert int.compare(clamped.test_count, 0) == order.Eq
}

// --- crashes -----------------------------------------------------------------

/// A queue spec whose `Pop` on exactly two items fails an `assert` inside
/// `execute`, the way a consumer's step asserts instead of returning `Error`.
fn asserting_spec() -> Spec(Model, Command, Queue) {
  Spec(
    ..queue_spec(NoBug),
    execute: fn(queue: Queue, model: Model, command: Command) {
      case command, model.items {
        Pop, [_, _] -> {
          assert model.executed < 0 as "pop at two"
          Ok(queue)
        }
        _, _ -> execute(queue, model, command)
      }
    },
  )
}

pub fn an_assert_inside_execute_is_a_shrunk_tagged_failure_test() {
  let failure = failure_of(asserting_spec(), 2)

  assert failure.violation.tag == "statem.crash"
  assert string.contains(failure.violation.detail, "pop at two")
  assert string.contains(failure.violation.detail, "execute crashed")
  assert failure.shrunk == [Push(0), Push(0), Pop]
  assert failure.step == 2
  assert failure.shrink_end == ShrinkConverged

  let text = statem.report(failure, describe)
  assert string.contains(text, "seed 2, run " <> int.to_string(failure.run))
  assert string.contains(text, "[statem.crash]")
}

pub fn a_crash_does_not_slip_to_another_failure_test() {
  // Both a crash and a `fifo` violation are reachable; the shrunk list of
  // each failure must keep the tag its own original list fails with.
  let spec =
    Spec(
      ..queue_spec(PopWrongAtTwo),
      execute: fn(queue: Queue, model: Model, command: Command) {
        case command, model.items {
          Clear, [_, _, _, ..] -> panic as "clear of three"
          _, _ -> execute(queue, model, command)
        }
      },
    )
  let failures = list.map(seeds(), fn(seed) { failure_of(spec, seed) })

  list.each(failures, fn(failure) {
    let assert Error(StepFailure(violation: original, ..)) =
      statem.replay(spec, failure.original)
      as "the original list must still fail"
    assert original.tag == failure.violation.tag
  })

  let tags = list.map(failures, fn(failure) { failure.violation.tag })
  assert list.contains(tags, "statem.crash")
  assert list.contains(tags, "fifo")
}

pub fn a_crash_in_finish_or_new_sut_is_a_violation_test() {
  let finishing =
    Spec(..queue_spec(NoBug), finish: fn(_, _) { panic as "finish blew up" })
  let failure = failure_of(finishing, 3)
  assert failure.violation.tag == "statem.crash"
  assert string.contains(failure.violation.detail, "finish crashed")
  assert failure.shrunk == []

  let building =
    Spec(..queue_spec(NoBug), new_sut: fn() { panic as "no system" })
  let failure = failure_of(building, 3)
  assert failure.violation.tag == "statem.crash"
  assert string.contains(failure.violation.detail, "new_sut crashed")
  assert failure.step == 0
}

pub fn a_crashing_teardown_never_escapes_test() {
  let passing =
    Spec(..queue_spec(NoBug), teardown: fn(_) { panic as "teardown blew up" })
  assert statem.check(passing, config(1)) == Ok(Nil)

  let failing =
    Spec(..queue_spec(PopWrongAtTwo), teardown: fn(_) {
      panic as "teardown blew up"
    })
  assert failure_of(failing, 2).shrunk == [Push(0), Push(1), Pop]
}

// --- the commands accessor ------------------------------------------------------

pub fn commands_is_the_original_of_the_failing_run_test() {
  let spec = queue_spec(PopWrongAtTwo)
  let failure = failure_of(spec, 2)

  assert statem.commands(spec, config(2), failure.run) == failure.original
  assert statem.commands(spec, config(2), failure.run)
    == statem.commands(spec, config(2), failure.run)
}

pub fn commands_vary_across_runs_and_stay_admissible_test() {
  let spec = queue_spec(NoBug)
  let lists =
    list.map(runs(0, 30), fn(run) { statem.commands(spec, config(5), run) })

  assert list.any(lists, fn(commands) { list.contains(commands, Clear) })
  assert list.unique(lists) != [[]]
  list.each(lists, fn(commands) {
    assert statem.replay(spec, commands) == Ok(Nil)
  })
}

// --- seeds ----------------------------------------------------------------------

pub fn any_int_seed_reproduces_a_run_test() {
  let spec = queue_spec(PopWrongAtTwo)

  list.each(
    [-7, 0, 9_000_000_000, 4_294_967_296, 123_456_789_012_345],
    fn(seed) {
      let cfg =
        statem.default_config(seed: seed) |> statem.with_max_commands(20)
      let lists = list.map(runs(0, 5), statem.commands(spec, cfg, _))

      assert lists == list.map(runs(0, 5), statem.commands(spec, cfg, _))
    },
  )
}

// --- the shrink search ----------------------------------------------------------

type Wide {
  Real(Int)
  Bogus(Int)
}

type Count {
  Count(commands: Int)
}

/// A command whose shrink tree holds `children` children, every one
/// inadmissible, or an infinite supply of them.
fn wide_generator(
  children: yielder.Yielder(tree.Tree(Wide)),
) -> fn(Count) -> qcheck.Generator(Wide) {
  fn(_model) {
    qcheck.Generator(fn(seed) {
      let #(drawn, seed) = qcheck.generate_tree(qcheck.bounded_int(0, 9), seed)
      let Tree(value, _) = drawn

      #(Tree(Real(value), children), seed)
    })
  }
}

/// A system that fails only in `finish`, once `fail_at` commands have run.
fn wide_spec(
  children: yielder.Yielder(tree.Tree(Wide)),
  fail_at: Int,
) -> Spec(Count, Wide, Int) {
  Spec(
    initial: Count(0),
    command: wide_generator(children),
    precondition: fn(_, command) {
      case command {
        Real(_) -> Admit
        Bogus(_) -> Reject
      }
    },
    next_model: fn(model, _) { Count(model.commands + 1) },
    new_sut: fn() { 0 },
    execute: fn(executed, _, _) { Ok(executed + 1) },
    finish: fn(executed, _) {
      case executed >= fail_at {
        True ->
          Error(Violation("long", "list reached " <> int.to_string(executed)))
        False -> Ok(Nil)
      }
    },
    teardown: fn(_) { Nil },
  )
}

fn bogus_children(count: Int) -> yielder.Yielder(tree.Tree(Wide)) {
  yielder.range(0, count - 1)
  |> yielder.map(fn(index) { tree.return(Bogus(index)) })
}

pub fn thousands_of_inadmissible_candidates_do_not_overflow_the_stack_test() {
  // Thirty commands with three thousand rejected replacements each: ninety
  // thousand free candidates in a single search. A search that spent a stack
  // frame per candidate overflowed on the JavaScript target.
  let cfg =
    statem.default_config(seed: 1)
    |> statem.with_max_commands(30)
    |> statem.with_test_count(200)
  let assert Error(failure) =
    statem.check(wide_spec(bogus_children(3000), 30), cfg)
    as "a run of thirty commands must be drawn"

  assert list.length(failure.shrunk) == 30
  assert failure.shrink_end == ShrinkConverged
  assert failure.candidates_run == 99
}

pub fn an_infinite_inadmissible_tree_still_terminates_test() {
  let cfg =
    statem.default_config(seed: 1)
    |> statem.with_max_commands(3)
    |> statem.with_test_count(50)
  let infinite = yielder.repeat(tree.return(Bogus(0)))
  let assert Error(failure) = statem.check(wide_spec(infinite, 1), cfg)
    as "a non-empty run must be drawn"

  assert list.length(failure.shrunk) == 1
  assert failure.shrink_end == ShrinkBoundHit
}

pub fn the_whole_list_is_executed_once_not_every_round_test() {
  // Failing in `finish` regardless of the commands, so the first candidate
  // reproduces: the empty list is accepted and the shrink ends converged on
  // one execution, whatever the (generous) budget.
  let spec =
    Spec(..queue_spec(NoBug), finish: fn(_, _) {
      Error(Violation("end", "always"))
    })
  let cfg = config(9) |> statem.with_max_shrinks(1)
  let assert Ok(run) =
    list.find(runs(0, 50), fn(run) { statem.commands(spec, cfg, run) != [] })
    as "some run must be non-empty"
  let assert Error(failure) = statem.check_run(spec, cfg, run)
    as "finish always fails"

  assert failure.shrunk == []
  assert failure.candidates_run == 1
  assert failure.shrink_end == ShrinkConverged
}

pub fn a_round_never_re_executes_the_empty_list_test() {
  // `Clear` after a nine needs two commands. With the whole list offered only
  // once, shrinking to that pair costs far fewer executions than one empty
  // list per descent round would add on top.
  let failure = failure_of(queue_spec(ClearAfterNine), 3)

  assert failure.shrunk == [Push(9), Clear]
  assert failure.candidates_run
    < failure.shrinks * list.length(failure.original) + 1
}

// --- shrink retries ---------------------------------------------------------------

/// A `run` that fails with its attempt index on the listed attempts only.
fn failing_on(attempts: List(Int)) -> fn(Int) -> Result(Nil, Int) {
  fn(attempt) {
    case list.contains(attempts, attempt) {
      True -> Error(attempt)
      False -> Ok(Nil)
    }
  }
}

fn any_failure(_failure: Int) -> Bool {
  True
}

pub fn a_later_failing_attempt_accepts_the_candidate_test() {
  assert retry.first_failure(4, 100, failing_on([2]), any_failure)
    == retry.Attempted(accepted: Some(2), executions: 3)
}

pub fn the_first_failing_attempt_stops_the_retries_test() {
  assert retry.first_failure(4, 100, failing_on([0, 1]), any_failure)
    == retry.Attempted(accepted: Some(0), executions: 1)
}

pub fn no_failing_attempt_rejects_the_candidate_test() {
  assert retry.first_failure(3, 100, failing_on([]), any_failure)
    == retry.Attempted(accepted: None, executions: 3)

  // A failure beyond the allowance is never seen.
  assert retry.first_failure(3, 100, failing_on([3]), any_failure)
    == retry.Attempted(accepted: None, executions: 3)
}

pub fn a_failure_under_another_tag_does_not_count_test() {
  // Attempt 0 fails differently, attempt 2 fails as wanted.
  let wanted = fn(failure) { failure == 2 }

  assert retry.first_failure(4, 100, failing_on([0, 2]), wanted)
    == retry.Attempted(accepted: Some(2), executions: 3)
  assert retry.first_failure(2, 100, failing_on([0, 2]), wanted)
    == retry.Attempted(accepted: None, executions: 2)
}

pub fn retries_stop_when_the_budget_does_test() {
  assert retry.first_failure(5, 2, failing_on([3]), any_failure)
    == retry.Attempted(accepted: None, executions: 2)
  assert retry.first_failure(5, 1, failing_on([]), any_failure)
    == retry.Attempted(accepted: None, executions: 1)
}

pub fn retried_executions_count_against_the_shrink_budget_test() {
  let spec = queue_spec(PopWrongAtTwo)
  let cfg =
    config(2)
    |> statem.with_max_shrinks(7)
    |> statem.with_shrink_retries(3)
  let assert Error(failure) = statem.check(spec, cfg) as "the bug must be found"

  // A deterministic bug is refuted three times per rejected candidate, and
  // the retries stop with the budget rather than overshooting it.
  assert failure.candidates_run == 7
  assert failure.shrink_end == ShrinkBoundHit
}

// --- the report -------------------------------------------------------------------

pub fn the_report_lists_both_the_original_and_the_shrunk_list_test() {
  let failure = failure_of(queue_spec(ClearAfterNine), 3)
  let text = statem.report(failure, describe)

  assert string.contains(text, "step 1")
  assert string.contains(
    text,
    "original list: "
      <> int.to_string(list.length(failure.original))
      <> " commands",
  )
  assert string.contains(text, "shrunk list: 2 commands")
  assert string.contains(text, "executions")
  assert string.contains(text, "    0. Push(9)")
  assert string.contains(text, "  > 1. Clear")

  // Every original command is printed, not only counted.
  let printed =
    list.count(string.split(text, "\n"), fn(line) {
      string.contains(line, ". Push(")
      || string.contains(line, ". Pop")
      || string.contains(line, ". Clear")
    })
  assert printed >= list.length(failure.original) + 2
}
