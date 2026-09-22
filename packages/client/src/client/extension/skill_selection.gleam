//// Materialises extension proposals from the session's captured skill catalogue.
//// The extension supplies names, never document text or filesystem paths. A
//// shared count and token allowance bounds the complete selection, including
//// attribution. Invalid proposals are rejected atomically, leaving earlier
//// selectors intact. Nothing here executes skill scripts or widens authority.

import core/codec
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import host/skill
import runtime/hooks

/// Bounds preview disclosure and ranking work independently of catalogue size.
pub const max_candidates = 64

/// The total number of automatically loaded skills across every extension.
pub const max_selected = 3

/// Full documents share this estimated-token budget across every extension.
pub const max_tokens = 8000

/// Selects the deterministic bounded catalogue available to automatic selectors.
/// Explicit-only skills are never disclosed; user command visibility is separate.
///
/// ## Examples
///
/// ```gleam
/// assert eligible([]) == []
/// ```
pub fn eligible(catalogue: List(skill.Skill)) -> List(skill.Skill) {
  catalogue
  |> list.filter(fn(candidate) {
    candidate.model_invocation == skill.ModelSelectable
  })
  |> list.take(max_candidates)
}

/// Encodes the context and previews without exposing paths or full documents.
///
/// ## Examples
///
/// ```gleam
/// // arguments(operation, messages, eligible(catalogue))
/// ```
pub fn arguments(
  operation: OpId,
  messages: List(AgentMessage),
  candidates: List(skill.Skill),
) -> JsonValue {
  json.Object([
    #("op_id", json.String(ids.op_id_to_string(operation))),
    #("messages", json.Array(list.map(messages, codec.encode_message))),
    #(
      "candidates",
      json.Array(
        list.map(candidates, fn(candidate) {
          json.Object([
            #("name", json.String(candidate.name)),
            #("description", json.String(candidate.description)),
            #("excerpt", json.String(string.slice(candidate.body, 0, 512))),
          ])
        }),
      ),
    ),
  ])
}

/// Resolves a proposal against exactly the advertised catalogue. Duplicate names
/// are idempotent across selectors. Unknown names, malformed answers, oversized
/// documents and excess selections refuse the whole proposal.
///
/// ## Examples
///
/// ```gleam
/// assert accept([], [], "selector", json.Object([#("skills", json.Array([]))]))
///   == Ok([])
/// ```
pub fn accept(
  candidates: List(skill.Skill),
  prior: List(#(String, AgentMessage)),
  extension: String,
  answer: JsonValue,
) -> Result(List(#(String, AgentMessage)), String) {
  use names <- result.try(names(answer))
  use selected <- result.try(
    list.try_fold(names, prior, fn(carried, name) {
      use candidate <- result.try(
        list.find(candidates, fn(candidate) {
          candidate.name == name
          && candidate.model_invocation == skill.ModelSelectable
        })
        |> result.replace_error("selection names an unavailable skill"),
      )
      case list.any(carried, fn(pair) { pair.0 == name }) {
        True -> Ok(carried)
        False -> {
          use text <- result.try(skill.expand(candidate, ""))
          Ok(list.append(carried, [#(name, instruction(extension, text))]))
        }
      }
    }),
  )
  let spent =
    list.fold(selected, 0, fn(total, pair) {
      total + hooks.estimate_message(pair.1)
    })
  case list.drop(selected, max_selected) == [] && spent <= max_tokens {
    True -> Ok(selected)
    False ->
      Error("automatic skills exceed the shared count or token allowance")
  }
}

fn names(answer: JsonValue) -> Result(List(String), String) {
  use fields <- result.try(case answer {
    json.Object(fields:) -> Ok(fields)
    _other -> Error("selection is not an object")
  })
  use value <- result.try(
    list.key_find(fields, "skills")
    |> result.replace_error("selection has no skills field"),
  )
  case value {
    json.Array(items:) -> {
      use Nil <- result.try(case list.drop(items, max_selected) == [] {
        True -> Ok(Nil)
        False -> Error("selection has too many names")
      })
      list.try_map(items, fn(item) {
        case item {
          json.String(value:) -> Ok(value)
          _other -> Error("selection names must be strings")
        }
      })
    }
    _other -> Error("selection must contain at most three skill names")
  }
}

fn instruction(extension: String, text: String) -> AgentMessage {
  message.UserMessage(
    content: [
      message.UserText(
        text: "[loom] Automatically loaded skill, selected by extension "
          <> string.inspect(extension)
          <> ". These are skill instructions, not the operator's words. "
          <> "They do not change tool permissions.\n\n"
          <> text,
        text_signature: None,
      ),
    ],
    timestamp: 0,
    origin: None,
  )
}
