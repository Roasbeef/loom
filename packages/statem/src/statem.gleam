//// Stateful, model-based property testing on top of qcheck.
////
//// qcheck draws independent values. A stateful system is not tested by
//// independent values: the interesting failures need a command that is only
//// meaningful after other commands, and the minimal reproduction is the
//// shortest command list that still reaches the bug. This module is the
//// layer between the two. A caller describes the system as a `Spec`: an
//// abstract model, a generator of commands plausible in a model, a
//// precondition that says whether a command may run in a model, a pure
//// `next_model` that advances the model, and an `execute` hook that runs a
//// command on a real system under test and checks what came back. `check`
//// then generates command lists, runs them, and on a failure shrinks the
//// list to a short one that fails the same way.
////
//// ## Why not `qcheck.run` and `qcheck.list`
////
//// Three properties of the stock combinators rule them out here. A list of
//// independent elements cannot let element `k` depend on the model after
//// elements `0..k-1`. `qcheck.bind` regenerates everything downstream of a
//// shrunk value and discards the inner generator's seed, so a sequence built
//// from nested binds shrinks into different commands rather than fewer ones.
//// And `qcheck.run` shrinks to whatever still panics, so a shrink can slip
//// from the bug that was found to a different one. The generator below
//// threads the seed and the model by hand through public qcheck API, keeps
//// each command's own shrink tree, and the driver below shrinks with its own
//// loop, which returns a `Result` and so needs no `panic` in this package.
////
//// ## The model
////
//// Commands are plain data, a consumer's custom type, never closures: a
//// list of them can be printed, replayed and re-validated against a model
//// without touching the system under test. `next_model` is pure and
//// symbolic for the same reason. It runs during generation, and again when a
//// shrink candidate is replayed to ask whether every precondition still
//// holds, so a candidate that deleted the command a later one depended on is
//// discarded without ever being executed.
////
//// There is one execution hook, not a separate postcondition. `execute` is
//// given the system, the model as it was BEFORE the command, and the
//// command, and returns the advanced system or a `Violation`. A test whose
//// oracle must observe the system's outputs keeps the oracle inside `sut`
//// and uses a coarse `model`; that is the intended shape, not a workaround.
////
//// ## Generation, shrinking and determinism
////
//// Run `i` of a check draws its command list from a seed derived from
//// `(config.seed, i)` alone, so any run reproduces without the runs before
//// it, and the `Failure` names both numbers. There is deliberately no random
//// default seed: a red gate must be the same red gate on every machine.
////
//// A failing list is shrunk greedily. Candidates come in two groups, in
//// order: delete a contiguous chunk (the whole list, then halves, quarters,
//// down to single commands, at every offset), then replace one command by
//// each child of its own shrink tree. The first candidate that is admissible
//// and fails with the SAME `Violation.tag` as the original is accepted and
//// the search restarts from it. Deleting from the middle is what qcheck
//// lists cannot do, and it is what lets a bug that needs two commands
//// separated by noise shrink to just the two.
////
//// Commands that name state by value (a key, a handle) shrink badly,
//// because deleting the command that created the value leaves its users
//// inadmissible. Prefer commands that name state by index or by position in
//// the model, so a shortened list is another valid list.
////
//// The pieces, in the order a failure meets them: `run_seed` derives one
//// run's seed from `(seed, run)`, `sequence_generator` builds the list,
//// `candidates` offers shrinks, of which `chunk_sizes` fixes the deletion
//// widths, and `search` and `descend` pick and repeat the first that holds.
////
//// ## Using it from a test
////
//// `check` returns a `Result` so this package never panics. A test turns
//// the failure into one:
////
//// ```gleam
//// pub fn queue_matches_its_model_test() {
////   case statem.check(queue_spec(), statem.default_config(seed: 7)) {
////     Ok(Nil) -> Nil
////     Error(failure) -> panic as statem.report(failure, describe)
////   }
//// }
//// ```
////
//// `execute` that panics, or a `new_sut` whose effects leak, is outside this
//// module's reach: `teardown` runs after every execution that returns, pass
//// or fail, but not after one that crashes.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/yielder.{type Yielder}
import qcheck
import qcheck/tree.{type Tree, Tree}

