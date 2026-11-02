//// The daemon's side of a project's verdicts: what the board says about a
//// rule, which recorded triggers still want a label, and how a verdict run
//// becomes an event.
////
//// The measurement itself is pure and lives in `project/tape`,
//// `project/judge` and `project/standing`, where it is tested on both
//// targets. This module only reads a state, calls them, and shapes the
//// answers as the JSON the wire and the board carry. It holds no process and
//// writes nothing: `run` returns the `VerdictRecorded` event and the owner's
//// reply, and the project actor, which is the only writer of the ledger,
//// commits the event.
////
//// ## The two lanes
////
//// `Replay` runs every labelled trigger through the gate as the code stands
//// and serves the router's recorded answers. It is the lane for a change to
//// the gate, the admission table or the engine, spends no model call, and
//// says nothing about the router's prompt or model.
////
//// `Live` asks `decide` for the router's choice, several times per trigger.
//// The caller supplies `decide`, because answering needs a router session of
//// the same prompt and model that does not feed the project's own engine.
//// The daemon has no such scratch router today (see the addendum of
//// protocol-change/106 on verdicts), so the wire command refuses the live
//// lane in words, and a test supplies a scripted `decide` to show that the
//// lane's arithmetic is the same.
////
//// ## Flow
////
//// `run` → `project_host.commit`
////
//// 1. `run` records the rule's tape from the state, with each trigger's
////    text.
//// 2. It takes the lane's samples and asks `project/judge` for a finding.
//// 3. It returns the event that records the finding, pinned to the policy
////    version, router prompt and model in force, and the reply body.

import core/json.{type JsonValue}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
    /// The router's choice for a frame at a trial index.
    decide: fn(tape.Frame, Int) -> judge.Choice,
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

fn frame_json(frame: tape.Frame) -> JsonValue {
  json.Object([
    #("trigger", json.String(frame.trigger.id.value)),
    #("actor", json.String(frame.trigger.actor.value)),
    #("text", json.String(string.slice(frame.text, 0, label_text_limit))),
    #("recorded", json.String(recorded_word(frame.recorded))),
    #("at_ms", json.Int(frame.trigger.at_ms)),
  ])
}

fn recorded_word(recorded: tape.Recorded) -> String {
  case recorded {
    tape.Took -> "took"
    tape.Declined -> "declined"
    tape.NotAsked -> "not_asked"
  }
}

/// Run a verdict for one rule. `Ok` carries the event that records it and the
/// reply body. `Error` is a sentence for the owner: too few labels, or no
/// router to ask.
///
/// ## Examples
///
/// ```gleam
/// // project_verdict.run(engine, source, rule, ReplayLane, fn(_) { "" })
/// ```
pub fn run(
  current: State,
  source: SourceId,
  rule: RuleId,
  lane: Lane,
  text_of: fn(TriggerId) -> String,
) -> Result(#(Event, JsonValue), String) {
  let found = tape.record(current, source, rule, text_of)
  let samples = case lane {
    ReplayLane -> judge.replay_samples(found, current.labels, gate.classify)
    LiveLane(decide) ->
      judge.live_samples(found, current.labels, judge.live_trials, decide)
  }
  let which = case lane {
    ReplayLane -> model.Replay
    LiveLane(_) -> model.Live
  }

  case judge.judge(samples, which) {
    Error(judge.NotEnoughLabels(have, need)) ->
      Error(
        "rule "
        <> rule.value
        <> " has "
        <> int.to_string(have)
        <> " of "
        <> int.to_string(need)
        <> " labelled triggers. Label "
        <> int.to_string(need - have)
        <> " more before running a verdict.",
      )
    Ok(finding) -> {
      let recorded =
        event.VerdictRecorded(
          source,
          rule,
          state.pin_of(current),
          finding.outcome,
          finding.covers,
        )
      Ok(#(recorded, report_json(rule, finding)))
    }
  }
}

fn report_json(rule: RuleId, finding: judge.Finding) -> JsonValue {
  let covers = finding.covers
  json.Object([
    #("rule", json.String(rule.value)),
    #("outcome", json.String(outcome_word(finding.outcome))),
    #("lane", json.String(lane_word(covers.lane))),
    #("triggers", json.Int(covers.triggers)),
    #("trials", json.Int(covers.trials)),
    #("changed", json.Int(covers.changed)),
    #("bound_points", json.Int(covers.bound_points)),
    #("words", json.String(standing.claim(covers))),
  ])
}

fn outcome_word(outcome: model.VerdictOutcome) -> String {
  case outcome {
    model.VerdictPassed -> "passed"
    model.VerdictFailed -> "failed"
  }
}

/// The lane a wire command names. A missing word is the replay lane. The
/// live lane is refused in words until the daemon can start a scratch router.
///
/// ## Examples
///
/// ```gleam
/// assert project_verdict.lane_of(None) == Ok(project_verdict.ReplayLane)
/// ```
pub fn lane_of(word: Option(String)) -> Result(Lane, String) {
  case word {
    None | Some("replay") -> Ok(ReplayLane)
    Some("live") ->
      Error(
        "the live lane needs a scratch router session of the same prompt and model, which this daemon cannot start yet. Run the replay lane, which judges the gate and the engine and says nothing about the router.",
      )
    Some(_) -> Error("a lane is replay or live")
  }
}
