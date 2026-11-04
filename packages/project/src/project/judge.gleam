//// The verdict computation: labelled triggers in, the evaluation instrument's
//// finding out.
////
//// A source and rule pair may go to `auto` only with a passing verdict
//// (`project/gate.mode_allowed`). This module produces the finding that a
//// verdict records. It adds no statistic. A trigger is a task, a trial passes
//// when the decision matches the person's label, and `evalstat` compares the
//// arm that records what the project did against the arm that records what
//// the candidate does now. The decision rule, the interval and the minimum
//// detectable effect are the instrument's.
////
//// ## Two lanes, two claims
////
//// The lanes differ in where the candidate's decisions come from, and so in
//// what a pass may be taken to say.
////
//// - `replay_samples` runs each recorded trigger through a gate function and
////    serves the router's recorded answer back. It is deterministic, spends
////    nothing, and claims that the same inputs now produce these decisions.
////    It says nothing about a router prompt or model, because no router ran.
//// - `live_samples` asks a decision function, which the host backs with the
////    real router, several times for each trigger. It claims how that router
////    judged these triggers, to within the minimum detectable effect the
////    finding carries.
////
//// ## What a pass means
////
//// A trigger set of about thirty is small. The instrument's own tests find
//// that at thirty tasks with three trials each on both arms, a thirty-point
//// drop reads `Harmed` on at least 95 percent of plans and a fifteen-point
//// drop on about 40 percent. The recorded arm here is one decision per
//// trigger and not three trials, which adds noise: on this module's synthetic
//// plans a thirty-point drop reads `Harmed` on about 60 percent and a
//// fifteen-point drop on about 18 percent. The verdict alone is therefore
//// too weak to gate on. A pass also needs the instrument's interval of the
//// change in agreement to stay above a drop of `max_bound_points`, and
//// `Covers.bound_points` records how far down it reached. A pass rules out a
//// large regression to that bound and does not show parity.
////
//// Neither the verdict nor the interval says the candidate is any good. Both
//// compare it with the recorded arm, and a router that disagrees with the
//// person's labels on both arms has not regressed. A pass therefore also needs
//// the candidate's own agreement with the labels to reach
//// `min_agreement_points`, and that agreement is measured separately for the
//// triggers labelled accept and for those labelled reject, and is the lower of
//// the two. An overall share would let a router that declines everything pass
//// when most labels are rejects, so a label set with no accept, or no reject,
//// is refused before any measurement (`MissingLabelClass`).
////
//// ## Flow
////
//// `replay_samples` or `live_samples` → `judge` → `outcome_of`
////
//// 1. A sampler pairs each labelled frame of the tape with the decisions of
////    the candidate.
//// 2. `judge` refuses fewer samples than the instrument's test size, builds
////    its rows, and asks it for a verdict.
//// 3. `outcome_of` turns the instrument's verdict into a pass or a fail, and
////    the finding keeps what the run covered.

import evalstat
import evalstat/paired
import evalstat/pairing
import evalstat/trial.{type Trial, Trial}
import evalstat/verdict as stat
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import project/gate.{type Admission}
import project/model.{
  type Covers, type Label, type Lane, type Trigger, type TriggerId,
  type VerdictOutcome, Covers, ShouldAccept, VerdictFailed, VerdictPassed,
}
import project/tape.{type Frame, type Tape}

/// The labelled triggers a verdict needs. The instrument's tests use thirty
/// tasks, and the claim a pass makes is only as large as that size allows.
pub const needed_labels: Int = 30

/// The trials of each trigger in the live lane.
pub const live_trials: Int = 3

/// The largest drop in agreement with the labels, in points, that a pass may
/// leave inside its interval. It is the "large regression" a pass claims to
/// rule out.
pub const max_bound_points: Int = 30

