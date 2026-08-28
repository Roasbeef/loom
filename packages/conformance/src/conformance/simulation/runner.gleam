//// The deterministic simulation runner: seed in, verdict out.
////
//// One seed becomes one script and one fault schedule. The script runs
//// twice — once with no faults at all, once under the schedule — and the
//// two runs are compared. Everything the schedule injects is required to
//// be invisible: the same terminal outcomes, the same projected
//// transcript, the same ledger, the same invariants. Whatever the script
//// itself asks for (a provider that refuses, a user who aborts) happens
//// in both runs, so it cannot be mistaken for damage.
////
//// A run is driven, not waited on. The runner watches the session's
//// event counter; while it moves the session is working, and when it
//// stops the session is waiting for a timer that will never arrive by
//// itself, so the runner advances logical time to the next deadline
//// instead of sleeping. Firing a deadline early is safe by construction:
//// the driver re-reads its durable state on every pass, so an early
//// wake costs one wasted planning pass and nothing else.
////
//// This module is test infrastructure: `let assert` appears here (as in
//// `conformance/storage_suite`) for the fixtures a run cannot proceed
//// without.

import conformance/simulation/control.{type Control}
import conformance/simulation/fault.{type Schedule}
import conformance/simulation/invariant
import conformance/simulation/random
import conformance/simulation/script.{type Op, type Script}
import conformance/simulation/store
import conformance/simulation/surface
import conformance/simulation/vclock.{type Clockwork}
import core/clock
import core/entry.{type Entry}
import core/ids.{type OpId}
import core/message.{
  type AgentMessage, AssistantMessage, AssistantText, AssistantThinking,
  AssistantToolCall, CustomMessage, ToolResultImage, ToolResultMessage,
  ToolResultText, UserImage, UserMessage, UserText,
}
import core/register
import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/acceptance
import machine/codec
import machine/operation.{type LastResult, ReplayNever}
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration, ThinkingOff,
}
import runtime/api
import runtime/supervisor
import runtime/writer
import session/session.{type Session}
import storage/storage

/// The strand every simulated session runs on.
pub const strand = "main"

/// The subagent strand a script with a `subagent` brief creates (the
/// surface owns the name so it can aim strand-restart faults).
pub const sub_strand = surface.sub_strand

/// What one run of a script converged to.
pub type Report {
  Report(
    /// One tag per accepted operation, in order.
    outcomes: List(String),
    /// Structural fingerprints of the final projected context.
    projection: List(String),
    /// The ledger's total token count.
    usage_total: Int,
    /// Commits that landed, counted across writer restarts.
    commits: Int,
    /// Invocation counts for every `replay: Never` call the script asks
    /// for.
    never_calls: List(#(String, Int)),
    /// Boundary-invariant violations recorded during the run.
    violations: List(String),
    /// Whether a scheduled crash actually fired.
    crashed: Bool,
    /// Whether the run ran out of drive budget without terminating.
    stalled: Bool,
    /// How many terminal transactions wrote `strand.last_result` on the
    /// main strand and on the subagent strand, kept separate (rather
    /// than pre-summed) so a `terminal/last-result-once` failure can name
    /// which strand is short instead of only the combined total — issue
    /// #58, where the harness report was otherwise clean.
    terminal_writes_main: Int,
    terminal_writes_sub: Int,
    /// Every named path this run reached.
    coverage: List(String),
    /// Effects dispatched, counted across restarts.
    effects: Int,
    /// Every reply an `attempt` did not observe, labelled
    /// `raised@<site>` or `expired@<site>`. An `expired@` entry is the
    /// only place a real clock decided anything, so a run with none of
    /// them has no wall-clock wait to blame.
    waits: List(String),
  )
}

/// A failed check: which one, and enough detail to act on it.
pub type Failure {
  Failure(check: String, detail: String)
}

/// The verdict for one seed.
pub type Verdict {
  /// Every check held.
  Passed
  /// A check failed; `reproduce` is the line to paste to re-run this
  /// case alone, and `corroboration` says whether re-running it changes
  /// the answer — which is the difference between a behaviour
  /// difference and a harness artefact. `failure.detail` carries both
  /// that verdict and the run's own timing evidence in prose, so a
  /// printer that only shows the detail still shows them.
  Failed(
    seed: Int,
    failure: Failure,
    reproduce: String,
    corroboration: Corroboration,
  )
}

// The drive budget: planning passes the runner will wait through for one
// operation before calling it stalled. Generous, because a crashed tree
// reboots and replays.
const budget = 4000

/// Runs one seed end to end and reports the verdict. Shrinking is not
/// attempted here — `check` does that — so this is the entry point for
/// re-running a single reported case.
///
/// ## Examples
///
/// ```gleam
/// // runner.run(seed: 12345)
/// ```
///
pub fn run(seed seed: Int) -> Verdict {
  examine(seed:).verdict
}

/// One seed's verdict together with every named path its two runs
/// reached. The coverage is what makes the suite's claim checkable: a
/// generator that never produced a deferred poll would pass every
/// convergence check and prove nothing.
pub type Examination {
  Examination(verdict: Verdict, coverage: List(String))
}

/// Runs one seed and reports both its verdict and its coverage.
///
/// ## Examples
///
/// ```gleam
/// // runner.examine(seed: 12345).coverage
/// ```
///
pub fn examine(seed seed: Int) -> Examination {
  let #(script, schedule, base) = plan(seed)
  let faulted = execute(script, schedule)
  let coverage =
    list.append(base.coverage, faulted.coverage)
    |> list.unique
    |> list.sort(string.compare)
  let verdict = case judge(script, schedule, base, faulted) {
    Ok(Nil) -> Passed
    Error(failure) ->
      failed(
        seed,
        failure,
        script,
        schedule,
        corroborate(seed, corroboration_runs, 1, 1),
      )
  }
  Examination(verdict:, coverage:)
}

/// Runs one seed and, on failure, searches for a simpler fault schedule
/// that still fails, re-running each candidate rather than inferring
/// anything about it. The reported schedule is always one that was
/// observed to fail, so a "minimal" case is never a guess.
///
/// ## Examples
///
/// ```gleam
/// // runner.check(seed: 12345, shrink_budget: 12)
/// ```
///
pub fn check(seed seed: Int, shrink_budget shrink_budget: Int) -> Verdict {
  let #(script, schedule, base) = plan(seed)
  case verify(script, schedule, base) {
    Ok(Nil) -> Passed
    // Corroborate before shrinking, not after. Shrinking asks "does this
    // smaller schedule still fail?", and a seed whose verdict is not
    // stable answers that question by coin toss — it would wander to
    // whichever candidate happened to lose the race, and report a
    // minimal schedule that means nothing. So an unstable seed is
    // reported at full size, which is also the honest thing to hand
    // someone: the case as it was drawn.
    Error(failure) ->
      case corroborate(seed, corroboration_runs, 1, 1) {
        Unstable(..) as corroboration ->
          failed(seed, failure, script, schedule, corroboration)
        Reproducible(..) as corroboration -> {
          let #(smallest, smallest_failure) =
            shrink(script, base, schedule, failure, shrink_budget)
          failed(seed, smallest_failure, script, smallest, corroboration)
        }
      }
  }
}

fn shrink(
  script: Script,
  base: Report,
  schedule: Schedule,
  failure: Failure,
  remaining: Int,
) -> #(Schedule, Failure) {
  case remaining <= 0 {
    True -> #(schedule, failure)
    False ->
      case first_failing(script, base, fault.shrink(schedule), remaining) {
        #(None, _spent) -> #(schedule, failure)
        #(Some(#(smaller, smaller_failure)), spent) ->
          shrink(script, base, smaller, smaller_failure, remaining - spent)
      }
  }
}

