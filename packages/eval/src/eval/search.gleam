//// Loom's side of the prompt search: the log rows `search.jsonl` holds,
//// their JSON codec, and the adapter that feeds them to the `gepa`
//// library, which owns every decision the search makes.
////
//// The library is generic over the host's world: a candidate is a map
//// from component name to text, a task an opaque id, a score a float, and
//// money whatever unit the host meters. This module is where Loom's own
//// nouns meet it. An `Arm` becomes a component map keyed by `slot_name`;
//// a sub-run's ledger becomes per-task means (`per_task_means`); a row of
//// `search.jsonl` becomes a `gepa.Event` (`to_gepa`), with the sub-plan id
//// riding as the evaluation's `ref` and an arm's components read through a
//// `Store`, because Loom's rows were written before the library existed
//// and carry neither. The on-disk format is therefore unchanged: a log
//// written before the extraction replays through the same codec and the
//// same fold.
////
//// `State` is the library's state plus the one thing Loom keeps richer:
//// the confirm run's full statistical verdict, which the headline prints
//// and the library reduces to an `Acceptance`. Everything else a reader of
//// the old `State` wanted (members, runs, the open step's plan ids) is a
//// projection of the library's state, built on request so the two cannot
//// drift. The fold is a fold of the log alone: a `Run` row becomes an
//// evaluation with no tasks, no scores and no cost, because Loom writes the
//// row before the run exists and reads the ledger from disk at every
//// decision, so a state folded while running and one replayed afterwards
//// are the same value. It follows that `gepa.next` is not the loop Loom
//// runs: `eval/optimize` orders its own effects, since each sub-run is a
//// resumable directory with a ledger and a cap the library cannot see, and
//// asks the library's pure pieces for every decision it would make.
////
//// ## Flow
////
//// - `encode_line`, `decode_line`, `parse`: the log's codec
//// - `to_gepa`, `apply`, `replay`: a row into the library's fold
//// - `members`, `runs`, `plan_of`, `recorded_cap`: Loom-shaped reads
//// - `component_map`, `per_task_means`: an arm and a ledger as the
////   library sees them
//// - `standing_of`, `acceptance_of`: Loom's verdicts as the library's
////   words
//// - `slot_name`, `verdict_json`, `decode_verdict`: the shared spellings

import core/json.{type JsonValue}
import eval/arm.{type Arm, type Component}
import eval/split.{type Split}
import eval/wire
import evalstat/dominance
import evalstat/trial as stat
import evalstat/verdict.{type Verdict}
import gepa
import gepa/budget
import gepa/select
import gepa/verdict as rule
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The log's encoding version.
pub const version = 1

/// Where a candidate came from.
pub type Source {
  /// The seed arm the operator supplied (or the empty base arm).
  Seed

  /// Minted from a parent by one reflection.
  Reflected
}

/// Which part a sub-run plays in a step.
pub type RunRole {
  /// The parent alone on the tune minibatch, to capture traces.
  ParentMinibatch

  /// The child alone on the same minibatch, for the screen.
  ChildMinibatch

  /// The child alone on the whole Validate split, for acceptance.
  ValidateRun

  /// Seed and best together on Validate: the one simultaneous comparison.
  Confirm
}

/// What a settled step did with its child.
pub type Disposition {
  /// Improved over its parent, and the pool's best by the same rule.
  Incumbent

  /// Improved over its parent; in the pool, ranked below the incumbent.
  Joined

  /// Neither improved nor harmed: a Pareto member, never ranked above its
  /// parent.
  ParetoOnly

  /// Harmed against its parent: discarded.
  Harmed

  /// The Validate run could not reach a verdict (a budget stop, an
  /// exhausted cell): discarded, the budget decides whether to go on.
  Unsettled

  /// The arm could not be applied, or the reflector's answer was refused.
  Refused

  /// Below its parent on the tune minibatch: never paid for.
  ScreenedOut

  /// The confirm run found the best `Improved` over the seed.
  Confirmed

  /// The confirm run did not: the headline says "not confirmed".
  Unconfirmed
}

/// Why a search stopped.
pub type StopReason {
  /// `max_steps` steps were taken.
  Steps

  /// The next step's worst case did not fit the remaining dollars.
  Dollars

  /// `max_reflections` reflections were made.
  Reflections

  /// `max_candidates` children were minted.
  Candidates
}

