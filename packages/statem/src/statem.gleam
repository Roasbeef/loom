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
//// `(config.seed, i)` alone, so any run reproduces without executing the
//// runs before it, and the `Failure` names both numbers. The per-run seeds
//// are successive draws of 32-bit values from one qcheck stream seeded with
//// `config.seed`, so the derivation is integer-exact on both targets for
//// any seed the target can represent; two seeds equal modulo 2^32 give the
//// same stream, which is qcheck's own limitation. There is deliberately no
//// random default seed: a red gate must be the same red gate on every
//// machine.
////
//// A failing list is shrunk greedily. The whole-list deletion is offered
//// once, first. After that, candidates come in two groups, in order: delete
//// a contiguous chunk of `n/2`, `n/4`, ..., down to `1` commands for a list
//// of `n`, at every offset (a halving schedule, so sizes such as 2 for a
//// list of 3 are not offered), then replace one command by each child of
//// its own shrink tree. The first candidate that is admissible and fails
//// with the SAME `Violation.tag` as the original is accepted and the search
//// restarts from it. Deleting from the middle is what qcheck lists cannot
//// do, and it is what lets a bug that needs two commands separated by noise
//// shrink to just the two.
////
//// Shrinking is bounded twice. `max_shrinks` bounds executions, and every
//// execution, including each retry under `with_shrink_retries`, spends one.
//// Candidates that fail a precondition are never executed and so are free
//// against it, but they are bounded by a fixed cap, so a hand-built shrink
//// tree that is infinite and inadmissible still terminates. Either bound
//// ending the search is reported as `ShrinkBoundHit`.
////
//// A third bound is the caller's, for what this package cannot measure.
//// R6 keeps a clock out of `statem`, so a test whose candidates cost real
//// time (a poll deadline, a process that must be waited out) cannot ask for
//// "stop after thirty seconds" by a number. `with_shrink_stop` takes a
//// `fn() -> ShrinkStop` the driver calls before it executes each candidate,
//// the first execution after the failing run included; the failing run
//// itself is never gated, because the failure must be reported. When it
//// answers `StopShrinking` the search ends there and the `Failure` carries
//// the best list found so far, with `ShrinkBoundHit`. The caller closes over
//// a monotonic deadline it read when its test began. The default,
//// `keep_shrinking`, always keeps shrinking.
////
//// Commands that name state by value (a key, a handle) shrink badly,
//// because deleting the command that created the value leaves its users
//// inadmissible. Prefer commands that name state by index or by position in
//// the model, so a shortened list is another valid list.
////
//// ## Crashes
////
//// A consumer's `execute` often asserts rather than returning a `Result`.
//// `new_sut`, `execute` and `finish` run under `exception.rescue`, and a
//// panic, throw or exit becomes a `Violation` tagged `statem.crash`. It
//// shrinks and reports like any other failure, with the same-tag rule
//// keeping a crash shrinking to a crash. `teardown` runs on every path
//// where a system exists, including after a crash, and nothing it does can
//// escape: a crash in `teardown` is discarded.
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
//// `commands` returns the list one run would generate without executing
//// anything, for a test that asserts its generator reaches every kind of
//// command.
////
//// ## Flow
////
//// `check` → `run_with` → `draw` → `execute_list` → `shrink` → `descend`
////
//// 1. `check` walks the runs with `check_from`, taking each run's seed from
////    `next_run_seed`; `check_run` and `commands` reach the same seed through
////    `run_seed` alone.
//// 2. `run_with` calls `draw`, whose `sequence_generator` threads the model
////    through the public `grow`, keeping each command's tree.
//// 3. `execute_list` builds a system, `drive`s the list through `guarded`
////    callbacks (a crash becomes `crashed`), and tears the system down.
//// 4. A failure goes to `shrink`, which offers the whole list once and then
////    `descend`s: each round `search`es the `candidates` (`deletions` sized
////    by `chunk_sizes`, then `replacements`), `judge`s each against
////    `first_rejection` and, when admissible, `attempt`s it.
//// 5. `report` renders the resulting `Failure`.

