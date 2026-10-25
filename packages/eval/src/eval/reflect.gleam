//// The reflection call: one model request with no tools that reads a
//// slot's current text, the objective and a bounded record of how the
//// parent fared on the tune minibatch, and answers the slot's new text.
////
//// The reflector is a catalogue entry name, resolved once to an exact
//// identity with no fallback, so the model that wrote every candidate is
//// pinned in the search log. It runs as a provider request from the
//// optimizer's own process, the way `client/blocksummary` asks the
//// summarize role: a model call that is not a session and runs no tool.
//// Rule Zero is untouched, because the only place the answer goes is a
//// profile component that the next trial's jailed agent reads, and that
//// agent's effects are brokered as they are for any prompt.
////
//// The injection surface runs the other way. The record the reflector
//// reads is built from the agent under test's own run and from verifier
//// output, and the agent is adversarial to its grader (ADR-021). So:
////
//// - The prompt template is the `gepa/prompt` library's constant and is
////   not an `arm.Component`. The type is closed, so "the reflection prompt
////   as a candidate" is unspellable rather than refused.
//// - Every excerpt is data inside a frame whose tokens are made frame-safe
////   (`prompt.frame_safe` breaks the token where it occurs in a body),
////   scrubbed with `trace.scrub_excerpt`, which the library does not know
////   about and so is applied here, and bounded by the library to
////   `prompt.max_excerpt_bytes` per field and `prompt.max_rows` rows.
//// - Hidden test ids a `Program` verifier names in `side_info` are
////   replaced by `<test N>` (`prompt.redact_ids`), so a reflector cannot
////   learn a test's name and write it into a prefix.
//// - The reflector sees tune rows only: `records` is given the rows of
////   the parent's minibatch and nothing else; nothing here reads a task's
////   verifier files or a Validate ledger.
//// - The answer is bounded (`prompt.answer`): empty, over
////   `prompt.max_answer_bytes`, or carrying a frame token is a refusal the
////   search records and costs.
//// - The call is metered: `dollars` prices the reported usage at the
////   reflector's card and `worst_case` is what the search reserves
////   before calling.
//// - The answer's stop reason travels with it (`Reply.finish`, from the
////   gateway's `StopReason` through `finish_of`), and `judge` refuses an
////   answer the provider cut at its output limit before `prompt.answer`
////   reads it: a rewrite cut mid-sentence can pass every bound and still
////   not be the rewrite the model meant.
////
//// What the reflector is told beyond the records is per slot. `background`
//// is the slot kind's standing constraints — a tool description may not
//// misdescribe the tool's schema or behaviour, a system suffix may not
//// override the operator's system prompt — rendered as the library's
//// notes; `view_for` picks which fields of a record a slot kind reads, so
//// a tool description's reflection sees the trial's tool-call and
//// tool-error counts, which is what the ledger row keeps of the trial's
//// tool use (per-call records are issue #1126's); and the driver hands in
//// the lineage's rejected rewrites of the slot as `tried`.

import client/auxiliary
import client/catalog.{type Catalog}
import client/evolution/trace
import client/mcp
import core/accounting
import core/message.{type Usage}
import eval/arm.{type Component}
import eval/ledger.{type Row}
import eval/task.{type Task}
import eval/wire
import gepa
import gepa/prompt
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/gateway.{type Gateway}
import provider/model.{type ResolvedModel}
import provider/pricing.{type Pricing}

/// Output tokens one reflection may produce.
pub const max_output_tokens = 2048

/// How long one reflection may take.
pub const timeout_ms = 300_000

/// One row of the reflective dataset: what the parent was asked, how it
/// ended, and what the verifier said.
pub type Record {
  Record(
    /// The task's human name.
    task: String,
    /// The task prompt, bounded and scrubbed.
    prompt: String,
    /// The outcome word the ledger uses.
    outcome: String,
    /// The reward in zero to one.
    reward: Float,
    /// The verifier's tail, bounded, scrubbed, test ids redacted.
    side_info: String,
    /// Tool calls the trial made.
    tool_calls: Int,
    /// Tool calls that returned an error.
    tool_errors: Int,
  )
}

/// Which fields of a record a slot's reflection reads.
pub type View {
  /// The outcome, the task prompt and the verifier's tail: what a prompt
  /// slot needs to see how the agent behaved.
  Behaviour

  /// The same, with the trial's tool-call and tool-error counts first:
  /// what a tool's description needs to see whether the tool was used and
  /// whether it failed.
  ToolUse
}

