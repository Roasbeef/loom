import gleam/int
import gleam/list
import gleam/order
import gleam/string
import gleam/yielder
import gleeunit
import qcheck
import statem.{
  type Failure, type Spec, type Violation, Admit, Config, Reject, ShrinkBoundHit,
  ShrinkConverged, Spec, StepFailure, Violation,
}

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

  assert clamped
    == Config(test_count: 0, seed: 1, max_commands: 0, max_shrinks: 0)
  assert int.compare(clamped.test_count, 0) == order.Eq
}
