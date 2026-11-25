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

import client/jev as transport
import client/project_jev_judge
import client/project_judge.{type Judge, type Measured, type Spend}
import client/project_settings.{type Router, JevRouter, ModelRouter}
import core/json.{type JsonValue}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/event.{type Event}
import project/gate
import project/jev_verdict
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

  /// Recorded triggers put to Jev first and to the router for what Jev leaves.
  /// The composed decider is the candidate, and the report adds what only a
  /// decider that can abstain needs reported (`project/jev_verdict`).
  JevLane(
    /// Jev's setting and the router's own decider.
    setup: project_jev_judge.Setup,
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
    /// What a Jev run reads its trials against, or none for any other.
    jev: Option(JevPlan),
  )
}

/// What a Jev run needs beyond a plain live one: what the router recorded for
/// each trigger, which `silver` compares Jev with, and the bar in force.
pub type JevPlan {
  JevPlan(
    /// What the router recorded for each labelled trigger.
    recorded: dict.Dict(TriggerId, jev_verdict.Target),
    /// The attach bar the run was made under, as a percent.
    percent: Int,
    /// Whether the finding is written to the ledger.
    recording: project_jev_judge.Recording,
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
      let #(recorded, body) =
        recording(current, source, rule, finding, None, None)
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
        jev: None,
      ))
    }
    JevLane(setup) -> {
      let work = judge.labelled_frames(found, current.labels)
      use Nil <- result.map(usable(rule, list.map(work, fn(entry) { entry.1 })))
      Measuring(Plan(
        source:,
        rule:,
        work:,
        judge: project_jev_judge.judge(setup, current),
        pin: state.pin_of(current),
        jev: Some(JevPlan(
          recorded: recorded_targets(current, work),
          percent: setup.setting.percent,
          recording: setup.recording,
        )),
      ))
    }
  }
}

