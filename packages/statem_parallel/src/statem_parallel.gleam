//// Parallel model-based testing: does a system behave like its sequential
//// model when several callers use it at once?
////
//// `statem` checks a system one caller at a time. That says nothing about
//// the bug that only exists when two callers overlap: a read-then-write that
//// loses an update, a check-then-act that both callers pass. This layer finds
//// those by running a sequential prefix, then several branches of commands at
//// the same moment, and asking `statem/linearize` whether what every caller
//// saw could have happened in some single order that the sequential model
//// agrees with. If not, the system is not linearizable, and the report shows
//// the history and where the search for an order got stuck.
////
//// ## What a case is
////
//// A `Case` is a sequential `prefix` and two or three `branches`. The prefix
//// runs alone, one call at a time, so it brings the system to a state worth
//// racing from. The branches then run at once, each on its own process, each
//// keeping its own order. The model after the prefix is the starting point
//// for deciding whether the branches' calls are legal in every order they
//// might interleave.
////
//// ## Generation
////
//// The prefix is drawn exactly as `statem` draws a command list, threading
//// the seed and the model. The branches are then drawn from the model AFTER
//// the prefix, each as if it ran alone, so a branch's commands are sensible
//// at its own start. That is not enough: a command that was admissible alone
//// can be inadmissible once a sibling's call has landed before it. A case is
//// admissible only if every command's precondition holds in EVERY interleaving
//// of the branches, each branch keeping its order, from the post-prefix
//// model. The generator checks this by enumerating the interleavings, which it
//// does only while there are at most `max_interleavings` of them: a case with
//// more is first reduced by `bound_interleavings`, which drops the last command
//// of its longest branch until it fits. An inadmissible case is drawn again, up to eight times, and
//// after that its branches are trimmed command by command until the rest is
//// admissible, which an empty set of branches always is. So generation always
//// terminates and a generated case is always admissible, at the price that a
//// precondition which is hard to satisfy concurrently yields short branches.
////
//// A case is a function of `(seed, run)` alone: run `i` takes the same
//// seed `statem` would, so `generate_case` reproduces it without executing
//// anything and a failure's `seed` and `run` name it exactly.
////
//// ## Running and checking
////
//// `new_sut` builds one fresh system. The prefix runs call by call, each
//// response checked against the model before the next call, as `statem` does;
//// a prefix violation fails at once without racing anything. The branches then
//// race (`statem_parallel/internal/runner`), bounded by a deadline, and the
//// histories go to the checker with the model after the prefix. `teardown`
//// runs on every path where a system exists. A callback that raises is a
//// `statem.crash` violation, a phase past its deadline is `statem.timeout`,
//// a search that ran out of budget is `statem.undecided`, and a history no
//// order explains is `statem.not_linearizable`; each is a fixed tag so a
//// shrink stays on the failure it found.
////
//// `run` is called from several processes at once, so it must be safe to call
//// concurrently. The `sut` is a handle, such as a subject or a pid-backed
//// client, that the processes share; a system that is a plain value would be
//// copied into each process and nothing would race.
////
//// ## Scheduling is not reproducible
////
//// The seed fixes the case, never the interleaving. A race that shows up in
//// one run in ten shows up in none of the nine, so two knobs exist. `repeat`
//// runs a generated case several times before calling it a pass, and
//// `shrink_retries` gives each shrink candidate several executions and keeps
//// it if any of them fails with the original tag. Both default above one for
//// that reason, and both spend real time.
////
//// ## Shrinking
////
//// A failing case is shrunk greedily. Candidates come in this order: drop a
//// whole branch when there are more than two, merge two branches into one
//// sequence, delete one command from a branch, delete one command from the
//// prefix (`delete_from_prefix`), and move a branch's first command to the end of the prefix (a
//// racing command that still fails when it runs first, alone, was never part
//// of the race). Every candidate must be admissible, by the same rule as
//// generation, and counts as failing if any of `shrink_retries` executions
//// fails with the original tag. The first accepted candidate restarts the
//// search. `max_shrinks` bounds executions, and `shrink_stop` is the caller's
//// own bound, as in `statem`.
////
//// ## Using it from a test
////
//// ```gleam
//// pub fn counter_is_linearizable_test() {
////   case statem_parallel.check(spec(), statem_parallel.default_config(seed: 7)) {
////     Ok(Nil) -> Nil
////     Error(failure) -> panic as statem_parallel.report(failure, describe)
////   }
//// }
//// ```
////
//// ## Flow
////
//// `check` → `run_with` → `generate` → `execute` → `shrink` → `descend`
////
//// 1. `check` walks the runs with `check_from`, taking each run's seed from
////    `statem.next_run_seed`; `check_run` and `generate_case` reach the same
////    seed through `statem.run_seed`.
//// 2. `run_with` calls `generate`, which draws the prefix with `statem.grow`,
////    then `draw_branches` until `interleave.admissible` agrees.
//// 3. `execute` builds a system, runs the prefix with `run_prefix`, races the
////    branches with `runner.race`, asks `linearize.check` for an order, and
////    tears the system down.
//// 4. A failure goes to `shrink`, whose `descend` `search`es the `candidates`
////    and `attempt`s the admissible ones under the retry policy.
//// 5. `report` renders the `Failure`.