/// The least agreement with the labels, in whole points of the candidate's
/// trials, that a pass needs, in each of the two label classes.
///
/// The interval rule compares the candidate with the recorded arm, so it says
/// nothing about a router that disagrees with the person on both arms. This
/// floor is the absolute claim: at most one trial in four goes against the
/// person's label, among the triggers labelled accept and among those labelled
/// reject alike.
///
/// The value follows from the size of a run and from what is being protected.
/// A guess agrees on half the trials. A router that answers the same way every
/// time clusters its three trials, so thirty triggers give an observed
/// agreement a standard error near 9 points, and 75 is 2.7 of them above
/// guessing. Measured on synthetic plans with half the labels of each kind, a
/// router that is right 85 percent of the time passes 264 of 300 runs, and one
/// that is right 75 percent of the time passes 82. A lower floor would admit
/// routers that the person's labels say are wrong on more than one inbound
/// message in four, and `auto` acts on those messages without asking.
///
/// The floor holds per class because a router that declines everything agrees
/// with the labels as often as they are rejects, so an overall share would pass
/// it when most labels are rejects. Each class has fewer triggers than the
/// whole set, so its share is noisier than the overall one, and the lower of
/// two noisy shares is lower still: a router that is right more often than the
/// floor passes somewhat less often than it would on the overall share.
pub const min_agreement_points: Int = 75

const recorded_arm = "recorded"

const candidate_arm = "candidate"

/// A decision about one trigger, reduced to the one question a label answers.
pub type Choice {
  /// Take the trigger on as work.
  Take

  /// Do not.
  Pass
}

/// The gate's classification, as a function, so a test can plant a flipped
/// admission without editing the gate.
pub type Classify =
  fn(Trigger, gate.ThreadRelation) -> Admission

/// One labelled trigger with the decisions measured on it.
pub type Sample {
  Sample(
    /// The trigger.
    trigger: TriggerId,
    /// The person's judgement.
    label: Label,
    /// What the project did when the trigger arrived.
    recorded: Choice,
    /// What the candidate decided, one entry per trial.
    candidate: List(Choice),
  )
}

/// What a run found.
pub type Finding {
  Finding(
    /// The instrument's verdict, untouched, for the report.
    measured: stat.Verdict,
    /// Whether the pair may go to `auto`.
    outcome: VerdictOutcome,
    /// What the run covered.
    covers: Covers,
    /// The share of the candidate's trials that matched the person's label, in
    /// whole points rounded down, taken among the triggers labelled accept and
    /// among those labelled reject, and the lower of the two. It is the number
    /// `min_agreement_points` holds a pass to.
    agreement_points: Int,
  )
}

/// Why no finding was computed.
pub type Refusal {
  /// Fewer triggers are labelled than the instrument needs.
  NotEnoughLabels(
    /// The labelled triggers of the tape.
    have: Int,
    /// What `needed_labels` asks for.
    need: Int,
  )

  /// No trigger carries this label. A router that always gave the other answer
  /// would agree with every label there is, so the labels cannot tell it from a
  /// good one.
  MissingLabelClass(
    /// The label no trigger has.
    missing: Label,
  )
}

/// What the project did with a frame when it arrived.
///
/// ## Examples
///
/// ```gleam
/// // -> judge.Take for a frame whose recorded answer is `tape.Took`
/// ```
pub fn recorded_choice(frame: Frame) -> Choice {
  answer_of(frame)
}

/// What the router's recorded answer amounts to.
fn answer_of(frame: Frame) -> Choice {
  case frame.recorded {
    tape.Took -> Take
    tape.Declined | tape.NotAsked -> Pass
  }
}

/// What the current gate decides for a frame if its pair were in `auto` with
/// a current verdict, with the router's recorded answer served back. The
/// hypothetical pair is the point: a label answers whether the project
/// should take the trigger on, and the pair's present mode is not part of
/// that question.
///
/// ## Examples
///
/// ```gleam
/// // -> judge.Pass for a frame the gate does not admit
/// ```
pub fn replay_choice(frame: Frame, classify: Classify) -> Choice {
  // The gate's admission comes first: a trigger it withholds is never taken,
  // whatever the router once said about it.
  case classify(frame.trigger, frame.relation) {
    gate.NotAdmitted(_) -> Pass
    gate.Admitted(strength, _, _) -> {
      let rule =
        option.map(frame.trigger.inputs.rule, fn(matched) { matched.rule })
      let pair = gate.Pair(rule, model.Auto, gate.VerdictCurrent)

      // Only a trigger the gate lets through reaches the router, so only then
      // is the router's recorded answer served.
      case gate.acceptance(strength, pair) {
        gate.Proceed -> answer_of(frame)
        gate.RecordOnly | gate.Refuse(_) -> Pass
      }
    }
  }
}