/// What the router recorded for each labelled trigger. A trigger a Jev pass
/// decided is no record of the router, and so is any other fate that is not a
/// routing choice.
fn recorded_targets(
  current: State,
  work: List(#(tape.Frame, model.Label)),
) -> dict.Dict(TriggerId, jev_verdict.Target) {
  list.map(work, fn(entry) {
    let id = entry.0.trigger.id
    #(id, target_of(current, id))
  })
  |> dict.from_list
}

fn target_of(current: State, id: TriggerId) -> jev_verdict.Target {
  case state.record(current, id) {
    Error(_) -> jev_verdict.Elsewhere
    Ok(stored) -> routed_target(stored)
  }
}

/// The router's choice a stored trigger's fate records.
fn routed_target(stored: state.TriggerRecord) -> jev_verdict.Target {
  // A judgement means Jev decided it, which is not the router's record.
  case stored.judgement, stored.fate {
    option.Some(_), _ -> jev_verdict.Elsewhere
    None, state.Decided(state.Accepted(_)) -> jev_verdict.Opened
    None, state.Decided(state.Attached(ticket)) ->
      jev_verdict.AttachedTo(ticket)
    None, state.Decided(state.Resumed(ticket)) -> jev_verdict.ResumedOn(ticket)
    None, state.Decided(state.Ignored) -> jev_verdict.Ignored
    None, _ -> jev_verdict.Elsewhere
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
      recording(
        current,
        plan.source,
        plan.rule,
        finding,
        Some(measured),
        jev_report(plan, measured),
      )
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
  // The missing kind names the router that the labels could not tell from a
  // good one: the one that always gives the other answer.
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
  jev_part: Option(#(JsonValue, String)),
) -> #(Event, JsonValue) {
  let recorded =
    event.VerdictRecorded(
      source,
      rule,
      state.pin_of(current),
      finding.outcome,
      finding.covers,
    )
  #(recorded, report_json(rule, finding, measured, jev_part))
}

/// The owner's reply to a verdict run: the outcome, the lane, what was
/// covered, the candidate's agreement with the labels, and the sentence saying
/// what a pass claims or why the run failed. A live run adds what it spent. It
/// carries no trigger text.
fn report_json(
  rule: RuleId,
  finding: judge.Finding,
  measured: Option(Measured),
  jev_part: Option(#(JsonValue, String)),
) -> JsonValue {
  let covers = finding.covers

  // A pass says what it rules out, and a failure says what did not hold. The
  // claim of a pass would be false about a failure.
  let said = case finding.outcome {
    model.VerdictPassed -> standing.claim(covers)
    model.VerdictFailed -> standing.failure(finding)
  }

  // A Jev run adds its own account after the finding's, in words and as data.
  let #(words, jev_field) = case jev_part {
    Some(#(body, account)) -> #(said <> " " <> account, [#("jev", body)])
    None -> #(said, [])
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
    list.append(jev_field, spent),
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

/// What the daemon can say about Jev for a verdict: the setting in force, and
/// who decides first when the command does not say.
pub type Jev {
  Jev(
    /// The router the daemon's `[project] router` names.
    default: Router,
    /// Jev's transport, model, bar and agents.
    setting: project_jev_judge.Setting,
  )
}

/// A daemon that runs no Jev: the model is the router, and the transport has no
/// key. A test that needs a control and never measures Jev uses it.
///
/// ## Examples
///
/// ```gleam
/// assert project_verdict.jev_off().default == project_settings.ModelRouter
/// ```
pub fn jev_off() -> Jev {
  Jev(
    default: ModelRouter,
    setting: project_jev_judge.Setting(
      client: transport.client_with(None, 3000, fn(_, _, _) { Error("off") }),
      model: "jev-latest",
      percent: 80,
      agents: [],
    ),
  )
}

/// The lane a wire command names. A missing word is the replay lane. The live
/// lane needs a judge, which `judge` supplies when it is asked for and not
/// before, so the replay lane never builds a model's configuration.
///
/// `router` names who is measured, `model` or `jev`, and is the daemon's
/// setting when absent. Jev is measured live only: a replay serves the router's
/// recorded answers, and Jev has none to serve.
///
/// ## Examples
///
/// ```gleam
/// assert project_verdict.lane_of(None, None, jev, fn() { Error("unused") })
///   == Ok(project_verdict.ReplayLane)
/// ```
pub fn lane_of(
  word: Option(String),
  router: Option(String),
  jev: Jev,
  judge: fn() -> Result(Judge, String),
) -> Result(Lane, String) {
  use measured <- result.try(router_of(router, jev.default))

  // The replay lane serves recorded answers, which a Jev run has none of, and
  // it measures the gate, which neither router decides.
  case word, router, measured {
    None, _, _ | Some("replay"), None, _ -> Ok(ReplayLane)
    Some("replay"), Some("jev"), _ ->
      Error(
        "a Jev verdict is live only: a replay serves the router's recorded answers, and Jev has none. Ask for lane live.",
      )
    Some("replay"), Some(_), _ -> Ok(ReplayLane)
    Some("live"), _, ModelRouter -> live_model(jev, judge)
    Some("live"), _, JevRouter ->
      result.map(judge(), fn(router_judge) {
        JevLane(project_jev_judge.Setup(
          setting: jev.setting,
          router: router_judge,
          recording: recording_for(jev.default),
        ))
      })
    Some(_), _, _ -> Error("a lane is replay or live")
  }
}

/// The router a command names, or the daemon's.
fn router_of(word: Option(String), default: Router) -> Result(Router, String) {
  case word {
    None -> Ok(default)
    Some("model") -> Ok(ModelRouter)
    Some("jev") -> Ok(JevRouter)
    Some(_) -> Error("a router is model or jev")
  }
}

/// A Jev run's account of itself: how the trials ended, the shares at the bar
/// in force, the sweep of other bars and the comparison with the router's
/// record, as the data the reply carries and the sentences the rule's row
/// shows. Nothing in it is trigger text.
fn jev_report(plan: Plan, measured: Measured) -> Option(#(JsonValue, String)) {
  use planned <- option.map(plan.jev)
  let entries = jev_entries(plan, planned, measured)
  let counted = jev_verdict.health(entries)
  let total = counted.decided + counted.abstained + counted.failed
  let rows = jev_verdict.sweep(entries, jev_verdict.sweep_percents)
  let compared = jev_verdict.silver(entries)
  let healthy = jev_verdict.service_healthy(counted)

  let body =
    json.Object([
      #("bar_percent", json.Int(planned.percent)),
      #("trials", json.Int(total)),
      #("decided", json.Int(counted.decided)),
      #("abstained", json.Int(counted.abstained)),
      #("failed", json.Int(counted.failed)),
      #("coverage_points", json.Int(jev_verdict.points(counted.decided, total))),
      #("service_healthy", json.Bool(healthy)),
      #("sweep", json.Array(list.map(rows, sweep_json))),
      #("silver", silver_json(compared)),
      #("uncompared", json.Int(list.length(entries) - compared.compared)),
      #("models", json.Array(list.map(models_of(entries), json.String))),
    ])
  #(body, jev_words(planned.percent, counted, healthy, rows, compared))
}

/// The labelled triggers with what each trial kept, in the plan's order.
fn jev_entries(
  plan: Plan,
  planned: JevPlan,
  measured: Measured,
) -> List(jev_verdict.Entry) {
  list.zip(plan.work, measured.trials)
  |> list.map(fn(pair) {
    let #(#(frame, label), trials) = pair
    jev_verdict.Entry(
      trigger: frame.trigger.id,
      label:,
      recorded: result.unwrap(
        dict.get(planned.recorded, frame.trigger.id),
        jev_verdict.Elsewhere,
      ),
      trials: option.values(trials),
    )
  })
}

/// The distinct model names the service reported, in order of first sight.
fn models_of(entries: List(jev_verdict.Entry)) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.filter_map(entry.trials, fn(trial) {
      option.to_result(trial.model, Nil)
    })
  })
  |> list.unique
}

/// One row of the sweep as the reply carries it: the bar, the trials Jev settled
/// at it of all trials, and the agreement of the settled ones with the labels.
fn sweep_json(row: jev_verdict.Row) -> JsonValue {
  json.Object([
    #("percent", json.Int(row.percent)),
    #("decided", json.Int(row.decided)),
    #("trials", json.Int(row.trials)),
    #("coverage_points", json.Int(jev_verdict.points(row.decided, row.trials))),
    #(
      "agreement_points",
      json.Int(jev_verdict.points(row.agreeing, row.decided)),
    ),
  ])
}

/// Jev compared with the router's record as the reply carries it: the counts and
/// the disagreements, each a trigger id and two words, never trigger text.
fn silver_json(found: jev_verdict.Silver) -> JsonValue {
  json.Object([
    #("compared", json.Int(found.compared)),
    #("agreeing", json.Int(found.agreeing)),
    #(
      "agreement_points",
      json.Int(jev_verdict.points(found.agreeing, found.compared)),
    ),
    #(
      "disagreements",
      json.Array(
        list.map(found.disagreements, fn(each) {
          json.Object([
            #("trigger", json.String(each.trigger.value)),
            #("jev", json.String(each.jev)),
            #("router", json.String(each.router)),
          ])
        }),
      ),
    ),
  ])
}

