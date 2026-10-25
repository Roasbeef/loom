//// A GEPA-shaped reflective search over the text components of a program,
//// as a pure state machine the host drives: the host asks `next`, gets a
//// typed request, performs it in its own world, and feeds back a typed
//// event; `apply` refuses an event the state cannot accept, and `replay`
//// of the event list rebuilds the state exactly.
////
//// # Why the boundary is here
////
//// The search *decides* a great deal — which parent to extend, which
//// tasks to try it on, whether a child is worth paying for, what each
//// stage may spend so the final confirmation is always still affordable,
//// when to stop — and none of it needs an effect. What it *does* is the
//// host's: run a candidate on some tasks, ask a model to rewrite a slot.
//// Keeping every decision over values means a search can be replayed from
//// its log without running anything, every rule can be property-tested
//// without a process, and the same library serves a host whose
//// evaluations are jailed agent sessions and one whose evaluations are a
//// function call. Nothing here depends on the host's language for tasks,
//// candidates or money: a candidate is a map from component name to text,
//// a task is an opaque id, a score is a float in `[0, 1]`, and the budget
//// is in whatever unit the host meters.
////
//// Requests rather than callbacks, because a callback would make `next`
//// an effect and the state unreplayable: the host performs the request
//// however it likes (synchronously, in a process pool, on another
//// machine, after a crash and a restart) and the library only ever sees
//// the event it chose to feed back. The cost of the shape is that the
//// host writes the loop; `README.md` shows it is a dozen lines.
////
//// # The loop
////
//// One step, given a pool whose members all have validate scores:
////
//// 1. a parent is drawn by `select.front` and `select.draw_parent` from a
////    generator seeded by the search id and the step number, the step's
////    slot is `select.slot_for` and its minibatch `select.minibatch`;
//// 2. the parent is evaluated on the minibatch (`Evaluate`,
////    `ParentMinibatch`) to collect feedback; a parent at the ceiling on
////    every minibatch task has nothing to reflect on, and the step ends
////    in a `Refused` row that costs nothing (`skipped_perfect_reason`);
//// 3. the reflector is shown that feedback (`Reflect`), with the slot's
////    background (`Config.background`) and a digest of the rewrites of
////    that slot the lineage already rejected (`tried`), and answers the
////    slot's new text; the child is the parent with that slot replaced
////    (`Minted`), or the step ends `Refused`, as it does when the host
////    reports the answer `Truncated` at an output limit, since a rewrite
////    cut mid-sentence is not the rewrite the reflector meant;
//// 4. the child is evaluated on the same minibatch (`ChildMinibatch`) and
////    `select.screen` decides whether to pay for validate;
//// 5. the child is evaluated on the whole validate split (`Validate`) and
////    judged against the parent and, when the parent is not the pool's
////    best, against the incumbent; `verdict.dispose` turns the acceptances
////    into the step's disposition.
////
//// At a stop (steps, budget, reflections, candidates) the seed and the
//// best are evaluated together (`Confirm`), the one simultaneous
//// comparison, and that judgement is the headline.
////
//// # The log is the state
////
//// `replay` folds the events and refuses the first that does not follow:
//// an event out of order, a candidate no `Minted` introduced, a settling
//// judgement whose evaluations are missing, a disposition that does not
//// follow from its acceptance, an incumbent judgement missing or
//// repeated, an event after the stop. A log that quietly tolerated a
//// dropped event would let a candidate look better by losing the
//// evaluation it failed. Resume is the same loop over the replayed state:
//// `next` re-enters an open step at the stage its events reached and asks
//// for the same thing again, and the draws are recomputed from the seed.
////
//// Two folds, for two kinds of host. `replay_checked` is the one an
//// embedder wants: it holds every row to the request `next` made before
//// it, so an evaluation of other tasks or under another cap, a stage out
//// of its order, a reflection charged above its worst case, a child in
//// the wrong slot, a judgement the search did not decide or a stop it
//// did not reach are refused by name. `replay` and `apply` check only the
//// shape of the step, because a host whose rows did not come from `next`
//// — Loom's `eval/search`, whose log predates this library and whose
//// driver orders its own effects — can still fold them, and that host
//// vouches for their contents itself.
////
//// # What is left for a later layer
////
//// The event encoding (`gepa/log`) is tagged by kind under a version
//// field, so a new kind is one constructor plus one encode and one decode
//// arm. Four extensions are anticipated and have their places named:
//// a reflection that asks for several proposals and screens a set of
//// children (a `Reflect` request with a count, a `Minted` per child, and a
//// screen judgement per child with only the best passer going to
//// validate); further dispositions such as a child skipped because the
//// parent is already perfect on the minibatch (a `verdict.Disposition`
//// variant and a `consistent` row); a richer reflection reply (`Finish`
//// already records how the answer ended, so a truncated one can be
//// refused; per-slot background goes in `prompt.Request.notes`, and a
//// "tried before" digest would sit beside it); and lineage enough for a
//// three-way merge (a `Merged` event naming an ancestor and two parents,
//// with `Member.parent` widened to a lineage).
////
//// ## Flow
////
//// - `start`, `replay`, `replay_checked`, `expected`, `answers`, `apply`:
////   the state and the two folds
//// - `apply_seeded`, `apply_evaluated`, `apply_reflected`, `apply_minted`,
////   `apply_refused`, `apply_judged`, `settle`, `apply_stopped`: one arm
////   of the fold each
//// - `next`: the request the host should perform now
//// - `between_steps`, `confirm_or_stop`, `within_step`, `draws`: how
////   `next` decides
//// - `reflect_or_refuse`, `records`, `tried`, `lineage`: what the
////   reflector is shown
//// - `admit`, `child_components`, `content_id`: minting a child from an
////   answer
//// - `validate_scores`, `minibatch_scores`, `spent`, `children`: reading
////   the state

import gepa/budget.{type Costs, type Design, type Limits, type StopReason}
import gepa/judge.{type Judge}
import gepa/prng
import gepa/prompt
import gepa/select
import gepa/verdict.{type Acceptance, type Basis, type Disposition}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Which part an evaluation plays in the search.
pub type Stage {
  /// The seed alone on the validate split, at step 0: the baseline every
  /// later comparison pairs against.
  SeedValidate

  /// The parent alone on the tune minibatch, to collect feedback.
  ParentMinibatch

  /// The child alone on the same minibatch, for the screen.
  ChildMinibatch

  /// The child alone on the whole validate split, for acceptance.
  Validate

  /// Seed and best together on validate: the one simultaneous comparison.
  Confirm
}

/// How a reflector's answer ended, so a host that knows can refuse a
/// truncated one; `Unknown` for a host that does not.
pub type Finish {
  /// The model stopped of its own accord.
  Complete

  /// The answer hit an output limit.
  Truncated

  /// The host did not say.
  Unknown
}

/// One task's result under one candidate.
pub type Score {
  Score(
    /// The task id.
    task: String,
    /// The score in zero to one, higher better, aggregated by the host
    /// over however many trials it ran.
    value: Float,
    /// Bounded side information the reflector may be shown: what the
    /// verifier said, how the run ended. Empty when the host has none.
    feedback: String,
  )
}

/// One candidate's scores from one evaluation.
pub type Measured {
  Measured(
    /// The candidate id.
    candidate: String,
    /// Its scores, one per task it was measured on.
    scores: List(Score),
  )
}

