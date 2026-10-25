//// The pure state of a prompt search: the append-only log it is folded from,
//// the pool and its front, the parent draw, the spend filter and the
//// bookkeeping that turns a verdict into a disposition.
////
//// `eval/optimize` is a loop with effects: it opens sessions, calls a model
//// and writes files. Everything the loop *decides* lives here instead, over
//// values, so that a search can be replayed from its log without running
//// anything and every rule can be tested without a process. The log is
//// `search.jsonl`, one JSON object per line, and `replay` is the fold that
//// turns it back into a `State`. The fold is strict: a row that arrives out
//// of order, names an arm no `candidate` row introduced, or settles a step
//// whose runs are missing is a refusal naming the row, never a smaller
//// search. That is the same rule the trial ledger is held to, and for the
//// same reason: a log that quietly tolerated a dropped row would let a
//// candidate look better by losing the run it failed.
////
//// Three decisions are the search's own and are stated here once.
////
//// - **Selection** follows GEPA's Algorithm 2 over the Validate split: for
////   each task the leading set is every pool member whose per-task mean is
////   within one sample's worth (`1 / K`) of the best, the union is pruned by
////   Pareto dominance over the per-task vectors, and the parent is drawn in
////   proportion to the tasks it leads from a generator seeded by the search
////   id and the step number, so a resumed search draws the same parent.
//// - **The minibatch is a spend filter, not a decision rule.** A child runs
////   the Validate split only when its mean per-task reward on the tune
////   minibatch is at least the parent's. With three or four tasks the sign
////   test cannot reach its level, so nothing is claimed at that size; the
////   screen only decides whether to pay for the run that can.
//// - **Acceptance is `evalstat.paired_verdict` on Validate**, child against
////   parent and against the incumbent. The verdict becomes a `Disposition`
////   by `dispose`: only `Improved` joins the pool as a ranked member;
////   `Indistinguishable` and `Underpowered` join as Pareto members that are
////   never ranked above their parent; `Harmed` and `Incomplete` stay out.
////
//// ## Flow
////
//// - `encode_line`, `decode_line`, `parse`: the log's codec
//// - `replay`, `apply`: the fold from rows to `State`
//// - `per_task_means`, `front`, `draw_parent`: selection
//// - `minibatch`, `slot_for`: the step's other two draws
//// - `screen`: the spend filter
//// - `dispose`: a verdict to a disposition
//// - `rank`: the order the front is reported in
//// - `slot_name`, `verdict_json`, `decode_verdict`: the shared spellings

import core/json.{type JsonValue}
import eval/arm.{type Component}
import eval/split.{type Split}
import eval/wire
import evalstat/dominance
import evalstat/prng.{type Prng}
import evalstat/trial as stat
import evalstat/verdict.{type Verdict}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
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

/// A candidate the fold has seen.
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

/// Where an unfinished step has got to. The rows a step writes arrive in
/// a fixed order, and the stage is the last one seen.
pub type Progress {
  Progress(
    /// The step number.
    step: Int,
    /// The parent drawn for the step.
    parent: String,
    /// The parent's minibatch sub-plan.
    parent_minibatch: String,
    /// Whether a reflection row has been seen since the minibatch.
    reflected: Reflected,
    /// The child, once minted.
    child: Option(String),
    /// The child's minibatch sub-plan, once started.
    child_minibatch: Option(String),
    /// The child's Validate sub-plan, once started.
    validate: Option(String),
    /// The verdict against the incumbent, when one was written before the
    /// settling row.
    against_incumbent: Option(Verdict),
  )
}

/// Whether the open step has reflected yet.
pub type Reflected {
  /// No reflection row since the parent's minibatch.
  NotYet

  /// At least one reflection row.
  Done
}

/// The confirm run and what it found.
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

/// The whole search, as the fold leaves it.
pub type State {
  State(
    /// The search id the log belongs to, as the first row named it.
    seed: String,
    /// Every candidate in log order.
    members: List(Member),
    /// The arms in the pool, in log order: the seed first.
    pool: List(String),
    /// The best arm by the search's rule.
    incumbent: String,
    /// Every sub-run, in log order.
    runs: List(Event),
    /// How many reflections have been made.
    reflections: Int,
    /// What the reflections cost.
    reflection_dollars: Float,
    /// The last step number opened.
    step: Int,
    /// The step in progress, if the log ends inside one.
    open: Option(Progress),
    /// The confirm run, once started.
    confirmation: Option(Confirmation),
    /// Why the search stopped, if it did.
    stopped: Option(StopReason),
  )
}