/// The sentences of a Jev run's account. The shares are of trials, and the
/// agreement of a bar is of the trials Jev settled at it.
fn jev_words(
  percent: Int,
  counted: jev_verdict.Health,
  healthy: Bool,
  rows: List(jev_verdict.Row),
  compared: jev_verdict.Silver,
) -> String {
  let total = counted.decided + counted.abstained + counted.failed
  let share = fn(part) { percent_text(jev_verdict.points(part, total)) }
  let first =
    "Jev settled "
    <> share(counted.decided)
    <> " of "
    <> int.to_string(total)
    <> " trials at an attach bar of "
    <> int.to_string(percent)
    <> " percent, abstained on "
    <> share(counted.abstained)
    <> " and gave no usable answer for "
    <> share(counted.failed)
    <> case healthy {
      True -> ", which is under the service-health bar of 5 percent."
      False -> ", which is not under the service-health bar of 5 percent."
    }
  let sweep =
    "By attach bar, settled and agreeing with the labels: "
    <> string.join(
      list.map(rows, fn(row) {
        int.to_string(row.percent)
        <> "% "
        <> percent_text(jev_verdict.points(row.decided, row.trials))
        <> " and "
        <> percent_text(jev_verdict.points(row.agreeing, row.decided))
      }),
      ", ",
    )
    <> "."
  let silver =
    "Against the router's own record Jev agreed on "
    <> int.to_string(compared.agreeing)
    <> " of "
    <> int.to_string(compared.compared)
    <> " triggers it settled and the router chose for. The rest are not compared: a rule in observe records the router's accepts as would-accept, which names no ticket to compare. The tickets listed are the ones at run time, so a trigger that arrived earlier was judged against a list it did not see."
  first <> " " <> sweep <> " " <> silver
}

/// Basis points as a percent with one decimal.
fn percent_text(points: Int) -> String {
  int.to_string(points / 100)
  <> "."
  <> int.to_string({ points % 100 } / 10)
  <> "%"
}

/// A model verdict on a daemon that routes with Jev would be recorded under the
/// Jev pin, which names a decider it did not measure, so it is refused.
fn live_model(
  jev: Jev,
  judge: fn() -> Result(Judge, String),
) -> Result(Lane, String) {
  // A daemon that routes with the model records a model verdict as it always has.
  case jev.default {
    ModelRouter -> result.map(judge(), LiveLane)
    JevRouter ->
      Error(
        "this daemon routes with Jev, so a verdict of the model router would be recorded under a pin that names Jev. Set [project] router to model first, or ask for router jev.",
      )
  }
}

/// A Jev verdict is recorded only when the daemon routes with Jev, since only
/// then is the pin in force the one that names Jev.
fn recording_for(default: Router) -> project_jev_judge.Recording {
  case default {
    JevRouter -> project_jev_judge.Records
    ModelRouter -> project_jev_judge.MeasuresOnly
  }
}