fn first_failing(
  script: Script,
  base: Report,
  candidates: List(Schedule),
  remaining: Int,
) -> #(Option(#(Schedule, Failure)), Int) {
  case candidates, remaining <= 0 {
    [], _ | _, True -> #(None, 1)
    [candidate, ..rest], False ->
      case verify(script, candidate, base) {
        Error(failure) -> #(Some(#(candidate, failure)), 1)
        Ok(Nil) -> {
          let #(found, spent) = first_failing(script, base, rest, remaining - 1)
          #(found, spent + 1)
        }
      }
  }
}

fn plan(seed: Int) -> #(Script, Schedule, Report) {
  let rng = random.from_seed(seed)
  let #(script_rng, rng) = random.split(rng)
  let #(fault_rng, _rng) = random.split(rng)
  let #(script, _) = script.generate(script_rng)
  // The fault-free run fixes the commit count that commit-indexed faults
  // are drawn against, so a schedule always lands inside its run.
  let base = execute(script, fault.none())
  let #(schedule, _) =
    fault.generate(
      fault_rng,
      commit_bound: base.commits,
      effect_bound: base.effects,
    )
  #(script, schedule, base)
}

/// Runs one hand-built script under one hand-built schedule and applies
/// every check, reporting the first that failed.
///
/// The generated seeds are the explorer; these are the memory. A pinned
/// case keeps its meaning when the generator changes, which a seed does
/// not, so a bug found once stays tested for.
///
/// ## Examples
///
/// ```gleam
/// // runner.verify_case(script, fault.Schedule(faults: [..]))
/// ```
///
pub fn verify_case(script: Script, schedule: Schedule) -> Result(Nil, Failure) {
  verify(script, schedule, execute(script, fault.none()))
}

/// Runs `count` seeds from `from` and returns one line per failing seed,
/// shrunk. The soak entry point: long runs by hand or nightly, where the
/// budget for shrinking is worth spending.
///
/// ## Examples
///
/// ```gleam
/// // runner.soak(from: 1, count: 5000)
/// ```
///
pub fn soak(from from: Int, count count: Int) -> List(String) {
  seeds(from, count)
  |> list.filter_map(fn(seed) {
    case check(seed:, shrink_budget: 12) {
      Passed -> Error(Nil)
      Failed(failure:, reproduce:, ..) ->
        Ok(failure.check <> " — " <> failure.detail <> "\n    " <> reproduce)
    }
  })
}

/// The seed range `[from, from + count)`.
///
/// ## Examples
///
/// ```gleam
/// assert runner.seeds(3, 2) == [3, 4]
/// ```
///
pub fn seeds(from: Int, count: Int) -> List(Int) {
  case count <= 0 {
    True -> []
    False -> [from, ..seeds(from + 1, count - 1)]
  }
}

/// The one-line reproduction a failing run prints.
///
/// ## Examples
///
/// ```gleam
/// // runner.reproduce(seed, script, schedule)
/// ```
///
pub fn reproduce(seed: Int, script: Script, schedule: Schedule) -> String {
  "seed "
  <> int.to_string(seed)
  <> "  |  script: "
  <> script.describe(script)
  <> "  |  faults: "
  <> fault.describe(schedule)
}

// --- the checks -----------------------------------------------------------

fn verify(
  script: Script,
  schedule: Schedule,
  base: Report,
) -> Result(Nil, Failure) {
  judge(script, schedule, base, execute(script, schedule))
}

// Every failure leaves here carrying what the run knows about its own
// timing. A reader of a red soak needs to know whether the harness went
// anywhere near a clock before deciding whether the diff is at fault,
// and asking them to re-run to find out is exactly the expensive habit
// this annotation exists to retire.
fn judge(
  script: Script,
  schedule: Schedule,
  base: Report,
  faulted: Report,
) -> Result(Nil, Failure) {
  adjudicate(script, schedule, base, faulted)
  |> result.map_error(with_timing(_, base, faulted))
}

fn adjudicate(
  script: Script,
  schedule: Schedule,
  base: Report,
  faulted: Report,
) -> Result(Nil, Failure) {
  use _ <- result.try(sound("fault-free", base))
  use _ <- result.try(sound("faulted", faulted))
  use _ <- result.try(crash_fired(schedule, faulted))
  case script.aborts(script) {
    // An abort is a race by design: how far the run got before the
    // marker landed is not a property of the fault schedule. Outcome
    // shape and the invariants still hold, and are checked above.
    True -> Ok(Nil)
    False -> {
      use _ <- result.try(same_outcomes(base, faulted))
      use _ <- result.try(same_projection(base, faulted))
      same_ledger(base, faulted)
    }
  }
}

// --- telling a timing artefact from a behaviour difference ----------------
//
// The soak is only worth what its failures mean. A seed that diverges
// because a planner changed and a seed that diverges because the BEAM
// interleaved two processes differently look identical once they are a
// line in a log, and the second-order cost of that is the expensive one:
// a real regression gets waved away as "the box was busy". So a failure
// carries its own evidence about which it is, and the reader is never
// asked to reconstruct it.
//
// Two independent pieces of evidence are attached. The first is what the
// run itself observed — every reply an `attempt` did not see, and in
// particular whether any of them was a wall-clock expiry, the one thing
// in a simulated session a loaded host can manufacture. The second is
// stronger and costs a re-run: whether the *same seed*, replanned from
// scratch with the same script and the same schedule, fails again.

// Attaches what the two runs observed about their own timing. This is
// cheap and always available, but it is only half the story: a run can
// diverge on an interleaving without ever touching a clock, and then
// this line correctly reports no wall-clock wait while the failure is
// still not a behaviour difference. `Corroboration` is the half that
// settles it.
fn with_timing(failure: Failure, base: Report, faulted: Report) -> Failure {
  let dangling =
    list.append(dangling("fault-free", base), dangling("faulted", faulted))
  let expiries =
    list.append(
      matching("fault-free", base, "expired@"),
      matching("faulted", faulted, "expired@"),
    )
  let raises =
    list.append(
      matching("fault-free", base, "raised@"),
      matching("faulted", faulted, "raised@"),
    )
  Failure(
    ..failure,
    detail: failure.detail
      <> "\n    "
      <> timing_line(dangling, expiries, raises),
  )
}

fn matching(which: String, report: Report, prefix: String) -> List(String) {
  report.waits
  |> list.filter(string.starts_with(_, prefix))
  |> list.map(fn(wait) { which <> " run: " <> wait })
}

// A scripted intervention the run started and never finished. `surface`
// brackets each admission with `intervening@path` and `intervened@path`,
// so an opening with no closing is an admission that was still in flight
// when the report was read.
fn dangling(which: String, report: Report) -> List(String) {
  let opened = paths_after(report, "intervening@")
  let closed = paths_after(report, "intervened@")
  opened
  |> list.filter(fn(path) { !list.contains(closed, path) })
  |> list.map(fn(path) { which <> " run: intervening@" <> path })
}

fn paths_after(report: Report, prefix: String) -> List(String) {
  report.waits
  |> list.filter(string.starts_with(_, prefix))
  |> list.map(string.drop_start(_, string.length(prefix)))
}

