//// Settled-response classification — pi harness spec §3.7, transcribed.
////
//// Classification is pure and computed in memory before the settlement
//// transaction. The order is normative and first match wins (spec §1.3):
////
//// 1. cancelled control
//// 2. overflow (adapter-reported | message-pattern | length below the
////    intended output limit)
//// 3. deferred with a valid handle
//// 4. retryable error (an invalid deferred handle and any other error
////    also land here, carrying their retryability)
//// 5. tool use (or an accepted response carrying calls)
//// 6. stop / genuine output-limit length
////
//// Two normalizations happen at commit and both are deliberate: a
//// cancelled response commits as `aborted`, and an overflow-classified
//// response commits as `error` (context projection then drops it by the
//// standard error rule). An `aborted` stop reason with running control is
//// unreachable and reported as corruption.

import core/corruption.{type CorruptionReport}
import core/message.{
  type AgentMessage, type DeferredHandle, Aborted, AssistantMessage,
  AssistantText, AssistantThinking, AssistantToolCall, CustomMessage, Deferred,
  Errored, Length, Pending, Stop, ToolResultMessage, ToolUse, UserMessage,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation.{type Control, CancelRequested, Running}
import machine/strand.{type ModelIdentity}

/// An assistant message that is guaranteed settled: the stop reason is
/// never `Pending`. Constructed only through `settle`, so the guarantee is
/// a type-level fact everywhere downstream.
pub opaque type SettledAssistantMessage {
  /// Invariant: `message` is an `AssistantMessage` whose stop reason is
  /// not `Pending`.
  SettledAssistantMessage(message: AgentMessage)
}

/// Wraps an assistant message as settled. Total: a non-assistant message
/// or a `Pending` stop reason is a corruption report, never a crash.
///
/// ## Examples
///
/// ```gleam
/// // classification.settle(assistant_with(message.Stop)) == Ok(_)
/// // classification.settle(assistant_with(message.Pending)) == Error(_)
/// ```
///
pub fn settle(
  message: AgentMessage,
) -> Result(SettledAssistantMessage, CorruptionReport) {
  case message {
    AssistantMessage(stop_reason: Pending, ..) ->
      Error(corruption.report(
        at: "machine/classification.settle",
        on: "stop reason",
        expected: "a settled stop reason",
        context: "pending",
      ))
    AssistantMessage(..) -> Ok(SettledAssistantMessage(message:))
    UserMessage(..) | ToolResultMessage(..) | CustomMessage(..) ->
      Error(corruption.report(
        at: "machine/classification.settle",
        on: "message role",
        expected: "an assistant message",
        context: "a non-assistant message",
      ))
  }
}

/// Unwraps the settled message.
///
/// ## Examples
///
/// ```gleam
/// // classification.message(settled) is the wrapped assistant message.
/// ```
///
pub fn message(settled: SettledAssistantMessage) -> AgentMessage {
  settled.message
}

/// Everything `classify` reads besides the settled message itself.
///
/// Constructor invariants: `control` is the operation's durable control at
/// settlement time. `intended_output_limit` is the value persisted in the
/// effect-pending intent (0 when no limit applies, e.g. deferred polls, so
/// the length-below-intended rule never fires). `expected_model` and
/// `expected_api` are the captured request identity, used to validate
/// deferred handles. `error_retryable` is the provider adapter's judgment
/// of the settled error, consulted only when the stop reason is `error`
/// and the error is not an overflow.
pub type ClassifyCtx {
  ClassifyCtx(
    control: Control,
    intended_output_limit: Int,
    expected_model: ModelIdentity,
    expected_api: String,
    error_retryable: Bool,
  )
}

/// The classification outcome, in the normative order's vocabulary.
pub type Classification {
  /// Control is `cancel_requested`: normalize the stop reason to
  /// `aborted` and settle under cancelled control.
  CancelledClassification

  /// The request did not fit the context window: normalize to `error`,
  /// then compact (first time) or drain as failure (second).
  OverflowClassification

  /// A deferred stop with a structurally valid handle: suspend.
  DeferredValidClassification(handle: DeferredHandle)

  /// A deferred stop without a valid handle: normalize to `error` and
  /// drain as failure.
  DeferredInvalidClassification

  /// An error settlement; `retryable` carries the adapter's judgment and
  /// the attempt policy decides between retry wait and failure drain.
  ErrorClassification(retryable: Bool, error_message: String)

  /// The response carries tool calls; `truncated` marks a genuine
  /// output-limit `length` whose calls must be answered with synthetic
  /// truncation errors instead of executing.
  ToolUseClassification(truncated: Bool)

  /// A normal stop or a genuine output-limit length without calls: the
  /// run may finish.
  FinishedClassification

  /// An `aborted` stop reason under running control — unreachable by
  /// construction, therefore corruption (pi invariant 19).
  CorruptClassification(report: CorruptionReport)
}

/// Classifies one settled response. Pure; first match wins in the
/// normative order (see the module doc).
///
/// ## Examples
///
/// ```gleam
/// // classify(stop_response, running_ctx) == FinishedClassification
/// // classify(anything, cancelled_ctx) == CancelledClassification
/// ```
///
pub fn classify(
  settled: SettledAssistantMessage,
  ctx: ClassifyCtx,
) -> Classification {
  let SettledAssistantMessage(message:) = settled
  case message {
    AssistantMessage(
      stop_reason:,
      content:,
      usage:,
      error_message:,
      deferred:,
      ..,
    ) ->
      // Rung 1 first, over both subjects at once: cancelled control wins
      // regardless of stop reason. Under running control, `aborted` is
      // normalized at commit only from cancelled control, so reaching it
      // here is unreachable by construction (pi invariant 19).
      case ctx.control, stop_reason {
        CancelRequested(..), _ -> CancelledClassification
        Running, Aborted ->
          CorruptClassification(report: corruption.report(
            at: "machine/classification.classify",
            on: "stop reason",
            expected: "aborted only under cancel_requested control",
            context: "aborted with running control",
          ))
        Running, _ ->
          // Rung 2 checked before dispatch into the ordinary rungs
          // below: an oversized request must compact rather than
          // retrying unchanged, so overflow pre-empts even a
          // retryable-error verdict `classify_running` would
          // otherwise reach for the same `Errored` stop reason.
          case is_overflow(stop_reason, error_message, usage.output, ctx) {
            True -> OverflowClassification
            False ->
              classify_running(
                stop_reason,
                content,
                error_message,
                deferred,
                ctx,
              )
          }
      }

    // Unreachable by the `settle` invariant; reported totally anyway.
    UserMessage(..) | ToolResultMessage(..) | CustomMessage(..) ->
      CorruptClassification(report: corruption.report(
        at: "machine/classification.classify",
        on: "message role",
        expected: "an assistant message",
        context: "a non-assistant message",
      ))
  }
}

fn classify_running(
  stop_reason: message.StopReason,
  content: List(message.AssistantBlock),
  error_message: Option(String),
  deferred: Option(DeferredHandle),
  ctx: ClassifyCtx,
) -> Classification {
  case stop_reason {
    Deferred ->
      case deferred {
        Some(handle) ->
          case handle_valid(handle, ctx) {
            True -> DeferredValidClassification(handle:)
            False -> DeferredInvalidClassification
          }
        None -> DeferredInvalidClassification
      }
    Errored ->
      ErrorClassification(
        retryable: ctx.error_retryable,
        error_message: option.unwrap(error_message, "provider error"),
      )
    ToolUse -> ToolUseClassification(truncated: False)
    Stop ->
      case has_tool_calls(content) {
        True -> ToolUseClassification(truncated: False)
        False -> FinishedClassification
      }
    Length ->
      case has_tool_calls(content) {
        True -> ToolUseClassification(truncated: True)
        False -> FinishedClassification
      }

    // Pending and Aborted are excluded before this function is reached.
    Pending | Aborted -> FinishedClassification
  }
}

/// The canonical context-overflow message patterns. An adapter that
/// detects overflow itself settles the response as `error` with a message
/// matching one of these, so adapter-reported and message-pattern overflow
/// share one detection path. Matching is lowercase containment.
const overflow_patterns = [
  "context window exceeded", "context length exceeded", "maximum context length",
  "prompt is too long", "input is too long", "request exceeds the maximum size",
]

/// The canonical message prefix the machine uses when it normalizes an
/// overflow settlement itself; matches `overflow_patterns`.
pub const overflow_message_prefix = "context window exceeded"

fn is_overflow(
  stop_reason: message.StopReason,
  error_message: Option(String),
  output_tokens: Int,
  ctx: ClassifyCtx,
) -> Bool {
  case stop_reason {
    Errored -> {
      let text = string.lowercase(option.unwrap(error_message, ""))
      list.any(overflow_patterns, string.contains(text, _))
    }

    // Harness-side heuristic: a length stop whose output is below the
    // intended limit means the input, not the output, hit the window. An
    // intended limit of 0 disables the rule (deferred polls).
    Length -> output_tokens < ctx.intended_output_limit
    _ -> False
  }
}

/// A deferred handle is valid when its id is non-empty and its
/// `{provider, model_id, api}` equals the captured request identity (pi
/// §3.2). Poll-source equality is a separate, stricter check owned by the
/// planner.
fn handle_valid(handle: DeferredHandle, ctx: ClassifyCtx) -> Bool {
  handle.id != ""
  && handle.provider == ctx.expected_model.provider
  && handle.model_id == ctx.expected_model.model_id
  && handle.api == ctx.expected_api
}

fn has_tool_calls(content: List(message.AssistantBlock)) -> Bool {
  list.any(content, fn(block) {
    case block {
      AssistantToolCall(..) -> True
      AssistantText(..) | AssistantThinking(..) -> False
    }
  })
}
