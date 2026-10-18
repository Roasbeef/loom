//// The harness's own single-prompt model requests, and the ledger row each
//// one leaves behind.
////
//// ## Flow
////
//// `target` → `gateway_summarizer` or `capped_gateway_summarizer` →
//// `bound_gateway_summarizer` → `record_request`
////
//// 1. `target` picks the identity a request dispatches to: the `Summarize`
////    role when the catalogue routes one, the resolved main entry otherwise.
//// 2. `gateway_summarizer` and `capped_gateway_summarizer` turn that target
////    into a `Summarizer` through `bound_gateway_summarizer`, whose request
////    sends one prompt and awaits its terminal event.
//// 3. A caller that kept the answer's accounting commits it with
////    `record_request`, so the cost lands in the session ledger where the
////    session lives.
////
//// # Why a seam rather than a gateway call
////
//// The block summaries and the glance loop each ask a cheap model one
//// question and want a line or two back. Both reach the provider through a
//// `Summarizer` and not through the gateway directly, which is what lets a
//// test script every answer and failure without a network. `ask` is total:
//// it returns a typed `Failure` and does not crash, and it has already
//// decided which identity the prompt dispatches to.
////
//// # Accounting survives both outcomes
////
//// Both success and failure carry the full request accounting, including
//// every fallback attempt, and the final response's usage stays separate
//// from it. A local refusal before dispatch has no remote attempts and so
//// writes no ledger row.

import client/internal/ffi_os
import core/accounting
import core/clock
import core/entry
import core/ids
import core/json
import core/message.{type AgentMessage, type Usage}
import core/tx.{InsertUsage, Tx}
import core/usage_evidence
import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway as provider_gateway
import provider/model.{type RequestTarget, ForResolved, ForRole}
import provider/stream
import session/session
import storage/storage

/// The final model response and the accounting of its complete request.
pub type Answer {
  /// A successful answer whose context usage remains the final attempt.
  Answer(
    /// The final response's text.
    text: String,
    /// The final attempt's usage, suitable for context estimation.
    usage: Usage,
    /// All attempts consumed by the logical request.
    accounting: accounting.RequestAccounting,
  )
}

/// A failed request's diagnostic and consumption, retained independently.
pub type Failure {
  /// The diagnostic may be displayed; accounting remains a typed ledger input.
  Failure(
    /// A redacted explanation of why no answer was produced.
    reason: String,
    /// All observations retained before the request failed.
    accounting: accounting.RequestAccounting,
  )
}

/// The whole provider surface of an auxiliary request: one prompt in, one
/// settled answer out.
///
/// Constructor invariants: `ask` is total, returning a typed `Failure`
/// rather than crashing, and it has already decided which identity the
/// prompt dispatches to (`target`). Production fills it with
/// `gateway_summarizer`; a test fills it with a script and the caller cannot
/// tell the difference.
pub type Summarizer {
  /// The request retains accounting on either result branch.
  Summarizer(
    /// Dispatches one prompt and returns its final answer or failure report.
    ask: fn(String) -> Result(Answer, Failure),
  )
}

/// How long one provider turn may take, in milliseconds.
pub const default_timeout_ms = 300_000