/// The labelled frames of a tape, in the tape's order, each with its label. A
/// host that decides the candidate's answers itself, in parallel and with
/// failures, takes its work from this list and builds `Sample`s from what it
/// gets back.
///
/// ## Examples
///
/// ```gleam
/// assert judge.labelled_frames(tape.Tape(source, rule, []), dict.new()) == []
/// ```
pub fn labelled_frames(
  found: Tape,
  labels: Dict(TriggerId, Label),
) -> List(#(Frame, Label)) {
  list.filter_map(found.frames, fn(frame) {
    dict.get(labels, frame.trigger.id)
    |> result.map(fn(label) { #(frame, label) })
  })
}

/// How many triggers of the tape carry a label.
///
/// ## Examples
///
/// ```gleam
/// assert judge.labelled_count(tape.Tape(source, rule, []), dict.new()) == 0
/// ```
pub fn labelled_count(found: Tape, labels: Dict(TriggerId, Label)) -> Int {
  list.length(labelled_frames(found, labels))
}

/// The replay lane's samples: one trial per labelled trigger, decided by
/// `classify` with the router's recorded answer served back.
///
/// ## Examples
///
/// ```gleam
/// assert judge.replay_samples(tape.Tape(source, rule, []), dict.new(), gate.classify) == []
/// ```
pub fn replay_samples(
  found: Tape,
  labels: Dict(TriggerId, Label),
  classify: Classify,
) -> List(Sample) {
  sampled(found, labels, fn(frame) { [replay_choice(frame, classify)] })
}

/// The live lane's samples: `trials` decisions from `decide` for each labelled
/// trigger. `decide` receives the frame and the trial's index, and the host
/// backs it with the real router.
///
/// ## Examples
///
/// ```gleam
/// assert judge.live_samples(tape.Tape(source, rule, []), dict.new(), 3, fn(_, _) { judge.Pass }) == []
/// ```
pub fn live_samples(
  found: Tape,
  labels: Dict(TriggerId, Label),
  trials: Int,
  decide: fn(Frame, Int) -> Choice,
) -> List(Sample) {
  let count = int.max(1, trials)
  sampled(found, labels, fn(frame) {
    indexes(count)
    |> list.map(fn(index) { decide(frame, index) })
  })
}

/// The indexes zero to `count - 1`.
fn indexes(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index })
}

/// The labelled frames of a tape as samples, each paired with the candidate
/// decisions `decisions` gives for it. Both lanes share this, so what a lane
/// decides is the only thing that differs between them.
fn sampled(
  found: Tape,
  labels: Dict(TriggerId, Label),
  decisions: fn(Frame) -> List(Choice),
) -> List(Sample) {
  labelled_frames(found, labels)
  |> list.map(fn(entry) {
    Sample(
      trigger: { entry.0 }.trigger.id,
      label: entry.1,
      recorded: recorded_choice(entry.0),
      candidate: decisions(entry.0),
    )
  })
}

/// Measure the samples with the evaluation instrument. A trial passes when its
/// decision matches the person's label. The recorded arm repeats the one
/// decision the project made at each of the candidate's trials, so the
/// pairing is by trial index and the variance comes from the candidate alone.
///
/// ## Examples
///
/// ```gleam
/// assert judge.judge([], model.Replay) == Error(judge.NotEnoughLabels(0, 30))
/// ```
pub fn judge(samples: List(Sample), lane: Lane) -> Result(Finding, Refusal) {
  use Nil <- result.map(
    check_labels(list.map(samples, fn(each) { each.label })),
  )
  measure(samples, lane)
}

