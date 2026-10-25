//// The arithmetic that makes a search safe to run unattended: what a step
//// could cost at worst, what must be held back from each stage so the
//// confirm run is always still payable, and when the search must stop.
////
//// Every number here is in the host's own unit — dollars, tokens, seconds,
//// whatever the host meters — and the library never converts. What it
//// promises is an ordering: money is held back, not merely checked. A
//// stage is handed a cap of `remaining - held_back(stage)`, where the hold
//// is the confirm run's worst case plus the worst case of every stage still
//// to come in the step, each cell priced at its retried worst. A stage
//// whose evaluations retry is therefore truncated by its own cap before it
//// can spend what a later stage, or the confirm run, was reserved. The
//// confirm run is the one simultaneous comparison the search ends with,
//// and a search that could spend its reservation would end on evidence it
//// could no longer afford to check.
////
//// A step may ask the reflector for several children (`Design.proposals`),
//// each reflected on and each run on the parent's minibatch before one of
//// them is paid a validate run, so a step's worst case is the parent's
//// minibatch, that many reflections and child minibatches, one validate
//// run and the confirm. The holds follow the same shape: before proposal
//// `i` the rest of the proposals and every child minibatch are still to
//// come, before a child's minibatch only the minibatches after it and the
//// validate run are.
////
//// A step is taken only when `remaining >= step_worst_case + confirm`, and
//// the counted ceilings (steps, reflections, candidates) are read before
//// the arithmetic, so a search with no money for a step stops for the
//// budget rather than quietly taking a cheaper one. The reflection and
//// candidate ceilings are read against the whole of the next step, so a
//// step of several proposals is not begun when only some of them fit.

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

/// What the host's evaluations and reflections cost at worst.
pub type Costs {
  Costs(
    /// The worst case of one trial of one task, in the host's unit.
    trial: Float,
    /// How many attempts the host may make at one cell before it gives
    /// up, every attempt charged; one when the host never retries.
    attempts: Int,
    /// The worst case of one reflection call; zero when the reflector is
    /// not metered.
    reflection: Float,
  )
}

/// The shape of the search's evaluations: how many tasks and trials each
/// stage runs.
pub type Design {
  Design(
    /// Tasks in the validate split.
    validate_tasks: Int,
    /// Tasks in a minibatch, after clamping to the tune split.
    minibatch_tasks: Int,
    /// Trials per cell on validate, the K of the design.
    trials: Int,
    /// Trials per cell on a minibatch.
    tune_trials: Int,
    /// Children a step asks the reflector for, each reflected on and
    /// screened before one is validated; one is the plain search.
    proposals: Int,
  )
}

/// The search's ceilings.
pub type Limits {
  Limits(
    /// What the whole search may spend, in the host's unit.
    budget: Float,
    /// Steps the search may take.
    max_steps: Int,
    /// Reflections the search may make.
    max_reflections: Int,
    /// Children the search may mint.
    max_candidates: Int,
  )
}

/// What the search has done so far, read against `Limits`.
pub type Counts {
  Counts(
    /// Steps opened.
    steps: Int,
    /// Reflections made, lost answers included.
    reflections: Int,
    /// Children minted.
    candidates: Int,
  )
}

/// Why a search stopped.
pub type StopReason {
  /// `max_steps` steps were taken.
  Steps

  /// The next step's worst case did not fit what remained.
  Budget

  /// `max_reflections` reflections were made.
  Reflections

  /// `max_candidates` children were minted.
  Candidates
}

/// Where in a step a stage is about to start, which decides how much of
/// the search's remaining budget is held back from it.
pub type Stage {
  /// The parent's minibatch: every reflection, every child's minibatch
  /// and the validate run are still to come.
  BeforeParentMinibatch

  /// Reflection `proposal` (counting from one): the reflections from it
  /// on, every child's minibatch and the validate run are still to come.
  BeforeReflection(proposal: Int)

  /// A child's minibatch, with `later` children's minibatches still to
  /// run after it, and then the validate run.
  BeforeChildMinibatch(later: Int)

  /// The child's validate run: only the confirm run is still to come.
  BeforeValidate
}

/// The worst case of one cell: the trial's worst case times the attempts
/// the host may make at it, since a faulting cell is retried and every
/// attempt is charged.
///
/// ## Examples
///
/// ```gleam
/// assert budget.cell_worst_case(budget.Costs(0.5, 3, 0.0)) == 1.5
/// ```
///
pub fn cell_worst_case(costs: Costs) -> Float {
  costs.trial *. int.to_float(int.max(costs.attempts, 1))
}