import exception
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import qcheck
import qcheck/tree.{type Tree, Tree}
import statem.{type Admission, type ShrinkStop, type Violation, Admit, Violation}
import statem/linearize.{type Event}
import statem_parallel/internal/interleave
import statem_parallel/internal/runner

// --- the specification ----------------------------------------------------

/// Everything `check` needs to know about a concurrent system and its model.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.Spec(
///   initial: 0,
///   command: fn(_) { qcheck.return(Increment) },
///   precondition: fn(_, _) { statem.Admit },
///   next_model: fn(count, _) { count + 1 },
///   new_sut: counter.start,
///   run: fn(counter, _) { counter.increment(counter) },
///   postcondition: fn(count, _, response) { expect(response, count + 1) },
///   teardown: counter.stop,
/// )
/// ```
pub type Spec(model, cmd, sut, response) {
  Spec(
    /// The abstract model before any command.
    initial: model,
    /// A generator of commands plausible in the given model. It may draw one
    /// the precondition rejects; that is a redraw, not an error.
    command: fn(model) -> qcheck.Generator(cmd),
    /// Whether a command may run in a model. For a parallel case it must hold
    /// in every interleaving the branches can take, which the generator
    /// enforces by enumeration.
    precondition: fn(model, cmd) -> Admission,
    /// The model after a command. Pure.
    next_model: fn(model, cmd) -> model,
    /// A fresh system under test, called once per execution. It is shared by
    /// every branch process, so it is a handle (a subject, a pid-backed
    /// client) rather than a value.
    new_sut: fn() -> sut,
    /// Run one command on the system and return what it answered. It MUST be
    /// safe to call from several processes at once.
    run: fn(sut, cmd) -> response,
    /// Whether `response` is right for `cmd` in the model as it was BEFORE
    /// the command. In a branch the model is whichever one the order being
    /// tried puts there, which is what makes the check a search.
    postcondition: fn(model, cmd, response) -> Result(Nil, Violation),
    /// Release the system. Called after every execution that built one, with
    /// the crash discarded.
    teardown: fn(sut) -> Nil,
  )
}

/// A sequential prefix and the branches that race after it.
pub type Case(cmd) {
  Case(
    /// Commands run alone, in order, before the race.
    prefix: List(cmd),
    /// Command sequences that run at once, each in its own order.
    branches: List(List(cmd)),
  )
}

// --- configuration --------------------------------------------------------

/// The most interleavings the generator will enumerate to prove a case
/// admissible. Past it, branches are trimmed until the count fits.
pub const max_interleavings = 10_000

/// How many runs, from which seed, and how hard to look and to shrink.
pub type Config {
  Config(
    /// The number of cases to generate and run.
    test_count: Int,
    /// The seed every run derives from. There is no default: the caller
    /// chooses it, so a gate is deterministic.
    seed: Int,
    /// How many branches race: two or three.
    branches: Int,
    /// The most commands in the sequential prefix.
    max_prefix: Int,
    /// The most commands in one branch, at most six.
    max_branch: Int,
    /// The most shrink executions for one failure, retries included.
    max_shrinks: Int,
    /// How many executions one shrink candidate gets; it counts as failing if
    /// any of them fails with the original tag.
    shrink_retries: Int,
    /// How many times a generated case runs before it is called a pass.
    repeat: Int,
    /// Asked before each shrink execution whether to go on.
    shrink_stop: fn() -> ShrinkStop,
    /// The deadline for the whole parallel phase of one execution, in
    /// milliseconds. A branch still running at the end is a timeout.
    deadline: Int,
    /// How many postcondition evaluations the checker may spend on one
    /// history before the answer is `statem.undecided`.
    search_budget: Int,
  )
}

/// A hundred cases of two branches, a prefix of up to six commands and
/// branches of up to four, each run three times, shrunk with up to ten
/// attempts per candidate, a ten second deadline and a hundred thousand
/// node search budget, from the caller's seed.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_test_count(300)
/// ```
pub fn default_config(seed seed: Int) -> Config {
  Config(
    test_count: 100,
    seed: seed,
    branches: 2,
    max_prefix: 6,
    max_branch: 4,
    max_shrinks: 500,
    shrink_retries: 10,
    repeat: 3,
    shrink_stop: fn() { statem.KeepShrinking },
    deadline: 10_000,
    search_budget: linearize.default_budget,
  )
}

/// Replace the number of cases. A negative count is treated as zero.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_test_count(10)
/// ```
pub fn with_test_count(config: Config, count: Int) -> Config {
  Config(..config, test_count: int.max(count, 0))
}