/// Whether labels can be judged: at least `needed_labels` of them, since fewer
/// than the instrument's own test size cannot say what a pass means, and at
/// least one accept and one reject, since without both the agreement floor
/// cannot tell a good router from one that always gives the other answer. A
/// host calls this before it spends anything on a run.
///
/// ## Examples
///
/// ```gleam
/// assert judge.check_labels([]) == Error(judge.NotEnoughLabels(0, 30))
/// ```
pub fn check_labels(labels: List(Label)) -> Result(Nil, Refusal) {
  let have = list.length(labels)

  // The count comes first, so a run that is short on both is told to label
  // more before it is told which kind.
  case have < needed_labels {
    True -> Error(NotEnoughLabels(have, needed_labels))
    False ->
      case
        list.contains(labels, ShouldAccept),
        list.contains(labels, model.ShouldNotAccept)
      {
        True, True -> Ok(Nil)
        False, _ -> Error(MissingLabelClass(ShouldAccept))
        True, False -> Error(MissingLabelClass(model.ShouldNotAccept))
      }
  }
}

/// The finding for enough samples: the instrument's verdict over the paired
/// rows, what the run covered, and whether the pair may go to `auto`. The
/// candidate's trials per trigger set the plan's width, so a sample with fewer
/// trials than the rest is an incomplete plan and fails.
fn measure(samples: List(Sample), lane: Lane) -> Finding {
  let trials =
    samples
    |> list.map(fn(each) { list.length(each.candidate) })
    |> list.fold(1, int.max)
  let rows = list.flat_map(samples, fn(each) { rows_of(each, trials) })
  let plan =
    pairing.plan(list.map(samples, fn(each) { each.trigger.value }), trials)
  let measured =
    evalstat.paired_verdict(
      rows,
      recorded_arm,
      candidate_arm,
      plan,
      stat.default_policy(),
    )
  let changed =
    list.count(samples, fn(each) {
      list.any(each.candidate, fn(choice) { choice != each.recorded })
    })
  let covers =
    Covers(
      lane:,
      triggers: list.length(samples),
      trials:,
      changed:,
      bound_points: bound_points(rows, plan),
    )
  let agreement_points = agreement_of(samples)
  Finding(
    measured:,
    outcome: outcome_of(measured, covers, agreement_points),
    covers:,
    agreement_points:,
  )
}

/// The share of the candidate's trials that matched the label, in whole points
/// rounded down so that a figure on the line is never counted in, taken among
/// the triggers of each label class and then the lower of the two. A class with
/// no trials agrees with nothing.
fn agreement_of(samples: List(Sample)) -> Int {
  int.min(
    class_agreement(samples, ShouldAccept),
    class_agreement(samples, model.ShouldNotAccept),
  )
}

/// The share of the candidate's trials on the triggers carrying `label` that
/// matched it.
fn class_agreement(samples: List(Sample), label: Label) -> Int {
  let trials =
    samples
    |> list.filter(fn(each) { each.label == label })
    |> list.flat_map(fn(each) { list.map(each.candidate, agrees(_, label)) })
  let matched = list.count(trials, fn(matches) { matches })

  // Integer division rounds down, which is the direction the floor wants.
  case list.length(trials) {
    0 -> 0
    total -> matched * 100 / total
  }
}

/// The rows of one trigger: the recorded arm's decision at every index, and
/// the candidate's decision at each index it made one.
fn rows_of(each: Sample, trials: Int) -> List(Trial) {
  let recorded =
    indexes(trials)
    |> list.map(fn(index) { row(each, recorded_arm, index, each.recorded) })
  let candidate =
    list.index_map(each.candidate, fn(choice, index) {
      row(each, candidate_arm, index, choice)
    })
  list.append(recorded, candidate)
}