// The verdict on a failing run's own conduct, strongest evidence first.
// Each case names a mechanism the reader can act on rather than a
// suspicion they have to chase.
fn timing_line(
  dangling: List(String),
  expiries: List(String),
  raises: List(String),
) -> String {
  case dangling, expiries, raises {
    // The strongest of the three, and the only one that settles the
    // question outright: the harness took a scripted turn's one-shot
    // claim and then lost the process that was to admit it. The two
    // runs are not comparing the same conversation, and no amount of
    // reading the diff will explain the difference.
    [_, ..], _, _ ->
      "[timing] HARNESS LOST A SCRIPTED TURN: "
      <> string.join(dangling, ", ")
      <> " — a scripted intervention was claimed and never observed to "
      <> "land, because the partial crash reaped the process awaiting it. "
      <> "The faulted run is one scripted turn short of the fault-free one "
      <> "for a reason that has nothing to do with the code under test. "
      <> "This is a known harness limitation, not a finding: see "
      <> "docs/architecture/simulation.md, \"What this does not cover\"."
    // A real millisecond budget ran out. Whatever the check says, this
    // run had a bound in it that is not part of the seed.
    [], [_, ..], _ ->
      "[timing] WALL CLOCK: "
      <> string.join(expiries, ", ")
      <> " — a real millisecond budget expired in this run. Nothing in the "
      <> "simulation controls it (control.attempt, \"Not simulation-safe\"), "
      <> "so this failure may be an artefact of a loaded host rather than "
      <> "of the code under test."
    // Replies that went unobserved because the process carrying them
    // died. Deterministic — a monitor saw it, not a clock — but worth
    // naming, because an unobserved admission is the ambiguity every
    // convergence divergence should be read against: it does not say
    // the commit failed, only that nobody saw it succeed.
    [], [], [_, ..] ->
      "[timing] no wall-clock wait; unobserved replies: "
      <> string.join(raises, ", ")
      <> " (each seen through a process monitor, not a clock, so each "
      <> "happened at the same point in the run on any machine)"
    [], [], [] ->
      "[timing] clean — no wall-clock wait, no unobserved reply, and every "
      <> "scripted intervention landed. Nothing about the harness explains "
      <> "this failure."
  }
}

// How many times a failing seed is replanned and re-run before its
// failure is characterised. Only a failing seed ever pays this, and the
// search stops at the first run that passes, so the common flake costs
// one extra run and a genuinely broken seed costs three.
const corroboration_runs = 3

/// Whether a failed check survived being run again. The runner drives
/// real BEAM processes and does not control how they interleave (see
/// `docs/architecture/simulation.md`, "What this does not cover"), so a
/// verdict that changes between two identical runs of one seed is a
/// statement about the harness, not about the code under it.
pub type Corroboration {
  /// Every run of this seed failed. Timing does not excuse it.
  Reproducible(runs: Int)
  /// A re-run of this seed passed. This particular failure is not
  /// evidence that behaviour changed — though a seed that only *became*
  /// unstable is still a finding, since instability is behaviour too.
  Unstable(failed: Int, of: Int)
}

/// How a corroboration reads in a failure report.
///
/// ## Examples
///
/// ```gleam
/// // runner.describe_corroboration(runner.Reproducible(runs: 4))
/// ```
///
pub fn describe_corroboration(corroboration: Corroboration) -> String {
  case corroboration {
    Reproducible(runs:) ->
      "[verdict] REPRODUCIBLE — this seed was run "
      <> int.to_string(runs)
      <> " times and failed every one. This is a behaviour difference; "
      <> "read the check."
    Unstable(failed:, of:) ->
      "[verdict] NOT REPRODUCIBLE — this seed was run "
      <> int.to_string(of)
      <> " times and failed "
      <> int.to_string(failed)
      <> ". The same script under the same schedule reached different "
      <> "verdicts, so this run is not by itself evidence of a behaviour "
      <> "change: it turns on an interleaving the runner does not control "
      <> "(docs/architecture/simulation.md, \"What this does not cover\"). "
      <> "It does not follow that nothing is wrong — a genuine race in the "
      <> "code under test is unreproducible too. What follows is only that "
      <> "one red run does not distinguish a diff from the commit before "
      <> "it. Compare the failure *rate* over many runs of this seed, and "
      <> "treat a seed that was stable before a change and unstable after "
      <> "it as a finding, because becoming unstable is a behaviour change."
  }
}

// Replans and re-runs the seed until one run passes or the budget is
// spent. Replanning re-derives the same script and the same schedule —
// `plan` draws only from the seed — so nothing here consults the
// generator differently or reshuffles a corpus; the only thing that
// varies between these runs is the machine.
fn corroborate(
  seed: Int,
  remaining: Int,
  failed: Int,
  of: Int,
) -> Corroboration {
  use <- bool.guard(when: remaining <= 0, return: Reproducible(runs: of))
  let #(script, schedule, base) = plan(seed)
  case verify(script, schedule, base) {
    Ok(Nil) -> Unstable(failed:, of: of + 1)
    Error(_failure) -> corroborate(seed, remaining - 1, failed + 1, of + 1)
  }
}

// Builds the verdict for a seed that failed, paying for corroboration
// once and folding it into the detail the existing printers already
// show.
fn failed(
  seed: Int,
  failure: Failure,
  script: Script,
  schedule: Schedule,
  corroboration: Corroboration,
) -> Verdict {
  Failed(
    seed:,
    failure: Failure(
      ..failure,
      detail: failure.detail
        <> "\n    "
        <> describe_corroboration(corroboration),
    ),
    reproduce: reproduce(seed, script, schedule),
    corroboration:,
  )
}

// The checks one run must pass on its own, regardless of the other. Each
// stage either continues or reports the first failing check; the order
// here is the order a violation is diagnosed in.
fn sound(which: String, report: Report) -> Result(Nil, Failure) {
  use _ <- result.try(check_terminated(which, report))
  use _ <- result.try(check_no_violation(which, report))
  use _ <- result.try(check_replay_once(which, report))
  check_terminal_writes_once(which, report)
}

fn check_terminated(which: String, report: Report) -> Result(Nil, Failure) {
  use <- bool.guard(when: !report.stalled, return: Ok(Nil))
  Error(Failure(
    check: "run/terminated",
    detail: which <> " run did not reach a terminal result",
  ))
}

fn check_no_violation(which: String, report: Report) -> Result(Nil, Failure) {
  case report.violations {
    [] -> Ok(Nil)
    [first, ..] ->
      Error(Failure(
        check: "invariant/boundary",
        detail: which <> " run: " <> first,
      ))
  }
}