/// Everything a reflection is asked about.
pub type Request {
  Request(
    /// What the operator is optimising for, in their words.
    objective: String,
    /// The slot's name, as `search.slot_name` spells it.
    slot: String,
    /// The slot's current text, possibly empty.
    current: String,
    /// The reflective dataset.
    records: List(Record),
    /// Background and constraints for the slot, shown as data.
    notes: List(String),
    /// Rewrites of this slot the search already rejected, shown as data.
    tried: List(prompt.Tried),
    /// Which fields of each record the slot reads.
    view: View,
  )
}

/// What the reflector answered and what it reported using.
pub type Reply {
  Reply(
    /// The answer text, unbounded: `judge` reads it.
    text: String,
    /// The usage of every attempt the request took, summed, so a retried
    /// call is charged for its retries.
    usage: Usage,
    /// How the answer ended, from the provider's stop reason.
    finish: gepa.Finish,
  )
}

/// A reflection that produced no answer, with what it cost anyway: a
/// timed-out or failed call is billed by the provider all the same.
pub type Refused {
  Refused(
    /// Why no answer came back.
    reason: String,
    /// Every attempt's usage, summed.
    usage: Usage,
  )
}

/// The reflection call as a value, so a test can script it.
pub type Reflector =
  fn(String) -> Result(Reply, Refused)

/// The pinned identity of the reflector, as the search plan records it.
pub type Identity {
  Identity(
    /// The catalogue entry name the operator gave.
    entry: String,
    /// The provider the entry resolves to.
    provider: String,
    /// The model id.
    model_id: String,
    /// The wire API the gateway speaks to it.
    api: String,
  )
}

/// Resolves a catalogue entry name to the identity the search pins and the
/// exact model the request dispatches to. An entry the catalogue lacks, or
/// one no provider is registered for, is refused by name.
///
/// ## Examples
///
/// ```gleam
/// // reflect.resolve(catalogue, gateway, "fixture") -> Ok(#(Identity("fixture", "fixture", "fixture", "anthropic-messages"), resolved))
/// ```
///
pub fn resolve(
  catalogue: Catalog,
  routed: Gateway,
  entry: String,
) -> Result(#(Identity, ResolvedModel), String) {
  use found <- result.try(
    catalog.find(catalogue, entry)
    |> result.map_error(fn(_) {
      "the catalogue holds no reflector model named " <> entry
    }),
  )
  let resolved =
    model.ResolvedModel(..catalog.resolved(found), thinking: model.ThinkingOff)
  use api <- result.map(
    gateway.api_for(routed, resolved)
    |> result.map_error(fn(_) {
      "no provider is registered for the reflector " <> entry
    }),
  )

  #(
    Identity(
      entry:,
      provider: resolved.provider,
      model_id: resolved.model_id,
      api:,
    ),
    resolved,
  )
}

/// A reflector over a gateway, pinned to `resolved` with no fallback, no
/// tools and no system text; the whole request is the rendered prompt.
///
/// ## Examples
///
/// ```gleam
/// // reflect.through_gateway(settings.gateway, resolved)("...") -> Ok(Reply(text, usage))
/// ```
///
pub fn through_gateway(routed: Gateway, resolved: ResolvedModel) -> Reflector {
  let auxiliary.Summarizer(ask:) =
    auxiliary.capped_gateway_summarizer(
      routed,
      model.ForResolved(resolved:),
      timeout_ms:,
      max_output_tokens:,
    )

  fn(prompt) {
    // Either way the whole accounting is charged: `Answer.usage` is the
    // final attempt alone, and a failed call's attempts were billed too.
    case ask(prompt) {
      Ok(auxiliary.Answer(text:, accounting:, stop_reason:, ..)) ->
        Ok(Reply(
          text:,
          usage: accounting.total(accounting),
          finish: finish_of(stop_reason),
        ))
      Error(auxiliary.Failure(reason:, accounting:)) ->
        Error(Refused(
          reason: "the reflector did not answer: " <> reason,
          usage: accounting.total(accounting),
        ))
    }
  }
}