// --- the specification ----------------------------------------------------

/// Whether a command may run in a given model. A two-variant type rather
/// than a `Bool` so the call site names the question.
pub type Admission {
  /// The command is meaningful in this model and may run.
  Admit

  /// The command is not meaningful in this model. The generator redraws; a
  /// shrink candidate containing it is discarded without being executed.
  Reject
}

/// A broken expectation, reported by `execute` or `finish`.
pub type Violation {
  Violation(
    /// A short stable name for the rule that broke, such as `"I3"` or
    /// `"fifo"`. Shrinking accepts a candidate only when it fails with the
    /// same tag as the original, so two different bugs must carry different
    /// tags or the shrink may slip from one to the other.
    tag: String,
    /// Free text for the reader: what was expected and what was observed.
    detail: String,
  )
}

/// Everything `check` needs to know about a system and its model.
///
/// ## Examples
///
/// ```gleam
/// statem.Spec(
///   initial: Model(depth: 0),
///   command: fn(_) { qcheck.return(Push) },
///   precondition: fn(_, _) { statem.Admit },
///   next_model: fn(model, _) { Model(depth: model.depth + 1) },
///   new_sut: stack.new,
///   execute: run_one,
///   finish: fn(_, _) { Ok(Nil) },
///   teardown: fn(_) { Nil },
/// )
/// ```
pub type Spec(model, cmd, sut) {
  Spec(
    /// The abstract model before any command. The generator and the
    /// precondition read it; the real system never sees it.
    initial: model,
    /// A generator of commands plausible in the given model. It may still
    /// draw one the precondition rejects; that is a redraw, not an error.
    command: fn(model) -> qcheck.Generator(cmd),
    /// Whether a command may run in a model.
    precondition: fn(model, cmd) -> Admission,
    /// The model after a command. Pure and symbolic: it runs during
    /// generation and while replaying shrink candidates, never against the
    /// system under test.
    next_model: fn(model, cmd) -> model,
    /// A fresh system under test. Called once per execution: once per run
    /// and once per shrink candidate that is executed, so nothing may leak
    /// between calls.
    new_sut: fn() -> sut,
    /// Run one command on the system, given the model BEFORE the command,
    /// check the postconditions, and return the advanced system.
    execute: fn(sut, model, cmd) -> Result(sut, Violation),
    /// Run after the last command, with the model after it: a final retire,
    /// end-state checks. A consumer with nothing to check returns `Ok(Nil)`.
    finish: fn(sut, model) -> Result(Nil, Violation),
    /// Release the system. Called after every execution that returns,
    /// whether it passed or failed.
    teardown: fn(sut) -> Nil,
  )
}

// --- configuration --------------------------------------------------------

/// How many runs, from which seed, and how hard to shrink.
pub type Config {
  Config(
    /// The number of command lists to generate and run.
    test_count: Int,
    /// The seed every run derives from. There is no default: the caller
    /// chooses it, so a gate is deterministic.
    seed: Int,
    /// The most commands in one generated list. A list may be shorter, and
    /// ends early when the precondition keeps rejecting what the generator
    /// offers.
    max_commands: Int,
    /// The most shrink candidates to execute for one failure. Candidates
    /// that fail their preconditions cost nothing against this budget.
    max_shrinks: Int,
  )
}

/// A hundred runs of up to thirty commands, at most a thousand shrink
/// executions, from the caller's seed.
///
/// ## Examples
///
/// ```gleam
/// statem.default_config(seed: 7) |> statem.with_test_count(300)
/// ```
pub fn default_config(seed seed: Int) -> Config {
  Config(test_count: 100, seed: seed, max_commands: 30, max_shrinks: 1000)
}

/// Replace the number of runs. A negative count is treated as zero.
///
/// ## Examples
///
/// ```gleam
/// statem.default_config(seed: 7) |> statem.with_test_count(10)
/// ```
pub fn with_test_count(config: Config, count: Int) -> Config {
  Config(..config, test_count: int.max(count, 0))
}

