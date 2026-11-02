//// The daemon's side of a project's verdicts: what the board says about a
//// rule, which recorded triggers still want a label, and how a verdict run
//// becomes an event.
////
//// The measurement itself is pure and lives in `project/tape`,
//// `project/judge` and `project/standing`, where it is tested on both
//// targets. This module only reads a state, calls them, and shapes the
//// answers as the JSON the wire and the board carry. It holds no process and
//// writes nothing: it returns the `VerdictRecorded` event and the owner's
//// reply, and the project actor, which is the only writer of the ledger,
//// commits the event.
////
//// ## The two lanes
////
//// `Replay` runs every labelled trigger through the gate as the code stands
//// and serves the router's recorded answers. It is the lane for a change to
//// the gate, the admission table or the engine, spends no model call, and
//// says nothing about the router's prompt or model. It finishes inside
//// `start`.
////
//// `Live` asks a `project_judge.Judge` for the router's choice, several times
//// per trigger. The judge opens a scratch session of the router's prompt and
//// model that feeds nothing to the project (`client/project_judge_session`),
//// and answering takes minutes and real spend, so `start` does not wait for
//// it. It returns a `Plan` that the project actor runs off its own process,
//// and the actor brings the measured samples back to `conclude`.
////
//// ## Flow
////
//// `standing_json` → `to_label_json` → `start` → `conclude`
////
//// 1. `standing_json` is what the board shows for a rule: the standing word,
////    a sentence, and the labelled count against what a verdict needs.
//// 2. `to_label_json` lists the recorded triggers of a rule that a person has
////    not yet judged, so labelling has something to read.
//// 3. `start` records the rule's tape from the state with each trigger's
////    text. A replay lane takes its samples at once and returns the event
////    that records the finding, pinned to the policy version, router prompt
////    and model in force, with the reply body. A live lane returns the plan.
//// 4. `conclude` turns a live plan and the samples measured for it into the
////    same event and reply, unless the pin moved while the run went.

import client/project_judge.{type Judge, type Measured, type Spend}
import core/json.{type JsonValue}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/event.{type Event}
import project/gate
import project/judge
import project/model.{type RuleId, type SourceId, type TriggerId}
import project/standing
import project/state.{type State}
import project/tape

/// The most characters of a trigger's text the label list shows.
const label_text_limit = 600

/// Which lane a verdict run takes.
pub type Lane {
  /// Recorded triggers through the current gate, with the router's recorded
  /// answers served back.
  ReplayLane

  /// Recorded triggers put to a router, `judge.live_trials` times each.
  LiveLane(
    /// How one trial is decided and what bounds the run.
    judge: Judge,
  )
}

/// What `start` made of a run.
pub type Started {
  /// The run finished inside `start`: the event that records it and the reply.
  Recorded(
    /// The `VerdictRecorded` event.
    event: Event,
    /// The owner's reply.
    body: JsonValue,
  )

  /// The run needs the model. The caller runs the plan and hands what it
  /// measured to `conclude`.
  Measuring(
    /// What to run.
    plan: Plan,
  )
}