/// Whether a child passed the spend filter.
pub type Screen {
  /// Its minibatch mean is at least the parent's: pay for Validate.
  Passed

  /// Below the parent: the step ends here.
  Failed
}

/// A pool member with the per-task means and the count of tasks it leads.
pub type Leader {
  Leader(
    /// The arm id.
    arm: String,
    /// The Validate tasks on which it is within one sample of the best.
    tasks_led: Int,
    /// Its mean reward per task, task-major in the plan's order.
    means: List(#(String, Float)),
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

/// Folds a log into the search's state, refusing the first row that does
/// not follow from the rows before it. An empty log is an error: a search
/// that has not started has no state to replay.
///
/// ## Examples
///
/// ```gleam
/// // search.replay([Candidate(seed, None, 0, Seed, None)]) -> Ok(State(..))
/// // search.replay([]) == Error("search row missing: the seed candidate")
/// ```
///
pub fn replay(events: List(Event)) -> Result(State, String) {
  case events {
    [Candidate(arm:, parent: None, step: 0, source: Seed, slot: None), ..rest] ->
      list.index_fold(rest, Ok(opened(arm)), fn(folded, event, position) {
        use state <- result.try(folded)

        apply(state, event)
        |> result.map_error(fn(reason) {
          "search row " <> int.to_string(position + 2) <> ": " <> reason
        })
      })

    [] -> Error("search row missing: the seed candidate")
    [_, ..] -> Error("search row 1: the log must begin with the seed candidate")
  }
}

/// The state right after the seed's candidate row: step 0 is open until the
/// seed's Validate run is recorded.
fn opened(seed: String) -> State {
  State(
    seed:,
    members: [
      Member(
        arm: seed,
        parent: None,
        step: 0,
        source: Seed,
        slot: None,
        validate_plan: None,
        disposition: Some(Incumbent),
      ),
    ],
    pool: [seed],
    incumbent: seed,
    runs: [],
    reflections: 0,
    reflection_dollars: 0.0,
    step: 0,
    open: None,
    confirmation: None,
    stopped: None,
  )
}

/// Applies one row to the state, or says why it cannot follow.
///
/// ## Examples
///
/// ```gleam
/// // search.apply(state, Stop(Steps)) -> Ok(State(..state, stopped: Some(Steps)))
/// ```
///
pub fn apply(state: State, event: Event) -> Result(State, String) {
  use Nil <- result.try(require(
    state.stopped == None,
    "a row follows the stop row",
  ))

  // Each row kind has one place in a step; the open progress says where the
  // step is, and the row must be the next stage.
  case event {
    Candidate(..) -> apply_candidate(state, event)
    Run(role: ParentMinibatch, ..) -> open_step(state, event)
    Run(role: ChildMinibatch, ..) -> apply_child_minibatch(state, event)
    Run(role: ValidateRun, ..) -> apply_validate_run(state, event)
    Run(role: Confirm, ..) -> apply_confirm_run(state, event)
    Reflection(step:, dollars:, ..) -> apply_reflection(state, step, dollars)
    Refusal(step:, arm:, ..) -> apply_refusal(state, step, arm)
    Judgement(..) -> apply_judgement(state, event)
    Stop(reason:) -> apply_stop(state, reason)
  }
}

/// A `candidate` row after the seed is a reflected child of the open step.
fn apply_candidate(state: State, event: Event) -> Result(State, String) {
  // A child needs an open step that has reflected; anything else is misplaced.
  case event, state.open {
    Candidate(arm:, parent: Some(parent), step:, source: Reflected, slot:),
      Some(progress)
    -> {
      use Nil <- result.try(require(
        step == progress.step
          && parent == progress.parent
          && progress.reflected == Done
          && progress.child == None,
        "a candidate row needs an open step that has reflected and has no child",
      ))
      use Nil <- result.try(require(
        !list.any(state.members, fn(member) { member.arm == arm }),
        "candidate " <> arm <> " was already introduced",
      ))

      let member =
        Member(
          arm:,
          parent: Some(parent),
          step:,
          source: Reflected,
          slot:,
          validate_plan: None,
          disposition: None,
        )

      Ok(
        State(
          ..state,
          members: list.append(state.members, [member]),
          open: Some(Progress(..progress, child: Some(arm))),
        ),
      )
    }

    Candidate(..), None ->
      Error("search row missing: the parent minibatch run that opens the step")
    Candidate(..), Some(_) ->
      Error("a candidate after the seed must be reflected from a parent")
    Run(..), _
    | Reflection(..), _
    | Refusal(..), _
    | Judgement(..), _
    | Stop(..), _
    -> Error("not a candidate row")
  }
}

/// The seed's Validate run closes step 0; every later step opens with the
/// parent's minibatch run, which must name a pool member and the next step.
fn open_step(state: State, event: Event) -> Result(State, String) {
  // A step opens only between steps, before the confirm run, from the tune split.
  case event, state.open, state.confirmation {
    Run(arm:, split: split.Tune, plan:, step:, role: ParentMinibatch, ..),
      None,
      None
    -> {
      use Nil <- result.try(require(
        step == state.step + 1,
        "a step opens at the step after the last",
      ))
      use Nil <- result.try(require(
        list.contains(state.pool, arm),
        "the parent " <> arm <> " is not in the pool",
      ))
      use Nil <- result.try(seed_validated(state))

      Ok(
        State(
          ..state,
          runs: list.append(state.runs, [event]),
          step:,
          open: Some(Progress(
            step:,
            parent: arm,
            parent_minibatch: plan,
            reflected: NotYet,
            child: None,
            child_minibatch: None,
            validate: None,
            against_incumbent: None,
          )),
        ),
      )
    }

    Run(..), Some(_), _ -> Error("a step opened inside an unfinished step")
    Run(..), None, Some(_) -> Error("a step opened after the confirm run")
    Run(..), None, None ->
      Error("a parent minibatch must draw from the tune split")
    Candidate(..), _, _
    | Reflection(..), _, _
    | Refusal(..), _, _
    | Judgement(..), _, _
    | Stop(..), _, _
    -> Error("not a run row")
  }
}

/// Step 0 is the seed's Validate run; nothing else may happen before it.
fn seed_validated(state: State) -> Result(Nil, String) {
  case list.first(state.members) {
    Ok(Member(validate_plan: Some(_), ..)) -> Ok(Nil)
    Ok(Member(validate_plan: None, ..)) | Error(Nil) ->
      Error("search row missing: the seed's validate run")
  }
}

/// A Validate run is the seed's at step 0, or the open step's child's.
fn apply_validate_run(state: State, event: Event) -> Result(State, String) {
  // Step 0's run is the seed's; a later one is the open step's child's.
  case event, state.open {
    Run(arm:, split: split.Validate, plan:, step: 0, role: ValidateRun, ..),
      None
    -> {
      use Nil <- result.try(require(
        arm == state.seed && state.step == 0 && state.runs == [],
        "the step 0 validate run belongs to the seed, before anything else",
      ))

      Ok(
        State(
          ..state,
          runs: [event],
          members: with_validate_plan(state.members, arm, plan),
        ),
      )
    }

    Run(arm:, split: split.Validate, plan:, step:, role: ValidateRun, ..),
      Some(progress)
    -> {
      use Nil <- result.try(require(
        step == progress.step
          && progress.child == Some(arm)
          && progress.validate == None,
        "a validate run needs the step's child and no earlier validate run",
      ))
      use Nil <- result.try(require(
        progress.child_minibatch != None,
        "search row missing: the child's minibatch run",
      ))

      Ok(
        State(
          ..state,
          runs: list.append(state.runs, [event]),
          members: with_validate_plan(state.members, arm, plan),
          open: Some(Progress(..progress, validate: Some(plan))),
        ),
      )
    }

    Run(..), _ -> Error("a validate run row out of place")
    Candidate(..), _
    | Reflection(..), _
    | Refusal(..), _
    | Judgement(..), _
    | Stop(..), _
    -> Error("not a run row")
  }
}

/// Records the sub-plan whose ledger holds an arm's Validate rows.
fn with_validate_plan(
  members: List(Member),
  arm: String,
  plan: String,
) -> List(Member) {
  list.map(members, fn(member) {
    case member.arm == arm {
      True -> Member(..member, validate_plan: Some(plan))
      False -> member
    }
  })
}

/// The child's minibatch follows its candidate row.
fn apply_child_minibatch(state: State, event: Event) -> Result(State, String) {
  // The child's minibatch follows its candidate row inside the open step.
  case event, state.open {
    Run(arm:, split: split.Tune, plan:, step:, role: ChildMinibatch, ..),
      Some(progress)
    -> {
      use Nil <- result.try(require(
        progress.child != None,
        "search row missing: the child's candidate row",
      ))
      use Nil <- result.try(require(
        step == progress.step
          && progress.child == Some(arm)
          && progress.child_minibatch == None,
        "a child minibatch needs the step's child and no earlier one",
      ))

      Ok(
        State(
          ..state,
          runs: list.append(state.runs, [event]),
          open: Some(Progress(..progress, child_minibatch: Some(plan))),
        ),
      )
    }

    Run(..), _ -> Error("a child minibatch row out of place")
    Candidate(..), _
    | Reflection(..), _
    | Refusal(..), _
    | Judgement(..), _
    | Stop(..), _
    -> Error("not a run row")
  }
}

/// The confirm run comes after the last step settles and before the stop.
fn apply_confirm_run(state: State, event: Event) -> Result(State, String) {
  // The confirm run comes once, between the last settled step and the stop.
  case event, state.open, state.confirmation {
    Run(arm:, split: split.Validate, plan:, step:, role: Confirm, ..),
      None,
      None
    -> {
      use Nil <- result.try(require(
        step == state.step && arm == state.incumbent && arm != state.seed,
        "a confirm run names the incumbent at the last step",
      ))

      Ok(
        State(
          ..state,
          runs: list.append(state.runs, [event]),
          confirmation: Some(Confirmation(best: arm, plan:, verdict: None)),
        ),
      )
    }

    Run(..), Some(_), _ -> Error("a confirm run inside an unfinished step")
    Run(..), None, Some(_) -> Error("a second confirm run")
    Run(..), None, None -> Error("a confirm run row out of place")
    Candidate(..), _, _
    | Reflection(..), _, _
    | Refusal(..), _, _
    | Judgement(..), _, _
    | Stop(..), _, _
    -> Error("not a run row")
  }
}

/// A reflection belongs to the open step, after the parent's minibatch and
/// before the child. A second one in the same step is a resumed search
/// that lost the first answer before minting, and is counted too.
fn apply_reflection(
  state: State,
  step: Int,
  dollars: Float,
) -> Result(State, String) {
  // A reflection belongs to an open step that has no child yet.
  case state.open {
    Some(progress) -> {
      use Nil <- result.try(require(
        step == progress.step && progress.child == None,
        "a reflection needs an open step with no child yet",
      ))

      Ok(
        State(
          ..state,
          reflections: state.reflections + 1,
          reflection_dollars: state.reflection_dollars +. dollars,
          open: Some(Progress(..progress, reflected: Done)),
        ),
      )
    }

    None ->
      Error("search row missing: the parent minibatch run that opens the step")
  }
}

/// A refusal closes the open step: with no arm after a refused answer, with
/// the child's arm when its settings refused.
fn apply_refusal(
  state: State,
  step: Int,
  arm: String,
) -> Result(State, String) {
  // A refusal closes an open step before its child has run.
  case state.open {
    Some(progress) -> {
      use Nil <- result.try(require(
        step == progress.step && progress.child_minibatch == None,
        "a refusal needs an open step whose child has not run",
      ))
      use Nil <- result.try(require(
        case arm {
          "" -> progress.child == None && progress.reflected == Done
          _ -> progress.child == Some(arm)
        },
        "a refusal names the step's child, or no arm before one was minted",
      ))

      Ok(
        State(
          ..state,
          members: with_disposition(state.members, arm, Refused),
          open: None,
        ),
      )
    }

    None ->
      Error("search row missing: the parent minibatch run that opens the step")
  }
}

/// Records what the search decided about an arm.
fn with_disposition(
  members: List(Member),
  arm: String,
  disposition: Disposition,
) -> List(Member) {
  list.map(members, fn(member) {
    case member.arm == arm {
      True -> Member(..member, disposition: Some(disposition))
      False -> member
    }
  })
}

/// A verdict row settles the open step when it is against the parent,
/// records the incumbent comparison when it is against the incumbent, or
/// judges the confirm run.
fn apply_judgement(state: State, event: Event) -> Result(State, String) {
  // A verdict settles the open step, records the incumbent comparison, or judges the confirm run.
  case event, state.open, state.confirmation {
    Judgement(arm:, against:, split:, verdict:, disposition:), Some(progress), _
    -> {
      use Nil <- result.try(require(
        progress.child == Some(arm),
        "a verdict names the step's child",
      ))

      // Against the parent the row settles the step; against the incumbent
      // it is kept for the settling row that follows.
      case against == progress.parent {
        True -> settle(state, progress, event, disposition)
        False -> {
          use Nil <- result.try(require(
            against == state.incumbent && progress.validate != None,
            "a verdict is against the parent or the incumbent, after validate",
          ))
          use Nil <- result.try(require(
            progress.against_incumbent == None,
            "a second verdict against the incumbent in one step",
          ))
          use Nil <- result.try(require(
            split == split.Validate && disposition == Unsettled,
            "an incumbent comparison is a validate row that settles nothing",
          ))

          Ok(
            State(
              ..state,
              open: Some(Progress(..progress, against_incumbent: Some(verdict))),
            ),
          )
        }
      }
    }

    Judgement(arm:, against:, verdict:, disposition:, ..),
      None,
      Some(confirmation)
    -> {
      use Nil <- result.try(require(
        arm == confirmation.best
          && against == state.seed
          && confirmation.verdict == None
          && { disposition == Confirmed || disposition == Unconfirmed },
        "a confirm verdict pairs the best against the seed once",
      ))

      Ok(
        State(
          ..state,
          confirmation: Some(
            Confirmation(..confirmation, verdict: Some(verdict)),
          ),
        ),
      )
    }

    Judgement(..), None, None -> Error("search row missing: the step's rows")
    Candidate(..), _, _
    | Run(..), _, _
    | Reflection(..), _, _
    | Refusal(..), _, _
    | Stop(..), _, _
    -> Error("not a verdict row")
  }
}

/// Closes a step with its disposition, checking the runs the disposition
/// presupposes are in the log. A disposition that needs a run the log does
/// not hold is a deleted row, and the search refuses to continue over it.
fn settle(
  state: State,
  progress: Progress,
  event: Event,
  disposition: Disposition,
) -> Result(State, String) {
  // Only a verdict row settles; the type does not narrow it, so its parts are read here.
  use #(arm, split, found) <- result.try(case event {
    Judgement(arm:, split:, verdict:, ..) -> Ok(#(arm, split, verdict))
    Candidate(..) | Run(..) | Reflection(..) | Refusal(..) | Stop(..) ->
      Error("not a verdict row")
  })

  // A disposition is what `dispose` makes of its verdict, and a row that
  // claims otherwise was not written by the search.
  use Nil <- result.try(require(
    consistent(found, split, disposition),
    "the disposition "
      <> disposition_name(disposition)
      <> " does not follow from its verdict",
  ))
  use Nil <- result.try(require(
    disposition != Incumbent
      || progress.parent == state.incumbent
      || progress.against_incumbent != None,
    "search row missing: the verdict against the incumbent",
  ))

  // Each disposition names the stage the step must have reached.
  use Nil <- result.try(case disposition {
    ScreenedOut ->
      require(
        progress.child_minibatch != None && progress.validate == None,
        "search row missing: a screened-out child has run its minibatch and nothing more",
      )
    Incumbent | Joined | ParetoOnly | Harmed | Unsettled ->
      require(
        progress.validate != None,
        "search row missing: the child's validate run",
      )
    Refused | Confirmed | Unconfirmed ->
      Error("a step does not settle as " <> disposition_name(disposition))
  })

  // Only the three joining dispositions change the pool.
  let pool = case disposition {
    Incumbent | Joined | ParetoOnly -> list.append(state.pool, [arm])
    Harmed | Unsettled | ScreenedOut | Refused | Confirmed | Unconfirmed ->
      state.pool
  }

  // The incumbent changes with exactly one of them.
  let incumbent = case disposition {
    Incumbent -> arm
    Joined
    | ParetoOnly
    | Harmed
    | Unsettled
    | ScreenedOut
    | Refused
    | Confirmed
    | Unconfirmed -> state.incumbent
  }

  Ok(
    State(
      ..state,
      members: with_disposition(state.members, arm, disposition),
      pool:,
      incumbent:,
      open: None,
    ),
  )
}

/// Whether a settling disposition is one `dispose` gives its verdict, on
/// the split that verdict was reached on.
fn consistent(found: Verdict, split: Split, disposition: Disposition) -> Bool {
  case found, split, disposition {
    verdict.Incomplete(..), split.Tune, ScreenedOut -> True
    verdict.Improved(..), split.Validate, Incumbent
    | verdict.Improved(..), split.Validate, Joined
    -> True
    verdict.Indistinguishable(..), split.Validate, ParetoOnly
    | verdict.Underpowered(..), split.Validate, ParetoOnly
    -> True
    verdict.Harmed(..), split.Validate, Harmed -> True
    verdict.Incomplete(..), split.Validate, Unsettled -> True
    _, _, _ -> False
  }
}

/// The stop row ends the log, and only between steps.
fn apply_stop(state: State, reason: StopReason) -> Result(State, String) {
  case state.open {
    None -> Ok(State(..state, stopped: Some(reason)))
    Some(_) -> Error("the search stopped inside a step")
  }
}

/// How many children the search has minted.
///
/// ## Examples
///
/// ```gleam
/// // search.children(state) == list.length(state.members) - 1
/// ```
///
pub fn children(state: State) -> Int {
  list.count(state.members, fn(member) { member.source == Reflected })
}

// --- selection ------------------------------------------------------------------------

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

/// GEPA's Algorithm 2 over the pool: the per-task leading sets, their union
/// pruned by Pareto dominance, and each survivor's count of tasks led. The
/// leading set of a task is every member within `1 / k` of its best mean,
/// because one lucky sample out of `k` must not make a member the sole
/// leader of a task. Survivors come back in pool order.
///
/// ## Examples
///
/// ```gleam
/// // search.front([#("a", means_a), #("b", means_b)], 3) -> [Leader("a", 5, ..), Leader("b", 3, ..)]
/// ```
///
pub fn front(
  members: List(#(String, List(#(String, Float)))),
  k: Int,
) -> List(Leader) {
  let tolerance = 1.0 /. int.to_float(int.max(k, 1))

  // Every member carries the same task order, so the first one names the tasks.
  let tasks = case members {
    [first, ..] -> list.map(first.1, fn(entry) { entry.0 })
    [] -> []
  }

  // The best mean per task, over every member, is the bar for leadership.
  let bests =
    list.map(tasks, fn(task) {
      #(
        task,
        list.fold(members, 0.0, fn(best, member) {
          float.max(best, mean_for(member.1, task))
        }),
      )
    })

  let leading =
    list.filter(members, fn(member) { leads(member.1, bests, tolerance) > 0 })
  let survivors =
    list.filter(leading, fn(member) {
      !list.any(leading, fn(other) {
        other.0 != member.0
        && dominance.pareto(member.1, other.1)
        == dominance.Dominated(dominance.Scores)
      })
    })

  list.map(survivors, fn(member) {
    Leader(
      arm: member.0,
      tasks_led: leads(member.1, bests, tolerance),
      means: member.1,
    )
  })
}

fn mean_for(means: List(#(String, Float)), task: String) -> Float {
  result.unwrap(list.key_find(means, task), 0.0)
}

/// How many tasks a member leads: those on which it is within `tolerance`
/// of the best.
fn leads(
  means: List(#(String, Float)),
  bests: List(#(String, Float)),
  tolerance: Float,
) -> Int {
  list.count(bests, fn(best) { mean_for(means, best.0) +. tolerance >=. best.1 })
}

/// Draws the parent in proportion to tasks led, from the step's generator.
/// An empty front cannot happen for a non-empty pool (the seed leads at
/// least the tasks nobody beats it on), but the type says so rather than
/// the caller trusting it.
///
/// ## Examples
///
/// ```gleam
/// // search.draw_parent(leaders, prng.from_string("search/3")) -> Ok(#("a", prng))
/// ```
///
pub fn draw_parent(
  leaders: List(Leader),
  generator: Prng,
) -> Result(#(String, Prng), Nil) {
  let total = list.fold(leaders, 0, fn(sum, leader) { sum + leader.tasks_led })

  // A front that leads nothing has nothing to draw from.
  use Nil <- result.try(case total > 0 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })

  let #(point, generator) = prng.below(generator, total)

  // Walk the leaders, each owning `tasks_led` points of the range.
  let chosen =
    list.fold_until(leaders, #(point, Error(Nil)), fn(held, leader) {
      case held.0 < leader.tasks_led {
        True -> list.Stop(#(held.0, Ok(leader.arm)))
        False -> list.Continue(#(held.0 - leader.tasks_led, Error(Nil)))
      }
    })

  result.map(chosen.1, fn(arm) { #(arm, generator) })
}

/// Draws `size` tune tasks without replacement, in draw order. Fewer tasks
/// than `size` means all of them, shuffled.
///
/// ## Examples
///
/// ```gleam
/// // search.minibatch(["a", "b", "c"], 2, generator) -> #(["c", "a"], generator)
/// ```
///
pub fn minibatch(
  tasks: List(String),
  size: Int,
  generator: Prng,
) -> #(List(String), Prng) {
  draw_without_replacement(
    tasks,
    int.min(size, list.length(tasks)),
    generator,
    [],
  )
}

/// Takes `wanted` elements from `remaining` one index draw at a time, so
/// every element is drawn at most once and the order is the draw order.
fn draw_without_replacement(
  remaining: List(String),
  wanted: Int,
  generator: Prng,
  drawn: List(String),
) -> #(List(String), Prng) {
  // Each draw takes one element by index from what is left; the walk ends
  // when enough are drawn or none remain.
  case wanted <= 0 || remaining == [] {
    True -> #(list.reverse(drawn), generator)
    False -> {
      let #(index, generator) = prng.below(generator, list.length(remaining))
      let before = list.take(remaining, index)
      let after = list.drop(remaining, index)

      // The drawn element is the head of the tail; an empty tail cannot
      // happen for an index below the length, but the type says so.
      case after {
        [picked, ..rest] ->
          draw_without_replacement(
            list.append(before, rest),
            wanted - 1,
            generator,
            [picked, ..drawn],
          )
        [] -> #(list.reverse(drawn), generator)
      }
    }
  }
}

/// The slot a step rewrites: round robin over the mutable set, step 1
/// taking the first.
///
/// ## Examples
///
/// ```gleam
/// // search.slot_for(3, [a, b]) == Ok(a)
/// ```
///
pub fn slot_for(step: Int, slots: List(Component)) -> Result(Component, Nil) {
  // Round robin needs at least one slot; step 1 takes the first.
  case slots {
    [] -> Error(Nil)
    [_, ..] -> {
      let index = { int.max(step, 1) - 1 } % list.length(slots)

      list.drop(slots, index) |> list.first
    }
  }
}

/// The spend filter: the child goes on to Validate when the mean over the
/// minibatch tasks of its per-task mean reward is at least the parent's.
/// Both ledgers are paired by task through `per_task_means`, so the
/// comparison is over the same tasks whatever order the rows arrived in.
///
/// ## Examples
///
/// ```gleam
/// // search.screen(parent_rows, child_rows, tasks) == search.Passed
/// ```
///
pub fn screen(
  parent: List(stat.Trial),
  child: List(stat.Trial),
  tasks: List(String),
) -> Screen {
  let parent_mean =
    per_task_means(parent, tasks) |> list.map(fn(entry) { entry.1 }) |> mean_of
  let child_mean =
    per_task_means(child, tasks) |> list.map(fn(entry) { entry.1 }) |> mean_of

  // The child pays for Validate only when it is at least as good as its parent on the minibatch.
  case child_mean >=. parent_mean {
    True -> Passed
    False -> Failed
  }
}

/// The disposition a Validate verdict earns. `against_incumbent` is the
/// verdict against the pool's best when the parent is not it, and `led` the
/// tasks the child and the incumbent lead on a front that includes both.
///
/// ## Examples
///
/// ```gleam
/// // search.dispose(verdict.Harmed(..), None, 0, 0) == search.Harmed
/// ```
///
pub fn dispose(
  against_parent: Verdict,
  against_incumbent: Option(Verdict),
  child_led: Int,
  incumbent_led: Int,
) -> Disposition {
  case against_parent {
    verdict.Improved(..) ->
      // The incumbent changes only when the child is not shown worse than
      // it and leads more tasks; otherwise the child joins below it.
      case not_worse(against_incumbent) && child_led > incumbent_led {
        True -> Incumbent
        False -> Joined
      }
    verdict.Indistinguishable(..) | verdict.Underpowered(..) -> ParetoOnly
    verdict.Harmed(..) -> Harmed
    verdict.Incomplete(..) -> Unsettled
  }
}

/// Whether the child stands against the incumbent: no comparison (the
/// parent is the incumbent) counts as standing, since the parent verdict
/// already decided; `Harmed` or `Incomplete` do not.
fn not_worse(against_incumbent: Option(Verdict)) -> Bool {
  case against_incumbent {
    None -> True
    Some(verdict.Improved(..))
    | Some(verdict.Indistinguishable(..))
    | Some(verdict.Underpowered(..)) -> True
    Some(verdict.Harmed(..)) | Some(verdict.Incomplete(..)) -> False
  }
}

// --- ranking ----------------------------------------------------------------------------

/// One line of the reported front.
pub type Ranked {
  Ranked(
    /// The arm id.
    arm: String,
    /// How it joined the pool.
    disposition: Disposition,
    /// The step that minted it; the seed's is zero.
    step: Int,
    /// Its standing against the seed over outcome and scores.
    dominance: dominance.Dominance,
    /// The tasks it leads.
    tasks_led: Int,
  )
}

/// Orders pool members for the front: the incumbent first, then the
/// members that improved over their parent (and the seed), then the
/// Pareto-only members. Within the improved tier the order is dominance
/// over the seed (outcome before scores, dominating before tied before
/// trading off before undecided before dominated), then tasks led; within
/// the Pareto tier it is the minting step, so a Pareto-only child never
/// stands above its parent; the arm id makes every order total.
///
/// ## Examples
///
/// ```gleam
/// // search.rank(lines, incumbent) -> [incumbent line, ..]
/// ```
///
pub fn rank(lines: List(Ranked), incumbent: String) -> List(Ranked) {
  list.sort(lines, fn(left, right) {
    // The incumbent outranks everything; among the rest the disposition
    // tier, then the tier's own order, then the id.
    case left.arm == incumbent, right.arm == incumbent {
      True, False -> order.Lt
      False, True -> order.Gt
      True, True | False, False ->
        int.compare(standing(left.disposition), standing(right.disposition))
        |> order.lazy_break_tie(fn() { within_tier(left, right) })
        |> order.lazy_break_tie(fn() { string.compare(left.arm, right.arm) })
    }
  })
}

/// The tier a disposition puts a member in: improved first, Pareto last.
fn standing(disposition: Disposition) -> Int {
  case disposition {
    Incumbent | Joined | Confirmed | Unconfirmed -> 0
    ParetoOnly -> 1
    Harmed | Unsettled | Refused | ScreenedOut -> 2
  }
}

/// The order inside one tier: a Pareto member by its step, an improved one
/// by dominance over the seed and then tasks led.
fn within_tier(left: Ranked, right: Ranked) -> order.Order {
  case left.disposition {
    ParetoOnly -> int.compare(left.step, right.step)
    Incumbent
    | Joined
    | Confirmed
    | Unconfirmed
    | Harmed
    | Unsettled
    | Refused
    | ScreenedOut ->
      int.compare(tier(left.dominance), tier(right.dominance))
      |> order.lazy_break_tie(fn() {
        int.compare(right.tasks_led, left.tasks_led)
      })
  }
}

/// The rank of a dominance outcome, lower first.
fn tier(found: dominance.Dominance) -> Int {
  case found {
    dominance.Dominates(dominance.Outcome) -> 0
    dominance.Dominates(dominance.Scores) -> 1
    dominance.Tie -> 2
    dominance.Tradeoff(..) -> 3
    dominance.Undecided -> 4
    dominance.Dominated(dominance.Scores) -> 5
    dominance.Dominated(dominance.Outcome) -> 6
  }
}

/// The per-member rows of a step's pool, as a dictionary by arm, for the
/// callers that look rows up by id.
///
/// ## Examples
///
/// ```gleam
/// // search.by_arm([#("a", rows_a)]) |> dict.get("a") == Ok(rows_a)
/// ```
///
pub fn by_arm(
  members: List(#(String, List(stat.Trial))),
) -> Dict(String, List(stat.Trial)) {
  dict.from_list(members)
}