/// The library's word for a provider's stop reason: a normal end is
/// `Complete`, a token limit is `Truncated`, and anything else the call
/// could have settled with (a tool call from a request that offered no
/// tools, an abort, a deferral) is `Unknown`, which `judge` lets through
/// to the bounds rather than guessing.
///
/// ## Examples
///
/// ```gleam
/// assert reflect.finish_of(message.Length) == gepa.Truncated
/// assert reflect.finish_of(message.Stop) == gepa.Complete
/// ```
///
pub fn finish_of(stop_reason: message.StopReason) -> gepa.Finish {
  case stop_reason {
    message.Stop -> gepa.Complete
    message.Length -> gepa.Truncated
    message.Pending
    | message.ToolUse
    | message.Errored
    | message.Aborted
    | message.Deferred -> gepa.Unknown
  }
}

/// The answer a reply earns: refused when the provider cut it at the
/// output limit, else `prompt.answer`'s reading of the text.
///
/// ## Examples
///
/// ```gleam
/// // reflect.judge(Reply("Be brief.", usage, gepa.Complete)) == Ok("Be brief.")
/// // reflect.judge(Reply("Be brief.", usage, gepa.Truncated)) == Error(gepa.truncated_reason)
/// ```
///
pub fn judge(reply: Reply) -> Result(String, String) {
  case reply.finish {
    gepa.Truncated -> Error(gepa.truncated_reason)
    gepa.Complete | gepa.Unknown -> prompt.answer(reply.text)
  }
}

/// What one reflection could cost at worst: a full context window on each
/// of the three input buckets plus the longest output, priced at the card.
///
/// ## Examples
///
/// ```gleam
/// // reflect.worst_case(card, resolved) == 3 * context + output, priced
/// ```
///
pub fn worst_case(card: Pricing, resolved: ResolvedModel) -> Float {
  let worst =
    message.Usage(
      ..accounting.zero_usage(),
      input: resolved.context_window,
      output: int.min(max_output_tokens, resolved.max_output_tokens),
      cache_read: resolved.context_window,
      cache_write: resolved.context_window,
    )

  pricing.price(worst, card).cost.total
}

/// What a reflection cost: the reported usage priced at the card, or the
/// usage's own recorded cost when the provider has no card.
///
/// ## Examples
///
/// ```gleam
/// // reflect.dollars(reply.usage, Some(card)) == 0.0123
/// ```
///
pub fn dollars(usage: Usage, card: Option(Pricing)) -> Float {
  case card {
    Some(card) -> pricing.price(usage, card).cost.total
    None -> usage.cost.total
  }
}

// --- the reflective dataset --------------------------------------------------------

/// The reflective dataset of a parent's minibatch: at most `max_rows` rows
/// in ledger order, each task's prompt and verifier tail bounded and
/// scrubbed, and every hidden test id the task's verifier names replaced
/// by `<test N>`. Rows of tasks the caller did not pass are dropped, which
/// is how the Validate and Holdout splits stay out: the caller passes tune
/// tasks only.
///
/// ## Examples
///
/// ```gleam
/// // reflect.records(rows, tune_tasks) -> [Record("fix-json", "...", "verifier_failed", 0.0, "..."), ..]
/// ```
///
pub fn records(rows: List(Row), tasks: List(Task)) -> List(Record) {
  rows
  |> list.filter(fn(row) { row.state == ledger.Scored })
  |> list.filter_map(fn(row) {
    use found <- result.map(
      list.find(tasks, fn(each) { each.id == row.task })
      |> result.replace_error(Nil),
    )

    Record(
      task: found.name,
      prompt: excerpt(found.prompt),
      outcome: outcome_word(row.outcome),
      reward: row.reward,
      side_info: excerpt(prompt.redact_ids(row.side_info, hidden_ids(found))),
      tool_calls: row.tool_calls,
      tool_errors: row.tool_errors,
    )
  })
  |> list.take(prompt.max_rows)
}

/// The ledger's word for an outcome; a running row has none.
fn outcome_word(outcome: Option(ledger.Outcome)) -> String {
  case outcome {
    Some(ledger.Passed) -> "passed"
    Some(ledger.VerifierFailed) -> "verifier_failed"
    Some(ledger.AgentTimeout) -> "agent_timeout"
    Some(ledger.SafetyRefusal) -> "safety_refusal"
    Some(ledger.Infrastructure) -> "infrastructure"
    None -> "running"
  }
}