/// A live run that has been checked and not yet run. It holds the tape's
/// labelled frames, copied out of the state at the moment the run began, so
/// the trials measure the triggers as they stood then and not as later events
/// change them.
pub type Plan {
  Plan(
    /// The source.
    source: SourceId,
    /// The rule.
    rule: RuleId,
    /// The labelled triggers, in the tape's order, each with its label.
    work: List(#(tape.Frame, model.Label)),
    /// How to decide a trial and what bounds the run.
    judge: Judge,
    /// The pin in force when the run began. A verdict is recorded under the
    /// pin in force when it ends, so a run that spans a change of prompt or
    /// model measured the wrong thing and is refused.
    pin: model.Pin,
  )
}

/// Where a rule stands on its verdict, as the board's rule list carries it:
/// the standing word, a sentence, and the labelled count against what is
/// needed.
///
/// ## Examples
///
/// ```gleam
/// // project_verdict.standing_json(engine, source, rule)
/// ```
pub fn standing_json(
  current: State,
  source: SourceId,
  rule: RuleId,
) -> JsonValue {
  let found = standing.of(current, source, rule)
  let labelled = state.labelled(current, source, rule)
  json.Object([
    #("state", json.String(standing.word(found))),
    #("words", json.String(standing.words(found, labelled))),
    #("labelled", json.Int(labelled)),
    #("needed", json.Int(judge.needed_labels)),
    #("lane", lane_json(found)),
  ])
}

/// The lane of the verdict a standing describes, or null when none was run.
fn lane_json(found: standing.Standing) -> JsonValue {
  case found {
    standing.Unmeasured -> json.Null
    standing.Failing(covers) -> json.String(lane_word(covers.lane))
    standing.Stale(covers, _) -> json.String(lane_word(covers.lane))
    standing.ReplayOnly(covers) -> json.String(lane_word(covers.lane))
    standing.Current(covers) -> json.String(lane_word(covers.lane))
  }
}

fn lane_word(lane: model.Lane) -> String {
  case lane {
    model.Replay -> "replay"
    model.Live -> "live"
  }
}

/// The recorded triggers of a rule that still want a label, newest first, with
/// the labelled count against what is needed. A person labels from this list.
/// The text is external and the caller passes it through untouched.
///
/// ## Examples
///
/// ```gleam
/// // project_verdict.to_label_json(engine, source, rule, fn(_) { "" }, 10)
/// ```
pub fn to_label_json(
  current: State,
  source: SourceId,
  rule: RuleId,
  text_of: fn(TriggerId) -> String,
  limit: Int,
) -> JsonValue {
  let found = tape.record(current, source, rule, text_of)
  let unlabelled =
    found.frames
    |> list.filter(fn(frame) { !dict.has_key(current.labels, frame.trigger.id) })
    |> list.reverse
    |> list.take(limit)

  json.Object([
    #("rule", json.String(rule.value)),
    #("labelled", json.Int(state.labelled(current, source, rule))),
    #("needed", json.Int(judge.needed_labels)),
    #("triggers", json.Array(list.map(unlabelled, frame_json))),
  ])
}

/// One trigger awaiting a label, with its text cut. The text is external and
/// is passed on untouched for the client to make safe.
fn frame_json(frame: tape.Frame) -> JsonValue {
  json.Object([
    #("trigger", json.String(frame.trigger.id.value)),
    #("actor", json.String(frame.trigger.actor.value)),
    #("text", json.String(string.slice(frame.text, 0, label_text_limit))),
    #("recorded", json.String(recorded_word(frame.recorded))),
    #("at_ms", json.Int(frame.trigger.at_ms)),
  ])
}

/// The wire word for what the project did with a recorded trigger.
fn recorded_word(recorded: tape.Recorded) -> String {
  case recorded {
    tape.Took -> "took"
    tape.Declined -> "declined"
    tape.NotAsked -> "not_asked"
  }
}

/// Begin a verdict for one rule. A replay run finishes here, and `Recorded`
/// carries the event that records it and the reply body. A live run is checked
/// and returned as a `Plan`, with nothing spent. `Error` is a sentence for the
/// owner, and it comes before any model call: too few labels is refused
/// whichever lane was asked for.
///
/// ## Examples
///
/// ```gleam
/// // project_verdict.start(engine, source, rule, ReplayLane, fn(_) { "" })
/// ```
pub fn start(
  current: State,
  source: SourceId,
  rule: RuleId,
  lane: Lane,
  text_of: fn(TriggerId) -> String,
) -> Result(Started, String) {
  let found = tape.record(current, source, rule, text_of)

  // The lane picks where the candidate's decisions come from: the current gate
  // with recorded router answers, which is known now, or the caller's router,
  // which is not.
  case lane {
    ReplayLane -> {
      let samples = judge.replay_samples(found, current.labels, gate.classify)
      use finding <- result.map(finish(rule, samples, model.Replay))
      let #(recorded, body) = recording(current, source, rule, finding, None)
      Recorded(recorded, body)
    }
    LiveLane(chosen) -> {
      let work = judge.labelled_frames(found, current.labels)

      // The labels are checked before the plan exists, so a run that cannot be
      // measured costs nothing and says why. That covers a label set with no
      // accept or no reject, which no router could pass.
      use Nil <- result.map(usable(rule, list.map(work, fn(entry) { entry.1 })))
      Measuring(Plan(
        source:,
        rule:,
        work:,
        judge: chosen,
        pin: state.pin_of(current),
      ))
    }
  }
}

/// The samples of a live run, measured for `plan`, as the event that records
/// them and the reply body. A run that began under a pin the engine no longer
/// holds is refused: the model that was measured is not the model the pair now
/// runs, and a pass recorded under the new pin would claim it was.
///
/// ## Examples
///
/// ```gleam
/// // project_verdict.conclude(engine, plan, measured)
/// ```
pub fn conclude(
  current: State,
  plan: Plan,
  measured: Measured,
) -> Result(#(Event, JsonValue), String) {
  // The pin in force now must be the one the run began under, or the samples
  // measured a router the pair no longer runs.
  case state.pin_of(current) == plan.pin {
    False ->
      Error(
        "The router's prompt or model changed while the run was going, so what it measured is not what the router now runs. Run the verdict again.",
      )
    True -> {
      use finding <- result.map(finish(plan.rule, measured.samples, model.Live))
      recording(current, plan.source, plan.rule, finding, Some(measured))
    }
  }
}

/// A finding for the samples, or a sentence when they are too few.
fn finish(
  rule: RuleId,
  samples: List(judge.Sample),
  which: model.Lane,
) -> Result(judge.Finding, String) {
  judge.judge(samples, which)
  |> result.map_error(refusal_words(rule, _))
}

/// Whether the labels can be judged, and the sentence if not.
fn usable(rule: RuleId, labels: List(model.Label)) -> Result(Nil, String) {
  judge.check_labels(labels)
  |> result.map_error(refusal_words(rule, _))
}

/// A refusal as a sentence for the owner. It records nothing.
fn refusal_words(rule: RuleId, refusal: judge.Refusal) -> String {
  case refusal {
    judge.NotEnoughLabels(have, need) -> not_enough(rule, have, need)
    judge.MissingLabelClass(missing:) -> missing_class(rule, missing)
  }
}

/// A label set with no trigger of one kind cannot show the router apart from
/// one that always gives the other answer, so the owner is told which kind to
/// add before a run is spent on it.
fn missing_class(rule: RuleId, missing: model.Label) -> String {
  let #(kind, other) = case missing {
    model.ShouldAccept -> #("accept", "declines every trigger")
    model.ShouldNotAccept -> #("reject", "takes every trigger on")
  }
  "rule "
  <> rule.value
  <> " has no trigger labelled "
  <> kind
  <> ". A router that "
  <> other
  <> " would agree with every label it has, so a verdict could not tell it from a good one. Label at least one trigger "
  <> kind
  <> " before running a verdict."
}

