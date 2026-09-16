import core/json
import core/message
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/image_budget

fn prompt(images: List(Int)) -> message.AgentMessage {
  message.UserMessage(
    content: [
      message.UserText("inspect these", None),
      ..list.map(images, fn(n) {
        message.UserImage(bit_array.base64_encode(<<n>>, True), "image/png")
      })
    ],
    timestamp: 12,
    origin: Some(message.Origin("owner", "Owner")),
  )
}

fn result(images: List(Int)) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "read-pictures",
    tool_name: "fs_read",
    content: [
      message.ToolResultText("pictures", None),
      ..list.map(images, fn(n) {
        message.ToolResultImage(
          bit_array.base64_encode(<<n>>, True),
          "image/png",
        )
      })
    ],
    details: Some(json.String("metadata")),
    usage: None,
    added_tool_names: Some(["helper"]),
    is_error: False,
    timestamp: 13,
  )
}

pub fn old_images_are_trimmed_without_losing_text_or_metadata_test() {
  let old = prompt([1, 2, 3, 4, 5, 6, 7, 8])
  let old_result = result([9, 10, 11, 12])
  let newest = prompt([13, 14])
  let context = [old, old_result, newest]
  let assert Ok([trimmed, preserved_result, preserved_newest]) =
    image_budget.project(context, 8, 0)
    as "twelve historical images and two new ones must fit into eight"
  assert preserved_result == old_result
  assert preserved_newest == newest
  let assert message.UserMessage(..) as old = old
    as "the fixture is a user message"
  let assert message.UserMessage(content:, ..) = trimmed
    as "trimming must preserve message roles"
  assert message.UserMessage(..old, content:) == trimmed
  let assert [message.UserText("inspect these", None), ..blocks] = content
    as "ordinary text must remain byte-identical"
  assert list.drop(blocks, 6) == list.drop(old.content, 7)
  list.each(list.take(blocks, 6), fn(block) {
    let assert message.UserText(text:, text_signature: None) = block
      as "omitted image blocks must become explicit placeholders"
    assert string.contains(text, "omitted from this request")
    assert string.contains(text, "retained in conversation history")
  })
  assert image_budget.count(context) == 14
  assert image_budget.count([trimmed, preserved_result, preserved_newest]) == 8
}

pub fn historical_tool_images_preserve_result_identity_test() {
  let old_result = result([1, 2, 3])
  let latest = prompt([4])
  let assert Ok([trimmed, latest_after]) =
    image_budget.project([old_result, latest], 2, 0)
    as "old tool-result pixels must obey the same limit"
  let assert message.ToolResultMessage(..) as old = old_result
    as "the fixture is a tool result"
  let assert message.ToolResultMessage(content:, ..) = trimmed
    as "image trimming must preserve the tool result"
  assert trimmed == message.ToolResultMessage(..old, content:)
  assert list.last(content) == list.last(old.content)
  assert latest_after == latest
  assert image_budget.count([trimmed, latest_after]) == 2
}

pub fn active_prompt_and_tool_images_cannot_be_silently_dropped_test() {
  let assert Error(reason) =
    image_budget.project([prompt([1, 2, 3, 4]), result([5, 6, 7, 8, 9])], 8, 0)
    as "the entire active turn must remain visible or be refused"
  assert string.contains(reason, "current turn contains 9 images")
  assert string.contains(reason, "at most 8")
  assert string.contains(reason, "new prompt")
}

pub fn held_batch_protection_survives_a_final_text_prompt_test() {
  let context = [prompt([1, 2, 3, 4, 5, 6, 7, 8, 9]), prompt([])]
  let assert Error(_) = image_budget.project(context, 8, 9)
    as "a held batch is one active run even when its last prompt is text"
  let assert Ok(projected) = image_budget.project(context, 8, 0)
    as "a genuinely new text run may omit earlier failed images"
  assert image_budget.count(projected) == 8
}

pub fn within_limit_is_identity_and_invalid_limit_is_local_test() {
  let context = [prompt([1, 2]), result([3])]
  assert image_budget.project(context, 3, 3) == Ok(context)
  assert image_budget.project(context, 3, 100) == Ok(context)
  assert image_budget.project([], 8, 0) == Ok([])
  assert image_budget.project(context, 0, 0)
    == Error("max_images must be a positive integer")
  assert image_budget.project(context, -1, 0)
    == Error("max_images must be a positive integer")
}

// Legacy messages have no attribution, so settled assistant responses still
// bound their turns. A tool call is a continuation, not a completed answer.
pub fn assistant_boundaries_preserve_answers_and_tool_continuations_test() {
  let assert message.UserMessage(..) as original =
    prompt([1, 2, 3, 4, 5, 6, 7, 8, 9])
    as "the fixture is a user message"
  let legacy = message.UserMessage(..original, origin: None)
  let answer =
    message.AssistantMessage(
      content: [message.AssistantText("I saw nine diagrams.", None)],
      api: "fixture",
      provider: "fixture",
      model: "fixture",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: message.Usage(
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        cache_write_1h: None,
        reasoning: None,
        total_tokens: 0,
        cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      ),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 10,
    )
  let next = message.UserMessage([message.UserText("continue", None)], 11, None)
  let assert Ok([_, kept_answer, kept_next]) =
    image_budget.project([legacy, answer, next], 8, 0)
    as "an answered legacy image turn can be budgeted"
  assert kept_answer == answer
  assert kept_next == next
  let step = message.AssistantMessage(..answer, stop_reason: message.ToolUse)
  let assert Error(_) = image_budget.project([legacy, step, result([10])], 8, 0)
    as "tool use keeps the image turn active"
}