/// Commits one auxiliary provider request's aggregate and bounded metadata.
/// Local refusals with no remote attempts write no ledger row. A commit
/// failure returns before callers may publish the summary derived from it.
///
/// ## Examples
///
/// ```gleam
/// assert auxiliary.record_request(session, accounting.empty(), "glance") == Ok(Nil)
/// ```
@internal
pub fn record_request(
  owner: session.Session,
  report: accounting.RequestAccounting,
  phase: String,
) -> Result(Nil, String) {
  use <- bool.guard(when: accounting.attempts(report) == 0, return: Ok(Nil))
  let generator =
    ids.generator(
      clock.from_function(ffi_os.system_time_ms),
      seed: ffi_os.unique_positive_integer(),
    )
  let #(id, _generator) = ids.mint_usage(generator)
  let row =
    entry.UsageRow(
      id:,
      seq: 0,
      entry_id: None,
      adjustment: False,
      usage: accounting.total(report),
      details: Some(
        accounting.details(report, [#("phase", json.String(phase))]),
      ),
    )
  storage.commit(owner.store, Tx(writes: [InsertUsage(row)], expected: []))
  |> result.map(fn(_committed) { Nil })
  |> result.map_error(fn(error) {
    "the request usage row did not commit: " <> string.inspect(error)
  })
}

/// Which identity an auxiliary request dispatches to: the `Summarize` role
/// when the catalogue routes one, and the resolved main entry otherwise.
///
/// The summary path's exact arrangement (`client/wiring`'s
/// `summary_target`), and for its reason: routing a one-line summary to a
/// cheap model is what the role exists for, and there is no durable
/// identity contract to honour, because the result is published as text and
/// not as a response attributed to a model.
///
/// ## Examples
///
/// ```gleam
/// // auxiliary.target(gateway) == model.ForRole(model.Summarize, option.None)
/// ```
///
pub fn target(
  gateway: provider_gateway.Gateway,
) -> Result(RequestTarget, String) {
  case provider_gateway.resolve(gateway, model.Summarize) {
    Ok(_routed) -> Ok(ForRole(role: model.Summarize, thinking: None))
    Error(_missing) ->
      provider_gateway.resolve(gateway, model.Main)
      |> result.map(fn(resolved) { ForResolved(resolved:) })
      |> result.replace_error(
        "the catalogue routes neither a summarize nor a main model",
      )
  }
}

/// The production summarizer: one prompt becomes one provider request on
/// `target`, awaited to its terminal event.
///
/// ## Examples
///
/// ```gleam
/// // auxiliary.gateway_summarizer(gateway, target, timeout_ms: 300_000)
/// ```
///
pub fn gateway_summarizer(
  gateway: provider_gateway.Gateway,
  target: RequestTarget,
  timeout_ms timeout_ms: Int,
) -> Summarizer {
  bound_gateway_summarizer(gateway, target, timeout_ms, None)
}

/// `gateway_summarizer` with the answer capped at `max_output_tokens`, for
/// a caller whose answer is a line or two and who pays for the request on
/// every refresh. The cap is sent as the request's own output ceiling, so
/// it overrides the resolved model's default rather than truncating after
/// the fact.
///
/// ## Examples
///
/// ```gleam
/// // auxiliary.capped_gateway_summarizer(gateway, target, timeout_ms: 30_000,
/// //   max_output_tokens: 160)
/// ```
///
pub fn capped_gateway_summarizer(
  gateway: provider_gateway.Gateway,
  target: RequestTarget,
  timeout_ms timeout_ms: Int,
  max_output_tokens max_output_tokens: Int,
) -> Summarizer {
  bound_gateway_summarizer(gateway, target, timeout_ms, Some(max_output_tokens))
}

fn bound_gateway_summarizer(
  gateway: provider_gateway.Gateway,
  target: RequestTarget,
  timeout_ms: Int,
  max_output_tokens: Option(Int),
) -> Summarizer {
  Summarizer(ask: fn(prompt) {
    let stream.PreparedStream(handle:, begin:) =
      provider_gateway.prepare(
        gateway,
        model.ProviderRequest(
          target:,
          system: None,
          messages: [user(prompt)],
          tools: [],
          max_output_tokens:,
        ),
      )

    // The timeout path cannot reconstruct an exit reason after a fast owner
    // has gone. Retaining the monitor before begin makes the later drain wait
    // an observation of the real exit rather than a `noproc` guess.
    let drain_witness = stream.watch_drain(handle)
    begin()
    case stream.await_terminal(handle, within: timeout_ms) {
      Error(Nil) -> {
        stream.cancel(handle)

        // A caller may issue the next billable request as soon as this call
        // returns. A timeout ends the receive, not the work; keep this step
        // private until the old provider subtree is gone.
        case stream.await_drain_forever(drain_witness) {
          stream.Drained ->
            Error(Failure(
              "the model did not answer inside the timeout",
              timeout_accounting(handle),
            ))
          stream.TimedOut | stream.ProofLost -> {
            process.kill(process.self())
            Error(Failure(
              "the provider owner exited without proving drain",
              unknown_accounting(),
            ))
          }
        }
      }
      Ok(#(_deltas, stream.Failed(error:, accounting: report))) -> {
        stream.release_drain(drain_witness)
        Error(Failure(stream.describe_error(error), report))
      }
      Ok(#(_deltas, stream.Delta(..))) -> {
        stream.release_drain(drain_witness)
        Error(Failure(
          "the stream ended on a delta, which cannot happen",
          unknown_accounting(),
        ))
      }
      Ok(#(_deltas, stream.Settled(message:, accounting: report))) -> {
        stream.release_drain(drain_witness)
        let settled = stream.message(message)
        Ok(Answer(
          text: settled_text(settled),
          usage: final_usage(settled),
          accounting: report,
        ))
      }
    }
  })
}

// Drain orders the terminal publication before owner exit. A local timeout
// may therefore retain the gateway's report even though it refuses the answer.
fn timeout_accounting(
  handle: stream.StreamHandle,
) -> accounting.RequestAccounting {
  case stream.await_terminal(handle, within: 0) {
    Ok(#(_, stream.Settled(accounting: report, ..)))
    | Ok(#(_, stream.Failed(accounting: report, ..))) -> report
    Ok(#(_, stream.Delta(..))) | Error(Nil) -> unknown_accounting()
  }
}

// A lost remote terminal cannot establish zero consumption.
fn unknown_accounting() -> accounting.RequestAccounting {
  accounting.from_usage(accounting.unknown_usage(usage_evidence.Other))
}

// The settled response owns context usage, independently of fallback totals.
fn final_usage(settled: AgentMessage) -> Usage {
  case settled {
    message.AssistantMessage(usage:, ..) -> usage
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> accounting.total(unknown_accounting())
  }
}

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn settled_text(settled: AgentMessage) -> String {
  case settled {
    message.AssistantMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantText(text:, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join("\n")
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> ""
  }
}