/// Too few labels is a sentence for the owner and records nothing.
fn not_enough(rule: RuleId, have: Int, need: Int) -> String {
  "rule "
  <> rule.value
  <> " has "
  <> int.to_string(have)
  <> " of "
  <> int.to_string(need)
  <> " labelled triggers. Label "
  <> int.to_string(need - have)
  <> " more before running a verdict."
}

/// The event that records a finding, pinned to the policy version, router
/// prompt and model in force, and the owner's reply.
fn recording(
  current: State,
  source: SourceId,
  rule: RuleId,
  finding: judge.Finding,
  measured: Option(Measured),
) -> #(Event, JsonValue) {
  let recorded =
    event.VerdictRecorded(
      source,
      rule,
      state.pin_of(current),
      finding.outcome,
      finding.covers,
    )
  #(recorded, report_json(rule, finding, measured))
}

/// The owner's reply to a verdict run: the outcome, the lane, what was
/// covered, the candidate's agreement with the labels, and the sentence saying
/// what a pass claims or why the run failed. A live run adds what it spent. It
/// carries no trigger text.
fn report_json(
  rule: RuleId,
  finding: judge.Finding,
  measured: Option(Measured),
) -> JsonValue {
  let covers = finding.covers

  // A pass says what it rules out, and a failure says what did not hold. The
  // claim of a pass would be false about a failure.
  let words = case finding.outcome {
    model.VerdictPassed -> standing.claim(covers)
    model.VerdictFailed -> standing.failure(finding)
  }

  // Only a live run spent anything.
  let spent = case measured {
    None -> []
    Some(found) -> [
      #("calls", json.Int(found.spend.calls)),
      #("tokens", json.Int(found.spend.tokens)),
      #("unrouted", json.Int(found.unrouted)),
    ]
  }

  json.Object(list.append(
    [
      #("rule", json.String(rule.value)),
      #("outcome", json.String(outcome_word(finding.outcome))),
      #("lane", json.String(lane_word(covers.lane))),
      #("triggers", json.Int(covers.triggers)),
      #("trials", json.Int(covers.trials)),
      #("changed", json.Int(covers.changed)),
      #("bound_points", json.Int(covers.bound_points)),
      #("agreement_points", json.Int(finding.agreement_points)),
      #("words", json.String(words)),
    ],
    spent,
  ))
}