import exception.{type Exception}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/yielder.{type Yielder}
import qcheck
import qcheck/tree.{type Tree, Tree}
import statem/internal/retry

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
    /// and once per shrink candidate that is executed (once per retry under
    /// `with_shrink_retries`), so nothing may leak between calls. A crash is
    /// a `statem.crash` violation.
    new_sut: fn() -> sut,
    /// Run one command on the system, given the model BEFORE the command,
    /// check the postconditions, and return the advanced system. When it
    /// returns `Error` or crashes, `teardown` receives the system as it was
    /// BEFORE this command, so a value system that owns a resource and was
    /// changed by a failing `execute` must keep that resource reachable from
    /// the pre-command value, or be a reference type.
    execute: fn(sut, model, cmd) -> Result(sut, Violation),
    /// Run after the last command, with the model after it: a final retire,
    /// end-state checks. A consumer with nothing to check returns `Ok(Nil)`.
    finish: fn(sut, model) -> Result(Nil, Violation),
    /// Release the system. Called after every execution that built one,
    /// whether it passed, failed or crashed, with the last system that
    /// existed. It must never escape: a crash here is discarded.
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
    /// The most shrink executions for one failure, retries included.
    /// Candidates that fail their preconditions cost nothing against this
    /// budget, but are bounded by a separate fixed cap.
    max_shrinks: Int,
    /// How many executions one shrink candidate gets. It counts as still
    /// failing if any of them fails with the original tag. For systems whose
    /// failure is scheduling dependent; the initial failing run is not
    /// retried.
    shrink_retries: Int,
    /// Asked before each shrink execution whether to go on. It is how a
    /// caller with a clock bounds shrinking by elapsed time, which this
    /// package may not read. `keep_shrinking` by default.
    shrink_stop: fn() -> ShrinkStop,
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
  Config(
    test_count: 100,
    seed: seed,
    max_commands: 30,
    max_shrinks: 1000,
    shrink_retries: 1,
    shrink_stop: keep_shrinking,
  )
}

fn keep_shrinking() -> ShrinkStop {
  KeepShrinking
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

/// Give each shrink candidate `attempts` executions instead of one; it
/// counts as still failing if any of them fails with the original tag. Every
/// execution, retries included, counts against `max_shrinks`. A value below
/// one is treated as one.
///
/// ## Examples
///
/// ```gleam
/// statem.default_config(seed: 7) |> statem.with_shrink_retries(3)
/// ```
pub fn with_shrink_retries(config: Config, attempts: Int) -> Config {
  Config(..config, shrink_retries: int.max(attempts, 1))
}

/// Stop shrinking once `stop` answers `StopShrinking`. The driver calls it
/// before each candidate it is about to execute, never before the initial
/// failing run and never for a candidate a precondition drops. The failure
/// reported is the best list found before the stop, ending `ShrinkBoundHit`.
/// The predicate is how a test bounds shrinking by wall time without this
/// package reading a clock: close over a monotonic deadline.
///
/// ## Examples
///
/// ```gleam
/// let deadline = now_ms() + 30_000
/// statem.default_config(seed: 7)
/// |> statem.with_shrink_stop(fn() {
///   case now_ms() > deadline {
///     True -> statem.StopShrinking
///     False -> statem.KeepShrinking
///   }
/// })
/// ```
pub fn with_shrink_stop(config: Config, stop: fn() -> ShrinkStop) -> Config {
  Config(..config, shrink_stop: stop)
}

// --- results --------------------------------------------------------------

/// The caller's answer to whether shrinking should go on.
pub type ShrinkStop {
  /// Run the next candidate.
  KeepShrinking

  /// End the search now and report the best list so far.
  StopShrinking
}

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

  /// A bound stopped the search with an admissible candidate still untried
  /// (`max_shrinks` executions spent, the cap on inadmissible candidates
  /// reached, or the caller's `with_shrink_stop` predicate said stop), so a
  /// shorter list may exist.
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
    /// How many shrink executions ran against the system, retries included,
    /// which is the quantity `max_shrinks` bounds.
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

/// The most inadmissible shrink candidates one shrink may discard. They cost
/// no execution, so `max_shrinks` cannot bound them; this does, and it is
/// what lets a shrink tree that is infinite and never admissible terminate.
/// It is generous because a wide but finite tree should be walked in full.
const max_inadmissible = 250_000

/// The largest value a per-run seed is drawn from: a full 32-bit seed, which
/// is all qcheck's generator keeps of one.
const seed_ceiling = 4_294_967_295

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
  check_from(spec, config, 0, qcheck.seed(config.seed))
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
  run_with(spec, config, run, run_seed(config.seed, run))
}