fn check_replay_once(which: String, report: Report) -> Result(Nil, Failure) {
  case list.find(report.never_calls, fn(pair: #(String, Int)) { pair.1 > 1 }) {
    Error(Nil) -> Ok(Nil)
    Ok(#(call, count)) ->
      Error(Failure(
        check: "replay/never-once",
        detail: which
          <> " run executed "
          <> call
          <> " "
          <> int.to_string(count)
          <> " times",
      ))
  }
}

// A failure here has landed clean of every other explanation this suite
// knows how to give (issue #58: the run touches no wall clock, drops no
// reply, leaves no intervention dangling, and still ends one write
// short). What is known — which strand the shortfall is on, and against
// how many operations the runner believes each strand ran — is reported
// rather than only the pre-summed total, so a future investigation does
// not have to re-instrument from scratch to learn even that much.
fn check_terminal_writes_once(
  which: String,
  report: Report,
) -> Result(Nil, Failure) {
  let total = report.terminal_writes_main + report.terminal_writes_sub
  // Whether the run wrote once per operation is settled by the operations
  // up to `total`: one outcome past that is already a mismatch, and the
  // whole list is walked only to *report* the shortfall, on the path that
  // is about to fail anyway.
  use <- bool.guard(
    when: counts_exactly(report.outcomes, total),
    return: Ok(Nil),
  )
  Error(Failure(
    check: "terminal/last-result-once",
    detail: which
      <> " run wrote strand.last_result "
      <> int.to_string(total)
      <> " times ("
      <> int.to_string(report.terminal_writes_main)
      <> " main, "
      <> int.to_string(report.terminal_writes_sub)
      <> " sub) for "
      <> int.to_string(list.length(report.outcomes))
      <> " operations: "
      <> string.join(report.outcomes, ", "),
  ))
}

/// Whether `items` holds exactly `count` elements, counting down through
/// them rather than measuring them: `list.length` answers a bounded
/// question by walking everything past the bound, which is the shape lint
/// R5 exists to find.
///
/// Public because the boundary is the whole of it — one place either side
/// of `count` is a different answer — and a boundary that cannot be tested
/// on its own gets tested by accident or not at all.
pub fn counts_exactly(items: List(a), count: Int) -> Bool {
  case items, count {
    [], 0 -> True
    [], _ | [_, ..], 0 -> False
    [_, ..rest], _ -> counts_exactly(rest, count - 1)
  }
}

// A commit-indexed crash is drawn inside the fault-free run's commit
// count, so it must fire; a bomb that never went off would make the run
// vacuous. An effect-indexed one is only reachable — a faulted run may
// dispatch fewer effects than the fault-free run did — so it is not
// required to fire.
fn crash_fired(schedule: Schedule, faulted: Report) -> Result(Nil, Failure) {
  let armed =
    list.any(schedule.faults, fn(item) {
      case item {
        // Only a boundary the faulted run actually reached: a run that
        // committed fewer times than the fault-free one never arrived at
        // the armed ordinal, and that is not a missed bomb.
        fault.CrashAtCommit(ordinal:) -> ordinal <= faulted.commits
        _ -> False
      }
    })
  case armed && !faulted.crashed {
    True ->
      Error(Failure(
        check: "run/crash-fired",
        detail: "a scheduled crash never fired, so the run proves nothing",
      ))
    False -> Ok(Nil)
  }
}

fn same_outcomes(base: Report, faulted: Report) -> Result(Nil, Failure) {
  case base.outcomes == faulted.outcomes {
    True -> Ok(Nil)
    False ->
      Error(Failure(
        check: "convergence/outcome",
        detail: "fault-free "
          <> string.join(base.outcomes, ",")
          <> " but faulted "
          <> string.join(faulted.outcomes, ","),
      ))
  }
}

fn same_projection(base: Report, faulted: Report) -> Result(Nil, Failure) {
  case converged(base.projection, faulted.projection) {
    True -> Ok(Nil)
    False ->
      Error(Failure(
        check: "convergence/projection",
        detail: "fault-free ["
          <> string.join(base.projection, " / ")
          <> "] but faulted ["
          <> string.join(faulted.projection, " / ")
          <> "]",
      ))
  }
}

fn same_ledger(base: Report, faulted: Report) -> Result(Nil, Failure) {
  case base.usage_total == faulted.usage_total {
    True -> Ok(Nil)
    False ->
      Error(Failure(
        check: "convergence/ledger",
        detail: "fault-free "
          <> int.to_string(base.usage_total)
          <> " tokens but faulted "
          <> int.to_string(faulted.usage_total),
      ))
  }
}

/// Whether two projections agree, allowing the one divergence a crash
/// may legitimately produce: a `replay: Never` call interrupted in
/// flight comes back as the synthetic interrupted result for the same
/// tool and call id, not as the scripted one.
///
/// ## Examples
///
/// ```gleam
/// // runner.converged(base_lines, crashed_lines)
/// ```
///
pub fn converged(base: List(String), crashed: List(String)) -> Bool {
  case base, crashed {
    [], [] -> True
    [b, ..base_rest], [c, ..crashed_rest] ->
      case b == c || interrupted_variant(b, c) {
        True -> converged(base_rest, crashed_rest)
        False -> False
      }
    _, _ -> False
  }
}

// A subagent forked over shared history repeats the main transcript's
// lines under the `sub|` prefix, so the allowance must recognize the
// interrupted variant there too.
fn interrupted_variant(base: String, crashed: String) -> Bool {
  case string.split(base, ":"), string.split(crashed, ":") {
    ["tool", name_b, id_b, ..], ["tool", name_c, id_c, "err", ..]
    | ["sub|tool", name_b, id_b, ..], ["sub|tool", name_c, id_c, "err", ..]
    -> name_b == name_c && id_b == id_c
    _, _ -> False
  }
}

// --- executing one run ----------------------------------------------------

type Context {
  Context(
    ctl: Control,
    vc: Clockwork,
    raw: Session,
    runtime: api.Runtime,
    script: Script,
    schedule: Schedule,
    /// Committed events from the writer: the runner's evidence that the
    /// session is still working. Silence here is quiescence, and
    /// quiescence is when logical time may move.
    events: process.Subject(writer.Event),
  )
}

/// Runs a script once under a schedule and reports what it converged to.
///
/// ## Examples
///
/// ```gleam
/// // runner.execute(script, fault.none())
/// ```
///
pub fn execute(script: Script, schedule: Schedule) -> Report {
  let vc = vclock.start(from: 1_700_000_000_000)
  let ctl = control.start()
  let assert Ok(raw) = session.open_memory(vclock.clock(vc))
    as "the memory session must open"
  let instrumented =
    store.instrument(raw, ctl, schedule, strand:, lease_interval_ms: 5)
  let surfaces = surface.build(ctl, vc, script, schedule, raw, strand:)
  let events: process.Subject(writer.Event) = process.new_subject()
  let base = api.default_options(configuration())
  // The script's flag *chooses* the mode rather than opting into one:
  // a parallel script runs its tool batches under `Parallel`, so
  // multi-call batches genuinely overlap their effects and the per-call
  // clearance frontier is driven under the fault schedule, and a
  // non-parallel one runs under `Sequential`. Naming both is what keeps
  // the oracle covering two modes now that `Parallel` is the shipped
  // default — inheriting the default here would quietly make every seed
  // a parallel seed.
  let settings = case script.parallel {
    True ->
      operation.RunSettings(..base.settings, tool_execution: operation.Parallel)
    False ->
      operation.RunSettings(
        ..base.settings,
        tool_execution: operation.Sequential,
      )
  }
  let options =
    api.Options(
      ..base,
      strand:,
      settings:,
      // A generous ladder on purpose: an injected fault costs an
      // attempt, and a schedule must not be able to exhaust the ladder
      // and turn a completed run into a failed one by arithmetic.
      retry_policy: operation.NormalizedRetryPolicy(
        max_attempts: 6,
        base_delay_ms: 40,
      ),
      poll_interval_ms: 25,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
      after_commit: fn(_ordinal) { post_commit(ctl, script, schedule) },
      subscribers: [events],
    )
  // Seed the strand first, then arm: seeding commits happen before the
  // writer exists and have no post-commit seam, so a schedule must not
  // be able to name one. `api.open` seeds again and finds nothing to do.
  let assert Ok(Nil) =
    session.ensure_strand(instrumented, strand, configuration())
    as "the strand must seed"
  // The session's canonical id is boot bookkeeping of the same kind and
  // is minted here for the same reason: `api.open` would otherwise commit
  // it as the run's first commit, shifting every scheduled fault ordinal
  // by one. Pre-minting leaves `api.open` with nothing to do.
  let assert Ok(#(_session_id, _generator)) =
    session.ensure_id(
      instrumented,
      ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 4242),
    )
    as "the session id must mint"
  control.arm(ctl)
  let assert Ok(runtime) = api.open(instrumented, surfaces, options)
    as "the session tree must boot"
  control.set_runtime(ctl, runtime)
  // Every commit from here is the writer's, and the writer closes its
  // own seam. Anything the open path committed before the writer existed
  // has no seam to close, so start from closed.
  control.seam_done(ctl)
  let ctx = Context(ctl:, vc:, raw:, runtime:, script:, schedule:, events:)
  let #(outcomes, stalled) = drive_ops(ctx, script.ops, [], False)
  // The multi-strand coda: spawn the scripted subagent (fork-in-place at
  // the main leaf, task brief as its first run), drive it to a terminal
  // result, then deliver a durable cross-strand message back to main and
  // drive the run it starts.
  let #(outcomes, stalled) = case script.subagent, stalled {
    Some(brief), False -> drive_subagent(ctx, brief, outcomes)
    _, _ -> #(outcomes, stalled)
  }
  // Never read the run's story while the writer is still telling it: a
  // seam still running is a scheduled fault that has not had its turn.
  settle_seam(ctl, 200)
  let report =
    Report(
      outcomes: list.reverse(outcomes),
      projection: list.append(fingerprints(raw), sub_fingerprints(raw)),
      usage_total: ledger_total(raw),
      commits: control.commits(ctl),
      never_calls: never_calls(ctl, script),
      violations: list.append(
        control.notes(ctl),
        terminal_violations(raw, stalled),
      ),
      crashed: control.crashed(ctl),
      stalled:,
      terminal_writes_main: control.read(ctl, "last_result:" <> strand),
      terminal_writes_sub: control.read(ctl, "last_result:" <> sub_strand),
      coverage: control.marks(ctl),
      effects: control.read(ctl, "effect"),
      waits: control.waits(ctl),
    )
  process.kill(runtime.tree.supervisor)
  let _closed = session.close(raw)
  vclock.stop(vc)
  control.stop(ctl)
  report
}

// Waits, briefly and boundedly, for the writer's post-commit seam to
// finish. Exhausting the wait is not an error here: a run that stalled
// may have left a writer wedged, and `run/terminated` is the check that
// reports it.
fn settle_seam(ctl: Control, attempts: Int) -> Nil {
  case attempts <= 0 || control.seam_quiet(ctl) {
    True -> Nil
    False -> {
      process.sleep(1)
      settle_seam(ctl, attempts - 1)
    }
  }
}

/// The strand configuration simulated sessions run under.
///
/// ## Examples
///
/// ```gleam
/// // runner.configuration()
/// ```
///
pub fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(
      provider: surface.provider_name,
      model_id: surface.model_id,
    ),
    thinking_level: ThinkingOff,
    active_tool_names: ["read", "write", "probe"],
  )
}