/// Replace the number of racing branches, clamped to two or three.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_branches(3)
/// ```
pub fn with_branches(config: Config, count: Int) -> Config {
  Config(..config, branches: int.clamp(count, min: 2, max: 3))
}

/// Replace the longest prefix. A negative length is treated as zero.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_max_prefix(0)
/// ```
pub fn with_max_prefix(config: Config, length: Int) -> Config {
  Config(..config, max_prefix: int.max(length, 0))
}

/// Replace the longest branch, clamped to between one and six: more than six
/// commands per branch has too many interleavings to prove admissible.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_max_branch(2)
/// ```
pub fn with_max_branch(config: Config, length: Int) -> Config {
  Config(..config, max_branch: int.clamp(length, min: 1, max: 6))
}

/// Replace the shrink budget. A negative budget is treated as zero, which
/// reports the original failure unshrunk.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_max_shrinks(100)
/// ```
pub fn with_max_shrinks(config: Config, budget: Int) -> Config {
  Config(..config, max_shrinks: int.max(budget, 0))
}

/// Give each shrink candidate `attempts` executions; it counts as failing if
/// any fails with the original tag. A value below one is treated as one.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_shrink_retries(20)
/// ```
pub fn with_shrink_retries(config: Config, attempts: Int) -> Config {
  Config(..config, shrink_retries: int.max(attempts, 1))
}

/// Run each generated case `times` before calling it a pass. A value below
/// one is treated as one.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_repeat(5)
/// ```
pub fn with_repeat(config: Config, times: Int) -> Config {
  Config(..config, repeat: int.max(times, 1))
}

/// Stop shrinking once `stop` answers `StopShrinking`, as in
/// `statem.with_shrink_stop`.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7)
/// |> statem_parallel.with_shrink_stop(fn() { statem.StopShrinking })
/// ```
pub fn with_shrink_stop(config: Config, stop: fn() -> ShrinkStop) -> Config {
  Config(..config, shrink_stop: stop)
}

/// Replace the parallel phase's deadline, in milliseconds. A value below one
/// is treated as one.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_deadline(2000)
/// ```
pub fn with_deadline(config: Config, milliseconds: Int) -> Config {
  Config(..config, deadline: int.max(milliseconds, 1))
}

/// Replace the checker's node budget. A negative budget is treated as zero,
/// which makes every history with a call undecided.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.default_config(seed: 7) |> statem_parallel.with_search_budget(1000)
/// ```
pub fn with_search_budget(config: Config, nodes: Int) -> Config {
  Config(..config, search_budget: int.max(nodes, 0))
}

// --- results --------------------------------------------------------------

/// What an execution left behind to show the reader.
pub type Evidence(cmd, response) {
  /// A prefix call failed, so nothing raced.
  InPrefix(
    /// The zero-based position in the prefix.
    step: Int,
  )

  /// The branches ran and their histories were checked.
  Raced(
    /// One history per branch, in order, with instants.
    histories: List(List(Event(cmd, response))),
    /// Where the search for an order got stuck, or `None` when it ran out of
    /// budget instead.
    explanation: Option(linearize.Explanation(cmd, response)),
  )

  /// Nothing was recorded: the system would not start, or a branch crashed
  /// or timed out before histories could be completed.
  Unrecorded
}

/// One failing check, with everything needed to reproduce and read it.
pub type Failure(cmd, response) {
  Failure(
    /// The `Config.seed` the check ran under.
    seed: Int,
    /// The zero-based run whose case failed.
    run: Int,
    /// The violation the SHRUNK case fails with; its tag equals the tag of
    /// the original failure.
    violation: Violation,
    /// The case as generated.
    original: Case(cmd),
    /// The case after shrinking.
    shrunk: Case(cmd),
    /// What the failing execution of the shrunk case recorded.
    evidence: Evidence(cmd, response),
    /// How many shrink candidates were accepted.
    shrinks: Int,
    /// How many shrink executions ran, retries included.
    candidates_run: Int,
    /// Whether the shrink converged or stopped on a bound.
    shrink_end: statem.ShrinkEnd,
  )
}

/// The tag of a history no order explains.
pub const not_linearizable_tag = "statem.not_linearizable"

/// The tag of a history whose search ran out of budget.
pub const undecided_tag = "statem.undecided"

// --- the driver -----------------------------------------------------------

/// How many times a case whose branches are not admissible is drawn again
/// before its branches are trimmed instead.
const max_redraws = 8

/// Run `test_count` generated cases against the spec and return the first
/// failure, already shrunk.
///
/// ## Examples
///
/// ```gleam
/// case statem_parallel.check(spec, statem_parallel.default_config(seed: 7)) {
///   Ok(Nil) -> Nil
///   Error(failure) -> panic as statem_parallel.report(failure, describe)
/// }
/// ```
pub fn check(
  spec: Spec(model, cmd, sut, response),
  config: Config,
) -> Result(Nil, Failure(cmd, response)) {
  check_from(spec, config, 0, qcheck.seed(config.seed))
}