/// Replace the longest generated list. A negative length is treated as zero.
///
/// ## Examples
///
/// ```gleam
/// statem.default_config(seed: 7) |> statem.with_max_commands(12)
/// ```
pub fn with_max_commands(config: Config, length: Int) -> Config {
  Config(..config, max_commands: int.max(length, 0))
}

/// Replace the shrink budget. A negative budget is treated as zero, which
/// reports the original failure unshrunk.
///
/// ## Examples
///
/// ```gleam
/// statem.default_config(seed: 7) |> statem.with_max_shrinks(200)
/// ```
pub fn with_max_shrinks(config: Config, budget: Int) -> Config {
  Config(..config, max_shrinks: int.max(budget, 0))
}

// --- results --------------------------------------------------------------

/// A violation and the step it surfaced at.
pub type StepFailure {
  StepFailure(
    /// The zero-based index of the command that failed. A failure from
    /// `finish` carries the length of the list, one past the last command.
    step: Int,
    /// What broke.
    violation: Violation,
  )
}

/// How the shrink loop ended.
pub type ShrinkEnd {
  /// No candidate failed the same way: the shrunk list is locally minimal
  /// under the deletions and replacements tried.
  ShrinkConverged

  /// The budget ran out with candidates left, so a shorter list may exist.
  ShrinkBoundHit
}

/// One failing check, with everything needed to reproduce and read it.
pub type Failure(cmd) {
  Failure(
    /// The `Config.seed` the check ran under.
    seed: Int,
    /// The zero-based run whose list failed. `check_run` reproduces it from
    /// `seed` and this index alone.
    run: Int,
    /// The violation the SHRUNK list fails with. Its tag equals the tag of
    /// the original failure.
    violation: Violation,
    /// The command list as generated.
    original: List(cmd),
    /// The command list after shrinking.
    shrunk: List(cmd),
    /// The step the shrunk list failed at.
    step: Int,
    /// How many shrink candidates were accepted.
    shrinks: Int,
    /// How many shrink candidates were executed against the system, which is
    /// the quantity `max_shrinks` bounds.
    candidates_run: Int,
    /// Whether the shrink converged or stopped on the budget.
    shrink_end: ShrinkEnd,
  )
}

// --- the driver -----------------------------------------------------------

/// The most consecutive rejected draws before a generated list ends early.
/// A generator that is rarely admissible still terminates, and a list that
/// ends early is a legitimate shorter list.
const max_rejections = 8

/// Run `test_count` generated command lists against the spec and return the
/// first failure, already shrunk.
///
/// ## Examples
///
/// ```gleam
/// case statem.check(spec, statem.default_config(seed: 7)) {
///   Ok(Nil) -> Nil
///   Error(failure) -> panic as statem.report(failure, describe)
/// }
/// ```
pub fn check(
  spec: Spec(model, cmd, sut),
  config: Config,
) -> Result(Nil, Failure(cmd)) {
  check_from(spec, config, 0)
}

/// Run one numbered run of a check on its own. The list is drawn from
/// `(config.seed, run)` alone, so this reproduces exactly the run `check`
/// reported in `Failure.run` without executing the runs before it.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(failure) = statem.check_run(spec, config, 41)
/// ```
pub fn check_run(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
) -> Result(Nil, Failure(cmd)) {
  let generator = sequence_generator(spec, config.max_commands)
  let #(drawn, _) = qcheck.generate_tree(generator, run_seed(config.seed, run))
  let Tree(trees, _) = drawn

  case execute_list(spec, roots(trees)) {
    Ok(Nil) -> Ok(Nil)
    Error(failure) -> Error(shrink(spec, config, run, trees, failure))
  }
}

/// The runs from `run` onward. A run that passes hands on to the next, so
/// the recursion is the loop over `0..test_count`, and a failure is the
/// only way out early.
fn check_from(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
) -> Result(Nil, Failure(cmd)) {
  case run >= config.test_count {
    True -> Ok(Nil)
    False ->
      case check_run(spec, config, run) {
        Ok(Nil) -> check_from(spec, config, run + 1)
        Error(failure) -> Error(failure)
      }
  }
}

