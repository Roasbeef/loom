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

import client/auxiliary
import client/catalog.{type Catalog}
import client/evolution/trace
import client/mcp
import core/accounting
import core/message.{type Usage}
import eval/ledger.{type Row}
import eval/task.{type Task}
import eval/wire
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
  )
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
  )
}

/// What the reflector answered and what it reported using.
pub type Reply {
  Reply(
    /// The answer text, unbounded: `answer` judges it.
    text: String,
    /// The usage of every attempt the request took, summed, so a retried
    /// call is charged for its retries.
    usage: Usage,
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
      Ok(auxiliary.Answer(text:, accounting:, ..)) ->
        Ok(Reply(text:, usage: accounting.total(accounting)))
      Error(auxiliary.Failure(reason:, accounting:)) ->
        Error(Refused(
          reason: "the reflector did not answer: " <> reason,
          usage: accounting.total(accounting),
        ))
    }
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

// --- the prompt and the answer --------------------------------------------------------

/// The prompt, as `gepa/prompt` renders it: each record's outcome, task
/// prompt and verifier tail are the framed fields the reflector reads.
///
/// ## Examples
///
/// ```gleam
/// // reflect.render(request) starts with "You are improving one text slot"
/// ```
///
pub fn render(request: Request) -> String {
  prompt.render(
    prompt.Request(
      objective: request.objective,
      slot: request.slot,
      current: request.current,
      records: list.map(request.records, fn(record) {
        prompt.Record(
          task: record.task,
          score: record.reward,
          fields: [
            #("outcome", record.outcome),
            #("prompt", record.prompt),
            #("verifier", record.side_info),
          ],
          hidden: [],
        )
      }),
      notes: [],
    ),
  )
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
