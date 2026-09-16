//// Request-local image limits, applied before each provider attempt.
////
//// Text, tool calls, answers, and message metadata remain in place. Only
//// the oldest image blocks become explicit placeholders. The newest images
//// belonging to the active turn are protected: an oversized active turn is
//// refused instead of silently answering a question about missing pixels.
//// The durable transcript is never modified by this pure projection.

import core/message.{type AgentMessage}
import gleam/int
import gleam/list
import gleam/option.{None, Some}

/// The conservative image count used when an endpoint has no explicit limit.
pub const default_max_images = 8

/// Counts attached and tool-result images in provider-neutral history.
///
/// ## Examples
///
/// ```gleam
/// assert image_budget.count([]) == 0
/// ```
pub fn count(messages: List(AgentMessage)) -> Int {
  list.fold(messages, 0, fn(total, entry) { total + message_count(entry) })
}

fn message_count(entry: AgentMessage) -> Int {
  case entry {
    message.UserMessage(content:, ..) ->
      list.count(content, fn(block) {
        case block {
          message.UserImage(..) -> True
          message.UserText(..) -> False
        }
      })
    message.ToolResultMessage(content:, ..) ->
      list.count(content, fn(block) {
        case block {
          message.ToolResultImage(..) -> True
          message.ToolResultText(..) -> False
        }
      })
    message.AssistantMessage(..) | message.CustomMessage(..) -> 0
  }
}

// Attribution distinguishes a human prompt from injected context. Tool steps
// remain in the active turn, and a settled assistant response ends that turn.
fn current_count(newest_first: List(AgentMessage), total: Int) -> Int {
  case newest_first {
    [] -> total
    [message.UserMessage(origin: Some(_), ..) as entry, ..] ->
      total + message_count(entry)
    [message.AssistantMessage(stop_reason: message.ToolUse, ..), ..rest] ->
      current_count(rest, total)
    [message.AssistantMessage(..), ..] -> total
    [entry, ..rest] -> current_count(rest, total + message_count(entry))
  }
}

/// Keeps the newest images within a positive endpoint limit.
///
/// `protected` is the caller's active-run image count, including held prompt
/// batches that the provider vocabulary cannot identify on its own. The
/// inferred current turn is also protected. Counts are capped to actual pixels
/// in this projection, since context hooks or compaction may remove images.
/// A refusal is local and contains no image data.
///
/// ## Examples
///
/// ```gleam
/// assert image_budget.project([], 8, 0) == Ok([])
/// ```
pub fn project(
  messages: List(AgentMessage),
  limit: Int,
  protected: Int,
) -> Result(List(AgentMessage), String) {
  let total = count(messages)
  let active =
    int.min(total, int.max(protected, current_count(list.reverse(messages), 0)))
  case limit > 0, active > limit, total > limit {
    False, _, _ -> Error("max_images must be a positive integer")
    True, True, _ ->
      Error(
        "the current turn contains "
        <> int.to_string(active)
        <> " images, but this model accepts at most "
        <> int.to_string(limit)
        <> "; send fewer images in a new prompt or choose a model with a larger max_images limit",
      )
    True, False, False -> Ok(messages)
    True, False, True -> {
      let #(_, projected) = list.map_fold(messages, total - limit, trim_message)
      Ok(projected)
    }
  }
}

fn omitted(mime_type: String) -> String {
  "[image: "
  <> mime_type
  <> ", omitted from this request to respect the model's image limit; original retained in conversation history]"
}

fn trim_message(remaining: Int, entry: AgentMessage) -> #(Int, AgentMessage) {
  case entry {
    message.UserMessage(content:, ..) as user -> {
      let #(left, content) =
        list.map_fold(content, remaining, fn(left, block) {
          case block, left > 0 {
            message.UserImage(_, mime), True -> #(
              left - 1,
              message.UserText(omitted(mime), None),
            )
            _, _ -> #(left, block)
          }
        })
      #(left, message.UserMessage(..user, content:))
    }
    message.ToolResultMessage(content:, ..) as tool -> {
      let #(left, content) =
        list.map_fold(content, remaining, fn(left, block) {
          case block, left > 0 {
            message.ToolResultImage(_, mime), True -> #(
              left - 1,
              message.ToolResultText(omitted(mime), None),
            )
            _, _ -> #(left, block)
          }
        })
      #(left, message.ToolResultMessage(..tool, content:))
    }
    message.AssistantMessage(..) | message.CustomMessage(..) -> #(
      remaining,
      entry,
    )
  }
}