/// Run one numbered run on its own. The case is drawn from
/// `(config.seed, run)` alone, so this reproduces the case `check` reported in
/// `Failure.run`, though not necessarily the interleaving that failed.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(failure) = statem_parallel.check_run(spec, config, 41)
/// ```
pub fn check_run(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  run: Int,
) -> Result(Nil, Failure(cmd, response)) {
  run_with(spec, config, run, statem.run_seed(config.seed, run))
}

/// The case run `run` of a check would generate, with nothing executed.
///
/// ## Examples
///
/// ```gleam
/// let case_ = statem_parallel.generate_case(spec, config, 3)
/// ```
pub fn generate_case(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  run: Int,
) -> Case(cmd) {
  generate(spec, config, statem.run_seed(config.seed, run))
}

/// Run one drawn case, repeating it, and shrink it if it fails.
fn run_with(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  run: Int,
  seed: qcheck.Seed,
) -> Result(Nil, Failure(cmd, response)) {
  let drawn = generate(spec, config, seed)

  // Every failure counts here, whatever its tag: the first one found is the
  // one to shrink. Repeats are what give a scheduling-dependent bug several
  // chances to show before the case is believed.
  let tried =
    statem.first_failure(
      config.repeat,
      config.repeat,
      fn(_) { execute(spec, config, drawn) },
      fn(_) { True },
    )

  case tried.accepted {
    None -> Ok(Nil)
    Some(trial) -> Error(shrink(spec, config, run, drawn, trial))
  }
}

/// The runs from `run` onward, threading the seed stream so a check costs one
/// draw per run.
fn check_from(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  run: Int,
  stream: qcheck.Seed,
) -> Result(Nil, Failure(cmd, response)) {
  case run >= config.test_count {
    True -> Ok(Nil)

    False -> {
      let #(seed, stream) = statem.next_run_seed(stream)

      case run_with(spec, config, run, seed) {
        Ok(Nil) -> check_from(spec, config, run + 1, stream)
        Error(failure) -> Error(failure)
      }
    }
  }
}

/// Render a failure as readable text: where it came from, what broke, the
/// original and shrunk cases, the failing history with times relative to the
/// first invocation, and where the search for an order got stuck. Responses
/// are shown with `string.inspect`.
///
/// ## Examples
///
/// ```gleam
/// statem_parallel.report(failure, fn(command) { string.inspect(command) })
/// ```
pub fn report(
  failure: Failure(cmd, response),
  describe describe: fn(cmd) -> String,
) -> String {
  let ending = case failure.shrink_end {
    statem.ShrinkConverged -> "converged"
    statem.ShrinkBoundHit -> "shrink bound hit"
  }

  string.join(
    list.flatten([
      [
        "parallel property failed: seed "
          <> int.to_string(failure.seed)
          <> ", run "
          <> int.to_string(failure.run),
        "violation ["
          <> failure.violation.tag
          <> "]: "
          <> failure.violation.detail,
        "original case:",
      ],
      render_case(failure.original, describe),
      [
        "shrunk case: "
        <> int.to_string(failure.shrinks)
        <> " shrinks accepted, "
        <> int.to_string(failure.candidates_run)
        <> " executions, "
        <> ending,
      ],
      render_case(failure.shrunk, describe),
      render_evidence(failure.evidence, describe),
    ]),
    "\n",
  )
}

/// A case as indented lines: the prefix, then each branch.
fn render_case(shown: Case(cmd), describe: fn(cmd) -> String) -> List(String) {
  let lines = fn(label, commands) {
    [
      "  " <> label <> ":",
      ..list.index_map(commands, fn(command, index) {
        "    " <> int.to_string(index) <> ". " <> describe(command)
      })
    ]
  }

  list.flatten([
    lines("prefix", shown.prefix),
    list.index_map(shown.branches, fn(commands, index) {
      lines("branch " <> int.to_string(index), commands)
    })
      |> list.flatten,
  ])
}

/// The history and the explanation, when the failure recorded any.
fn render_evidence(
  evidence: Evidence(cmd, response),
  describe: fn(cmd) -> String,
) -> List(String) {
  case evidence {
    InPrefix(step) -> [
      "the prefix failed at step " <> int.to_string(step) <> "; nothing raced",
    ]

    Unrecorded -> ["no history was recorded"]

    Raced(histories, explanation) -> {
      let origin =
        histories
        |> list.flatten
        |> list.map(fn(event) { event.invoked_at })
        |> list.reduce(int.min)
        |> option.from_result
        |> option.unwrap(0)

      list.flatten([
        ["failing history (milliseconds after the first invocation):"],
        render_histories(histories, origin, describe),
        render_explanation(explanation, describe),
      ])
    }
  }
}