// The writer's post-commit seam: the crash scheduler, the lease thief's
// trigger, and the abort that races the terminal transaction all fire
// from here, after the commit is durable and published but before its
// committer learns of it.
fn post_commit(ctl: Control, script: Script, schedule: Schedule) -> Nil {
  let armed =
    list.any(schedule.faults, fn(item) {
      case item {
        fault.CrashAtCommit(..) -> True
        _ -> False
      }
    })
    || list.any(script.interventions, fn(intervention) {
      script.trigger_of(intervention) == script.AtTerminalCommit
    })
  case armed {
    False -> Nil
    True -> fire_post_commit(ctl, script, schedule)
  }
  // Closed on every path: the runner treats an open seam as a commit
  // whose schedule has not had its turn yet, so a seam that never
  // closed would park the run rather than end it. The one path that
  // does not reach here is the crash itself, which kills this process
  // — and that is recorded separately.
  control.seam_done(ctl)
}

fn fire_post_commit(ctl: Control, script: Script, schedule: Schedule) -> Nil {
  let landed = control.commits(ctl)
  terminal_interventions(ctl, script)
  case
    list.any(schedule.faults, fn(item) {
      case item {
        fault.CrashAtCommit(ordinal:) -> ordinal == landed
        _ -> False
      }
    })
  {
    False -> Nil
    True ->
      case control.claim(ctl, "crash@c" <> int.to_string(landed)) {
        False -> Nil
        True -> {
          control.note_crash(ctl)
          control.mark(ctl, "crash-at-commit")
          process.kill(process.self())
        }
      }
  }
}

// Interventions triggered at the terminal commit fire from here, inside
// the writer process. They must not be waited for: admission calls back
// into this very writer, so awaiting one deadlocks it until the wait
// times out — which is how a crash armed on the terminal commit came to
// lose a race against the runner's own terminal detection.
fn terminal_interventions(ctl: Control, script: Script) -> Nil {
  use <- bool.guard(
    when: control.read(ctl, "terminal_commits") < 1,
    return: Nil,
  )
  list.each(script.interventions, fn(intervention) {
    fire_if_terminal(ctl, intervention)
  })
}

// The claim and the mark are `surface.apply`'s business now, and they
// happen on the disposable process it spawns rather than here. That
// matters most on this path: this runs inside the writer, and a crash
// schedule aimed at this very commit is about to kill it — claiming
// here would risk spending the one-shot on a process that does not live
// long enough to use it.
fn fire_if_terminal(ctl: Control, intervention: script.Intervention) -> Nil {
  use <- bool.guard(
    when: script.trigger_of(intervention) != script.AtTerminalCommit,
    return: Nil,
  )
  surface.apply(ctl, intervention, awaited: False)
}

fn drive_ops(
  ctx: Context,
  ops: List(Op),
  outcomes: List(String),
  stalled: Bool,
) -> #(List(String), Bool) {
  case ops, stalled {
    [], _ | _, True -> #(outcomes, stalled)
    [op, ..rest], False -> {
      let before = latest_result(ctx.raw)
      case admit(ctx, op, before, 5) {
        // Refused is a legitimate answer (a navigation with nowhere to
        // go): nothing opened, so nothing is awaited.
        Refused -> drive_ops(ctx, rest, outcomes, False)
        // It opened, ran, and finished while the runner was still
        // asking whether its acceptance had landed.
        Completed(last) -> drive_ops(ctx, rest, [tag(last), ..outcomes], False)
        Opened(op_id) -> {
          ring(ctx)
          case pump(ctx, op_id, budget) {
            Error(Nil) -> #(outcomes, True)
            Ok(last) -> drive_ops(ctx, rest, [tag(last), ..outcomes], False)
          }
        }
      }
    }
  }
}

// A retry that follows an unobserved reply is a retry into a tree that
// may still be rebooting, and addressing a process that is not yet
// registered raises again — spending an attempt off a finite ladder
// without learning anything. So the runner lets the world move first:
// one logical step, which releases anything parked on a deadline, and
// one real millisecond, which is the supervisor's chance to put the tree
// back.
//
// That millisecond is a wall clock and is named as one. It replaces a
// far larger one: `attempt` used to learn about a dead carrier only by
// letting a three-second budget expire, which gave the tree all the time
// in the world by accident. Learning it from a monitor instead is what
// makes the ladder's pacing something the runner has to state on purpose
// rather than inherit from a timeout.
fn before_retrying(ctx: Context) -> Nil {
  let _advanced = vclock.advance(ctx.vc)
  process.sleep(1)
}

// What became of an acceptance attempt.
type Admission {
  Opened(OpId)
  Completed(LastResult)
  Refused
}

// --- the subagent coda ----------------------------------------------------

/// The configuration a scripted subagent strand runs under: its own
/// model identity, so the surface answers it by identity rather than by
/// the main script's turns.
pub fn sub_configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(
      provider: surface.provider_name,
      model_id: surface.sub_model_id,
    ),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}