/// One row of `search.jsonl`.
pub type Event {
  /// An arm entered the search: the seed at step 0, a child later.
  Candidate(
    /// The arm id.
    arm: String,
    /// The parent it was minted from; `None` for the seed.
    parent: Option(String),
    /// The step that minted it.
    step: Int,
    /// Seed or reflected.
    source: Source,
    /// The slot the reflection rewrote, as `slot_name` spells it.
    slot: Option(String),
  )

  /// A sub-run started. Its directory is `runs/<plan>/`.
  Run(
    /// The arm the row is about: the parent, the child, or the best in a
    /// confirm run.
    arm: String,
    /// Which split the sub-plan's tasks come from.
    split: Split,
    /// The sub-plan id.
    plan: String,
    /// The step the run belongs to.
    step: Int,
    /// Its part in the step.
    role: RunRole,
    /// The dollar cap the sub-plan was written with: what remained to the
    /// search when the run began. It is what rebuilds the sub-plan, and its
    /// id, when the run directory was never written.
    cap: Float,
  )

  /// One reflection call, priced.
  Reflection(
    /// The step.
    step: Int,
    /// The provider that answered.
    provider: String,
    /// The model that answered.
    model: String,
    /// The wire API.
    api: String,
    /// What the call cost.
    dollars: Float,
    /// SHA-256 of the prompt sent.
    input_digest: String,
    /// SHA-256 of the text received.
    output_digest: String,
  )

  /// A step's child was refused before it ran: no arm when the answer was
  /// refused, the arm when its settings were.
  Refusal(
    /// The step.
    step: Int,
    /// The refused arm, or empty when no arm was minted.
    arm: String,
    /// Why.
    reason: String,
  )

  /// A comparison the search made.
  Judgement(
    /// The arm judged.
    arm: String,
    /// The arm it was paired against.
    against: String,
    /// The split the rows came from.
    split: Split,
    /// The verdict.
    verdict: Verdict,
    /// What the search did about it.
    disposition: Disposition,
  )

  /// The search ended.
  Stop(
    /// Why.
    reason: StopReason,
  )
}

/// A candidate as Loom reports it: the library's member with Loom's
/// names, and the sub-plan whose ledger holds its Validate rows.
pub type Member {
  Member(
    /// The arm id.
    arm: String,
    /// Its parent, if any.
    parent: Option(String),
    /// The step that minted it.
    step: Int,
    /// Seed or reflected.
    source: Source,
    /// The slot that was rewritten.
    slot: Option(String),
    /// The sub-plan whose ledger holds its Validate rows, once it has run.
    validate_plan: Option(String),
    /// What the search decided about it, once settled.
    disposition: Option(Disposition),
  )
}

/// The confirm run and what it found, with the full verdict the headline
/// prints.
pub type Confirmation {
  Confirmation(
    /// The best arm's id.
    best: String,
    /// The `[seed, best]` sub-plan.
    plan: String,
    /// The verdict, once judged.
    verdict: Option(Verdict),
  )
}

/// The whole search: the library's state and Loom's confirm verdict.
pub type State {
  State(
    /// The library's state, which every decision reads.
    search: gepa.State,
    /// The confirm run, once started, with its verdict once judged.
    confirmation: Option(Confirmation),
  )
}