/// One line per call, grouped by branch.
fn render_histories(
  histories: List(List(Event(cmd, response))),
  origin: Int,
  describe: fn(cmd) -> String,
) -> List(String) {
  histories
  |> list.index_map(fn(events, branch) {
    list.map(events, fn(event) {
      "  branch "
      <> int.to_string(branch)
      <> " +"
      <> int.to_string(event.invoked_at - origin)
      <> ".."
      <> int.to_string(event.returned_at - origin)
      <> "  "
      <> describe(event.cmd)
      <> " -> "
      <> string.inspect(event.response)
    })
  })
  |> list.flatten
}

/// What the search placed and what stopped every branch after it.
fn render_explanation(
  explanation: Option(linearize.Explanation(cmd, response)),
  describe: fn(cmd) -> String,
) -> List(String) {
  case explanation {
    None -> ["the search ran out of budget before it could decide"]

    Some(linearize.Explanation(placed, blocked)) -> {
      let call = fn(entry: linearize.Placed(cmd, response)) {
        "branch "
        <> int.to_string(entry.branch)
        <> " call "
        <> int.to_string(entry.index)
        <> " ("
        <> describe(entry.event.cmd)
        <> " -> "
        <> string.inspect(entry.event.response)
        <> ")"
      }

      list.flatten([
        [
          "longest order found: "
          <> int.to_string(list.length(placed))
          <> " calls",
        ],
        list.map(placed, fn(entry) { "  placed " <> call(entry) }),
        ["then no branch could go next:"],
        list.map(blocked, fn(entry) {
          "  " <> call(entry.placed) <> " " <> obstacle_text(entry.obstacle)
        }),
      ])
    }
  }
}

/// Why a call could not take effect next, in words.
fn obstacle_text(obstacle: linearize.Obstacle) -> String {
  case obstacle {
    linearize.Violated(violation) ->
      "violated [" <> violation.tag <> "]: " <> violation.detail

    linearize.Overtaken(branch, index) ->
      "was overtaken by branch "
      <> int.to_string(branch)
      <> " call "
      <> int.to_string(index)
  }
}

// --- generation -----------------------------------------------------------

/// The case one seed generates.
fn generate(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  seed: qcheck.Seed,
) -> Case(cmd) {
  let #(length_tree, seed) =
    qcheck.generate_tree(
      qcheck.bounded_int(from: 0, to: config.max_prefix),
      seed,
    )
  let Tree(length, _) = length_tree

  let statem.Grown(trees, after_prefix, seed) =
    statem.grow(
      spec.command,
      spec.precondition,
      spec.next_model,
      length: length,
      from: spec.initial,
      seed: seed,
    )

  Case(
    prefix: roots(trees),
    branches: draw_branches(spec, config, after_prefix, seed, max_redraws),
  )
}

/// Draw the branches from the model after the prefix and make them
/// admissible. A draw that is not is retried while `redraws` last, and then
/// trimmed, so the result is always admissible.
fn draw_branches(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  model: model,
  seed: qcheck.Seed,
  redraws: Int,
) -> List(List(cmd)) {
  let #(drawn, seed) = grow_branches(spec, config, model, seed)
  let bounded = bound_interleavings(drawn)

  case admissible(spec, model, bounded), bounded {
    Admit, [_, _, ..] -> bounded

    // A draw that is inadmissible, or left fewer than two branches to race
    // because a generator that keeps being rejected drew nothing for one of
    // them, is drawn again; once the redraws are spent whatever is
    // admissible is kept, however little of it there is.
    _, _ ->
      case redraws <= 0 {
        True -> trim_until_admissible(spec, model, bounded)
        False -> draw_branches(spec, config, model, seed, redraws - 1)
      }
  }
}

/// Each branch drawn alone from the same model, with its own target length of
/// at least one. A branch the precondition left empty is dropped, since an
/// empty branch races nothing.
fn grow_branches(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  model: model,
  seed: qcheck.Seed,
) -> #(List(List(cmd)), qcheck.Seed) {
  let #(drawn, seed) =
    list.fold(list.repeat(Nil, config.branches), #([], seed), fn(state, _) {
      let #(done, seed) = state
      let #(length_tree, seed) =
        qcheck.generate_tree(
          qcheck.bounded_int(from: 1, to: config.max_branch),
          seed,
        )
      let Tree(length, _) = length_tree
      let statem.Grown(trees, _, seed) =
        statem.grow(
          spec.command,
          spec.precondition,
          spec.next_model,
          length: length,
          from: model,
          seed: seed,
        )

      #(list.append(done, [roots(trees)]), seed)
    })

  #(list.filter(drawn, fn(branch) { branch != [] }), seed)
}

/// Drop the last command of the longest branch until the interleavings can be
/// enumerated.
fn bound_interleavings(branches: List(List(cmd))) -> List(List(cmd)) {
  case interleave.count(list.map(branches, list.length)) > max_interleavings {
    True -> bound_interleavings(trim_longest(branches))
    False -> branches
  }
}