/// Execute one exact command list from the initial model and return the
/// first violation. The list is checked against the preconditions first; a
/// rejected command is reported as a violation tagged `statem.precondition`
/// rather than run, since a list that is not admissible says nothing about
/// the system.
///
/// ## Examples
///
/// ```gleam
/// assert statem.replay(spec, [Push, Pop]) == Ok(Nil)
/// ```
pub fn replay(
  spec: Spec(model, cmd, sut),
  commands: List(cmd),
) -> Result(Nil, StepFailure) {
  case first_rejection(spec, spec.initial, commands, 0) {
    Some(step) ->
      Error(StepFailure(
        step: step,
        violation: Violation(
          tag: "statem.precondition",
          detail: "the command at step "
            <> int.to_string(step)
            <> " is rejected by its precondition",
        ),
      ))
    None -> execute_list(spec, commands)
  }
}

/// Render a failure as a readable multi-line message: where it came from,
/// what broke, and the shrunk list with the failing step marked.
///
/// ## Examples
///
/// ```gleam
/// statem.report(failure, fn(command) { string.inspect(command) })
/// ```
pub fn report(
  failure: Failure(cmd),
  describe describe: fn(cmd) -> String,
) -> String {
  let ending = case failure.shrink_end {
    ShrinkConverged -> "converged"
    ShrinkBoundHit -> "shrink bound hit"
  }

  let steps =
    list.index_map(failure.shrunk, fn(command, index) {
      let marker = case index == failure.step {
        True -> "  > "
        False -> "    "
      }
      marker <> int.to_string(index) <> ". " <> describe(command)
    })

  let finish_marker = case list.drop(failure.shrunk, failure.step) == [] {
    True -> ["  > end of list (finish)"]
    False -> []
  }

  string.join(
    list.flatten([
      [
        "stateful property failed: seed "
          <> int.to_string(failure.seed)
          <> ", run "
          <> int.to_string(failure.run),
        "violation ["
          <> failure.violation.tag
          <> "]: "
          <> failure.violation.detail,
        "original list: "
          <> int.to_string(list.length(failure.original))
          <> " commands",
        "shrunk list: "
          <> int.to_string(list.length(failure.shrunk))
          <> " commands, "
          <> int.to_string(failure.shrinks)
          <> " shrinks accepted, "
          <> int.to_string(failure.candidates_run)
          <> " candidates run, "
          <> ending,
      ],
      steps,
      finish_marker,
    ]),
    "\n",
  )
}

// --- generation -----------------------------------------------------------

/// The seed for one run. Both numbers go in, so the run is independent of
/// the others; the multiplier keeps neighbouring seeds' runs apart.
fn run_seed(seed: Int, run: Int) -> qcheck.Seed {
  qcheck.seed(seed * 1_000_003 + run)
}

/// A generator of admissible command lists that keeps each command's own
/// shrink tree. The value is the list of trees rather than the commands so
/// the driver can offer a command's children as shrink candidates; the
/// generator's own tree is trivial because the driver does the shrinking.
fn sequence_generator(
  spec: Spec(model, cmd, sut),
  max_commands: Int,
) -> qcheck.Generator(List(Tree(cmd))) {
  let length = qcheck.bounded_int(from: 0, to: max_commands)

  qcheck.Generator(fn(seed) {
    let #(length_tree, seed) = qcheck.generate_tree(length, seed)
    let Tree(target, _) = length_tree
    let #(trees, seed) = grow(spec, target, spec.initial, seed, [], 0)

    #(tree.return(trees), seed)
  })
}

/// Draw commands one at a time, advancing the model after each admitted one.
/// A rejected draw is retried with the advanced seed, and
/// `max_rejections` consecutive rejections end the list.
fn grow(
  spec: Spec(model, cmd, sut),
  remaining: Int,
  model: model,
  seed: qcheck.Seed,
  acc: List(Tree(cmd)),
  rejected: Int,
) -> #(List(Tree(cmd)), qcheck.Seed) {
  case remaining <= 0 || rejected >= max_rejections {
    True -> #(list.reverse(acc), seed)

    False -> {
      let #(drawn, seed) = qcheck.generate_tree(spec.command(model), seed)
      let Tree(command, _) = drawn

      case spec.precondition(model, command) {
        Reject -> grow(spec, remaining, model, seed, acc, rejected + 1)

        Admit ->
          grow(
            spec,
            remaining - 1,
            spec.next_model(model, command),
            seed,
            [drawn, ..acc],
            0,
          )
      }
    }
  }
}