// Spawns the scripted subagent, drives its brief run to a terminal
// result, then delivers a durable cross-strand message back to the main
// strand and drives the run it starts. Faults land here exactly as on
// the main ops: a crash reboots the tree (the strand booter must restore
// both strands), a refused commit retries after the durable state is
// re-checked.
fn drive_subagent(
  ctx: Context,
  brief: String,
  outcomes: List(String),
) -> #(List(String), Bool) {
  control.mark(ctx.ctl, "subagent-spawn")
  case spawn_child(ctx, brief, 6) {
    Refused -> #(outcomes, True)
    Completed(last) -> cross_message(ctx, [tag(last), ..outcomes])
    Opened(op_id) ->
      case pump_strand(ctx, sub_strand, op_id, budget) {
        Error(Nil) -> #(outcomes, True)
        Ok(last) -> cross_message(ctx, [tag(last), ..outcomes])
      }
  }
}

// Creating the child under faults mirrors `admit`: an attempt may lose
// its commit reply while the commit landed, so every retry first asks
// the durable state what actually happened.
fn spawn_child(ctx: Context, brief: String, attempts: Int) -> Admission {
  case session.strand_state(ctx.raw, sub_strand) {
    // Seeded already (or partially created): the durable state decides.
    Ok(Some(_)) ->
      case
        open_operation_on(ctx.raw, sub_strand),
        latest_result_on(ctx.raw, sub_strand)
      {
        Some(open), _ -> Opened(open)
        None, Some(last) -> Completed(last)
        None, None -> accept_child_brief(ctx, brief, attempts)
      }
    _ -> attempt_create_child(ctx, brief, attempts)
  }
}

fn attempt_create_child(
  ctx: Context,
  brief: String,
  attempts: Int,
) -> Admission {
  use <- bool.guard(when: attempts <= 0, return: Refused)
  case
    control.attempt(
      ctx.ctl,
      at: "create-strand",
      action: fn() { create_child(ctx, brief) },
      within_ms: 3000,
    )
  {
    control.Answered(Ok(op_id)) -> Opened(op_id)
    // A refusal, a raise, and an expiry are one case here on purpose:
    // only the first says the create failed, and the other two say
    // nothing at all — so all three go back to `spawn_child`, which asks
    // the durable state what actually happened before trying again.
    control.Answered(Error(_)) | control.Raised | control.Expired -> {
      before_retrying(ctx)
      spawn_child(ctx, brief, attempts - 1)
    }
  }
}

fn create_child(ctx: Context, brief: String) -> Result(OpId, Nil) {
  let fork = case session.strand_leaf(ctx.raw, strand) {
    Ok(Some(cell)) -> cell.value
    _ -> None
  }
  case
    api.create_strand(
      ctx.runtime,
      named: sub_strand,
      configuration: sub_configuration(),
      at: fork,
      brief: [surface.user(brief)],
    )
  {
    Ok(op_id) -> Ok(op_id)
    Error(_) -> Error(Nil)
  }
}

// The strand exists but its brief run never opened (the seed committed,
// the acceptance was lost to a fault): accept it directly.
fn accept_child_brief(ctx: Context, brief: String, attempts: Int) -> Admission {
  use <- bool.guard(when: attempts <= 0, return: Refused)
  let child = api.on_strand(ctx.runtime, sub_strand)
  let accepted =
    control.attempt(
      ctx.ctl,
      at: "accept-brief",
      action: fn() { api.accept_quietly(child, [surface.user(brief)]) },
      within_ms: 3000,
    )
  case accepted {
    control.Answered(Ok(op_id)) -> {
      control.detached(fn() { api.nudge(child) })
      Opened(op_id)
    }
    control.Answered(Error(_)) | control.Raised | control.Expired -> {
      before_retrying(ctx)
      spawn_child(ctx, brief, attempts - 1)
    }
  }
}

// The child's completion travels back as a durable message: the main
// strand is idle after its scripted ops, so the send accepts a fresh
// run there (design §4.6 request/reply, closed the durable way).
fn cross_message(
  ctx: Context,
  outcomes: List(String),
) -> #(List(String), Bool) {
  control.mark(ctx.ctl, "cross-strand-message")
  case deliver_cross(ctx, latest_result(ctx.raw), 6) {
    Refused -> #(outcomes, True)
    Completed(last) -> #([tag(last), ..outcomes], False)
    Opened(op_id) ->
      case pump_strand(ctx, strand, op_id, budget) {
        Error(Nil) -> #(outcomes, True)
        Ok(last) -> #([tag(last), ..outcomes], False)
      }
  }
}

fn deliver_cross(
  ctx: Context,
  before: Option(LastResult),
  attempts: Int,
) -> Admission {
  use <- bool.guard(when: attempts <= 0, return: Refused)
  let sent =
    control.attempt(
      ctx.ctl,
      at: "deliver-cross",
      action: fn() {
        api.send_to_strand(
          ctx.runtime,
          to: strand,
          message: surface.user(surface.cross_report),
        )
      },
      within_ms: 3000,
    )
  case sent {
    control.Answered(Ok(api.Started(operation:))) -> Opened(operation)
    // The main strand is idle after its ops, so a steer means a
    // racing run this runner did not open; treat like a lost reply.
    control.Answered(Ok(api.Steered(..)))
    | control.Answered(Error(_))
    | control.Raised
    | control.Expired ->
      case open_operation(ctx.raw), latest_result(ctx.raw) {
        Some(open), _ -> Opened(open)
        None, after if after != before ->
          case after {
            Some(last) -> Completed(last)
            None -> Refused
          }
        None, _ -> {
          before_retrying(ctx)
          deliver_cross(ctx, before, attempts - 1)
        }
      }
  }
}

// Acceptance under faults: the commit may be refused as stale, or its
// writer may die mid-call with the commit already durable. Retrying is
// what the api's own admission path does — but a retry must first ask
// the strand whether the previous attempt actually opened (or even
// finished) an operation, or the runner would start a second one.
fn admit(
  ctx: Context,
  op: Op,
  before: Option(LastResult),
  attempts: Int,
) -> Admission {
  case
    control.attempt(
      ctx.ctl,
      at: "admit",
      action: fn() { accept(ctx, op) },
      within_ms: 3000,
    )
  {
    control.Answered(Ok(op_id)) -> Opened(op_id)
    // An unobserved reply is not a failed admission: the commit may be
    // durable already, with only the answer lost. So every non-answer
    // goes the same way — read the strand's durable state, and only
    // retry when it shows nothing happened.
    control.Answered(Error(_)) | control.Raised | control.Expired ->
      case open_operation(ctx.raw), latest_result(ctx.raw) {
        Some(open), _ -> Opened(open)
        None, after if after != before ->
          case after {
            Some(last) -> Completed(last)
            None -> Refused
          }
        None, _ ->
          case attempts <= 1 {
            True -> Refused
            False -> {
              before_retrying(ctx)
              admit(ctx, op, before, attempts - 1)
            }
          }
      }
  }
}

// The strand's most recent terminal result, whatever operation it names.
fn latest_result(raw: Session) -> Option(LastResult) {
  latest_result_on(raw, strand)
}

fn latest_result_on(raw: Session, strand_name: String) -> Option(LastResult) {
  case session.last_result(raw, strand_name) {
    Ok(Some(cell)) -> Some(cell.value)
    _ -> None
  }
}

// The operation the strand currently has open, if any.
fn open_operation(raw: Session) -> Option(OpId) {
  open_operation_on(raw, strand)
}

fn open_operation_on(raw: Session, strand_name: String) -> Option(OpId) {
  case session.strand_state(raw, strand_name) {
    Ok(Some(cell)) -> cell.value.current_operation
    _ -> None
  }
}