/// Trim the last command from the longest branch, and a branch left empty
/// disappears.
fn trim_longest(branches: List(List(cmd))) -> List(List(cmd)) {
  let sized = list.map(branches, fn(branch) { #(list.length(branch), branch) })
  let longest = list.fold(sized, 0, fn(most, entry) { int.max(most, entry.0) })

  sized
  |> trim_first_longest(longest)
  |> list.filter(fn(branch) { branch != [] })
}

/// Remove the final command of the first branch whose length is `longest`,
/// leaving the others as they were.
fn trim_first_longest(
  sized: List(#(Int, List(cmd))),
  longest: Int,
) -> List(List(cmd)) {
  case sized {
    [] -> []

    [#(length, branch), ..rest] ->
      case length == longest {
        True -> [
          list.take(branch, length - 1),
          ..list.map(rest, fn(entry) { entry.1 })
        ]

        False -> [branch, ..trim_first_longest(rest, longest)]
      }
  }
}

/// Trim until every interleaving is admissible. Empty branches are
/// admissible, so this ends.
fn trim_until_admissible(
  spec: Spec(model, cmd, sut, response),
  model: model,
  branches: List(List(cmd)),
) -> List(List(cmd)) {
  case admissible(spec, model, branches) {
    Admit -> branches
    statem.Reject -> trim_until_admissible(spec, model, trim_longest(branches))
  }
}

/// Whether the branches are admissible in every interleaving from `model`.
fn admissible(
  spec: Spec(model, cmd, sut, response),
  model: model,
  branches: List(List(cmd)),
) -> Admission {
  interleave.admissible(spec.precondition, spec.next_model, model, branches)
}

fn roots(trees: List(Tree(cmd))) -> List(cmd) {
  list.map(trees, fn(drawn) {
    let Tree(command, _) = drawn
    command
  })
}

// --- execution ------------------------------------------------------------

/// A violation and what the execution recorded around it.
type Trial(cmd, response) {
  Trial(violation: Violation, evidence: Evidence(cmd, response))
}

/// Run a case once on a fresh system, tear it down, and return the first
/// violation.
fn execute(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  shown: Case(cmd),
) -> Result(Nil, Trial(cmd, response)) {
  case exception.rescue(spec.new_sut) {
    Error(crash) -> Error(Trial(statem.crashed("new_sut", crash), Unrecorded))

    Ok(sut) -> {
      let outcome = play(spec, config, sut, shown)

      // The verdict belongs to the case, so a crash in teardown is dropped
      // rather than allowed to mask it.
      let _ = exception.rescue(fn() { spec.teardown(sut) })

      outcome
    }
  }
}

/// The prefix, the race, and the check, in that order.
fn play(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  sut: sut,
  shown: Case(cmd),
) -> Result(Nil, Trial(cmd, response)) {
  case run_prefix(spec, sut, spec.initial, shown.prefix, 0) {
    Error(trial) -> Error(trial)

    Ok(after_prefix) ->
      case runner.race(spec.run, sut, shown.branches, config.deadline) {
        Error(violation) -> Error(Trial(violation, Unrecorded))
        Ok(histories) -> judge_histories(spec, config, after_prefix, histories)
      }
  }
}

/// Run the prefix one call at a time, checking each response against the
/// model before the next call, and return the model after it.
fn run_prefix(
  spec: Spec(model, cmd, sut, response),
  sut: sut,
  model: model,
  commands: List(cmd),
  step: Int,
) -> Result(model, Trial(cmd, response)) {
  case commands {
    [] -> Ok(model)

    [command, ..rest] ->
      case exception.rescue(fn() { spec.run(sut, command) }) {
        Error(crash) ->
          Error(Trial(statem.crashed("run", crash), InPrefix(step)))

        Ok(response) ->
          case
            exception.rescue(fn() {
              spec.postcondition(model, command, response)
            })
          {
            Error(crash) ->
              Error(Trial(
                statem.crashed("postcondition", crash),
                InPrefix(step),
              ))

            Ok(Error(violation)) -> Error(Trial(violation, InPrefix(step)))

            Ok(Ok(Nil)) ->
              run_prefix(
                spec,
                sut,
                spec.next_model(model, command),
                rest,
                step + 1,
              )
          }
      }
  }
}

/// Ask the checker whether the histories have an order, turning each answer
/// into the violation it deserves.
fn judge_histories(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  model: model,
  histories: List(List(Event(cmd, response))),
) -> Result(Nil, Trial(cmd, response)) {
  let machine =
    linearize.Machine(
      next_model: spec.next_model,
      postcondition: spec.postcondition,
    )

  case
    exception.rescue(fn() {
      linearize.check(machine, model, histories, config.search_budget)
    })
  {
    Error(crash) ->
      Error(Trial(statem.crashed("checker", crash), Raced(histories, None)))

    Ok(linearize.Linearizable(_)) -> Ok(Nil)

    Ok(linearize.Undecided(nodes)) ->
      Error(Trial(
        Violation(
          tag: undecided_tag,
          detail: "the search spent its budget of "
            <> int.to_string(nodes)
            <> " nodes without deciding",
        ),
        Raced(histories, None),
      ))

    Ok(linearize.NotLinearizable(explanation)) ->
      Error(Trial(
        Violation(
          tag: not_linearizable_tag,
          detail: "no order of the calls is consistent with the model",
        ),
        Raced(histories, Some(explanation)),
      ))
  }
}

// --- shrinking ------------------------------------------------------------

/// The end state of a shrink.
type Shrunk(cmd, response) {
  Shrunk(
    shrunk: Case(cmd),
    trial: Trial(cmd, response),
    accepted: Int,
    executed: Int,
    ending: statem.ShrinkEnd,
  )
}

/// What one round of the search found.
type Search(cmd, response) {
  /// An admissible candidate that fails with the original tag.
  Found(shrunk: Case(cmd), trial: Trial(cmd, response), executed: Int)

  /// Every candidate was tried or inadmissible.
  Exhausted(executed: Int)

  /// A bound stopped the round with an admissible candidate untried.
  OutOfBudget(executed: Int)
}

/// Shrink a failing case and package the result.
fn shrink(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  run: Int,
  original: Case(cmd),
  first: Trial(cmd, response),
) -> Failure(cmd, response) {
  let Shrunk(shrunk, trial, accepted, executed, ending) =
    descend(spec, config, first.violation.tag, original, first, 0, 0)

  Failure(
    seed: config.seed,
    run: run,
    violation: trial.violation,
    original: original,
    shrunk: shrunk,
    evidence: trial.evidence,
    shrinks: accepted,
    candidates_run: executed,
    shrink_end: ending,
  )
}

/// Take the first accepted candidate and restart from it. Every candidate is
/// smaller in command count, or equal in count with fewer commands racing, or
/// equal in both with fewer branches, so the descent terminates.
fn descend(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  tag: String,
  current: Case(cmd),
  trial: Trial(cmd, response),
  accepted: Int,
  executed: Int,
) -> Shrunk(cmd, response) {
  case search(spec, config, tag, candidates(current), executed) {
    Found(next, next_trial, next_executed) ->
      descend(spec, config, tag, next, next_trial, accepted + 1, next_executed)

    Exhausted(next_executed) ->
      Shrunk(current, trial, accepted, next_executed, statem.ShrinkConverged)

    OutOfBudget(next_executed) ->
      Shrunk(current, trial, accepted, next_executed, statem.ShrinkBoundHit)
  }
}

/// What became of one candidate.
type Verdict(cmd, response) {
  /// A precondition rejects it; nothing ran.
  Dropped

  /// It is admissible but a bound forbids running it.
  Stopped

  /// It failed with the original tag, after `executions` runs.
  Accepted(trial: Trial(cmd, response), executions: Int)

  /// It ran `executions` times and every run passed or failed another way.
  Refuted(executions: Int)
}

/// Walk the candidates in order, one `judge` at a time.
fn search(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  tag: String,
  pending: List(Case(cmd)),
  executed: Int,
) -> Search(cmd, response) {
  case pending {
    [] -> Exhausted(executed)

    [candidate, ..rest] ->
      case judge(spec, config, tag, candidate, executed) {
        Dropped -> search(spec, config, tag, rest, executed)

        Refuted(used) -> search(spec, config, tag, rest, executed + used)

        Stopped -> OutOfBudget(executed)

        Accepted(trial, used) -> Found(candidate, trial, executed + used)
      }
  }
}

/// Decide one candidate: drop it unexecuted if a precondition rejects it,
/// otherwise see whether a bound lets it run.
fn judge(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  tag: String,
  candidate: Case(cmd),
  executed: Int,
) -> Verdict(cmd, response) {
  case case_admissible(spec, candidate) {
    statem.Reject -> Dropped
    Admit -> pay(spec, config, tag, candidate, executed)
  }
}

/// Stop if a bound is spent, otherwise pay for the candidate's executions. The
/// caller's predicate is asked only here, where an execution is about to be
/// paid for, as in `statem`: a dropped candidate costs nothing worth stopping
/// for.
fn pay(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  tag: String,
  candidate: Case(cmd),
  executed: Int,
) -> Verdict(cmd, response) {
  use <- bool.guard(executed >= config.max_shrinks, Stopped)

  case config.shrink_stop() {
    statem.StopShrinking -> Stopped

    statem.KeepShrinking -> {
      let tried = attempt(spec, config, tag, candidate, executed)

      case tried.accepted {
        Some(trial) -> Accepted(trial, tried.executions)
        None -> Refuted(tried.executions)
      }
    }
  }
}

/// Execute one admissible candidate under the retry policy: it is accepted if
/// any execution fails with the wanted tag. The result's `executions` is what
/// the caller charges to `max_shrinks`.
fn attempt(
  spec: Spec(model, cmd, sut, response),
  config: Config,
  tag: String,
  candidate: Case(cmd),
  executed: Int,
) -> statem.Attempted(Trial(cmd, response)) {
  statem.first_failure(
    config.shrink_retries,
    config.max_shrinks - executed,
    fn(_) { execute(spec, config, candidate) },
    fn(trial) { trial.violation.tag == tag },
  )
}

/// Whether a candidate may run: its prefix is admissible from the initial
/// model, and its branches are admissible in every interleaving from the model
/// after it, within the same enumeration bound generation uses.
fn case_admissible(
  spec: Spec(model, cmd, sut, response),
  candidate: Case(cmd),
) -> Admission {
  case replay_prefix(spec, spec.initial, candidate.prefix) {
    Error(Nil) -> statem.Reject

    Ok(after_prefix) ->
      case
        interleave.count(list.map(candidate.branches, list.length))
        > max_interleavings
      {
        True -> statem.Reject
        False -> admissible(spec, after_prefix, candidate.branches)
      }
  }
}

/// The model after the prefix, or `Error` if a precondition rejects a
/// command on the way.
fn replay_prefix(
  spec: Spec(model, cmd, sut, response),
  model: model,
  commands: List(cmd),
) -> Result(model, Nil) {
  case commands {
    [] -> Ok(model)

    [command, ..rest] ->
      case spec.precondition(model, command) {
        statem.Reject -> Error(Nil)
        Admit -> replay_prefix(spec, spec.next_model(model, command), rest)
      }
  }
}

/// Every way to make a case smaller, in the order they are tried: whole
/// branches first, then single commands, then the move that turns a racing
/// command into a sequential one.
fn candidates(shown: Case(cmd)) -> List(Case(cmd)) {
  list.flatten([
    drop_branch(shown),
    merge_branches(shown),
    delete_from_branches(shown),
    delete_from_prefix(shown),
    hoist_first_commands(shown),
  ])
}

/// Drop one whole branch, offered only while more than two race, so a case
/// does not shrink out of being parallel by this step.
fn drop_branch(shown: Case(cmd)) -> List(Case(cmd)) {
  case shown.branches {
    [_, _, _, ..] ->
      list.index_map(shown.branches, fn(_, index) {
        Case(..shown, branches: remove_at(shown.branches, index))
      })

    _ -> []
  }
}

/// Merge each pair of branches into one sequence: the later branch's
/// commands follow the earlier's, at the earlier's place.
fn merge_branches(shown: Case(cmd)) -> List(Case(cmd)) {
  let indexed =
    list.index_map(shown.branches, fn(branch, index) { #(index, branch) })

  list.flat_map(indexed, fn(first) {
    list.filter_map(indexed, fn(second) {
      case first.0 < second.0 {
        False -> Error(Nil)

        True ->
          Ok(
            Case(
              ..shown,
              branches: shown.branches
                |> list.index_map(fn(branch, index) {
                  case index == first.0 {
                    True -> list.append(first.1, second.1)
                    False -> branch
                  }
                })
                |> remove_at(second.0),
            ),
          )
      }
    })
  })
}

/// Delete each single command from each branch. A branch emptied by it
/// disappears, since an empty branch races nothing.
fn delete_from_branches(shown: Case(cmd)) -> List(Case(cmd)) {
  shown.branches
  |> list.index_map(fn(branch, branch_index) {
    list.index_map(branch, fn(_, command_index) {
      let shorter = remove_at(branch, command_index)

      Case(
        ..shown,
        branches: shown.branches
          |> list.index_map(fn(existing, index) {
            case index == branch_index {
              True -> shorter
              False -> existing
            }
          })
          |> list.filter(fn(existing) { existing != [] }),
      )
    })
  })
  |> list.flatten
}

/// Delete each single command from the prefix.
fn delete_from_prefix(shown: Case(cmd)) -> List(Case(cmd)) {
  list.index_map(shown.prefix, fn(_, index) {
    Case(..shown, prefix: remove_at(shown.prefix, index))
  })
}

/// Move each branch's first command to the end of the prefix. A failure that
/// survives it did not need that command to race.
fn hoist_first_commands(shown: Case(cmd)) -> List(Case(cmd)) {
  shown.branches
  |> list.index_map(fn(branch, branch_index) {
    case branch {
      [] -> []

      [first, ..rest] -> [
        Case(
          prefix: list.append(shown.prefix, [first]),
          branches: shown.branches
            |> list.index_map(fn(existing, index) {
              case index == branch_index {
                True -> rest
                False -> existing
              }
            })
            |> list.filter(fn(existing) { existing != [] }),
        ),
      ]
    }
  })
  |> list.flatten
}

/// The list without the element at `index`.
fn remove_at(items: List(a), index: Int) -> List(a) {
  list.append(list.take(items, index), list.drop(items, index + 1))
}