/// The admissible command list run `run` of a check would generate, with
/// nothing executed. It is the `original` of the `Failure` for that run, so
/// a test can assert that its generator reaches every kind of command
/// across the runs it checks.
///
/// ## Examples
///
/// ```gleam
/// let lists = list.map([0, 1, 2, 3], statem.commands(spec, config, _))
/// assert list.any(list.flatten(lists), is_revoke)
/// ```
pub fn commands(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
) -> List(cmd) {
  roots(draw(spec, config, run_seed(config.seed, run)))
}

/// Execute one drawn run, shrinking it if it fails.
fn run_with(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
  seed: qcheck.Seed,
) -> Result(Nil, Failure(cmd)) {
  let trees = draw(spec, config, seed)

  case execute_list(spec, roots(trees)) {
    Ok(Nil) -> Ok(Nil)
    Error(failure) -> Error(shrink(spec, config, run, trees, failure))
  }
}

/// The runs from `run` onward. A run that passes hands on to the next, so
/// the recursion is the loop over `0..test_count`, and a failure is the
/// only way out early. The seed stream is threaded rather than recomputed,
/// so a check costs one seed draw per run.
fn check_from(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
  stream: qcheck.Seed,
) -> Result(Nil, Failure(cmd)) {
  case run >= config.test_count {
    True -> Ok(Nil)

    False -> {
      let #(seed, stream) = next_run_seed(stream)

      case run_with(spec, config, run, seed) {
        Ok(Nil) -> check_from(spec, config, run + 1, stream)
        Error(failure) -> Error(failure)
      }
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
/// what broke, the original list, and the shrunk list with the failing step
/// marked.
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

  let numbered = fn(commands, failing) {
    list.index_map(commands, fn(command, index) {
      let marker = case index == failing {
        True -> "  > "
        False -> "    "
      }
      marker <> int.to_string(index) <> ". " <> describe(command)
    })
  }

  let finish_marker = case list.drop(failure.shrunk, failure.step) {
    [] -> ["  > end of list (finish)"]
    [_, ..] -> []
  }

  string.join(
    list.flatten([
      [
        "stateful property failed: seed "
          <> int.to_string(failure.seed)
          <> ", run "
          <> int.to_string(failure.run)
          <> ", step "
          <> int.to_string(failure.step),
        "violation ["
          <> failure.violation.tag
          <> "]: "
          <> failure.violation.detail,
        "original list: "
          <> int.to_string(list.length(failure.original))
          <> " commands",
      ],
      numbered(failure.original, -1),
      [
        "shrunk list: "
        <> int.to_string(list.length(failure.shrunk))
        <> " commands, "
        <> int.to_string(failure.shrinks)
        <> " shrinks accepted, "
        <> int.to_string(failure.candidates_run)
        <> " executions, "
        <> ending,
      ],
      numbered(failure.shrunk, failure.step),
      finish_marker,
    ]),
    "\n",
  )
}

/// How one candidate fared under the retry policy: the first failure the
/// caller's test accepted, if any (`accepted`), and the executions performed
/// (`executions`). An alias of the policy's own type, so a caller can name it
/// and read its fields without importing the internal module.
pub type Attempted(failure) =
  retry.Attempted(failure)

/// The retry policy `check` applies to one shrink candidate, public for a
/// layer whose candidates are not command lists. `run` is executed up to
/// `attempts` times, stopping at the first failure `wanted` accepts or when
/// `budget` executions are spent; the result's `accepted` field is that
/// failure and `executions` is what the caller charges to its own budget.
/// The first attempt always runs.
///
/// ## Examples
///
/// ```gleam
/// let tried =
///   statem.first_failure(3, 10, fn(attempt) { Error(attempt) }, fn(n) { n == 1 })
/// // tried.accepted == Some(1), tried.executions == 2
/// ```
pub fn first_failure(
  attempts: Int,
  budget: Int,
  run: fn(Int) -> Result(Nil, failure),
  wanted: fn(failure) -> Bool,
) -> Attempted(failure) {
  retry.first_failure(attempts, budget, run, wanted)
}

// --- generation -----------------------------------------------------------

/// The seed for run `run`: the `run`th draw of a stream seeded with `seed`.
/// Walking the stream costs one draw per skipped run, which is cheap beside
/// executing one, and it keeps every run's seed a function of `(seed, run)`
/// alone. Public so a layer built on this one, such as the parallel runner
/// in `statem_parallel`, derives its runs' seeds the same way and a
/// `(seed, run)` pair names the same stream in both.
///
/// ## Examples
///
/// ```gleam
/// statem.run_seed(7, 3) == statem.run_seed(7, 3)
/// ```
pub fn run_seed(seed: Int, run: Int) -> qcheck.Seed {
  skip_seeds(qcheck.seed(seed), int.max(run, 0))
}

/// Advance the stream past `count` runs and return the next run's seed.
fn skip_seeds(stream: qcheck.Seed, count: Int) -> qcheck.Seed {
  let #(seed, stream) = next_run_seed(stream)

  case count <= 0 {
    True -> seed
    False -> skip_seeds(stream, count - 1)
  }
}

/// One run's seed and the stream that follows it. A full 32-bit draw is
/// integer arithmetic below 2^53, so it is exact on both targets. Public for
/// the same reason as `run_seed`: a layer that walks the runs of a check
/// threads the stream instead of recomputing it for every run.
///
/// ## Examples
///
/// ```gleam
/// let #(first, stream) = statem.next_run_seed(qcheck.seed(7))
/// ```
pub fn next_run_seed(stream: qcheck.Seed) -> #(qcheck.Seed, qcheck.Seed) {
  let #(drawn, stream) =
    qcheck.generate_tree(qcheck.bounded_int(from: 0, to: seed_ceiling), stream)
  let Tree(value, _) = drawn

  #(qcheck.seed(value), stream)
}

/// The trees of the admissible list one seed generates.
fn draw(
  spec: Spec(model, cmd, sut),
  config: Config,
  seed: qcheck.Seed,
) -> List(Tree(cmd)) {
  let #(drawn, _) =
    qcheck.generate_tree(sequence_generator(spec, config.max_commands), seed)
  let Tree(trees, _) = drawn

  trees
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
  let Spec(initial:, command:, precondition:, next_model:, ..) = spec

  qcheck.Generator(fn(seed) {
    let #(length_tree, seed) = qcheck.generate_tree(length, seed)
    let Tree(target, _) = length_tree
    let Grown(trees, _, seed) =
      grow(
        command,
        precondition,
        next_model,
        length: target,
        from: initial,
        seed: seed,
      )

    #(tree.return(trees), seed)
  })
}

/// What `grow` produced: the admitted commands with their shrink trees, the
/// model after the last of them, and the seed to continue drawing from.
pub type Grown(model, cmd) {
  Grown(
    /// The admitted commands in order, each with its own shrink tree.
    trees: List(Tree(cmd)),
    /// The model after the last admitted command, or the model `grow` was
    /// given when nothing was admitted. A caller that draws a second stage
    /// from where the first ended starts from it.
    model: model,
    /// The seed after the last draw, admitted or rejected.
    seed: qcheck.Seed,
  )
}

/// Draw up to `length` admissible commands, advancing the model after each
/// admitted one: the generator behind every command list `check` runs,
/// public so a layer with its own notion of a case draws its sequential
/// stretches the same way. A rejected draw is retried with the advanced
/// seed, and eight consecutive rejections end the list early.
///
/// ## Examples
///
/// ```gleam
/// let grown =
///   statem.grow(
///     spec.command,
///     spec.precondition,
///     spec.next_model,
///     length: 5,
///     from: spec.initial,
///     seed: qcheck.seed(7),
///   )
/// ```
pub fn grow(
  command: fn(model) -> qcheck.Generator(cmd),
  precondition: fn(model, cmd) -> Admission,
  next_model: fn(model, cmd) -> model,
  length length: Int,
  from model: model,
  seed seed: qcheck.Seed,
) -> Grown(model, cmd) {
  grow_loop(command, precondition, next_model, length, model, seed, [], 0)
}

/// The recursion behind `grow`, with the rejection streak and the reversed
/// accumulator it threads.
fn grow_loop(
  command: fn(model) -> qcheck.Generator(cmd),
  precondition: fn(model, cmd) -> Admission,
  next_model: fn(model, cmd) -> model,
  remaining: Int,
  model: model,
  seed: qcheck.Seed,
  acc: List(Tree(cmd)),
  rejected: Int,
) -> Grown(model, cmd) {
  case remaining <= 0 || rejected >= max_rejections {
    True -> Grown(trees: list.reverse(acc), model: model, seed: seed)

    False -> {
      let #(drawn, seed) = qcheck.generate_tree(command(model), seed)
      let Tree(chosen, _) = drawn

      case precondition(model, chosen) {
        Reject ->
          grow_loop(
            command,
            precondition,
            next_model,
            remaining,
            model,
            seed,
            acc,
            rejected + 1,
          )

        Admit ->
          grow_loop(
            command,
            precondition,
            next_model,
            remaining - 1,
            next_model(model, chosen),
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
/// violation. The list is assumed admissible. A `new_sut` that crashes is
/// a violation at step 0 with no system to tear down.
fn execute_list(
  spec: Spec(model, cmd, sut),
  commands: List(cmd),
) -> Result(Nil, StepFailure) {
  case exception.rescue(spec.new_sut) {
    Error(crash) -> Error(StepFailure(0, crashed("new_sut", crash)))

    Ok(fresh) -> {
      let #(sut, outcome) = drive(spec, fresh, spec.initial, commands, 0)

      // Teardown is the one callback whose failure is dropped: the verdict
      // belongs to the commands, and a second crash must not mask it.
      let _ = exception.rescue(fn() { spec.teardown(sut) })

      outcome
    }
  }
}

/// Walk the list, threading the system and the model. The system returned
/// is the last one that exists (the pre-command one when a command fails or
/// crashes), so the caller tears it down on every path.
fn drive(
  spec: Spec(model, cmd, sut),
  sut: sut,
  model: model,
  commands: List(cmd),
  step: Int,
) -> #(sut, Result(Nil, StepFailure)) {
  case commands {
    [] ->
      case guarded("finish", fn() { spec.finish(sut, model) }) {
        Ok(Nil) -> #(sut, Ok(Nil))
        Error(violation) -> #(sut, Error(StepFailure(step, violation)))
      }

    [command, ..rest] ->
      case guarded("execute", fn() { spec.execute(sut, model, command) }) {
        Error(violation) -> #(sut, Error(StepFailure(step, violation)))

        Ok(advanced) ->
          drive(spec, advanced, spec.next_model(model, command), rest, step + 1)
      }
  }
}

/// Run a consumer callback, turning a crash into the `statem.crash`
/// violation so it shrinks and reports like any other failure.
fn guarded(
  callback: String,
  body: fn() -> Result(a, Violation),
) -> Result(a, Violation) {
  case exception.rescue(body) {
    Ok(result) -> result
    Error(crash) -> Error(crashed(callback, crash))
  }
}

/// The violation for a crash. The tag is fixed so a crash shrinks to a crash
/// whatever its message; the detail names the callback and what was raised.
/// Public so a layer that rescues consumer callbacks on its own processes,
/// as `statem_parallel` does for a call made inside a branch, reports a
/// crash under the same tag.
///
/// ## Examples
///
/// ```gleam
/// let violation = case exception.rescue(fn() { run(sut, command) }) {
///   Error(crash) -> statem.crashed("run", crash)
///   Ok(_) -> statem.Violation(tag: "none", detail: "")
/// }
/// ```
pub fn crashed(callback: String, crash: Exception) -> Violation {
  Violation(
    tag: "statem.crash",
    detail: callback <> " crashed: " <> string.inspect(crash),
  )
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

/// What one shrink has spent so far, against its two bounds.
type Spent {
  Spent(
    /// Executions run, retries included; bounded by `max_shrinks`.
    executed: Int,
    /// Inadmissible candidates discarded; bounded by `max_inadmissible`.
    discarded: Int,
  )
}

/// What stays fixed while one failure shrinks.
type Limits {
  Limits(
    /// The tag every accepted candidate must reproduce.
    tag: String,
    /// `Config.max_shrinks`.
    budget: Int,
    /// `Config.shrink_retries`.
    retries: Int,
    /// `Config.shrink_stop`.
    stop: fn() -> ShrinkStop,
  )
}

/// What the greedy search found for one round.
type Search(cmd) {
  /// An admissible candidate that fails with the original tag.
  Found(trees: List(Tree(cmd)), failure: StepFailure, spent: Spent)

  /// Every candidate was tried or discarded.
  Exhausted(spent: Spent)

  /// A bound stopped the search with an admissible candidate untried.
  OutOfBudget(spent: Spent)
}

/// What became of one candidate.
type Verdict {
  /// A precondition rejected it; nothing ran.
  Dropped(spent: Spent)

  /// It is admissible but a bound forbids running it.
  Stopped(spent: Spent)

  /// It failed with the original tag.
  Accepted(failure: StepFailure, spent: Spent)

  /// It ran and passed, or failed under another tag.
  Refuted(spent: Spent)
}

/// The end state of a shrink.
type Shrunk(cmd) {
  Shrunk(
    trees: List(Tree(cmd)),
    failure: StepFailure,
    accepted: Int,
    spent: Spent,
    ending: ShrinkEnd,
  )
}

/// Shrink a failing list and package the result. The whole-list deletion is
/// offered once here, so a descent round never begins by executing the empty
/// list again; if it reproduces the failure there is nothing left to shrink.
fn shrink(
  spec: Spec(model, cmd, sut),
  config: Config,
  run: Int,
  trees: List(Tree(cmd)),
  original_failure: StepFailure,
) -> Failure(cmd) {
  let limits =
    Limits(
      tag: original_failure.violation.tag,
      budget: config.max_shrinks,
      retries: config.shrink_retries,
      stop: config.shrink_stop,
    )
  let none = Spent(executed: 0, discarded: 0)
  let whole = case trees {
    [] -> yielder.empty()
    _ -> yielder.single([])
  }

  let Shrunk(final_trees, final_failure, accepted, spent, ending) = case
    search(spec, limits, whole, none)
  {
    Found(emptied, failure, spent) ->
      Shrunk(emptied, failure, 1, spent, ShrinkConverged)

    Exhausted(spent) -> descend(spec, limits, trees, original_failure, 0, spent)

    OutOfBudget(spent) ->
      Shrunk(trees, original_failure, 0, spent, ShrinkBoundHit)
  }

  Failure(
    seed: config.seed,
    run: run,
    violation: final_failure.violation,
    original: roots(trees),
    shrunk: roots(final_trees),
    step: final_failure.step,
    shrinks: accepted,
    candidates_run: spent.executed,
    shrink_end: ending,
  )
}

/// Take the first accepted candidate and restart from it. Greedy descent
/// terminates because every accepted candidate is strictly smaller in
/// command count or in its commands' shrink trees. The search itself reports
/// whether a bound stopped it, so a list that converges on the last unit of
/// budget is not reported as cut short.
fn descend(
  spec: Spec(model, cmd, sut),
  limits: Limits,
  trees: List(Tree(cmd)),
  failure: StepFailure,
  accepted: Int,
  spent: Spent,
) -> Shrunk(cmd) {
  case search(spec, limits, candidates(trees), spent) {
    Found(next_trees, next_failure, next_spent) ->
      descend(spec, limits, next_trees, next_failure, accepted + 1, next_spent)

    Exhausted(next_spent) ->
      Shrunk(trees, failure, accepted, next_spent, ShrinkConverged)

    OutOfBudget(next_spent) ->
      Shrunk(trees, failure, accepted, next_spent, ShrinkBoundHit)
  }
}

/// Walk the candidates lazily, one `judge` at a time. This is the only
/// recursion in the search and it is a self tail call, which Gleam compiles
/// to a loop on both targets, so a long run of inadmissible candidates
/// cannot grow the stack.
fn search(
  spec: Spec(model, cmd, sut),
  limits: Limits,
  pending: Yielder(List(Tree(cmd))),
  spent: Spent,
) -> Search(cmd) {
  case yielder.step(pending) {
    yielder.Done -> Exhausted(spent)

    yielder.Next(candidate, rest) ->
      case judge(spec, limits, candidate, spent) {
        Dropped(next) -> search(spec, limits, rest, next)
        Refuted(next) -> search(spec, limits, rest, next)
        Stopped(next) -> OutOfBudget(next)
        Accepted(failure, next) -> Found(candidate, failure, next)
      }
  }
}

/// Decide one candidate: drop it unexecuted if a precondition rejects it,
/// stop if a bound is spent, otherwise pay for its executions.
fn judge(
  spec: Spec(model, cmd, sut),
  limits: Limits,
  candidate: List(Tree(cmd)),
  spent: Spent,
) -> Verdict {
  let commands = roots(candidate)

  case first_rejection(spec, spec.initial, commands, 0) {
    Some(_) ->
      case spent.discarded >= max_inadmissible {
        True -> Stopped(spent)
        False -> Dropped(Spent(..spent, discarded: spent.discarded + 1))
      }

    None ->
      case spent.executed >= limits.budget {
        True -> Stopped(spent)

        // The caller's predicate is asked only here, where an execution is
        // about to be paid for: a dropped candidate costs nothing worth
        // stopping for, and asking per candidate keeps a slow poll deadline
        // from running past the caller's own limit.
        False ->
          case limits.stop() {
            StopShrinking -> Stopped(spent)
            KeepShrinking -> attempt(spec, limits, commands, spent)
          }
      }
  }
}

/// Execute one admissible candidate under the retry policy and accept it if
/// any execution fails with the wanted tag. Each execution spends budget, so
/// `max_shrinks` bounds the executions however many retries are asked for.
fn attempt(
  spec: Spec(model, cmd, sut),
  limits: Limits,
  commands: List(cmd),
  spent: Spent,
) -> Verdict {
  let result =
    retry.first_failure(
      limits.retries,
      limits.budget - spent.executed,
      fn(_attempt) { execute_list(spec, commands) },
      fn(failure) { failure.violation.tag == limits.tag },
    )
  let spent = Spent(..spent, executed: spent.executed + result.executions)

  case result.accepted {
    Some(failure) -> Accepted(failure, spent)
    None -> Refuted(spent)
  }
}

/// Every candidate, deletions before replacements: the cheap, large steps
/// come first so the list gets short before the commands get simple.
fn candidates(trees: List(Tree(cmd))) -> Yielder(List(Tree(cmd))) {
  yielder.append(deletions(trees), replacements(trees))
}

/// Delete a contiguous chunk of each size in `chunk_sizes`, at every
/// offset. The whole list is not among them; `shrink` offers it once.
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

/// The chunk sizes for a list of this length: `length / 2`, then repeated
/// halving (integer division) down to one. Empty for a list shorter than
/// two, whose only deletion is the whole list. It is a halving schedule,
/// not every size: for a length of 3 only single commands are offered.
fn chunk_sizes(length: Int) -> List(Int) {
  case length / 2 {
    0 -> []
    half -> [half, ..chunk_sizes(half)]
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
