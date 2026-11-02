//// Where a source and rule pair stands on its verdict, and what to say about
//// it.
////
//// The engine decides whether a verdict is current (`project/state.verdict_of`)
//// and the gate decides what that allows. This module only reads the state to
//// answer a person's questions: is there a verdict, is it still current, what
//// did it measure, and what is missing. It is the one place that words the
//// claim a pass makes, so the board, the terminal, the web view and the
//// refusal of `auto` all say the same thing.
////
//// The claim is deliberately modest. A pass over about thirty labelled
//// triggers rules out a large drop in agreement with the labels and does not
//// show that the pair is as good as before. A replay pass says nothing about
//// a router prompt or model, because no router ran.

import gleam/dict
import gleam/int
import project/gate
import project/judge
import project/model.{type Covers, type RuleId, type SourceId}
import project/state.{type State}

/// How a pair stands.
pub type Standing {
  /// No verdict was ever recorded for the pair.
  Unmeasured

  /// The latest verdict failed.
  Failing(
    /// What it covered.
    covers: Covers,
  )

  /// The latest verdict passed under a pin that is no longer in force.
  Stale(
    /// What it covered.
    covers: Covers,
    /// Which of policy version, prompt revision and model changed.
    why: String,
  )

  /// A passing verdict under the pin in force.
  Current(
    /// What it covered.
    covers: Covers,
  )
}

/// Read a pair's standing from the state.
///
/// ## Examples
///
/// ```gleam
/// assert standing.of(state.start(config), model.SourceId("s"), model.RuleId("r"))
///   == standing.Unmeasured
/// ```
pub fn of(current: State, source: SourceId, rule: RuleId) -> Standing {
  case dict.get(current.verdicts, #(source, rule)) {
    Error(Nil) -> Unmeasured
    Ok(found) ->
      case found.outcome, state.verdict_of(current, source, rule) {
        model.VerdictFailed, _ -> Failing(found.covers)
        model.VerdictPassed, gate.VerdictCurrent -> Current(found.covers)
        model.VerdictPassed, gate.VerdictMissing ->
          Stale(found.covers, changed(found.pin, state.pin_of(current)))
      }
  }
}

/// Which parts of a pin differ, in words.
fn changed(was: model.Pin, now: model.Pin) -> String {
  let parts = [
    differs(was.policy_version != now.policy_version, "the policy version"),
    differs(was.prompt_revision != now.prompt_revision, "the router prompt"),
    differs(was.model != now.model, "the router model"),
  ]
  case list_join(parts) {
    "" -> "the pin changed"
    named -> named <> " changed since it was measured"
  }
}

fn differs(did: Bool, name: String) -> String {
  case did {
    True -> name
    False -> ""
  }
}

// The names that changed, separated by commas, skipping the empty ones.
fn list_join(parts: List(String)) -> String {
  case parts {
    [] -> ""
    [first, ..rest] ->
      case first, list_join(rest) {
        "", tail -> tail
        head, "" -> head
        head, tail -> head <> ", " <> tail
      }
  }
}

/// The word a client matches on: `none`, `failing`, `stale` or `current`.
///
/// ## Examples
///
/// ```gleam
/// assert standing.word(standing.Unmeasured) == "none"
/// ```
pub fn word(found: Standing) -> String {
  case found {
    Unmeasured -> "none"
    Failing(_) -> "failing"
    Stale(..) -> "stale"
    Current(_) -> "current"
  }
}

/// What a pass claims, for a verdict that covered `covers`.
///
/// ## Examples
///
/// ```gleam
/// let covers = model.Covers(model.Replay, 30, 1, 0, 100)
/// assert string.contains(standing.claim(covers), "nothing about the router")
/// ```
pub fn claim(covers: Covers) -> String {
  let triggers = int.to_string(covers.triggers) <> " labelled triggers"
  let size = int.to_string(covers.bound_points) <> " points"

  case covers.lane {
    model.Replay ->
      "Replay over "
      <> triggers
      <> ": "
      <> int.to_string(covers.changed)
      <> " decided differently from the recording. The same inputs give these decisions, which says nothing about the router's prompt or model. It could rule out a change of more than "
      <> size
      <> " in agreement with the labels, and not a smaller one."
    model.Live ->
      "Live over "
      <> triggers
      <> ", "
      <> int.to_string(covers.trials)
      <> " trials each: it rules out a drop of more than "
      <> size
      <> " in agreement with the labels. It does not show the router is as good as before."
  }
}

/// A pair's standing as a sentence, given how many of its triggers are
/// labelled.
///
/// ## Examples
///
/// ```gleam
/// assert standing.words(standing.Unmeasured, 12)
///   == "No verdict yet. 12 of 30 triggers are labelled."
/// ```
pub fn words(found: Standing, labelled: Int) -> String {
  case found {
    Unmeasured ->
      "No verdict yet. "
      <> int.to_string(labelled)
      <> " of "
      <> int.to_string(judge.needed_labels)
      <> " triggers are labelled."
    Failing(covers) -> "The latest verdict failed. " <> claim_of_failure(covers)
    Stale(covers, why) ->
      "Stale: "
      <> why
      <> ". The rule is back in observe until it is measured again. It last passed: "
      <> claim(covers)
    Current(covers) -> "Passing. " <> claim(covers)
  }
}

fn claim_of_failure(covers: Covers) -> String {
  int.to_string(covers.changed)
  <> " of "
  <> int.to_string(covers.triggers)
  <> " labelled triggers decided differently from the recording."
}

/// The sentence that refuses `auto` for a pair, saying what is missing. It
/// holds the labelled count against what is needed, so the owner knows
/// whether to label more or to run the check.
///
/// ## Examples
///
/// ```gleam
/// let words = standing.refusal(state.start(config), model.SourceId("s"), model.RuleId("r"))
/// assert string.contains(words, "auto is refused")
/// ```
pub fn refusal(current: State, source: SourceId, rule: RuleId) -> String {
  let labelled = state.labelled(current, source, rule)
  let missing = int.max(0, judge.needed_labels - labelled)
  let count =
    int.to_string(labelled) <> " of " <> int.to_string(judge.needed_labels)

  let next = case missing {
    0 -> "Run the verdict for this rule."
    _ ->
      "Label "
      <> int.to_string(missing)
      <> " more triggers, then run the verdict."
  }

  "auto is refused for rule "
  <> rule.value
  <> " because "
  <> case of(current, source, rule) {
    Unmeasured ->
      "no verdict has been recorded. "
      <> count
      <> " triggers are labelled. "
      <> next
    Failing(_) ->
      "its latest verdict failed. "
      <> count
      <> " triggers are labelled. Change what the rule admits or label more triggers, and run the verdict again."
    Stale(_, why) ->
      "its verdict is stale: " <> why <> ". Run the verdict again."
    Current(_) -> "of a state the engine did not expect."
  }
}