/// The test ids a task's verifier names, sorted, which the reflector must
/// never read.
fn hidden_ids(found: Task) -> List(String) {
  case found.verifier {
    task.Program(fail_to_pass:, pass_to_pass:, ..) ->
      wire.sorted_set(list.append(fail_to_pass, pass_to_pass))
    task.ExpectedFiles(..) -> []
  }
}

/// One excerpt: scrubbed by the trace scrubber, then made frame-safe and
/// cut to `prompt.max_excerpt_bytes` by the library, keeping the end,
/// where a verifier's verdict sits.
fn excerpt(text: String) -> String {
  prompt.excerpt(trace.scrub_excerpt(text, 65_536))
}

// --- what each slot is told -------------------------------------------------------------

/// The standing constraints of a slot's kind, in the operator's stead,
/// shown to the reflector as the slot's notes. A tool's description is
/// read by the model as a contract, so one that promises what the tool
/// does not do, or hides an argument it takes, misleads every later turn;
/// the note says so before the model rewrites it.
///
/// ## Examples
///
/// ```gleam
/// // reflect.background(ToolDescription(target, "fs_read")) mentions the schema
/// ```
///
pub fn background(component: Component) -> String {
  case component {
    arm.SystemSuffix(..) ->
      "This text is appended to the agent's system prompt for every task. "
      <> "It may add guidance and priorities; it may not contradict or "
      <> "override the operator's system prompt, name specific tests or "
      <> "files, or instruct the agent to game a verifier."
    arm.TaskPrefix(..) ->
      "This text is placed before every task's prompt. It may frame how the "
      <> "agent should approach a task; it may not restate or answer any one "
      <> "task, name specific tests or files, or claim facts about the "
      <> "repository it cannot know for every task."
    arm.ToolDescription(tool:, ..) ->
      "This text is the description of the tool `"
      <> tool
      <> "` as the agent sees it. It may not misdescribe the tool's schema or "
      <> "behaviour: every argument it names must exist and mean what the "
      <> "tool makes it mean, and it may not promise a result the tool does "
      <> "not produce. Say when the tool should and should not be chosen, "
      <> "and what its errors mean."
    arm.PromptPack ->
      "This text is the named prompt pack the agent runs under. It may not "
      <> "name specific tests or files, or instruct the agent to game a "
      <> "verifier."
  }
}

/// Which fields of a record a slot's kind reads: a tool's description is
/// shown the trial's tool use first; every prompt slot is shown behaviour.
///
/// ## Examples
///
/// ```gleam
/// assert reflect.view_for(arm.PromptPack) == reflect.Behaviour
/// ```
///
pub fn view_for(component: Component) -> View {
  case component {
    arm.ToolDescription(..) -> ToolUse
    arm.SystemSuffix(..) | arm.TaskPrefix(..) | arm.PromptPack -> Behaviour
  }
}

// --- the prompt and the answer --------------------------------------------------------

/// The prompt, as `gepa/prompt` renders it: each record's fields under the
/// request's view, the slot's notes and the rejected rewrites framed as
/// data.
///
/// ## Examples
///
/// ```gleam
/// // reflect.render(request) starts with "You are improving one text slot"
/// ```
///
pub fn render(request: Request) -> String {
  prompt.render(prompt.Request(
    objective: request.objective,
    slot: request.slot,
    current: request.current,
    records: list.map(request.records, fn(record) {
      prompt.Record(
        task: record.task,
        score: record.reward,
        fields: fields(record, request.view),
        hidden: [],
      )
    }),
    notes: request.notes,
    tried: request.tried,
  ))
}

/// The fields of one record under a view.
fn fields(record: Record, view: View) -> List(#(String, String)) {
  let behaviour = [
    #("outcome", record.outcome),
    #("prompt", record.prompt),
    #("verifier", record.side_info),
  ]

  // A tool's description is shown the tool use before the behaviour.
  case view {
    Behaviour -> behaviour
    ToolUse -> [
      #(
        "tools",
        int.to_string(record.tool_calls)
          <> " tool calls, "
          <> int.to_string(record.tool_errors)
          <> " returned an error",
      ),
      ..behaviour
    ]
  }
}

/// The digest the log records of a prompt or an answer.
///
/// ## Examples
///
/// ```gleam
/// // reflect.digest("x") == mcp.sha256_hex("x")
/// ```
///
pub fn digest(text: String) -> String {
  mcp.sha256_hex(text)
}