/// The worst case of the confirm run: seed and best on every validate
/// cell.
///
/// ## Examples
///
/// ```gleam
/// // two arms, ten tasks, three trials, one unit a cell
/// assert budget.confirm_worst_case(costs, design) == 60.0
/// ```
///
pub fn confirm_worst_case(costs: Costs, design: Design) -> Float {
  cell_worst_case(costs)
  *. int.to_float(2 * design.validate_tasks * design.trials)
}

/// The budget a stage started at `stage` may not touch: the confirm run's
/// worst case and the worst case of the stages still to come in its step,
/// every cell at its retried worst. The stage's cap is what remains less
/// this, so a step whose cells retry cannot spend the confirm's
/// reservation. Before reflection `i` of `n` the hold counts the `n - i +
/// 1` reflections still to make and all `n` child minibatches, since
/// which proposals will mint is not yet known; before a child's minibatch
/// it counts only the `later` minibatches after it, which is known.
///
/// ## Examples
///
/// ```gleam
/// // The hold only ever shrinks as the step advances.
/// assert budget.held_back(costs, design, budget.BeforeValidate)
///   == budget.confirm_worst_case(costs, design)
/// ```
///
pub fn held_back(costs: Costs, design: Design, stage: Stage) -> Float {
  let per_cell = cell_worst_case(costs)
  let minibatch =
    int.to_float(design.minibatch_tasks * design.tune_trials) *. per_cell
  let validate = int.to_float(design.validate_tasks * design.trials) *. per_cell
  let proposals = int.max(design.proposals, 1)

  // Each stage holds back what follows it. The parent minibatch's hold and
  // the first reflection's are the same sum in the same order, so the two
  // are equal to the bit and nothing is owed between them.
  let later = case stage {
    BeforeParentMinibatch ->
      int.to_float(proposals)
      *. costs.reflection
      +. int.to_float(proposals)
      *. minibatch
      +. validate
    BeforeReflection(proposal:) ->
      int.to_float(int.clamp(proposals - proposal + 1, 1, proposals))
      *. costs.reflection
      +. int.to_float(proposals)
      *. minibatch
      +. validate
    BeforeChildMinibatch(later:) ->
      int.to_float(int.max(later, 0)) *. minibatch +. validate
    BeforeValidate -> 0.0
  }

  confirm_worst_case(costs, design) +. later
}

/// The worst case of one whole step: the parent's minibatch, then a
/// reflection and a child's minibatch per proposal, then one validate
/// run. The confirm run is not included; `stop_reason` adds it.
///
/// ## Examples
///
/// ```gleam
/// // b * k_tune * cell + n * (reflection + b * k_tune * cell) + |V| * k * cell
/// assert budget.step_worst_case(costs, design) >=. 0.0
/// ```
///
pub fn step_worst_case(costs: Costs, design: Design) -> Float {
  let per_cell = cell_worst_case(costs)
  let parent_minibatch =
    int.to_float(design.minibatch_tasks * design.tune_trials) *. per_cell

  held_back(costs, design, BeforeParentMinibatch)
  -. confirm_worst_case(costs, design)
  +. parent_minibatch
}

/// The cap a stage is handed: what remains less the hold, never negative.
///
/// ## Examples
///
/// ```gleam
/// assert budget.cap(remaining: 10.0, hold: 12.0) == 0.0
/// assert budget.cap(remaining: 10.0, hold: 4.0) == 6.0
/// ```
///
pub fn cap(remaining remaining: Float, hold hold: Float) -> Float {
  float.max(remaining -. hold, 0.0)
}

/// What the search has left: the budget less what was spent, never
/// negative.
///
/// ## Examples
///
/// ```gleam
/// assert budget.remaining(limits, spent: 4.0) == limits.budget -. 4.0
/// ```
///
pub fn remaining(limits: Limits, spent spent: Float) -> Float {
  float.max(limits.budget -. spent, 0.0)
}