fn roots(trees: List(Tree(cmd))) -> List(cmd) {
  list.map(trees, fn(drawn) {
    let Tree(command, _) = drawn
    command
  })
}

// --- execution ------------------------------------------------------------

/// Run a list on a fresh system, tear it down, and return the first
/// violation. The list is assumed admissible.
fn execute_list(
  spec: Spec(model, cmd, sut),
  commands: List(cmd),
) -> Result(Nil, StepFailure) {
  let #(sut, outcome) = drive(spec, spec.new_sut(), spec.initial, commands, 0)
  spec.teardown(sut)

  outcome
}

/// Walk the list, threading the system and the model. The system returned
/// is the last one that exists, so the caller can tear it down on a failure
/// as well as on success.
fn drive(
  spec: Spec(model, cmd, sut),
  sut: sut,
  model: model,
  commands: List(cmd),
  step: Int,
) -> #(sut, Result(Nil, StepFailure)) {
  case commands {
    [] ->
      case spec.finish(sut, model) {
        Ok(Nil) -> #(sut, Ok(Nil))
        Error(violation) -> #(sut, Error(StepFailure(step, violation)))
      }

    [command, ..rest] ->
      case spec.execute(sut, model, command) {
        Error(violation) -> #(sut, Error(StepFailure(step, violation)))

        Ok(advanced) ->
          drive(spec, advanced, spec.next_model(model, command), rest, step + 1)
      }
  }
}

/// The index of the first command whose precondition rejects it, replaying
/// the model from `model`. `None` means the whole list is admissible.
fn first_rejection(
  spec: Spec(model, cmd, sut),
  model: model,
  commands: List(cmd),
  step: Int,
) -> Option(Int) {
  case commands {
    [] -> None

    [command, ..rest] ->
      case spec.precondition(model, command) {
        Reject -> Some(step)

        Admit ->
          first_rejection(spec, spec.next_model(model, command), rest, step + 1)
      }
  }
}

// --- shrinking ------------------------------------------------------------

/// What the greedy search found for one round.
type Search(cmd) {
  /// An admissible candidate that fails with the original tag.
  Found(trees: List(Tree(cmd)), failure: StepFailure, run_count: Int)

  /// Every candidate was tried or discarded.
  Exhausted(run_count: Int)

  /// The execution budget ran out before the candidates did.
  OutOfBudget(run_count: Int)
}

/// Shrink a failing list and package the result. The tag of the original
/// failure is the one every accepted candidate must reproduce.
fn shrink(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
  trees: List(Tree(cmd)),
  original_failure: StepFailure,
) -> Failure(cmd) {
  let tag = original_failure.violation.tag
  let #(final_trees, final_failure, accepted, run_count, ending) =
    descend(spec, config.max_shrinks, tag, trees, original_failure, 0, 0)

  Failure(
    seed: config.seed,
    run: run,
    violation: final_failure.violation,
    original: roots(trees),
    shrunk: roots(final_trees),
    step: final_failure.step,
    shrinks: accepted,
    candidates_run: run_count,
    shrink_end: ending,
  )
}

/// Take the first accepted candidate and restart from it. Greedy descent
/// terminates because every accepted candidate is strictly smaller in
/// command count or in its commands' shrink trees.
fn descend(
  spec: Spec(model, cmd, sut),
  budget: Int,
  tag: String,
  trees: List(Tree(cmd)),
  failure: StepFailure,
  accepted: Int,
  run_count: Int,
) -> #(List(Tree(cmd)), StepFailure, Int, Int, ShrinkEnd) {
  case search(spec, budget, tag, candidates(trees), run_count) {
    Found(next_trees, next_failure, next_count) ->
      descend(
        spec,
        budget,
        tag,
        next_trees,
        next_failure,
        accepted + 1,
        next_count,
      )

    Exhausted(count) -> #(trees, failure, accepted, count, ShrinkConverged)

    OutOfBudget(count) -> #(trees, failure, accepted, count, ShrinkBoundHit)
  }
}