/// One instrument row: a trial passes when the decision is the one the label
/// asks for. No row is an infrastructure fault or a timeout, so every row is
/// counted, and the cost is zero because neither lane spends here.
fn row(each: Sample, arm: String, index: Int, choice: Choice) -> Trial {
  let passed = agrees(choice, each.label)
  Trial(
    task: each.trigger.value,
    arm:,
    index:,
    reward: case passed {
      True -> 1.0
      False -> 0.0
    },
    scores: [],
    outcome: case passed {
      True -> trial.Passed
      False -> trial.VerifierFailed
    },
    cost: trial.Cost(
      tokens: 0,
      dollars: 0.0,
      turns: 0,
      tool_errors: 0,
      wall_ms: 0,
    ),
  )
}

/// Whether a decision is the one a label asks for.
fn agrees(choice: Choice, label: Label) -> Bool {
  case choice, label {
    Take, ShouldAccept -> True
    Pass, model.ShouldNotAccept -> True
    Take, model.ShouldNotAccept -> False
    Pass, ShouldAccept -> False
  }
}

/// How far down the instrument's interval of the change in agreement reaches,
/// in whole points rounded up and at most a hundred. It is a hundred when the
/// interval cannot be formed: the rows are incomplete, or fewer than two
/// triggers leave no variance. The interval is `paired.interval`, the same
/// one the verdict's `Improved` and `Harmed` clauses read.
fn bound_points(rows: List(Trial), plan: List(#(String, Int))) -> Int {
  // Pairing fails on an incomplete plan, and the standard error fails below
  // two triggers; neither leaves an interval to read.
  let lower = case pairing.pair(rows, recorded_arm, candidate_arm, plan) {
    Error(_) -> option.None
    Ok(paired) -> {
      let differences = paired.differences(paired)

      // The standard error is undefined below two triggers.
      case paired.clustered_se(differences) {
        Error(Nil) -> option.None
        Ok(se) -> option.Some(paired.interval(paired.mean(differences), se).0)
      }
    }
  }

  // An interval that stays at or above zero rules out any drop, and one that
  // cannot be formed rules out none.
  case lower {
    option.None -> 100
    option.Some(bound) if bound >=. 0.0 -> 0
    option.Some(bound) ->
      int.min(100, float.truncate(float.ceiling(float.negate(bound) *. 100.0)))
  }
}

/// Whether the instrument's verdict lets the pair go to `auto`.
///
/// A pass needs three things. The instrument must not have called the candidate
/// `Harmed` or found the rows `Incomplete`. Its interval of the change in
/// agreement with the labels must not reach below a drop of `max_bound_points`.
/// And the candidate's own agreement with the labels, `agreement_points`, which
/// is the lower of its agreement on accepts and on rejects, must reach
/// `min_agreement_points`.
///
/// The second is what lets a pass say it ruled out a large regression. The
/// verdict alone cannot say that, because `Underpowered` is the instrument's
/// answer to most plans of this size and means only that nothing was shown. On
/// the synthetic plans of the tests, passing on "not `Harmed`" would have let
/// about a third of thirty-point drops through, and with the interval rule
/// about 4 percent pass. The third is what lets a pass say the router is good,
/// which a comparison with the recorded arm cannot: a router that disagrees
/// with the labels as often as the recording did has not regressed.
///
/// ## Examples
///
/// ```gleam
/// let covers = model.Covers(model.Replay, 30, 1, 0, 0)
/// assert judge.outcome_of(stat.Underpowered(0.9, 400, "no spread"), covers, 90)
///   == model.VerdictPassed
/// ```
pub fn outcome_of(
  measured: stat.Verdict,
  covers: Covers,
  agreement_points: Int,
) -> VerdictOutcome {
  let bounded = covers.bound_points <= max_bound_points
  let agreeing = agreement_points >= min_agreement_points

  // A verdict that harmed or could not form fails whatever else holds. Of the
  // rest, only a run that is both bounded and agreeing passes.
  case measured, bounded && agreeing {
    stat.Harmed(..), _ -> VerdictFailed
    stat.Incomplete(_), _ -> VerdictFailed
    _, True -> VerdictPassed
    _, False -> VerdictFailed
  }
}