fn accept(ctx: Context, op: Op) -> Result(OpId, String) {
  case op {
    script.RunOp(prompt:, ..) ->
      case api.accept_quietly(ctx.runtime, [surface.user(prompt)]) {
        Ok(id) -> Ok(id)
        Error(_) -> Error("run acceptance refused")
      }
    script.CompactOp -> {
      control.mark(ctx.ctl, "standalone-compaction")
      accept_directly(
        ctx,
        acceptance.AcceptCompaction(
          custom_instructions: None,
          preparation: surface.compaction_preparation(surface.projection(
            ctx.raw,
            strand,
          )),
        ),
      )
    }
    script.NavigateOp(summarize:) -> {
      control.mark(ctx.ctl, case summarize {
        True -> "navigation-summarized"
        False -> "navigation-unsummarized"
      })
      case oldest_entry(ctx.raw) {
        None -> Error("no navigation target")
        Some(target) ->
          accept_directly(
            ctx,
            acceptance.AcceptNavigation(
              target: Some(target),
              summarize:,
              label: None,
              custom_instructions: None,
              preparation: case summarize {
                False -> None
                True ->
                  surface.branch_summary(surface.projection(ctx.raw, strand))
              },
              target_known: True,
            ),
          )
      }
    }
  }
}

// Compaction and navigation have no api entry point yet, so the runner
// builds their acceptance the way `runtime/api` builds a run's and
// commits it through the same writer. Nothing is bypassed: the plan
// comes from `machine/acceptance` and the commit from the session's one
// committer.
fn accept_directly(
  ctx: Context,
  request: acceptance.AcceptRequest,
) -> Result(OpId, String) {
  case
    session.strand_state(ctx.raw, strand),
    session.strand_leaf(ctx.raw, strand)
  {
    Ok(Some(state_cell)), Ok(leaf_cell) -> {
      let now = vclock.now(ctx.vc)
      let leaf = option.then(leaf_cell, fn(cell) { cell.value })
      let leaf_seq = option.map(leaf_cell, fn(cell) { cell.seq })
      let plan =
        acceptance.accept_prompt(
          request,
          acceptance.AcceptCtx(
            strand:,
            now:,
            generator: ids.generator(
              clock.fixed(at: now),
              seed: ctx.runtime.effects.entropy(),
            ),
            strand_state: state_cell.value,
            strand_state_seq: state_cell.seq,
            leaf:,
            leaf_seq:,
            settings: ctx.runtime.settings,
            pending: dict.new(),
          ),
        )
      case plan {
        Error(_reason) -> Error("acceptance refused")
        Ok(acceptance.AcceptancePlan(operation:, tx: plan_tx, ..)) ->
          case
            writer.commit(
              process.named_subject(ctx.runtime.tree.writer),
              plan_tx,
            )
          {
            Ok(_) -> Ok(operation.id)
            Error(_) -> Error("acceptance commit refused")
          }
      }
    }
    _, _ -> Error("the strand registers are unreadable")
  }
}

fn oldest_entry(raw: Session) -> Option(ids.EntryId) {
  use cell <- option.then(result.unwrap(session.strand_leaf(raw, strand), None))
  use leaf <- option.then(cell.value)
  use entries <- option.then(
    option.from_result(storage.scan_branch(
      raw.store,
      storage.branch_scan(from: leaf),
    )),
  )
  case list.reverse(entries) {
    // A single-entry (or empty) branch has nowhere to navigate to.
    [] | [_] -> None
    [oldest, ..] -> Some(entry_id(oldest))
  }
}

fn entry_id(row: Entry) -> ids.EntryId {
  case row {
    entry.MessageEntry(id:, ..)
    | entry.CompactionEntry(id:, ..)
    | entry.BranchSummaryEntry(id:, ..)
    | entry.CustomEntry(id:, ..) -> id
  }
}

// Ring the doorbell, subject to the message faults: a dropped doorbell
// must cost latency alone, and a late one must not reorder anything that
// matters.
fn ring(ctx: Context) -> Nil {
  let index = control.bump(ctx.ctl, "doorbell")
  let dropped =
    list.any(ctx.schedule.faults, fn(item) {
      case item {
        fault.DropDoorbell(index: at) -> at == index
        _ -> False
      }
    })
  let delay =
    list.fold(ctx.schedule.faults, None, fn(found, item) {
      case found, item {
        None, fault.DelayDoorbell(index: at, delay_ms:) if at == index ->
          Some(delay_ms)
        _, _ -> found
      }
    })
  let runtime = ctx.runtime
  case dropped, delay {
    True, _ -> Nil
    False, Some(delay_ms) ->
      vclock.schedule(ctx.vc, delay_ms, fn() {
        control.detached(fn() { api.nudge(runtime) })
      })
    False, None -> control.detached(fn() { api.nudge(runtime) })
  }
}

// The drive loop: watch the session's event counter, and when it stops
// moving advance logical time to the next deadline rather than sleeping
// for it.
fn pump(ctx: Context, op_id: OpId, remaining: Int) -> Result(LastResult, Nil) {
  pump_strand(ctx, strand, op_id, remaining)
}

// A scripted intervention's decision belongs here, not to whichever
// effect happened to reach its trigger (issue #57). `surface.intervene`
// registers the trigger and blocks; this drains that queue on every pass
// through the drive loop and fires each one through `surface.fire_due`,
// which is what actually admits it. The runner's own process is never a
// target of any fault in the taxonomy, so a `RestartStrand` that reaps
// the effect waiting on the release cannot also take the admission with
// it — the admission already ran, on a carrier this call owns, before
// that effect is ever resumed.
fn service_interventions(ctx: Context) -> Nil {
  case control.take_pending_interventions(ctx.ctl) {
    [] -> Nil
    due ->
      list.each(due, fn(waiting) {
        let #(trigger, reply) = waiting
        surface.fire_due(ctx.ctl, ctx.script, trigger)
        process.send(reply, Nil)
      })
  }
}

fn pump_strand(
  ctx: Context,
  strand_name: String,
  op_id: OpId,
  remaining: Int,
) -> Result(LastResult, Nil) {
  use <- bool.guard(when: remaining <= 0, return: Error(Nil))
  service_interventions(ctx)
  case terminal_on(ctx.raw, strand_name, op_id) {
    // A terminal result is visible before the writer has run the
    // post-commit seam for the transaction that wrote it, so taking
    // it here would end the run while a fault aimed at that commit
    // was still queued. Wait for the seam to close.
    //
    // A scripted intervention looks like the same race one layer out —
    // it is claimed before it is admitted, and a partial crash can reap
    // the process awaiting it — but it is deliberately *not* waited for
    // here. Waiting was tried: a reaped effect process leaves nobody to
    // enforce the carrier's own budget either, so a carrier that is
    // stuck rather than merely slow never settles, and the gate turns a
    // divergence that names its own cause into a run that never
    // terminates. The debt is recorded and reported instead — issue #44,
    // and "What this does not cover" in docs/architecture/simulation.md.
    Some(last) ->
      case control.seam_quiet(ctx.ctl) {
        True -> {
          note_missing_op_result(ctx.ctl, ctx.raw, strand_name, op_id)
          Ok(last)
        }
        False -> {
          process.sleep(1)
          pump_strand(ctx, strand_name, op_id, remaining - 1)
        }
      }
    None ->
      case process.receive(ctx.events, 1) {
        // A commit landed: the session is working, so leave time
        // alone and look again.
        Ok(_committed) -> pump_strand(ctx, strand_name, op_id, remaining - 1)
        // Nothing committed: either the session is waiting for a
        // deadline, or it is inside an effect. Advancing logical
        // time releases the first and costs the second one wasted
        // planning pass.
        Error(Nil) -> {
          let _advanced = vclock.advance(ctx.vc)
          pump_strand(ctx, strand_name, op_id, remaining - 1)
        }
      }
  }
}

