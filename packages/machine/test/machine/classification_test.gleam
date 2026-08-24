//// Classification-order tests: the normative first-match-wins order of
//// spec §1.3, plus the two normalization-adjacent corruption rules.

import core/message
import gleam/option.{None, Some}
import machine/classification.{
  CancelledClassification, ClassifyCtx, CorruptClassification,
  DeferredInvalidClassification, DeferredValidClassification,
  ErrorClassification, FinishedClassification, OverflowClassification,
  ToolUseClassification,
}
import machine/operation.{CancelRequested, Running}
import machine/strand.{ModelIdentity}
import support/fixture

fn running_ctx() -> classification.ClassifyCtx {
  ClassifyCtx(
    control: Running,
    intended_output_limit: 4096,
    expected_model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    expected_api: "acme-api",
    error_retryable: False,
  )
}

fn cancelled_ctx() -> classification.ClassifyCtx {
  ClassifyCtx(
    ..running_ctx(),
    control: CancelRequested(
      requested_at: 1,
      drained_steer: [],
      drained_follow_up: [],
    ),
  )
}

pub fn settle_rejects_pending_test() {
  let assert Error(_report) =
    classification.settle(fixture.assistant(message.Pending, "draft", 1))
}

pub fn settle_rejects_non_assistant_test() {
  let assert Error(_report) = classification.settle(fixture.user("hi"))
}

pub fn cancelled_wins_over_everything_test() {
  // Even an overflow-shaped error classifies cancelled first.
  let overflow = fixture.assistant_error("context window exceeded: big", True)
  assert classification.classify(fixture.settled(overflow), cancelled_ctx())
    == CancelledClassification
}

pub fn aborted_with_running_control_is_corruption_test() {
  let aborted = fixture.assistant(message.Aborted, "", 0)
  let assert CorruptClassification(report: _) =
    classification.classify(fixture.settled(aborted), running_ctx())
}

pub fn overflow_by_message_pattern_test() {
  let overflow =
    fixture.assistant_error("Prompt is too long for this model", True)
  // Overflow is checked before retryable error, so an oversized request
  // compacts rather than retrying unchanged.
  assert classification.classify(fixture.settled(overflow), running_ctx())
    == OverflowClassification
}

pub fn overflow_by_length_below_intended_test() {
  // A length stop with output below the intended limit is input overflow.
  let short = fixture.assistant(message.Length, "tiny", 10)
  assert classification.classify(fixture.settled(short), running_ctx())
    == OverflowClassification
}

pub fn genuine_length_at_intended_limit_finishes_test() {
  let genuine = fixture.assistant(message.Length, "long output", 5000)
  assert classification.classify(fixture.settled(genuine), running_ctx())
    == FinishedClassification
}

pub fn genuine_length_with_calls_is_truncated_tool_use_test() {
  let calls = fixture.assistant_calls(["bash"])
  let truncated = case calls {
    message.AssistantMessage(..) ->
      message.AssistantMessage(
        ..calls,
        stop_reason: message.Length,
        usage: fixture.usage_of(100, 5000),
      )
    other -> other
  }
  assert classification.classify(fixture.settled(truncated), running_ctx())
    == ToolUseClassification(truncated: True)
}

pub fn deferred_valid_handle_test() {
  let handle = fixture.handle("job-1")
  let deferred = fixture.assistant_deferred(Some(handle))
  assert classification.classify(fixture.settled(deferred), running_ctx())
    == DeferredValidClassification(handle:)
}

pub fn deferred_wrong_identity_is_invalid_test() {
  let handle =
    message.DeferredHandle(..fixture.handle("job-1"), provider: "other")
  let deferred = fixture.assistant_deferred(Some(handle))
  assert classification.classify(fixture.settled(deferred), running_ctx())
    == DeferredInvalidClassification
}

pub fn deferred_missing_handle_is_invalid_test() {
  let deferred = fixture.assistant_deferred(None)
  assert classification.classify(fixture.settled(deferred), running_ctx())
    == DeferredInvalidClassification
}

pub fn deferred_empty_id_is_invalid_test() {
  let deferred = fixture.assistant_deferred(Some(fixture.handle("")))
  assert classification.classify(fixture.settled(deferred), running_ctx())
    == DeferredInvalidClassification
}

pub fn retryable_error_carries_adapter_judgment_test() {
  let error = fixture.assistant_error("overloaded", True)
  let ctx = ClassifyCtx(..running_ctx(), error_retryable: True)
  assert classification.classify(fixture.settled(error), ctx)
    == ErrorClassification(retryable: True, error_message: "overloaded")
}

pub fn terminal_error_test() {
  let error = fixture.assistant_error("invalid request", False)
  assert classification.classify(fixture.settled(error), running_ctx())
    == ErrorClassification(retryable: False, error_message: "invalid request")
}

pub fn tool_use_test() {
  let calls = fixture.assistant_calls(["bash"])
  assert classification.classify(fixture.settled(calls), running_ctx())
    == ToolUseClassification(truncated: False)
}

pub fn stop_with_calls_is_tool_use_test() {
  // An accepted response carrying calls plans tools even on stop.
  let calls = fixture.assistant_calls(["bash"])
  let stop_with_calls = case calls {
    message.AssistantMessage(..) ->
      message.AssistantMessage(..calls, stop_reason: message.Stop)
    other -> other
  }
  assert classification.classify(
      fixture.settled(stop_with_calls),
      running_ctx(),
    )
    == ToolUseClassification(truncated: False)
}

pub fn plain_stop_finishes_test() {
  let stop = fixture.assistant(message.Stop, "done", 20)
  assert classification.classify(fixture.settled(stop), running_ctx())
    == FinishedClassification
}