/// Walk the candidates lazily. An inadmissible candidate is dropped for
/// free; an admissible one spends a unit of budget, and one that passes or
/// fails with a different tag is dropped after being paid for.
fn search(
  spec: Spec(model, cmd, sut),
  budget: Int,
  tag: String,
  pending: Yielder(List(Tree(cmd))),
  run_count: Int,
) -> Search(cmd) {
  case yielder.step(pending) {
    yielder.Done -> Exhausted(run_count)

    yielder.Next(candidate, rest) ->
      consider(spec, budget, tag, candidate, rest, run_count)
  }
}

/// Decide one candidate: drop it unexecuted if a precondition rejects it,
/// stop if the budget is spent, otherwise pay for an execution and either
/// accept it or move on to `rest`.
fn consider(
  spec: Spec(model, cmd, sut),
  budget: Int,
  tag: String,
  candidate: List(Tree(cmd)),
  rest: Yielder(List(Tree(cmd))),
  run_count: Int,
) -> Search(cmd) {
  case first_rejection(spec, spec.initial, roots(candidate), 0) {
    Some(_) -> search(spec, budget, tag, rest, run_count)

    None ->
      case run_count >= budget {
        True -> OutOfBudget(run_count)

        False ->
          case attempt(spec, tag, candidate) {
            Ok(failure) -> Found(candidate, failure, run_count + 1)
            Error(Nil) -> search(spec, budget, tag, rest, run_count + 1)
          }
      }
  }
}

/// Execute one admissible candidate and keep its failure only if it is the
/// bug being shrunk.
fn attempt(
  spec: Spec(model, cmd, sut),
  tag: String,
  candidate: List(Tree(cmd)),
) -> Result(StepFailure, Nil) {
  same_failure(execute_list(spec, roots(candidate)), tag)
}

/// A failure with the wanted tag, or nothing. A pass and a failure under a
/// different tag are both `Error(Nil)`: neither is the bug being shrunk.
fn same_failure(
  outcome: Result(Nil, StepFailure),
  tag: String,
) -> Result(StepFailure, Nil) {
  case outcome {
    Ok(Nil) -> Error(Nil)

    Error(failure) ->
      case failure.violation.tag == tag {
        True -> Ok(failure)
        False -> Error(Nil)
      }
  }
}

/// Every candidate, deletions before replacements: the cheap, large steps
/// come first so the list gets short before the commands get simple.
fn candidates(trees: List(Tree(cmd))) -> Yielder(List(Tree(cmd))) {
  yielder.append(deletions(trees), replacements(trees))
}

/// Delete a contiguous chunk: the whole list, then halves, quarters, down to
/// single commands, each at every offset.
fn deletions(trees: List(Tree(cmd))) -> Yielder(List(Tree(cmd))) {
  let length = list.length(trees)

  chunk_sizes(length)
  |> yielder.from_list
  |> yielder.flat_map(fn(size) {
    yielder.range(0, length - size)
    |> yielder.map(fn(offset) {
      list.append(list.take(trees, offset), list.drop(trees, offset + size))
    })
  })
}

/// The chunk sizes for a list of this length: the length itself, then
/// repeated halving down to one. Empty for an empty list.
fn chunk_sizes(length: Int) -> List(Int) {
  case length < 1 {
    True -> []
    False -> [length, ..chunk_sizes(length / 2)]
  }
}

/// Replace one command by each child of its own shrink tree. The child
/// carries its own children, so a replaced command can shrink again.
fn replacements(trees: List(Tree(cmd))) -> Yielder(List(Tree(cmd))) {
  trees
  |> list.index_map(fn(drawn, index) { #(index, drawn) })
  |> yielder.from_list
  |> yielder.flat_map(fn(entry) {
    let #(index, Tree(_, children)) = entry

    yielder.map(children, fn(child) {
      list.index_map(trees, fn(existing, position) {
        case position == index {
          True -> child
          False -> existing
        }
      })
    })
  })
}