/// Why the search should stop now, if it should: the counted ceilings
/// first, each read against the whole of the next step (a step of `n`
/// proposals makes `n` reflections and may mint `n` children, and is not
/// begun when only some of them fit), then whether the next step's worst
/// case and the confirm run together fit what remains, compared without
/// tolerance.
///
/// ## Examples
///
/// ```gleam
/// // A search at its step ceiling stops for steps before any arithmetic.
/// assert budget.stop_reason(limits, counts_at_ceiling, 1000.0, costs, design)
///   == Some(budget.Steps)
/// ```
///
pub fn stop_reason(
  limits: Limits,
  counts: Counts,
  remaining: Float,
  costs: Costs,
  design: Design,
) -> Option(StopReason) {
  let proposals = int.max(design.proposals, 1)

  // The counted ceilings need no arithmetic; the budget does.
  case
    counts.steps >= limits.max_steps,
    counts.reflections + proposals > limits.max_reflections,
    counts.candidates + proposals > limits.max_candidates
  {
    True, _, _ -> Some(Steps)
    False, True, _ -> Some(Reflections)
    False, False, True -> Some(Candidates)
    False, False, False -> {
      let need =
        step_worst_case(costs, design) +. confirm_worst_case(costs, design)

      // The step is taken only when the confirm run still fits after it,
      // and strictly: nothing has been reserved yet that rounding could
      // owe the search.
      case remaining >=. need {
        False -> Some(Budget)
        True -> None
      }
    }
  }
}

/// One part in a billion, relative: what remains is a sum of the host's
/// own charges, and a sum of floats that should come to exactly the
/// reservation can land a few ulps under it. The tolerance is allowed in
/// exactly two places, the two questions about a reservation the
/// arithmetic already made: whether the confirm run, held back since the
/// seed's run, is still covered, and whether a reflection, whose hold
/// every earlier stage respected, is. Step admission is strict: a step
/// is a choice to spend, not a reservation to honour, and a hair short
/// means the search does not start it.
const rounding = 1.0e-9

/// Whether `remaining` covers `need`, allowing the rounding of a sum.
///
/// ## Examples
///
/// ```gleam
/// assert budget.covers(remaining: 3.5999999999999996, need: 3.6)
/// assert !budget.covers(remaining: 3.59, need: 3.6)
/// ```
///
pub fn covers(remaining remaining: Float, need need: Float) -> Bool {
  remaining +. rounding *. float.max(1.0, need) >=. need
}

/// Whether reflection `proposal` may be made: what remains must cover it,
/// the proposals after it, every child's minibatch and the validate run,
/// the confirm run included, which is the hold the stage before it was
/// given less what that stage could spend. Under the caps each reflection
/// of a step passes in turn, since no earlier stage could spend into its
/// hold; the check bites a host that overspent its cap, and a resumed step
/// that lost its answer and reflects again, whose first call already
/// spent from the hold. A reflection is a live call the search cannot
/// truncate once made, so one that would leave the confirm run unpayable
/// is refused instead.
///
/// ## Examples
///
/// ```gleam
/// // One reflection at 2.0 and nothing else to run: 1.9 does not cover it.
/// assert !budget.reflection_affordable(remaining: 1.9, costs: Costs(0.0, 1, 2.0), design:, proposal: 1)
/// ```
///
pub fn reflection_affordable(
  remaining remaining: Float,
  costs costs: Costs,
  design design: Design,
  proposal proposal: Int,
) -> Bool {
  covers(remaining:, need: held_back(costs, design, BeforeReflection(proposal)))
}

/// Whether the confirm run is still covered when the search is ready to
/// end. A confirm run the budget no longer covers is skipped, never
/// started and truncated: a truncated comparison would be evidence of
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert budget.confirm_affordable(remaining: 0.0, costs:, design:) == False
/// ```
///
pub fn confirm_affordable(
  remaining remaining: Float,
  costs costs: Costs,
  design design: Design,
) -> Bool {
  covers(remaining:, need: confirm_worst_case(costs, design))
}

/// The spelling of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// assert budget.stop_name(budget.Budget) == "budget"
/// ```
///
pub fn stop_name(reason: StopReason) -> String {
  case reason {
    Steps -> "steps"
    Budget -> "budget"
    Reflections -> "reflections"
    Candidates -> "candidates"
  }
}

/// Parses a stop reason's spelling.
///
/// ## Examples
///
/// ```gleam
/// assert budget.parse_stop("steps") == Ok(budget.Steps)
/// ```
///
pub fn parse_stop(name: String) -> Result(StopReason, String) {
  case name {
    "steps" -> Ok(Steps)
    "budget" -> Ok(Budget)
    "reflections" -> Ok(Reflections)
    "candidates" -> Ok(Candidates)
    other -> Error("unknown stop reason \"" <> other <> "\"")
  }
}