// The terminal transaction writes the result twice, atomically: the
// strand's latest-wins register and the operation-keyed record awaiting
// keys on. A terminal reachable only through the strand register means
// the operation-keyed half is missing — the ABA hole where a child's
// second run makes the first result unobservable.
fn note_missing_op_result(
  ctl: Control,
  raw: Session,
  strand_name: String,
  op_id: OpId,
) -> Nil {
  case op_result_on(raw, op_id) {
    Some(_) -> Nil
    None ->
      control.note(
        ctl,
        "terminal/op-result: "
          <> strand_name
          <> " finished an operation without its "
          <> "operation-keyed result record",
      )
  }
}

// The operation's terminal result, preferring the operation-keyed
// record (the register `api.await_strand_result` keys on, immune to a
// later run's overwrite) and falling back to the strand's latest-wins
// register.
fn terminal_on(
  raw: Session,
  strand_name: String,
  op_id: OpId,
) -> Option(LastResult) {
  case op_result_on(raw, op_id) {
    Some(last) -> Some(last)
    None ->
      case session.last_result(raw, strand_name) {
        Ok(Some(cell)) ->
          case result_operation(cell.value) == op_id {
            True -> Some(cell.value)
            False -> None
          }
        _ -> None
      }
  }
}

// The durable `operation-result/{op}` record, read straight from the
// store. Unreadable or undecodable reads as absent: the pump keeps
// polling, and the terminal check above reports the record's absence.
fn op_result_on(raw: Session, op_id: OpId) -> Option(LastResult) {
  case
    storage.get_register(
      raw.store,
      register.FactCustom,
      operation.result_fact_key(op_id),
    )
  {
    Ok(Some(cell)) ->
      case codec.decode_last_result(cell.value.payload) {
        Ok(last) -> Some(last)
        Error(_report) -> None
      }
    _ -> None
  }
}

fn result_operation(last: LastResult) -> OpId {
  case last {
    operation.RunLastResult(operation:, ..)
    | operation.CompactionLastResult(operation:, ..)
    | operation.NavigationLastResult(operation:, ..) -> operation
  }
}

/// The outcome tag recorded for one terminal result.
///
/// ## Examples
///
/// ```gleam
/// // runner.tag(last_result) == "run/completed"
/// ```
///
pub fn tag(last: LastResult) -> String {
  case last {
    operation.RunLastResult(outcome: operation.RunCompleted(..), ..) ->
      "run/completed"
    operation.RunLastResult(outcome: operation.RunFailed(..), ..) ->
      "run/failed"
    operation.RunLastResult(outcome: operation.RunAborted, ..) -> "run/aborted"
    operation.CompactionLastResult(outcome:, ..) ->
      "compaction/" <> structural_tag(outcome)
    operation.NavigationLastResult(outcome:, ..) ->
      "navigation/" <> structural_tag(outcome)
  }
}

fn structural_tag(outcome: operation.StructuralOutcome) -> String {
  case outcome {
    operation.StructuralCompleted -> "completed"
    operation.StructuralDeclined -> "declined"
    operation.StructuralFailed(..) -> "failed"
    operation.StructuralAborted -> "aborted"
  }
}

// --- reporting ------------------------------------------------------------

fn terminal_violations(raw: Session, stalled: Bool) -> List(String) {
  case stalled {
    // A stalled run has not reached a terminal boundary, so the terminal
    // invariants do not apply to it; `run/terminated` reports it.
    True -> []
    False -> {
      let sub_checks = case session.strand_state(raw, sub_strand) {
        Ok(Some(_)) -> [
          invariant.terminal_registers(raw.store, strand: sub_strand),
        ]
        _ -> []
      }
      [
        invariant.terminal_registers(raw.store, strand:),
        invariant.calls_answered(raw.store),
        ..sub_checks
      ]
      |> list.filter_map(fn(outcome) {
        case outcome {
          Ok(Nil) -> Error(Nil)
          Error(violation) -> Ok(invariant.describe(violation))
        }
      })
    }
  }
}

fn never_calls(ctl: Control, script: Script) -> List(#(String, Int)) {
  script.ops
  |> list.flat_map(fn(op) {
    case op {
      script.RunOp(settles:, ..) -> settles
      _ -> []
    }
  })
  |> list.flat_map(fn(settle) {
    case settle {
      script.Calls(calls:, ..) -> calls
      _ -> []
    }
  })
  |> list.filter(fn(call: script.Call) {
    list.key_find(script.registry, call.tool) == Ok(ReplayNever)
  })
  |> list.map(fn(call: script.Call) {
    let key = "tool:" <> call.tool <> ":" <> call.id
    #(key, control.read(ctl, key))
  })
}

fn ledger_total(raw: Session) -> Int {
  case storage.scan_usage(raw.store, storage.usage_scan()) {
    Ok(rows) ->
      list.fold(rows, 0, fn(total, row) { total + row.usage.total_tokens })
    Error(_) -> -1
  }
}

fn fingerprints(raw: Session) -> List(String) {
  case session.strand_leaf(raw, strand) {
    Ok(Some(cell)) ->
      case session.project_context(raw, cell.value) {
        Ok(messages) -> list.map(messages, fingerprint)
        Error(_) -> ["<unprojectable>"]
      }
    _ -> ["<no leaf>"]
  }
}

// The subagent strand's final projection, prefixed so its lines never
// collide with the main strand's; empty when the script had no
// subagent (or it never got created).
fn sub_fingerprints(raw: Session) -> List(String) {
  case session.strand_leaf(raw, sub_strand) {
    Ok(Some(cell)) ->
      case session.project_context(raw, cell.value) {
        Ok(messages) ->
          list.map(messages, fn(message) { "sub|" <> fingerprint(message) })
        Error(_) -> ["sub|<unprojectable>"]
      }
    _ -> []
  }
}

/// One message's structural fingerprint: role, text, call ids, and stop
/// kind, never minted ids or timestamps, which legitimately differ
/// between two runs of the same script.
///
/// ## Examples
///
/// ```gleam
/// // runner.fingerprint(message)
/// ```
///
pub fn fingerprint(message: AgentMessage) -> String {
  case message {
    UserMessage(content:, ..) ->
      "user:"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            UserText(text:, ..) -> text
            UserImage(..) -> "<image>"
          }
        }),
        "|",
      )
    AssistantMessage(content:, stop_reason:, ..) ->
      "assistant:"
      <> stop_tag(stop_reason)
      <> ":"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            AssistantText(text:, ..) -> text
            AssistantThinking(..) -> "<thinking>"
            AssistantToolCall(call:) -> "call(" <> call.id <> ")" <> call.name
          }
        }),
        "|",
      )
    ToolResultMessage(tool_name:, tool_call_id:, content:, is_error:, ..) ->
      "tool:"
      <> tool_name
      <> ":"
      <> tool_call_id
      <> ":"
      <> case is_error {
        True -> "err"
        False -> "ok"
      }
      <> ":"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            ToolResultText(text:, ..) -> text
            ToolResultImage(..) -> "<image>"
          }
        }),
        "|",
      )
    CustomMessage(schema:, ..) -> "custom:" <> schema
  }
}

fn stop_tag(stop: message.StopReason) -> String {
  case stop {
    message.Pending -> "pending"
    message.Stop -> "stop"
    message.Length -> "length"
    message.ToolUse -> "tool_use"
    message.Errored -> "error"
    message.Aborted -> "aborted"
    message.Deferred -> "deferred"
  }
}