/// Where the fold reads what the rows do not carry: an arm's components,
/// which the library holds a candidate as. The function is data access,
/// not an effect: a test hands in a constant, `eval/optimize` a reader of
/// `arms/<id>.json`.
pub type Store {
  Store(
    /// An arm's components by `slot_name`.
    components: fn(String) -> Result(List(#(String, String)), String),
  )
}

// --- the codec --------------------------------------------------------------------

/// One row as the line the log holds, without its newline.
///
/// ## Examples
///
/// ```gleam
/// // search.encode_line(search.Stop(search.Steps)) == "{\"kind\":\"stop\",\"reason\":\"steps\",\"v\":1}"
/// ```
///
pub fn encode_line(event: Event) -> String {
  json.to_string(to_json(event))
}

/// The canonical encoding of one row.
///
/// ## Examples
///
/// ```gleam
/// // search.to_json(event) |> search.decode == Ok(event)
/// ```
///
pub fn to_json(event: Event) -> JsonValue {
  // Each row kind carries its own fields under the shared version tag.
  let fields = case event {
    Candidate(arm:, parent:, step:, source:, slot:) -> [
      #("kind", json.String("candidate")),
      #("arm", json.String(arm)),
      #("parent", option_json(parent)),
      #("step", json.Int(step)),
      #("source", json.String(source_name(source))),
      #("slot", option_json(slot)),
    ]
    Run(arm:, split:, plan:, step:, role:, cap:) -> [
      #("kind", json.String("run")),
      #("arm", json.String(arm)),
      #("split", json.String(split_name(split))),
      #("plan", json.String(plan)),
      #("step", json.Int(step)),
      #("role", json.String(role_name(role))),
      #("cap", json.Float(cap)),
    ]
    Reflection(
      step:,
      provider:,
      model:,
      api:,
      dollars:,
      input_digest:,
      output_digest:,
    ) -> [
      #("kind", json.String("reflection")),
      #("step", json.Int(step)),
      #("provider", json.String(provider)),
      #("model", json.String(model)),
      #("api", json.String(api)),
      #("dollars", json.Float(dollars)),
      #("input_digest", json.String(input_digest)),
      #("output_digest", json.String(output_digest)),
    ]
    Refusal(step:, arm:, reason:) -> [
      #("kind", json.String("refused")),
      #("step", json.Int(step)),
      #("arm", json.String(arm)),
      #("reason", json.String(reason)),
    ]
    Judgement(arm:, against:, split:, verdict:, disposition:) -> [
      #("kind", json.String("verdict")),
      #("arm", json.String(arm)),
      #("against", json.String(against)),
      #("split", json.String(split_name(split))),
      #("verdict", verdict_json(verdict)),
      #("disposition", json.String(disposition_name(disposition))),
    ]
    Stop(reason:) -> [
      #("kind", json.String("stop")),
      #("reason", json.String(stop_name(reason))),
    ]
  }

  json.canonical(json.Object([#("v", json.Int(version)), ..fields]))
}

/// Decodes one row. Total: every malformed row is an `Error`.
///
/// ## Examples
///
/// ```gleam
/// // search.decode(json.Null) == Error("expected an object")
/// ```
///
pub fn decode(value: JsonValue) -> Result(Event, String) {
  use fields <- result.try(wire.object(value, event_keys))
  use v <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(require(v == version, "unsupported search row version"))
  use kind <- result.try(wire.text(fields, "kind"))

  // The kind tag picks which of the allowed keys the row must carry.
  // Each row kind carries its own fields under the shared version tag.
  case kind {
    "candidate" -> decode_candidate(fields)
    "run" -> decode_run(fields)
    "reflection" -> decode_reflection(fields)
    "refused" -> decode_refusal(fields)
    "verdict" -> decode_judgement(fields)
    "stop" -> {
      use reason <- result.try(
        wire.text(fields, "reason") |> result.try(decode_stop),
      )
      Ok(Stop(reason:))
    }
    other -> Error("unknown search row kind \"" <> other <> "\"")
  }
}

/// Decodes one line of the log.
///
/// ## Examples
///
/// ```gleam
/// // search.decode_line("{\"v\":1,\"kind\":\"stop\",\"reason\":\"steps\"}") == Ok(Stop(Steps))
/// ```
///
pub fn decode_line(line: String) -> Result(Event, String) {
  use value <- result.try(
    json.parse(line)
    |> result.map_error(fn(_report) { "search row is not valid JSON" }),
  )

  decode(value)
}

/// Decodes a whole log. A trailing partial line (a crash mid-write) is
/// refused, as the trial ledger refuses one, so a torn row is never read as
/// the end of the search.
///
/// ## Examples
///
/// ```gleam
/// // search.parse("") == Ok([])
/// ```
///
pub fn parse(text: String) -> Result(List(Event), String) {
  text
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.index_map(fn(line, position) { #(position + 1, line) })
  |> list.try_map(fn(numbered) {
    decode_line(numbered.1)
    |> result.map_error(fn(reason) {
      "search row " <> int.to_string(numbered.0) <> ": " <> reason
    })
  })
}

const event_keys = [
  "v", "kind", "arm", "parent", "step", "source", "slot", "split", "plan",
  "role", "provider", "model", "api", "dollars", "input_digest", "output_digest",
  "reason", "against", "verdict", "disposition", "cap",
]

/// Decodes a `candidate` row.
fn decode_candidate(fields: wire.Fields) -> Result(Event, String) {
  use arm <- result.try(wire.text(fields, "arm"))
  use parent <- result.try(optional_text(fields, "parent"))
  use step <- result.try(wire.int_between(fields, "step", 0, 1_000_000))
  use source <- result.try(
    wire.text(fields, "source") |> result.try(decode_source),
  )
  use slot <- result.try(optional_text(fields, "slot"))
  use Nil <- result.try(require(wire.is_hex(arm, 64), "bad arm id"))

  Ok(Candidate(arm:, parent:, step:, source:, slot:))
}

/// Decodes a `run` row.
fn decode_run(fields: wire.Fields) -> Result(Event, String) {
  use arm <- result.try(wire.text(fields, "arm"))
  use split <- result.try(
    wire.text(fields, "split") |> result.try(decode_split),
  )
  use plan <- result.try(wire.text(fields, "plan"))
  use step <- result.try(wire.int_between(fields, "step", 0, 1_000_000))
  use role <- result.try(wire.text(fields, "role") |> result.try(decode_role))
  use cap <- result.try(wire.number(fields, "cap"))
  use Nil <- result.try(require(wire.is_hex(arm, 64), "bad arm id"))
  use Nil <- result.try(require(wire.is_hex(plan, 64), "bad plan id"))

  Ok(Run(arm:, split:, plan:, step:, role:, cap:))
}

/// Decodes a `reflection` row.
fn decode_reflection(fields: wire.Fields) -> Result(Event, String) {
  use step <- result.try(wire.int_between(fields, "step", 0, 1_000_000))
  use provider <- result.try(wire.text(fields, "provider"))
  use model <- result.try(wire.text(fields, "model"))
  use api <- result.try(wire.text(fields, "api"))
  use dollars <- result.try(wire.number(fields, "dollars"))
  use input_digest <- result.try(wire.text(fields, "input_digest"))
  use output_digest <- result.try(wire.text(fields, "output_digest"))

  Ok(Reflection(
    step:,
    provider:,
    model:,
    api:,
    dollars:,
    input_digest:,
    output_digest:,
  ))
}

/// Decodes a `refused` row.
fn decode_refusal(fields: wire.Fields) -> Result(Event, String) {
  use step <- result.try(wire.int_between(fields, "step", 0, 1_000_000))
  use arm <- result.try(wire.text(fields, "arm"))
  use reason <- result.try(wire.text(fields, "reason"))
  use Nil <- result.try(require(arm == "" || wire.is_hex(arm, 64), "bad arm id"))

  Ok(Refusal(step:, arm:, reason:))
}

/// Decodes a `verdict` row.
fn decode_judgement(fields: wire.Fields) -> Result(Event, String) {
  use arm <- result.try(wire.text(fields, "arm"))
  use against <- result.try(wire.text(fields, "against"))
  use split <- result.try(
    wire.text(fields, "split") |> result.try(decode_split),
  )
  use verdict <- result.try(
    wire.required(fields, "verdict") |> result.try(decode_verdict),
  )
  use disposition <- result.try(
    wire.text(fields, "disposition") |> result.try(decode_disposition),
  )
  use Nil <- result.try(require(wire.is_hex(arm, 64), "bad arm id"))
  use Nil <- result.try(require(wire.is_hex(against, 64), "bad arm id"))

  Ok(Judgement(arm:, against:, split:, verdict:, disposition:))
}

/// A string field that may be JSON null.
fn optional_text(
  fields: wire.Fields,
  key: String,
) -> Result(Option(String), String) {
  use value <- result.try(wire.required(fields, key))

  // Null is absence; any other non-string shape is a malformed row.
  case value {
    json.Null -> Ok(None)
    json.String(text) -> Ok(Some(text))
    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..) -> Error("\"" <> key <> "\" must be a string or null")
  }
}

/// An optional string as a JSON string or null.
fn option_json(value: Option(String)) -> JsonValue {
  case value {
    Some(text) -> json.String(text)
    None -> json.Null
  }
}

fn require(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

/// The wire spelling of a candidate source.
fn source_name(source: Source) -> String {
  case source {
    Seed -> "seed"
    Reflected -> "reflect"
  }
}

/// Parses a candidate source's spelling.
fn decode_source(name: String) -> Result(Source, String) {
  case name {
    "seed" -> Ok(Seed)
    "reflect" -> Ok(Reflected)
    other -> Error("unknown candidate source \"" <> other <> "\"")
  }
}

/// The wire spelling of a split; the holdout is spelt so a refusal can name it.
fn split_name(split: Split) -> String {
  case split {
    split.Tune -> "tune"
    split.Validate -> "validate"
    split.Holdout -> "holdout"
  }
}

/// Parses a split's spelling. The holdout is refused here as well as at the
/// door: a log that named it would be a log of a search that read it.
fn decode_split(name: String) -> Result(Split, String) {
  case name {
    "tune" -> Ok(split.Tune)
    "validate" -> Ok(split.Validate)
    other -> Error("a search row cannot name the split \"" <> other <> "\"")
  }
}

/// The wire spelling of a run role.
fn role_name(role: RunRole) -> String {
  case role {
    ParentMinibatch -> "parent_minibatch"
    ChildMinibatch -> "child_minibatch"
    ValidateRun -> "validate"
    Confirm -> "confirm"
  }
}

/// Parses a run role's spelling.
fn decode_role(name: String) -> Result(RunRole, String) {
  case name {
    "parent_minibatch" -> Ok(ParentMinibatch)
    "child_minibatch" -> Ok(ChildMinibatch)
    "validate" -> Ok(ValidateRun)
    "confirm" -> Ok(Confirm)
    other -> Error("unknown run role \"" <> other <> "\"")
  }
}

/// The wire spelling of a disposition, which the front reports as well.
///
/// ## Examples
///
/// ```gleam
/// assert search.disposition_name(search.ParetoOnly) == "pareto_only"
/// ```
///
pub fn disposition_name(disposition: Disposition) -> String {
  case disposition {
    Incumbent -> "incumbent"
    Joined -> "joined"
    ParetoOnly -> "pareto_only"
    Harmed -> "harmed"
    Unsettled -> "unsettled"
    Refused -> "refused"
    ScreenedOut -> "screened_out"
    Confirmed -> "confirmed"
    Unconfirmed -> "unconfirmed"
  }
}

/// Parses a disposition's spelling.
fn decode_disposition(name: String) -> Result(Disposition, String) {
  case name {
    "incumbent" -> Ok(Incumbent)
    "joined" -> Ok(Joined)
    "pareto_only" -> Ok(ParetoOnly)
    "harmed" -> Ok(Harmed)
    "unsettled" -> Ok(Unsettled)
    "refused" -> Ok(Refused)
    "screened_out" -> Ok(ScreenedOut)
    "confirmed" -> Ok(Confirmed)
    "unconfirmed" -> Ok(Unconfirmed)
    other -> Error("unknown disposition \"" <> other <> "\"")
  }
}

/// The wire spelling of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// assert search.stop_name(search.Dollars) == "dollars"
/// ```
///
pub fn stop_name(reason: StopReason) -> String {
  case reason {
    Steps -> "steps"
    Dollars -> "dollars"
    Reflections -> "reflections"
    Candidates -> "candidates"
  }
}

/// Parses a stop reason's spelling.
fn decode_stop(name: String) -> Result(StopReason, String) {
  case name {
    "steps" -> Ok(Steps)
    "dollars" -> Ok(Dollars)
    "reflections" -> Ok(Reflections)
    "candidates" -> Ok(Candidates)
    other -> Error("unknown stop reason \"" <> other <> "\"")
  }
}

/// A verdict as a JSON object tagged by `kind`, the shape `eval/report`
/// writes into `report.json`.
///
/// ## Examples
///
/// ```gleam
/// // search.verdict_json(verdict.Incomplete("x")) == json.Object([#("kind", json.String("incomplete")), #("reason", json.String("x"))])
/// ```
///
pub fn verdict_json(found: Verdict) -> JsonValue {
  case found {
    verdict.Improved(effect:, ci:, p:, mde:) ->
      directed("improved", effect, ci, p, mde)
    verdict.Harmed(effect:, ci:, p:, mde:) ->
      directed("harmed", effect, ci, p, mde)
    verdict.Indistinguishable(effect:, ci:, p:, mde:) ->
      directed("indistinguishable", effect, ci, p, mde)
    verdict.Underpowered(mde:, needed_tasks:, reason:) ->
      json.Object([
        #("kind", json.String("underpowered")),
        #("mde", json.Float(mde)),
        #("needed_tasks", json.Int(needed_tasks)),
        #("reason", json.String(reason)),
      ])
    verdict.Incomplete(reason:) ->
      json.Object([
        #("kind", json.String("incomplete")),
        #("reason", json.String(reason)),
      ])
  }
}

/// A verdict that has an effect, an interval and a p-value, as JSON.
fn directed(
  kind: String,
  effect: Float,
  ci: #(Float, Float),
  p: Float,
  mde: Float,
) -> JsonValue {
  json.Object([
    #("kind", json.String(kind)),
    #("effect", json.Float(effect)),
    #("ci_low", json.Float(ci.0)),
    #("ci_high", json.Float(ci.1)),
    #("p", json.Float(p)),
    #("mde", json.Float(mde)),
  ])
}

/// Decodes `verdict_json`'s shape. Total.
///
/// ## Examples
///
/// ```gleam
/// // search.decode_verdict(search.verdict_json(v)) == Ok(v)
/// ```
///
pub fn decode_verdict(value: JsonValue) -> Result(Verdict, String) {
  use fields <- result.try(
    wire.object(value, [
      "kind", "effect", "ci_low", "ci_high", "p", "mde", "needed_tasks",
      "reason",
    ]),
  )
  use kind <- result.try(wire.text(fields, "kind"))

  // The kind tag decides which fields the verdict carries.
  case kind {
    "improved" -> decode_directed(fields, verdict.Improved)
    "harmed" -> decode_directed(fields, verdict.Harmed)
    "indistinguishable" -> decode_directed(fields, verdict.Indistinguishable)
    "underpowered" -> {
      use mde <- result.try(wire.number(fields, "mde"))
      use needed_tasks <- result.try(wire.int(fields, "needed_tasks"))
      use reason <- result.try(wire.text(fields, "reason"))
      Ok(verdict.Underpowered(mde:, needed_tasks:, reason:))
    }
    "incomplete" -> {
      use reason <- result.try(wire.text(fields, "reason"))
      Ok(verdict.Incomplete(reason:))
    }
    other -> Error("unknown verdict kind \"" <> other <> "\"")
  }
}

/// Decodes the four numbers a directed verdict carries. An effect may be
/// negative, which `wire.number` refuses, so the signed fields are read
/// directly.
fn decode_directed(
  fields: wire.Fields,
  build: fn(Float, #(Float, Float), Float, Float) -> Verdict,
) -> Result(Verdict, String) {
  use effect <- result.try(signed(fields, "effect"))
  use low <- result.try(signed(fields, "ci_low"))
  use high <- result.try(signed(fields, "ci_high"))
  use p <- result.try(wire.number(fields, "p"))
  use mde <- result.try(wire.number(fields, "mde"))

  Ok(build(effect, #(low, high), p, mde))
}

/// A finite number of either sign.
fn signed(fields: wire.Fields, key: String) -> Result(Float, String) {
  use value <- result.try(wire.required(fields, key))

  // An integer literal is accepted as a number, as `wire.number` does.
  case value {
    json.Float(number) -> Ok(number)
    json.Int(number) -> Ok(int.to_float(number))
    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Bool(..)
    | json.Null -> Error("\"" <> key <> "\" must be a number")
  }
}

/// The name a slot is logged and reported under:
/// `<kind>:<provider>/<model>/<api>/<role>[/<tool>]`, or `prompt_pack`.
///
/// ## Examples
///
/// ```gleam
/// // search.slot_name(TaskPrefix(Target("fixture", "fixture", "anthropic-messages", Any)))
/// // == "task_prefix:fixture/fixture/anthropic-messages/any"
/// ```
///
pub fn slot_name(component: Component) -> String {
  case component {
    arm.SystemSuffix(target:) -> "system_suffix:" <> target_name(target)
    arm.TaskPrefix(target:) -> "task_prefix:" <> target_name(target)
    arm.ToolDescription(target:, tool:) ->
      "tool_description:" <> target_name(target) <> "/" <> tool
    arm.PromptPack -> "prompt_pack"
  }
}

/// A target as `provider/model/api/role`, the middle of a slot name.
fn target_name(target: arm.Target) -> String {
  string.join(
    [
      target.provider,
      target.model_id,
      target.api,
      case target.role {
        arm.Any -> "any"
        arm.Main -> "main"
        arm.Subagent -> "subagent"
        arm.Advisor -> "advisor"
        arm.Summarize -> "summarize"
      },
    ],
    "/",
  )
}

// --- the fold -----------------------------------------------------------------------

/// One row as the library's event. The store supplies the seed's and a
/// child's components; a run's tasks, scores and cost stay in Loom's
/// ledgers, so its evaluation carries none.
///
/// ## Examples
///
/// ```gleam
/// // search.to_gepa(Stop(Steps), store) == Ok(gepa.Stopped(budget.Steps))
/// ```
///
pub fn to_gepa(event: Event, store: Store) -> Result(gepa.Event, String) {
  // Each row kind has one library counterpart; the seed's validate run is
  // told apart from a child's by its step. The two things Loom's rows say
  // that the library's do not — a candidate's source and a run's split —
  // are checked here, so the adapter refuses what the old fold refused.
  case event {
    Candidate(arm:, parent: None, step: 0, source: Seed, slot: None) -> {
      use components <- result.map(store.components(arm))

      gepa.Seeded(candidate: arm, components:)
    }

    Candidate(
      arm:,
      parent: Some(parent),
      step:,
      source: Reflected,
      slot: Some(slot),
    ) -> {
      use components <- result.map(store.components(arm))

      gepa.Minted(
        candidate: arm,
        parent:,
        step:,
        slot:,
        text: result.unwrap(list.key_find(components, slot), ""),
      )
    }

    Candidate(parent: None, ..) ->
      Error("the seed candidate is at step 0, from the seed, with no slot")
    Candidate(parent: Some(_), ..) ->
      Error(
        "a candidate after the seed must be reflected from a parent into a slot",
      )

    Run(arm:, split:, plan:, step:, role:, cap:) -> {
      use Nil <- result.try(require(
        split == split_of(role),
        "a "
          <> role_name(role)
          <> " run draws from the "
          <> split_name(split_of(role))
          <> " split",
      ))

      Ok(gepa.Evaluated(
        stage: stage_of(role, step),
        step:,
        candidate: arm,
        tasks: [],
        cap:,
        ref: plan,
        measured: [],
        cost: 0.0,
      ))
    }

    Reflection(step:, dollars:, output_digest:, ..) ->
      Ok(gepa.Reflected(
        step:,
        cost: dollars,
        ref: output_digest,
        finish: gepa.Unknown,
      ))

    Refusal(step:, arm:, reason:) ->
      Ok(gepa.Refused(
        step:,
        candidate: case arm {
          "" -> None
          _ -> Some(arm)
        },
        reason:,
      ))

    Judgement(arm:, against:, split:, verdict: found, disposition:) ->
      Ok(gepa.Judged(
        candidate: arm,
        against:,
        basis: basis_of(split, disposition),
        acceptance: acceptance_of(found),
        disposition: disposition_to_gepa(disposition),
        ref: "",
      ))

    Stop(reason:) -> Ok(gepa.Stopped(stop_to_gepa(reason)))
  }
}

/// The split a run role draws from: the minibatches from tune, the
/// validate and confirm runs from validate.
fn split_of(role: RunRole) -> Split {
  case role {
    ParentMinibatch | ChildMinibatch -> split.Tune
    ValidateRun | Confirm -> split.Validate
  }
}

/// The library's stage for a run role: the seed's step-0 validate run is
/// its own stage.
fn stage_of(role: RunRole, step: Int) -> gepa.Stage {
  case role, step {
    ValidateRun, 0 -> gepa.SeedValidate
    ValidateRun, _ -> gepa.Validate
    ParentMinibatch, _ -> gepa.ParentMinibatch
    ChildMinibatch, _ -> gepa.ChildMinibatch
    Confirm, _ -> gepa.Confirm
  }
}

/// The library's basis for a judgement: the split it was reached on, or
/// the confirm run when the disposition says so.
fn basis_of(split: Split, disposition: Disposition) -> rule.Basis {
  // The two confirm dispositions name the confirm run whatever the split
  // says; otherwise the split is the basis.
  case disposition, split {
    Confirmed, _ | Unconfirmed, _ -> rule.OnConfirm
    Incumbent, split.Tune
    | Joined, split.Tune
    | ParetoOnly, split.Tune
    | Harmed, split.Tune
    | Unsettled, split.Tune
    | Refused, split.Tune
    | ScreenedOut, split.Tune
    -> rule.OnMinibatch
    Incumbent, split.Validate
    | Joined, split.Validate
    | ParetoOnly, split.Validate
    | Harmed, split.Validate
    | Unsettled, split.Validate
    | Refused, split.Validate
    | ScreenedOut, split.Validate
    | Incumbent, split.Holdout
    | Joined, split.Holdout
    | ParetoOnly, split.Holdout
    | Harmed, split.Holdout
    | Unsettled, split.Holdout
    | Refused, split.Holdout
    | ScreenedOut, split.Holdout
    -> rule.OnValidate
  }
}

/// Applies one row to the state, or says why it cannot follow: the
/// library's fold, then Loom's confirm verdict.
///
/// ## Examples
///
/// ```gleam
/// // search.apply(state, Stop(Steps), store) -> Ok(State(..state, search: stopped))
/// ```
///
pub fn apply(
  state: State,
  event: Event,
  store: Store,
) -> Result(State, String) {
  use translated <- result.try(to_gepa(event, store))
  use search <- result.map(gepa.apply(state.search, translated))

  // The confirm run's row opens Loom's confirmation; its judgement
  // carries the verdict the library reduced to a word.
  let confirmation = case event, state.confirmation {
    Run(arm:, plan:, role: Confirm, ..), _ ->
      Some(Confirmation(best: arm, plan:, verdict: None))
    Judgement(verdict: found, disposition: Confirmed, ..), Some(open)
    | Judgement(verdict: found, disposition: Unconfirmed, ..), Some(open)
    -> Some(Confirmation(..open, verdict: Some(found)))
    Run(..), held
    | Judgement(..), held
    | Candidate(..), held
    | Reflection(..), held
    | Refusal(..), held
    | Stop(..), held
    -> held
  }

  State(search:, confirmation:)
}

/// Folds a log into the search's state, refusing the first row that does
/// not follow from the rows before it. An empty log is an error: a search
/// that has not started has no state to replay.
///
/// ## Examples
///
/// ```gleam
/// // search.replay([Candidate(seed, None, 0, Seed, None)], store) -> Ok(State(..))
/// // search.replay([], store) == Error("search row missing: the seed candidate")
/// ```
///
pub fn replay(events: List(Event), store: Store) -> Result(State, String) {
  // The seed's row opens the library's state; every later row folds in.
  case events {
    [Candidate(arm:, parent: None, step: 0, source: Seed, slot: None), ..rest] -> {
      use components <- result.try(store.components(arm))
      let opened =
        State(search: gepa.start(arm, components), confirmation: None)

      list.index_fold(rest, Ok(opened), fn(folded, event, position) {
        use state <- result.try(folded)

        apply(state, event, store)
        |> result.map_error(fn(reason) {
          "search row " <> int.to_string(position + 2) <> ": " <> reason
        })
      })
    }

    [] -> Error("search row missing: the seed candidate")
    [_, ..] -> Error("search row 1: the log must begin with the seed candidate")
  }
}

// --- Loom-shaped reads ----------------------------------------------------------------

/// Every candidate in log order, with Loom's names.
///
/// ## Examples
///
/// ```gleam
/// // search.members(state) |> list.first -> Ok(Member(arm: seed, source: Seed, ..))
/// ```
///
pub fn members(state: State) -> List(Member) {
  list.map(state.search.members, fn(member) {
    Member(
      arm: member.candidate,
      parent: member.parent,
      step: member.step,
      source: case member.parent {
        None -> Seed
        Some(_) -> Reflected
      },
      slot: member.slot,
      validate_plan: member.validated,
      disposition: option.map(member.disposition, disposition_from_gepa),
    )
  })
}

/// Every sub-run in log order, as the `Run` rows that recorded them.
///
/// ## Examples
///
/// ```gleam
/// // search.runs(state) -> [Run(seed, Validate, plan_a, 0, ValidateRun, 9.0), ..]
/// ```
///
pub fn runs(state: State) -> List(Event) {
  list.map(state.search.evaluations, fn(evaluation) {
    // The seed's validate run and a child's share Loom's role.
    let role = case evaluation.stage {
      gepa.SeedValidate | gepa.Validate -> ValidateRun
      gepa.ParentMinibatch -> ParentMinibatch
      gepa.ChildMinibatch -> ChildMinibatch
      gepa.Confirm -> Confirm
    }

    Run(
      arm: evaluation.candidate,
      split: split_of(role),
      plan: evaluation.ref,
      step: evaluation.step,
      role:,
      cap: evaluation.cap,
    )
  })
}

/// Why the search stopped, in Loom's words, if it did.
///
/// ## Examples
///
/// ```gleam
/// // search.stopped(state) == Some(search.Dollars)
/// ```
///
pub fn stopped(state: State) -> Option(StopReason) {
  option.map(state.search.stopped, stop_from_gepa)
}

/// The sub-plan a step's run of one role was recorded with, if any.
///
/// ## Examples
///
/// ```gleam
/// // search.plan_of(state, 3, ChildMinibatch) == Ok(plan_c)
/// ```
///
pub fn plan_of(state: State, step: Int, role: RunRole) -> Result(String, Nil) {
  list.find_map(state.search.evaluations, fn(evaluation) {
    case evaluation.step == step && stage_of(role, step) == evaluation.stage {
      True -> Ok(evaluation.ref)
      False -> Error(Nil)
    }
  })
}

/// The cap a Run row recorded for a sub-plan.
///
/// ## Examples
///
/// ```gleam
/// // search.recorded_cap(state, plan_b) == Ok(4.5)
/// ```
///
pub fn recorded_cap(state: State, plan_id: String) -> Result(Float, String) {
  list.find_map(state.search.evaluations, fn(evaluation) {
    case evaluation.ref == plan_id {
      True -> Ok(evaluation.cap)
      False -> Error(Nil)
    }
  })
  |> result.map_error(fn(_) {
    "search row missing: the run row for " <> plan_id
  })
}

// --- an arm and a ledger as the library sees them -----------------------------------

/// An arm's components keyed by `slot_name`, the map the library holds a
/// candidate as.
///
/// ## Examples
///
/// ```gleam
/// // search.component_map(arm) == [#("task_prefix:p/m/api/any", "Be brief.")]
/// ```
///
pub fn component_map(candidate: Arm) -> List(#(String, String)) {
  list.map(candidate.components, fn(component) {
    #(slot_name(component.0), component.1)
  })
}

/// The mean reward per task of one arm's counted Validate rows, in the
/// order of `tasks`. A task with no counted row scores zero: the design
/// owes every task a measurement, and an arm that failed to produce one
/// must not lead that task by omission.
///
/// ## Examples
///
/// ```gleam
/// // search.per_task_means(rows, ["t1", "t2"]) == [#("t1", 0.667), #("t2", 1.0)]
/// ```
///
pub fn per_task_means(
  rows: List(stat.Trial),
  tasks: List(String),
) -> List(#(String, Float)) {
  list.map(tasks, fn(task) {
    let counted =
      list.filter_map(rows, fn(row) {
        case row.task == task, stat.standing(row.outcome) {
          True, stat.Counted(fate) -> Ok(stat.indicator(fate))
          True, stat.Excluded | False, _ -> Error(Nil)
        }
      })

    #(task, mean_of(counted))
  })
}

/// The arithmetic mean, zero of nothing.
fn mean_of(values: List(Float)) -> Float {
  case values {
    [] -> 0.0
    [_, ..] ->
      list.fold(values, 0.0, float.add) /. int.to_float(list.length(values))
  }
}

/// Loom's dominance ruling as the library's standing, for the front's
/// order.
///
/// ## Examples
///
/// ```gleam
/// assert search.standing_of(dominance.Tie) == select.Tied
/// ```
///
pub fn standing_of(found: dominance.Dominance) -> select.Standing {
  case found {
    dominance.Dominates(dominance.Outcome) -> select.DominatesOnOutcome
    dominance.Dominates(dominance.Scores) -> select.DominatesOnScores
    dominance.Tie -> select.Tied
    dominance.Tradeoff(..) -> select.Tradeoff
    dominance.Undecided -> select.Undecided
    dominance.Dominated(dominance.Scores) -> select.DominatedOnScores
    dominance.Dominated(dominance.Outcome) -> select.DominatedOnOutcome
  }
}

/// Loom's statistical verdict as the four words the library decides
/// with: `Indistinguishable` and `Underpowered` are both inconclusive.
///
/// ## Examples
///
/// ```gleam
/// assert search.acceptance_of(verdict.Incomplete("x")) == rule.Incomplete
/// ```
///
pub fn acceptance_of(found: Verdict) -> rule.Acceptance {
  case found {
    verdict.Improved(..) -> rule.Improved
    verdict.Harmed(..) -> rule.Harmed
    verdict.Indistinguishable(..) | verdict.Underpowered(..) ->
      rule.Inconclusive
    verdict.Incomplete(..) -> rule.Incomplete
  }
}

/// Loom's disposition as the library's; the words are the same but for
/// `Harmed`, which the library calls `Discarded` to keep it apart from the
/// acceptance of the same name.
///
/// ## Examples
///
/// ```gleam
/// assert search.disposition_to_gepa(search.Harmed) == rule.Discarded
/// ```
///
pub fn disposition_to_gepa(disposition: Disposition) -> rule.Disposition {
  case disposition {
    Incumbent -> rule.Incumbent
    Joined -> rule.Joined
    ParetoOnly -> rule.ParetoOnly
    Harmed -> rule.Discarded
    Unsettled -> rule.Unsettled
    Refused -> rule.Refused
    ScreenedOut -> rule.ScreenedOut
    Confirmed -> rule.Confirmed
    Unconfirmed -> rule.Unconfirmed
  }
}

/// The library's disposition as Loom's.
///
/// ## Examples
///
/// ```gleam
/// assert search.disposition_from_gepa(rule.Discarded) == search.Harmed
/// ```
///
pub fn disposition_from_gepa(disposition: rule.Disposition) -> Disposition {
  case disposition {
    rule.Incumbent -> Incumbent
    rule.Joined -> Joined
    rule.ParetoOnly -> ParetoOnly
    rule.Discarded -> Harmed
    rule.Unsettled -> Unsettled
    rule.Refused -> Refused
    rule.ScreenedOut -> ScreenedOut
    rule.Confirmed -> Confirmed
    rule.Unconfirmed -> Unconfirmed
  }
}

/// Loom's stop reason as the library's: dollars are the library's budget.
///
/// ## Examples
///
/// ```gleam
/// assert search.stop_to_gepa(search.Dollars) == budget.Budget
/// ```
///
pub fn stop_to_gepa(reason: StopReason) -> budget.StopReason {
  case reason {
    Steps -> budget.Steps
    Dollars -> budget.Budget
    Reflections -> budget.Reflections
    Candidates -> budget.Candidates
  }
}

/// The library's stop reason as Loom's.
///
/// ## Examples
///
/// ```gleam
/// assert search.stop_from_gepa(budget.Budget) == search.Dollars
/// ```
///
pub fn stop_from_gepa(reason: budget.StopReason) -> StopReason {
  case reason {
    budget.Steps -> Steps
    budget.Budget -> Dollars
    budget.Reflections -> Reflections
    budget.Candidates -> Candidates
  }
}