/// One row of the search log.
pub type Event {
  /// The first row: the seed entered the search.
  Seeded(
    /// The seed's id.
    candidate: String,
    /// Its components, by name.
    components: List(#(String, String)),
  )

  /// An evaluation the host completed.
  Evaluated(
    /// Its part in the step.
    stage: Stage,
    /// The step it belongs to; zero for the seed's validate run.
    step: Int,
    /// The candidate it is about: the parent, the child, or the best in a
    /// confirm run (which also measures the seed).
    candidate: String,
    /// The tasks it ran.
    tasks: List(String),
    /// The budget the stage was handed, which rebuilds what the host
    /// planned when its own record of the run was never written.
    cap: Float,
    /// The host's handle for the run: a directory, a job id, empty.
    ref: String,
    /// What was measured, per candidate.
    measured: List(Measured),
    /// What it cost, in the host's unit.
    cost: Float,
  )

  /// One reflection call, whether or not it answered.
  Reflected(
    /// The step.
    step: Int,
    /// What the call cost, in the host's unit.
    cost: Float,
    /// The host's handle for the call: a digest, a request id, empty.
    ref: String,
    /// How the answer ended.
    finish: Finish,
  )

  /// A child was minted from the open step's parent.
  Minted(
    /// The child's id, chosen by the host.
    candidate: String,
    /// The parent.
    parent: String,
    /// The step.
    step: Int,
    /// The slot the reflection rewrote.
    slot: String,
    /// The slot's new text.
    text: String,
  )

  /// A step's child was refused before it ran: no candidate when the
  /// answer was refused, the candidate when the host could not build it.
  Refused(
    /// The step.
    step: Int,
    /// The refused candidate, or none when none was minted.
    candidate: Option(String),
    /// Why.
    reason: String,
  )

  /// A comparison the search made.
  Judged(
    /// The candidate judged.
    candidate: String,
    /// The candidate it was paired against.
    against: String,
    /// Where the measurements came from.
    basis: Basis,
    /// What the comparison concluded.
    acceptance: Acceptance,
    /// What the search did about it.
    disposition: Disposition,
    /// The host's handle for the judgement's own record, empty when it
    /// has none.
    ref: String,
  )

  /// The search ended.
  Stopped(
    /// Why.
    reason: StopReason,
  )
}

/// A candidate the fold has seen.
pub type Member {
  Member(
    /// The candidate id.
    candidate: String,
    /// Its components, by name, sorted.
    components: List(#(String, String)),
    /// Its parent, if any.
    parent: Option(String),
    /// The step that minted it.
    step: Int,
    /// The slot that was rewritten.
    slot: Option(String),
    /// The handle of the evaluation whose scores are its validate scores,
    /// once it has run.
    validated: Option(String),
    /// What the search decided about it, once settled.
    disposition: Option(Disposition),
  )
}

/// One evaluation as the fold keeps it.
pub type Evaluation {
  Evaluation(
    /// Its part in the step.
    stage: Stage,
    /// The step.
    step: Int,
    /// The candidate it is about.
    candidate: String,
    /// The tasks it ran.
    tasks: List(String),
    /// The budget it was handed.
    cap: Float,
    /// The host's handle.
    ref: String,
    /// What was measured.
    measured: List(Measured),
    /// What it cost.
    cost: Float,
  )
}

/// How far an open step has got. The events a step writes arrive in a
/// fixed order, and this is the last stage seen.
pub type Reached {
  /// The parent's minibatch has been evaluated.
  ParentMeasured

  /// At least one reflection has been made since.
  ReflectedOnce

  /// The child has been minted.
  ChildMinted

  /// The child's minibatch has been evaluated.
  ChildMeasured

  /// The child's validate run has been evaluated.
  ChildValidated
}

/// Where an unfinished step has got to.
pub type Progress {
  Progress(
    /// The step number.
    step: Int,
    /// The parent drawn for the step.
    parent: String,
    /// The last stage seen.
    reached: Reached,
    /// The child, once minted.
    child: Option(String),
    /// How the last reflection's answer ended, from its row, so `admit`
    /// can refuse a truncated one; none before the step has reflected.
    finish: Option(Finish),
    /// The acceptance against the incumbent, when one was recorded before
    /// the settling judgement.
    against_incumbent: Option(Acceptance),
  )
}

/// The confirm run and what it found.
pub type Confirmation {
  Confirmation(
    /// The best candidate's id.
    best: String,
    /// The host's handle for the run.
    ref: String,
    /// The acceptance, once judged.
    acceptance: Option(Acceptance),
  )
}

/// The whole search, as the fold leaves it.
pub type State {
  State(
    /// The seed's id.
    seed: String,
    /// Every candidate in log order.
    members: List(Member),
    /// The candidates in the pool, in log order: the seed first.
    pool: List(String),
    /// The best candidate by the search's rule.
    incumbent: String,
    /// Every evaluation, in log order.
    evaluations: List(Evaluation),
    /// How many reflections have been made.
    reflections: Int,
    /// What the evaluations cost.
    spent_evaluating: Float,
    /// What the reflections cost.
    spent_reflecting: Float,
    /// The last step number opened.
    step: Int,
    /// The step in progress, if the log ends inside one.
    open: Option(Progress),
    /// The confirm run, once evaluated.
    confirmation: Option(Confirmation),
    /// Why the search stopped, if it did.
    stopped: Option(StopReason),
  )
}

/// The fields of one record the reflector is shown for one score, chosen
/// by the host per slot: a tool's description wants the calls that tool
/// took and their errors, a system prompt wants the verifier's tail. The
/// host packs what it has into `Score.feedback` and unpacks it here;
/// `feedback_evidence` is the view that shows the feedback whole.
pub type Evidence =
  fn(String, Score) -> List(#(String, String))

/// Everything `next` needs that does not change over the search.
pub type Config {
  Config(
    /// The search id, which seeds every draw.
    id: String,
    /// What the search optimises for, in the operator's words.
    objective: String,
    /// Background or constraints per slot, by slot name, shown to the
    /// reflector as framed data; a slot with none gets none.
    background: List(#(String, String)),
    /// Which fields of a score each slot's reflection is shown.
    evidence: Evidence,
    /// The tune tasks, which supply minibatches and feedback.
    tune: List(String),
    /// The validate tasks, which supply acceptance and the front.
    validate: List(String),
    /// Trials per cell on validate, the K of the design.
    k: Int,
    /// Trials per cell on a minibatch.
    k_tune: Int,
    /// Tasks per minibatch, clamped to the tune split.
    minibatch: Int,
    /// The slots a reflection may rewrite, in round-robin order.
    slots: List(String),
    /// Identifiers per task the reflector must never read.
    hidden: List(#(String, List(String))),
    /// The search's ceilings.
    limits: Limits,
    /// What evaluations and reflections cost at worst.
    costs: Costs,
    /// The host's acceptance rule.
    judge: Judge,
  )
}

/// What the host should do now.
pub type Request {
  /// Evaluate `candidate` on `tasks` at `trials` per cell, spending at
  /// most `cap`, then feed back `Evaluated`. For `Confirm` the host
  /// evaluates the seed alongside, in the same run, and measures both.
  Evaluate(
    /// Its part in the step.
    stage: Stage,
    /// The step.
    step: Int,
    /// The candidate.
    candidate: String,
    /// The tasks.
    tasks: List(String),
    /// Trials per cell.
    trials: Int,
    /// What the run may spend, in the host's unit.
    cap: Float,
  )

  /// Show the reflector `prompt.render(request)` and feed back
  /// `Reflected`, then `admit` the answer.
  Reflect(
    /// The step.
    step: Int,
    /// The parent.
    parent: String,
    /// The slot being rewritten.
    slot: String,
    /// What to show.
    request: prompt.Request,
    /// The worst case the call may cost, already covered.
    worst_case: Float,
  )

  /// Nothing to do but apply this event, which the search decided itself.
  Record(
    /// The event.
    event: Event,
  )

  /// The search has stopped.
  Done
}

/// The reason of the `Refused` row a step ends in when its parent scored
/// one on every minibatch task: there is nothing for a reflection to
/// improve on, so none is paid for.
pub const skipped_perfect_reason =
  "skipped_perfect: the parent scored 1.0 on every minibatch task"

/// The reason of the `Refused` row `admit` writes when the host reported
/// the reflection's answer `Truncated`: a rewrite cut at an output limit
/// is not the rewrite the reflector meant, however well it reads.
pub const truncated_reason =
  "the reflector's answer was truncated at the output limit"

// What a step draws before it runs anything: all from the pool as it
// stood and a generator seeded by the search id and the step, so a
// resumed step draws the same.
type Draws {
  Draws(parent: String, tasks: List(String), slot: String)
}

// --- the state and the fold -----------------------------------------------------------

/// The state right after the seed's row: step 0 is open until the seed's
/// validate run is recorded.
///
/// ## Examples
///
/// ```gleam
/// let state = gepa.start("seed", [#("system", "Be brief.")])
/// assert state.pool == ["seed"]
/// ```
///
pub fn start(seed: String, components: List(#(String, String))) -> State {
  State(
    seed:,
    members: [
      Member(
        candidate: seed,
        components: sorted(components),
        parent: None,
        step: 0,
        slot: None,
        validated: None,
        disposition: Some(verdict.Incumbent),
      ),
    ],
    pool: [seed],
    incumbent: seed,
    evaluations: [],
    reflections: 0,
    spent_evaluating: 0.0,
    spent_reflecting: 0.0,
    step: 0,
    open: None,
    confirmation: None,
    stopped: None,
  )
}

/// Components sorted by name, the one order a candidate has.
fn sorted(components: List(#(String, String))) -> List(#(String, String)) {
  list.sort(components, fn(left, right) { string.compare(left.0, right.0) })
}

/// The evidence view that shows every slot the score's feedback, whole,
/// under one field: what a host with no per-slot views hands `Config`.
///
/// ## Examples
///
/// ```gleam
/// assert gepa.feedback_evidence("system", gepa.Score("t", 0.0, "failed"))
///   == [#("feedback", "failed")]
/// ```
///
pub fn feedback_evidence(
  _slot: String,
  score: Score,
) -> List(#(String, String)) {
  [#("feedback", score.feedback)]
}

/// Folds a log into the search's state, refusing the first row that does
/// not follow from the rows before it. An empty log is an error: a search
/// that has not started has no state to replay.
///
/// ## Examples
///
/// ```gleam
/// // gepa.replay([Seeded("s", [])]) == Ok(gepa.start("s", []))
/// // gepa.replay([]) == Error("search row missing: the seed")
/// ```
///
pub fn replay(events: List(Event)) -> Result(State, String) {
  case events {
    [Seeded(candidate: "", ..), ..] ->
      Error("search row 1: the seed is a nonempty id")
    [Seeded(candidate:, components:), ..rest] ->
      list.index_fold(
        rest,
        Ok(start(candidate, components)),
        fn(folded, event, position) {
          use state <- result.try(folded)

          apply(state, event)
          |> result.map_error(fn(reason) {
            "search row " <> int.to_string(position + 2) <> ": " <> reason
          })
        },
      )

    [] -> Error("search row missing: the seed")
    [_, ..] -> Error("search row 1: the log must begin with the seed")
  }
}

/// Folds a log that a host driving `next` wrote, refusing the first row
/// that is not the answer to the request `next` made before it, and then
/// everything `replay` refuses. This is the fold for an embedder; `replay`
/// alone is for a host whose rows did not come from `next`.
///
/// ## Examples
///
/// ```gleam
/// // gepa.replay_checked(events, config) == Ok(state)   // a log `next` wrote
/// // gepa.replay_checked([seeded, evaluated_under_another_cap], config)
/// //   -> Error("search row 2: ...")
/// ```
///
pub fn replay_checked(
  events: List(Event),
  config: Config,
) -> Result(State, String) {
  // The seed's row opens the state; every later row is first held to the
  // request before it, then folded.
  case events {
    [Seeded(candidate: "", ..), ..] ->
      Error("search row 1: the seed is a nonempty id")
    [Seeded(candidate:, components:), ..rest] ->
      list.index_fold(
        rest,
        Ok(start(candidate, components)),
        fn(folded, event, position) {
          use state <- result.try(folded)

          {
            use Nil <- result.try(expected(state, config, event))
            apply(state, event)
          }
          |> result.map_error(fn(reason) {
            "search row " <> int.to_string(position + 2) <> ": " <> reason
          })
        },
      )

    [] -> Error("search row missing: the seed")
    [_, ..] -> Error("search row 1: the log must begin with the seed")
  }
}

/// Whether a row answers the request `next` makes of the state before
/// it. A `Record` must be applied as decided; an evaluation must be of
/// the stage, step, candidate, tasks and cap asked for and cost no more
/// than its cap; a reflection must be of the step asked for and cost no
/// more than its worst case; a child must be minted from the parent and
/// slot asked for, or refused with no child; a child the host could not
/// build is refused where its minibatch was asked for.
///
/// ## Examples
///
/// ```gleam
/// // gepa.expected(state, config, Stopped(budget.Steps))
/// //   == Error("the search did not decide this row: ...")
/// ```
///
pub fn expected(
  state: State,
  config: Config,
  event: Event,
) -> Result(Nil, String) {
  // A child, or the refusal of an answer, that follows a reflection answers
  // the `Reflect` request before it, not the question `next` asks now:
  // after the reflection was charged `next` asks whether another one is
  // still affordable, which is the resume case, not this one.
  case state.open, event {
    Some(Progress(reached: ReflectedOnce, step:, parent:, ..)),
      Minted(parent: got_parent, step: got_step, slot: got_slot, ..)
    -> {
      use drawn <- result.try(draws(state, config, step))

      require(
        step == got_step && parent == got_parent && drawn.slot == got_slot,
        "the child is not minted from the parent and slot asked for",
      )
    }

    Some(Progress(reached: ReflectedOnce, step:, ..)),
      Refused(step: got_step, candidate: None, ..)
    -> require(step == got_step, "the refusal is not of the step asked for")

    _, _ -> answers(state, config, event)
  }
}

/// Whether a row answers the request `next` makes of the state before it.
fn answers(state: State, config: Config, event: Event) -> Result(Nil, String) {
  use request <- result.try(next(state, config))

  // Each request admits the rows that answer it, and no other.
  case request, event {
    Record(wanted), got ->
      require(
        wanted == got,
        "the search did not decide this row: it recorded "
          <> describe(Record(wanted)),
      )

    Evaluate(stage:, step:, candidate:, tasks:, cap:, ..),
      Evaluated(
        stage: got_stage,
        step: got_step,
        candidate: got_candidate,
        tasks: got_tasks,
        cap: got_cap,
        cost:,
        ..,
      )
    -> {
      use Nil <- result.try(require(
        stage == got_stage
          && step == got_step
          && candidate == got_candidate
          && tasks == got_tasks
          && cap == got_cap,
        "the evaluation is not the one asked for: " <> describe(request),
      ))

      require(cost <=. cap, "an evaluation spent past its cap")
    }

    Evaluate(stage: ChildMinibatch, step:, candidate:, ..),
      Refused(step: got_step, candidate: Some(got_candidate), ..)
    ->
      require(
        step == got_step && candidate == got_candidate,
        "a refused child is the one whose minibatch was asked for",
      )

    Reflect(step:, worst_case:, ..), Reflected(step: got_step, cost:, ..) -> {
      use Nil <- result.try(require(
        step == got_step,
        "the reflection is not the one asked for",
      ))

      require(cost <=. worst_case, "a reflection cost more than its worst case")
    }

    Done, _ -> Error("a row follows the stop row")
    _, _ -> Error("the row does not answer the request: " <> describe(request))
  }
}

/// A request in a sentence, for a refusal.
fn describe(request: Request) -> String {
  case request {
    Evaluate(stage:, step:, candidate:, cap:, ..) ->
      "an evaluation of "
      <> candidate
      <> " at step "
      <> int.to_string(step)
      <> " ("
      <> stage_word(stage)
      <> ", cap "
      <> float.to_string(cap)
      <> ")"
    Reflect(step:, parent:, slot:, ..) ->
      "a reflection on "
      <> parent
      <> "'s "
      <> slot
      <> " at step "
      <> int.to_string(step)
    Record(Stopped(reason:)) -> "the stop (" <> budget.stop_name(reason) <> ")"
    Record(Judged(candidate:, against:, disposition:, ..)) ->
      "a judgement of "
      <> candidate
      <> " against "
      <> against
      <> " ("
      <> verdict.disposition_name(disposition)
      <> ")"
    Record(Reflected(step:, ..)) ->
      "a zero-cost reflection at step " <> int.to_string(step)
    Record(Refused(step:, reason:, ..)) ->
      "a refusal at step " <> int.to_string(step) <> " (" <> reason <> ")"
    Record(Seeded(..)) | Record(Evaluated(..)) | Record(Minted(..)) ->
      "a row of its own"
    Done -> "nothing: the search has stopped"
  }
}

/// A stage as one word.
fn stage_word(stage: Stage) -> String {
  case stage {
    SeedValidate -> "seed validate"
    ParentMinibatch -> "parent minibatch"
    ChildMinibatch -> "child minibatch"
    Validate -> "validate"
    Confirm -> "confirm"
  }
}

/// Applies one row to the state, or says why it cannot follow.
///
/// ## Examples
///
/// ```gleam
/// // gepa.apply(state, Stopped(budget.Steps)) -> Ok(State(..state, stopped: Some(Steps)))
/// ```
///
pub fn apply(state: State, event: Event) -> Result(State, String) {
  use Nil <- result.try(require(
    state.stopped == None,
    "a row follows the stop row",
  ))

  // Each row kind has one place in a step; the open progress says where
  // the step is, and the row must be the next stage.
  case event {
    Seeded(..) -> apply_seeded(state)
    Evaluated(..) -> apply_evaluated(state, event)
    Reflected(step:, cost:, finish:, ..) ->
      apply_reflected(state, step, cost, finish)
    Minted(..) -> apply_minted(state, event)
    Refused(step:, candidate:, ..) -> apply_refused(state, step, candidate)
    Judged(..) -> apply_judged(state, event)
    Stopped(reason:) -> apply_stopped(state, reason)
  }
}

/// A second seed row is a second search.
fn apply_seeded(_state: State) -> Result(State, String) {
  Error("a second seed row")
}

/// An evaluation belongs to one stage of one step, and the stage says
/// where in the step it must fall.
fn apply_evaluated(state: State, event: Event) -> Result(State, String) {
  // Only an evaluation row reaches here; the type does not narrow it.
  use evaluation <- result.try(case event {
    Evaluated(stage:, step:, candidate:, tasks:, cap:, ref:, measured:, cost:) ->
      Ok(Evaluation(
        stage:,
        step:,
        candidate:,
        tasks:,
        cap:,
        ref:,
        measured:,
        cost:,
      ))
    Seeded(..)
    | Reflected(..)
    | Minted(..)
    | Refused(..)
    | Judged(..)
    | Stopped(..) -> Error("not an evaluation row")
  })

  use Nil <- result.try(well_measured(state, evaluation))
  use Nil <- result.try(well_formed(evaluation))

  // Each stage has its own place in the step.
  case evaluation.stage {
    SeedValidate -> seed_validate(state, evaluation)
    ParentMinibatch -> open_step(state, evaluation)
    ChildMinibatch -> child_minibatch(state, evaluation)
    Validate -> validate_run(state, evaluation)
    Confirm -> confirm_run(state, evaluation)
  }
}

/// An evaluation measures the candidate it names, and the seed as well in
/// a confirm run, each at most once.
fn well_measured(state: State, evaluation: Evaluation) -> Result(Nil, String) {
  // A confirm run measures the seed too; every other stage one candidate.
  let allowed = case evaluation.stage {
    Confirm -> [state.seed, evaluation.candidate]
    SeedValidate | ParentMinibatch | ChildMinibatch | Validate -> [
      evaluation.candidate,
    ]
  }

  let named = list.map(evaluation.measured, fn(measured) { measured.candidate })

  use Nil <- result.try(require(
    list.all(named, list.contains(allowed, _)),
    "an evaluation measures only the candidates it is about",
  ))

  require(
    list.length(list.unique(named)) == list.length(named),
    "an evaluation measures each candidate once",
  )
}

/// An evaluation names a candidate and tasks that are not empty, and
/// its money and scores are finite, the money never negative: a hole in
/// an id would be a candidate nothing can refer to, and a NaN would
/// decide nothing and encode differently on each target.
fn well_formed(evaluation: Evaluation) -> Result(Nil, String) {
  use Nil <- result.try(nonempty(
    evaluation.candidate,
    "an evaluation's candidate",
  ))
  use Nil <- result.try(require(
    list.all(evaluation.tasks, fn(task) { task != "" }),
    "a task id is nonempty",
  ))
  use Nil <- result.try(money(evaluation.cap, "an evaluation's cap"))
  use Nil <- result.try(money(evaluation.cost, "an evaluation's cost"))

  require(
    list.all(evaluation.measured, fn(measured) {
      measured.candidate != ""
      && list.all(measured.scores, fn(score) {
        score.task != "" && is_finite(score.value)
      })
    }),
    "a measurement names a candidate and tasks, with finite scores",
  )
}

/// A finite, non-negative amount in the host's unit.
fn money(amount: Float, what: String) -> Result(Nil, String) {
  require(
    is_finite(amount) && amount >=. 0.0,
    what <> " is a finite, non-negative amount",
  )
}

/// An id that is not the empty string.
fn nonempty(id: String, what: String) -> Result(Nil, String) {
  require(id != "", what <> " is a nonempty id")
}

/// Step 0 is the seed's validate run, before anything else.
fn seed_validate(
  state: State,
  evaluation: Evaluation,
) -> Result(State, String) {
  use Nil <- result.try(require(
    evaluation.candidate == state.seed
      && evaluation.step == 0
      && state.step == 0
      && state.evaluations == []
      && state.open == None,
    "the step 0 validate run belongs to the seed, before anything else",
  ))

  Ok(
    State(
      ..state,
      evaluations: [evaluation],
      spent_evaluating: state.spent_evaluating +. evaluation.cost,
      members: with_validated(state.members, state.seed, evaluation.ref),
    ),
  )
}

/// Every later step opens with the parent's minibatch run, which must
/// name a pool member and the next step.
fn open_step(state: State, evaluation: Evaluation) -> Result(State, String) {
  // A step opens only between steps, before the confirm run.
  case state.open, state.confirmation {
    None, None -> {
      use Nil <- result.try(require(
        evaluation.step == state.step + 1,
        "a step opens at the step after the last",
      ))
      use Nil <- result.try(require(
        list.contains(state.pool, evaluation.candidate),
        "the parent " <> evaluation.candidate <> " is not in the pool",
      ))
      use Nil <- result.try(seed_validated(state))

      Ok(
        State(
          ..state,
          evaluations: list.append(state.evaluations, [evaluation]),
          spent_evaluating: state.spent_evaluating +. evaluation.cost,
          step: evaluation.step,
          open: Some(Progress(
            step: evaluation.step,
            parent: evaluation.candidate,
            reached: ParentMeasured,
            child: None,
            finish: None,
            against_incumbent: None,
          )),
        ),
      )
    }

    Some(_), _ -> Error("a step opened inside an unfinished step")
    None, Some(_) -> Error("a step opened after the confirm run")
  }
}

/// Step 0 is the seed's validate run; nothing else may happen before it.
fn seed_validated(state: State) -> Result(Nil, String) {
  case list.first(state.members) {
    Ok(Member(validated: Some(_), ..)) -> Ok(Nil)
    Ok(Member(validated: None, ..)) | Error(Nil) ->
      Error("search row missing: the seed's validate run")
  }
}

/// The child's minibatch follows its minting.
fn child_minibatch(
  state: State,
  evaluation: Evaluation,
) -> Result(State, String) {
  // The child's minibatch follows its candidate row inside the open step.
  case state.open {
    Some(progress) -> {
      use Nil <- result.try(require(
        progress.child != None,
        "search row missing: the child's candidate row",
      ))
      use Nil <- result.try(require(
        evaluation.step == progress.step
          && progress.child == Some(evaluation.candidate)
          && progress.reached == ChildMinted,
        "a child minibatch needs the step's child and no earlier one",
      ))

      Ok(
        State(
          ..state,
          evaluations: list.append(state.evaluations, [evaluation]),
          spent_evaluating: state.spent_evaluating +. evaluation.cost,
          open: Some(Progress(..progress, reached: ChildMeasured)),
        ),
      )
    }

    None ->
      Error("search row missing: the parent minibatch run that opens the step")
  }
}

/// A validate run after step 0 is the open step's child's, after its
/// minibatch.
fn validate_run(state: State, evaluation: Evaluation) -> Result(State, String) {
  // A later validate run is the open step's child's.
  case state.open {
    Some(progress) -> {
      use Nil <- result.try(require(
        evaluation.step == progress.step
          && progress.child == Some(evaluation.candidate)
          && progress.reached != ChildValidated,
        "a validate run needs the step's child and no earlier validate run",
      ))
      use Nil <- result.try(require(
        progress.reached == ChildMeasured,
        "search row missing: the child's minibatch run",
      ))

      Ok(
        State(
          ..state,
          evaluations: list.append(state.evaluations, [evaluation]),
          spent_evaluating: state.spent_evaluating +. evaluation.cost,
          members: with_validated(
            state.members,
            evaluation.candidate,
            evaluation.ref,
          ),
          open: Some(Progress(..progress, reached: ChildValidated)),
        ),
      )
    }

    None -> Error("a validate run row out of place")
  }
}

/// The confirm run comes once, between the last settled step and the
/// stop, and names the incumbent.
fn confirm_run(state: State, evaluation: Evaluation) -> Result(State, String) {
  // The confirm run comes once, between the last settled step and the stop.
  case state.open, state.confirmation {
    None, None -> {
      use Nil <- result.try(require(
        evaluation.step == state.step
          && evaluation.candidate == state.incumbent
          && evaluation.candidate != state.seed,
        "a confirm run names the incumbent at the last step",
      ))

      Ok(
        State(
          ..state,
          evaluations: list.append(state.evaluations, [evaluation]),
          spent_evaluating: state.spent_evaluating +. evaluation.cost,
          confirmation: Some(Confirmation(
            best: evaluation.candidate,
            ref: evaluation.ref,
            acceptance: None,
          )),
        ),
      )
    }

    Some(_), _ -> Error("a confirm run inside an unfinished step")
    None, Some(_) -> Error("a second confirm run")
  }
}

/// Records the evaluation whose scores are a candidate's validate scores.
fn with_validated(
  members: List(Member),
  candidate: String,
  ref: String,
) -> List(Member) {
  list.map(members, fn(member) {
    case member.candidate == candidate {
      True -> Member(..member, validated: Some(ref))
      False -> member
    }
  })
}

/// A reflection belongs to the open step, after the parent's minibatch and
/// before the child. A second one in the same step is a resumed search
/// that lost the first answer before minting, and is counted too.
fn apply_reflected(
  state: State,
  step: Int,
  cost: Float,
  finish: Finish,
) -> Result(State, String) {
  // A reflection belongs to an open step that has no child yet.
  case state.open {
    Some(progress) -> {
      use Nil <- result.try(require(
        step == progress.step && progress.child == None,
        "a reflection needs an open step with no child yet",
      ))
      use Nil <- result.try(money(cost, "a reflection's cost"))

      Ok(
        State(
          ..state,
          reflections: state.reflections + 1,
          spent_reflecting: state.spent_reflecting +. cost,
          open: Some(
            Progress(..progress, reached: ReflectedOnce, finish: Some(finish)),
          ),
        ),
      )
    }

    None ->
      Error("search row missing: the parent minibatch run that opens the step")
  }
}

/// A child is minted from the open step's parent, after a reflection, and
/// is new to the search.
fn apply_minted(state: State, event: Event) -> Result(State, String) {
  // A child needs an open step that has reflected; anything else is misplaced.
  case event, state.open {
    Minted(candidate:, parent:, step:, slot:, text:), Some(progress) -> {
      use Nil <- result.try(nonempty(candidate, "a child's candidate"))
      use Nil <- result.try(nonempty(slot, "a child's slot"))
      use Nil <- result.try(require(
        step == progress.step
          && parent == progress.parent
          && progress.reached == ReflectedOnce,
        "a candidate row needs an open step that has reflected and has no child",
      ))
      use Nil <- result.try(require(
        !list.any(state.members, fn(member) { member.candidate == candidate }),
        "candidate " <> candidate <> " was already introduced",
      ))
      use origin <- result.try(member_of(state, parent))

      let member =
        Member(
          candidate:,
          components: child_components(origin.components, slot, text),
          parent: Some(parent),
          step:,
          slot: Some(slot),
          validated: None,
          disposition: None,
        )

      Ok(
        State(
          ..state,
          members: list.append(state.members, [member]),
          open: Some(
            Progress(..progress, reached: ChildMinted, child: Some(candidate)),
          ),
        ),
      )
    }

    Minted(..), None ->
      Error("search row missing: the parent minibatch run that opens the step")
    Seeded(..), _
    | Evaluated(..), _
    | Reflected(..), _
    | Refused(..), _
    | Judged(..), _
    | Stopped(..), _
    -> Error("not a candidate row")
  }
}

/// The member with an id.
fn member_of(state: State, candidate: String) -> Result(Member, String) {
  list.find(state.members, fn(member) { member.candidate == candidate })
  |> result.map_error(fn(_) { "no candidate row for " <> candidate })
}

/// A refusal closes the open step: with no candidate after a refused
/// answer, or before any reflection when the step had nothing to reflect
/// on; with the child when the host could not build it.
fn apply_refused(
  state: State,
  step: Int,
  candidate: Option(String),
) -> Result(State, String) {
  // A refusal closes an open step before its child has run.
  case state.open {
    Some(progress) -> {
      use Nil <- result.try(require(
        step == progress.step,
        "a refusal names the open step",
      ))
      use Nil <- result.try(require(
        case candidate {
          None ->
            progress.reached == ReflectedOnce
            || progress.reached == ParentMeasured
          Some(_) ->
            progress.child == candidate && progress.reached == ChildMinted
        },
        "a refusal names the step's child, or no candidate before one was minted",
      ))

      Ok(
        State(
          ..state,
          members: with_disposition(
            state.members,
            option.unwrap(candidate, ""),
            verdict.Refused,
          ),
          open: None,
        ),
      )
    }

    None ->
      Error("search row missing: the parent minibatch run that opens the step")
  }
}

/// Records what the search decided about a candidate.
fn with_disposition(
  members: List(Member),
  candidate: String,
  disposition: Disposition,
) -> List(Member) {
  list.map(members, fn(member) {
    case member.candidate == candidate {
      True -> Member(..member, disposition: Some(disposition))
      False -> member
    }
  })
}

/// A judgement settles the open step when it is against the parent,
/// records the incumbent comparison when it is against the incumbent, or
/// judges the confirm run.
fn apply_judged(state: State, event: Event) -> Result(State, String) {
  // A judgement settles the open step, records the incumbent comparison,
  // or judges the confirm run.
  case event, state.open, state.confirmation {
    Judged(candidate:, against:, basis:, acceptance:, disposition:, ..),
      Some(progress),
      _
    -> {
      use Nil <- result.try(nonempty(against, "a judgement's baseline"))
      use Nil <- result.try(require(
        progress.child == Some(candidate),
        "a judgement names the step's child",
      ))

      // Against the parent the row settles the step; against the
      // incumbent it is kept for the settling row that follows.
      case against == progress.parent {
        True ->
          settle(state, progress, candidate, basis, acceptance, disposition)
        False -> {
          use Nil <- result.try(require(
            against == state.incumbent && progress.reached == ChildValidated,
            "a judgement is against the parent or the incumbent, after validate",
          ))
          use Nil <- result.try(require(
            progress.against_incumbent == None,
            "a second judgement against the incumbent in one step",
          ))
          use Nil <- result.try(require(
            basis == verdict.OnValidate && disposition == verdict.Unsettled,
            "an incumbent comparison is a validate row that settles nothing",
          ))

          Ok(
            State(
              ..state,
              open: Some(
                Progress(..progress, against_incumbent: Some(acceptance)),
              ),
            ),
          )
        }
      }
    }

    Judged(candidate:, against:, basis:, acceptance:, disposition:, ..),
      None,
      Some(confirmation)
    -> {
      use Nil <- result.try(require(
        candidate == confirmation.best
          && against == state.seed
          && confirmation.acceptance == None
          && basis == verdict.OnConfirm
          && verdict.consistent(acceptance, basis, disposition),
        "a confirm judgement pairs the best against the seed once",
      ))

      Ok(
        State(
          ..state,
          confirmation: Some(
            Confirmation(..confirmation, acceptance: Some(acceptance)),
          ),
        ),
      )
    }

    Judged(..), None, None -> Error("search row missing: the step's rows")
    Seeded(..), _, _
    | Evaluated(..), _, _
    | Reflected(..), _, _
    | Minted(..), _, _
    | Refused(..), _, _
    | Stopped(..), _, _
    -> Error("not a judgement row")
  }
}

/// Closes a step with its disposition, checking the evaluations the
/// disposition presupposes are in the log. A disposition that needs an
/// evaluation the log does not hold is a deleted row, and the search
/// refuses to continue over it.
fn settle(
  state: State,
  progress: Progress,
  candidate: String,
  basis: Basis,
  acceptance: Acceptance,
  disposition: Disposition,
) -> Result(State, String) {
  // A disposition is what `dispose` makes of its acceptance, and a row
  // that claims otherwise was not written by the search.
  use Nil <- result.try(require(
    verdict.consistent(acceptance, basis, disposition),
    "the disposition "
      <> verdict.disposition_name(disposition)
      <> " does not follow from its acceptance",
  ))
  use Nil <- result.try(require(
    disposition != verdict.Incumbent
      || progress.parent == state.incumbent
      || progress.against_incumbent != None,
    "search row missing: the judgement against the incumbent",
  ))

  // Each disposition names the stage the step must have reached.
  use Nil <- result.try(case disposition {
    verdict.ScreenedOut ->
      require(
        progress.reached == ChildMeasured,
        "search row missing: a screened-out child has run its minibatch and nothing more",
      )
    verdict.Incumbent
    | verdict.Joined
    | verdict.ParetoOnly
    | verdict.Discarded
    | verdict.Unsettled ->
      require(
        progress.reached == ChildValidated,
        "search row missing: the child's validate run",
      )
    verdict.Refused | verdict.Confirmed | verdict.Unconfirmed ->
      Error(
        "a step does not settle as " <> verdict.disposition_name(disposition),
      )
  })

  // Only the three joining dispositions change the pool.
  let pool = case disposition {
    verdict.Incumbent | verdict.Joined | verdict.ParetoOnly ->
      list.append(state.pool, [candidate])
    verdict.Discarded
    | verdict.Unsettled
    | verdict.ScreenedOut
    | verdict.Refused
    | verdict.Confirmed
    | verdict.Unconfirmed -> state.pool
  }

  // The incumbent changes with exactly one of them.
  let incumbent = case disposition {
    verdict.Incumbent -> candidate
    verdict.Joined
    | verdict.ParetoOnly
    | verdict.Discarded
    | verdict.Unsettled
    | verdict.ScreenedOut
    | verdict.Refused
    | verdict.Confirmed
    | verdict.Unconfirmed -> state.incumbent
  }

  Ok(
    State(
      ..state,
      members: with_disposition(state.members, candidate, disposition),
      pool:,
      incumbent:,
      open: None,
    ),
  )
}

/// The stop row ends the log, and only between steps.
fn apply_stopped(state: State, reason: StopReason) -> Result(State, String) {
  case state.open {
    None -> Ok(State(..state, stopped: Some(reason)))
    Some(_) -> Error("the search stopped inside a step")
  }
}

fn require(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

// --- the next request -------------------------------------------------------------------

/// The request the host should perform now, from the state and the
/// configuration alone, so the same state always asks for the same thing.
/// An error is a configuration the search cannot run with (no slots, a
/// front that leads nothing), never a stage the search cannot pay for:
/// that is a `Record(Stopped(Budget))`.
///
/// ## Examples
///
/// ```gleam
/// // gepa.next(gepa.start("s", components), config)
/// // == Ok(Evaluate(SeedValidate, 0, "s", config.validate, config.k, cap))
/// ```
///
pub fn next(state: State, config: Config) -> Result(Request, String) {
  // A stopped search is done; an open step is re-entered where its rows
  // reached; otherwise the next thing is decided between steps.
  case state.stopped, state.open {
    Some(_), _ -> Ok(Done)
    None, Some(progress) -> within_step(state, config, progress)
    None, None -> between_steps(state, config)
  }
}

/// Between steps: the seed's validate run first, then a stop check, then
/// a new step.
fn between_steps(state: State, config: Config) -> Result(Request, String) {
  let left = remaining(state, config)
  let design = design_of(config)

  // The seed's validate run is step 0, before any stop check: a search
  // that has not measured its baseline has nothing to stop on.
  case seed_validated(state) {
    Error(_) ->
      Ok(Evaluate(
        stage: SeedValidate,
        step: 0,
        candidate: state.seed,
        tasks: config.validate,
        trials: config.k,
        cap: budget.cap(
          remaining: left,
          hold: budget.confirm_worst_case(config.costs, design),
        ),
      ))

    Ok(Nil) -> {
      let counts =
        budget.Counts(
          steps: state.step,
          reflections: state.reflections,
          candidates: children(state),
        )

      // A reason to stop ends the search after the confirm run; none
      // means another step.
      case
        budget.stop_reason(config.limits, counts, left, config.costs, design)
      {
        Some(reason) -> confirm_or_stop(state, config, reason)
        None -> {
          use drawn <- result.map(draws(state, config, state.step + 1))

          Evaluate(
            stage: ParentMinibatch,
            step: state.step + 1,
            candidate: drawn.parent,
            tasks: drawn.tasks,
            trials: config.k_tune,
            cap: budget.cap(
              remaining: left,
              hold: budget.held_back(
                config.costs,
                design,
                budget.BeforeParentMinibatch,
              ),
            ),
          )
        }
      }
    }
  }
}

/// At a stop: the confirm run if there is a best to confirm and the
/// budget still covers it, its judgement once it has run, and then the
/// stop row.
fn confirm_or_stop(
  state: State,
  config: Config,
  reason: StopReason,
) -> Result(Request, String) {
  let left = remaining(state, config)
  let design = design_of(config)

  // Nothing to confirm, a run to start, a run to judge, or a judged run.
  case state.incumbent == state.seed, state.confirmation {
    True, _ -> Ok(Record(Stopped(reason)))

    False, None ->
      // A confirm run the search can no longer cover is not started; the
      // host's headline then says the budget, not the evidence, left it
      // unconfirmed.
      case
        budget.confirm_affordable(remaining: left, costs: config.costs, design:)
      {
        True ->
          Ok(Evaluate(
            stage: Confirm,
            step: state.step,
            candidate: state.incumbent,
            tasks: config.validate,
            trials: config.k,
            cap: left,
          ))
        False -> Ok(Record(Stopped(reason)))
      }

    False, Some(Confirmation(best:, ref:, acceptance: None)) -> {
      let seed_scores = confirm_scores(state, state.seed)
      let best_scores = confirm_scores(state, best)
      let found = judged(config, seed_scores, best_scores)

      Ok(
        Record(Judged(
          candidate: best,
          against: state.seed,
          basis: verdict.OnConfirm,
          acceptance: found,
          disposition: verdict.confirm(found),
          ref:,
        )),
      )
    }

    False, Some(Confirmation(acceptance: Some(_), ..)) ->
      Ok(Record(Stopped(reason)))
  }
}

/// Inside a step: the stage after the one the rows reached.
fn within_step(
  state: State,
  config: Config,
  progress: Progress,
) -> Result(Request, String) {
  use drawn <- result.try(draws(state, config, progress.step))
  use Nil <- result.try(require(
    drawn.parent == progress.parent,
    "on resume the step drew parent "
      <> drawn.parent
      <> " but the log holds "
      <> progress.parent,
  ))
  let left = remaining(state, config)
  let design = design_of(config)

  // Each stage reached names the next request.
  case progress.reached, progress.child {
    ParentMeasured, _ ->
      // A parent at the ceiling leaves a reflection nothing to improve, so
      // the step ends here at no cost rather than paying to be told so.
      case
        select.perfect(
          minibatch_scores(state, progress.parent, progress.step),
          drawn.tasks,
        )
      {
        True ->
          Ok(
            Record(Refused(
              step: progress.step,
              candidate: None,
              reason: skipped_perfect_reason,
            )),
          )
        False -> reflect_or_refuse(state, config, progress, drawn)
      }

    ReflectedOnce, _ -> reflect_or_refuse(state, config, progress, drawn)

    ChildMinted, Some(child) ->
      Ok(Evaluate(
        stage: ChildMinibatch,
        step: progress.step,
        candidate: child,
        tasks: drawn.tasks,
        trials: config.k_tune,
        cap: budget.cap(
          remaining: left,
          hold: budget.held_back(
            config.costs,
            design,
            budget.BeforeChildMinibatch,
          ),
        ),
      ))

    ChildMeasured, Some(child) ->
      // A failed screen is recorded as a minibatch judgement that claims
      // nothing; a passed one pays for validate.
      case
        select.screen(
          minibatch_scores(state, progress.parent, progress.step),
          minibatch_scores(state, child, progress.step),
          drawn.tasks,
        )
      {
        select.Failed ->
          Ok(
            Record(Judged(
              candidate: child,
              against: progress.parent,
              basis: verdict.OnMinibatch,
              acceptance: verdict.Incomplete,
              disposition: verdict.ScreenedOut,
              ref: "",
            )),
          )
        select.Passed ->
          Ok(Evaluate(
            stage: Validate,
            step: progress.step,
            candidate: child,
            tasks: config.validate,
            trials: config.k,
            cap: budget.cap(
              remaining: left,
              hold: budget.held_back(
                config.costs,
                design,
                budget.BeforeValidate,
              ),
            ),
          ))
      }

    ChildValidated, Some(child) ->
      Ok(Record(judge_child(state, config, progress, child)))

    ChildMinted, None | ChildMeasured, None | ChildValidated, None ->
      Error("search row missing: the child's candidate row")
  }
}

/// The reflection, when its worst case is covered; otherwise a zero-cost
/// reflection row and then the refusal, so the step's rows keep the order
/// the fold expects.
fn reflect_or_refuse(
  state: State,
  config: Config,
  progress: Progress,
  drawn: Draws,
) -> Result(Request, String) {
  use parent <- result.try(member_of(state, progress.parent))
  let left = remaining(state, config)

  // The call is made only when it and every stage after it are still
  // covered; a second reflection of a resumed step is held to the same.
  case
    budget.reflection_affordable(
      remaining: left,
      costs: config.costs,
      design: design_of(config),
    ),
    progress.reached
  {
    True, _ ->
      Ok(Reflect(
        step: progress.step,
        parent: progress.parent,
        slot: drawn.slot,
        request: prompt.Request(
          objective: config.objective,
          slot: drawn.slot,
          current: result.unwrap(
            list.key_find(parent.components, drawn.slot),
            "",
          ),
          records: records(state, config, progress, drawn.slot),
          notes: option.values([
            option.from_result(list.key_find(config.background, drawn.slot)),
          ]),
          tried: tried(state, progress, drawn.slot),
        ),
        worst_case: config.costs.reflection,
      ))

    False, ParentMeasured ->
      Ok(
        Record(Reflected(
          step: progress.step,
          cost: 0.0,
          ref: "",
          finish: Unknown,
        )),
      )

    False, ReflectedOnce
    | False, ChildMinted
    | False, ChildMeasured
    | False, ChildValidated
    ->
      Ok(
        Record(Refused(
          step: progress.step,
          candidate: None,
          reason: "budget: the search cannot cover a reflection's worst case",
        )),
      )
  }
}

/// The reflective dataset: the parent's minibatch scores at this step,
/// each shown through the host's evidence view for the slot, with the
/// task's hidden identifiers.
fn records(
  state: State,
  config: Config,
  progress: Progress,
  slot: String,
) -> List(prompt.Record) {
  state.evaluations
  |> list.filter(fn(evaluation) {
    evaluation.stage == ParentMinibatch
    && evaluation.step == progress.step
    && evaluation.candidate == progress.parent
  })
  |> list.flat_map(fn(evaluation) { evaluation.measured })
  |> list.filter(fn(measured) { measured.candidate == progress.parent })
  |> list.flat_map(fn(measured) { measured.scores })
  |> list.map(fn(score) {
    prompt.Record(
      task: score.task,
      score: score.value,
      fields: config.evidence(slot, score),
      hidden: result.unwrap(list.key_find(config.hidden, score.task), []),
    )
  })
}

/// The digest of rewrites of `slot` this lineage already tried and did
/// not keep: the children of the parent and of its ancestors that were
/// refused, screened out or shown harmed in that slot, oldest first, the
/// last `prompt.max_tried` of them. A child whose answer was refused
/// before minting left no text and is not in it; one shown inconclusive or
/// left unsettled was not rejected and is not either. Deterministic over
/// the log, so a resumed step renders the same digest.
fn tried(state: State, progress: Progress, slot: String) -> List(prompt.Tried) {
  let ancestors = lineage(state, progress.parent)

  state.members
  |> list.filter(fn(member) {
    member.slot == Some(slot)
    && option.map(member.parent, list.contains(ancestors, _)) == Some(True)
  })
  |> list.filter_map(fn(member) {
    // Only a rejection counts: a refusal, a failed screen or a harm.
    case member.disposition {
      Some(verdict.Refused)
      | Some(verdict.ScreenedOut)
      | Some(verdict.Discarded) ->
        Ok(prompt.Tried(
          step: member.step,
          outcome: verdict.disposition_name(option.unwrap(
            member.disposition,
            verdict.Refused,
          )),
          text: result.unwrap(list.key_find(member.components, slot), ""),
        ))
      Some(verdict.Incumbent)
      | Some(verdict.Joined)
      | Some(verdict.ParetoOnly)
      | Some(verdict.Unsettled)
      | Some(verdict.Confirmed)
      | Some(verdict.Unconfirmed)
      | None -> Error(Nil)
    }
  })
  |> last(prompt.max_tried)
}

/// A candidate and its ancestors up to the seed, nearest first.
fn lineage(state: State, candidate: String) -> List(String) {
  // Each member names its parent; the walk ends at the seed, which has
  // none, or at an id the log does not hold.
  case member_of(state, candidate) {
    Ok(Member(parent: Some(parent), ..)) -> [
      candidate,
      ..lineage(state, parent)
    ]
    Ok(Member(parent: None, ..)) | Error(_) -> [candidate]
  }
}

/// The last `count` elements of a list, in order.
fn last(items: List(a), count: Int) -> List(a) {
  list.drop(items, int.max(list.length(items) - count, 0))
}

/// The settling judgement of a validated child: against the incumbent
/// first when the parent is not it, then against the parent.
fn judge_child(
  state: State,
  config: Config,
  progress: Progress,
  child: String,
) -> Event {
  let child_scores = validate_scores(state, child)

  // The incumbent comparison exists only when the parent is not the
  // incumbent, and is recorded before the settling row.
  case progress.parent == state.incumbent, progress.against_incumbent {
    False, None ->
      Judged(
        candidate: child,
        against: state.incumbent,
        basis: verdict.OnValidate,
        acceptance: judged(
          config,
          validate_scores(state, state.incumbent),
          child_scores,
        ),
        disposition: verdict.Unsettled,
        ref: "",
      )

    True, _ | False, Some(_) -> {
      let against_parent =
        judged(config, validate_scores(state, progress.parent), child_scores)
      let leaders =
        select.front(
          list.append(
            list.map(state.pool, fn(id) { #(id, validate_scores(state, id)) }),
            [#(child, child_scores)],
          ),
          config.validate,
          config.k,
        )
      let led = fn(id: String) {
        list.find(leaders, fn(leader) { leader.candidate == id })
        |> result.map(fn(leader) { leader.tasks_led })
        |> result.unwrap(0)
      }

      Judged(
        candidate: child,
        against: progress.parent,
        basis: verdict.OnValidate,
        acceptance: against_parent,
        disposition: verdict.dispose(
          against_parent,
          progress.against_incumbent,
          led(child),
          led(state.incumbent),
        ),
        ref: "",
      )
    }
  }
}

/// The host's acceptance over the validate pairs, or `Incomplete` when a
/// task is missing on either side, so the judge never sees a hole.
fn judged(
  config: Config,
  baseline: List(#(String, Float)),
  candidate: List(#(String, Float)),
) -> Acceptance {
  let paired = judge.pairs(config.validate, baseline, candidate)

  // Fewer pairs than tasks is a hole, not a smaller design.
  case list.length(paired) == list.length(config.validate) {
    True -> config.judge(paired)
    False -> verdict.Incomplete
  }
}

/// The step's parent, minibatch and slot, from the pool as it stands and a
/// generator seeded by the search id and the step.
fn draws(state: State, config: Config, step: Int) -> Result(Draws, String) {
  let leaders =
    select.front(
      list.map(state.pool, fn(id) { #(id, validate_scores(state, id)) }),
      config.validate,
      config.k,
    )
  let generator = prng.from_string(config.id <> "/" <> int.to_string(step))

  use #(parent, generator) <- result.try(
    select.draw_parent(leaders, generator)
    |> result.replace_error(
      "the front leads no task, so no parent can be drawn",
    ),
  )
  let #(tasks, _generator) =
    select.minibatch(config.tune, config.minibatch, generator)
  use slot <- result.map(
    select.slot_for(step, config.slots)
    |> result.replace_error("the mutable set is empty"),
  )

  Draws(parent:, tasks:, slot:)
}

/// The design the configuration describes, the minibatch clamped to the
/// tune split.
fn design_of(config: Config) -> Design {
  budget.Design(
    validate_tasks: list.length(config.validate),
    minibatch_tasks: int.min(config.minibatch, list.length(config.tune)),
    trials: config.k,
    tune_trials: config.k_tune,
  )
}

/// What the search has left.
fn remaining(state: State, config: Config) -> Float {
  budget.remaining(config.limits, spent: spent(state))
}

// --- minting a child ----------------------------------------------------------------------

/// The event an answer earns in the open step: `Minted` with the id
/// `id_of` gives the child's components, or `Refused` when the answer
/// was refused, was reported `Truncated` by the `Reflected` row before it,
/// or reproduces a candidate the search already holds.
///
/// ## Examples
///
/// ```gleam
/// // gepa.admit(state, "slot", Ok("new text"), gepa.content_id) -> Ok(Minted(..))
/// // gepa.admit(state, "slot", Error("the reflector answered nothing"), gepa.content_id) -> Ok(Refused(..))
/// ```
///
pub fn admit(
  state: State,
  slot: String,
  answer: Result(String, String),
  id_of: fn(List(#(String, String))) -> String,
) -> Result(Event, String) {
  use progress <- result.try(option.to_result(
    state.open,
    "search row missing: the parent minibatch run that opens the step",
  ))
  use parent <- result.try(member_of(state, progress.parent))

  // A refused or truncated answer ends the step with no candidate; a good
  // one mints the child unless the search already holds it.
  case answer, progress.finish {
    Error(reason), _ ->
      Ok(Refused(step: progress.step, candidate: None, reason:))
    Ok(_), Some(Truncated) ->
      Ok(Refused(step: progress.step, candidate: None, reason: truncated_reason))
    Ok(text), Some(Complete) | Ok(text), Some(Unknown) | Ok(text), None -> {
      let components = child_components(parent.components, slot, text)
      let candidate = id_of(components)

      // An answer that reproduces a candidate already in the search mints
      // nothing new; the log would refuse the id twice.
      case
        list.any(state.members, fn(member) { member.candidate == candidate })
      {
        True ->
          Ok(Refused(
            step: progress.step,
            candidate: None,
            reason: "the reflection reproduced candidate " <> candidate,
          ))
        False ->
          Ok(Minted(
            candidate:,
            parent: progress.parent,
            step: progress.step,
            slot:,
            text:,
          ))
      }
    }
  }
}

/// The parent's components with one slot replaced, sorted by name.
///
/// ## Examples
///
/// ```gleam
/// assert gepa.child_components([#("a", "x")], "b", "y") == [#("a", "x"), #("b", "y")]
/// ```
///
pub fn child_components(
  components: List(#(String, String)),
  slot: String,
  text: String,
) -> List(#(String, String)) {
  sorted(list.key_set(components, slot, text))
}

/// A content id for a candidate: 128 bits of salted FNV-1a over the
/// sorted components, as 32 hex characters. Enough to tell the candidates
/// of one search apart; a host with a stronger hash should use its own.
///
/// ## Examples
///
/// ```gleam
/// assert string.length(gepa.content_id([#("a", "x")])) == 32
/// assert gepa.content_id([#("a", "x")]) == gepa.content_id([#("a", "x")])
/// ```
///
pub fn content_id(components: List(#(String, String))) -> String {
  let canonical =
    sorted(components)
    |> list.map(fn(component) {
      int.to_string(string.length(component.0))
      <> ":"
      <> component.0
      <> int.to_string(string.length(component.1))
      <> ":"
      <> component.1
    })
    |> string.concat

  ["0:", "1:", "2:", "3:"]
  |> list.map(fn(salt) { hex32(prng.fnv1a(salt <> canonical)) })
  |> string.concat
}

/// A 32-bit word as eight lowercase hex digits.
fn hex32(word: Int) -> String {
  string.pad_start(string.lowercase(int.to_base16(word)), 8, "0")
}

// --- reading the state ------------------------------------------------------------------

/// A candidate's validate scores: from its validate run, or the seed's.
/// Empty before it has one.
///
/// ## Examples
///
/// ```gleam
/// // gepa.validate_scores(state, "child") == [#("t1", 1.0), #("t2", 0.5)]
/// ```
///
pub fn validate_scores(
  state: State,
  candidate: String,
) -> List(#(String, Float)) {
  scores_at(state, candidate, fn(evaluation) {
    { evaluation.stage == Validate || evaluation.stage == SeedValidate }
    && evaluation.candidate == candidate
  })
}

/// A candidate's minibatch scores at a step, from its parent or child
/// minibatch run there. Empty before it has one.
///
/// ## Examples
///
/// ```gleam
/// // gepa.minibatch_scores(state, "child", 3) == [#("t7", 0.0)]
/// ```
///
pub fn minibatch_scores(
  state: State,
  candidate: String,
  step: Int,
) -> List(#(String, Float)) {
  scores_at(state, candidate, fn(evaluation) {
    {
      evaluation.stage == ParentMinibatch || evaluation.stage == ChildMinibatch
    }
    && evaluation.step == step
    && evaluation.candidate == candidate
  })
}

/// A candidate's scores from the confirm run.
fn confirm_scores(state: State, candidate: String) -> List(#(String, Float)) {
  scores_at(state, candidate, fn(evaluation) { evaluation.stage == Confirm })
}

/// The scores of a candidate in the last evaluation `wanted` admits.
fn scores_at(
  state: State,
  candidate: String,
  wanted: fn(Evaluation) -> Bool,
) -> List(#(String, Float)) {
  state.evaluations
  |> list.filter(wanted)
  |> list.last
  |> result.map(fn(evaluation) {
    evaluation.measured
    |> list.filter(fn(measured) { measured.candidate == candidate })
    |> list.flat_map(fn(measured) { measured.scores })
    |> list.map(fn(score) { #(score.task, score.value) })
  })
  |> result.unwrap([])
}

/// Whether a float is a number and not infinite: the one float that is
/// not zero when subtracted from itself is one the search must never
/// record, since no arithmetic over it decides anything and the log
/// could not spell it the same on both targets.
///
/// ## Examples
///
/// ```gleam
/// assert gepa.is_finite(1.5)
/// assert !gepa.is_finite(1.0e308 *. 10.0)
/// ```
///
pub fn is_finite(value: Float) -> Bool {
  value -. value == 0.0
}

/// What the search has spent: evaluations and reflections together.
///
/// ## Examples
///
/// ```gleam
/// assert gepa.spent(gepa.start("s", [])) == 0.0
/// ```
///
pub fn spent(state: State) -> Float {
  state.spent_evaluating +. state.spent_reflecting
}

/// How many children the search has minted.
///
/// ## Examples
///
/// ```gleam
/// assert gepa.children(gepa.start("s", [])) == 0
/// ```
///
pub fn children(state: State) -> Int {
  list.count(state.members, fn(member) { member.parent != None })
}