/// What a started live run tells the owner at once: it is running, how big it
/// is, and where to read it. The finding comes later, as the rule's verdict.
///
/// ## Examples
///
/// ```gleam
/// // project_verdict.started_json(plan)
/// ```
pub fn started_json(plan: Plan) -> JsonValue {
  let triggers = list.length(plan.work)
  json.Object([
    #("rule", json.String(plan.rule.value)),
    #("lane", json.String("live")),
    #("state", json.String("running")),
    #("triggers", json.Int(triggers)),
    #("trials", json.Int(triggers * judge.live_trials)),
    #(
      "words",
      json.String(
        "A live verdict is running over "
        <> int.to_string(triggers)
        <> " labelled triggers, "
        <> int.to_string(judge.live_trials)
        <> " trials each. It records nothing until every trial is done. Read its progress and its spend on the rule's row of the board.",
      ),
    ),
  ])
}

/// The spend of a run in words, for the rule's row and the log.
///
/// ## Examples
///
/// ```gleam
/// assert project_verdict.spend_words(project_judge.Spend(90, 41_000))
///   == "90 calls and 41000 tokens"
/// ```
pub fn spend_words(spent: Spend) -> String {
  int.to_string(spent.calls)
  <> " calls and "
  <> int.to_string(spent.tokens)
  <> " tokens"
}

fn outcome_word(outcome: model.VerdictOutcome) -> String {
  case outcome {
    model.VerdictPassed -> "passed"
    model.VerdictFailed -> "failed"
  }
}

/// The lane a wire command names. A missing word is the replay lane. The live
/// lane needs a judge, which `judge` supplies when it is asked for and not
/// before, so the replay lane never builds a model's configuration.
///
/// ## Examples
///
/// ```gleam
/// assert project_verdict.lane_of(None, fn() { Error("unused") })
///   == Ok(project_verdict.ReplayLane)
/// ```
pub fn lane_of(
  word: Option(String),
  judge: fn() -> Result(Judge, String),
) -> Result(Lane, String) {
  case word {
    None | Some("replay") -> Ok(ReplayLane)
    Some("live") -> result.map(judge(), LiveLane)
    Some(_) -> Error("a lane is replay or live")
  }
}
