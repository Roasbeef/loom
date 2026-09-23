//// The Responses item's validated replay boundary.
////
//// Wire objects are projected onto an allowlist before storage or comparison.
//// The same decoder protects replay: a diagnostics object cannot introduce
//// executable calls that disagree with the durable assistant content.

import core/json.{type JsonValue}
import core/message
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/internal/wire

/// The bounded diagnostics namespace, distinct from all other adapters.
pub const namespace = "loom.openai-responses.v1"

/// Removes content already held by durable blocks from replay metadata.
/// Item identities, part boundaries and citation annotations remain available
/// even when the answer text is larger than the diagnostics budget.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.template(json.Null) == json.Null
/// ```
pub fn template(value: JsonValue) -> JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.filter_map(fields, fn(field) {
          let #(key, value) = field
          case key {
            "encrypted_content" -> Error(Nil)
            "text" | "refusal" | "arguments" -> Ok(#(key, json.String("")))
            "content" | "summary" -> Ok(#(key, template(value)))
            _ -> Ok(field)
          }
        }),
      )
    json.Array(values) -> json.Array(list.map(values, template))
    _ -> value
  }
}

/// Rehydrates canonical item templates from the exact durable block sequence.
/// A malformed template or extra/missing block refuses the whole replay hint.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.restore([], []) == Ok([])
/// ```
pub fn restore(
  templates: List(JsonValue),
  content: List(message.AssistantBlock),
) -> Result(List(JsonValue), Nil) {
  use state <- result.try(
    list.try_fold(templates, #([], content), fn(state, raw) {
      let #(output, remaining) = state
      use canonical <- result.try(item(raw))
      use rebuilt <- result.try(restore_item(canonical, remaining))
      Ok(#([rebuilt.0, ..output], rebuilt.1))
    }),
  )
  use <- bool.guard(state.1 != [], Error(Nil))
  let output = list.reverse(state.0)
  use <- bool.guard(blocks(output) != content, Error(Nil))
  Ok(output)
}

fn put(value: JsonValue, name: String, replacement: JsonValue) -> JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.append(list.filter(fields, fn(field) { field.0 != name }), [
          #(name, replacement),
        ]),
      )
    _ -> value
  }
}

fn restore_item(
  raw: JsonValue,
  content: List(message.AssistantBlock),
) -> Result(#(JsonValue, List(message.AssistantBlock)), Nil) {
  use kind <- result.try(wire.string_field(raw, "type"))
  case kind, content {
    "function_call", [message.AssistantToolCall(call), ..rest] -> {
      use <- bool.guard(
        wire.string_field(raw, "call_id") != Ok(call.id)
          || wire.string_field(raw, "name") != Ok(call.name),
        Error(Nil),
      )
      let arguments = case message.malformed_arguments_of(call.arguments) {
        Ok(malformed) -> malformed.0
        Error(Nil) -> json.to_string(call.arguments)
      }
      Ok(#(put(raw, "arguments", json.String(arguments)), rest))
    }
    "message", _ -> {
      use parts <- result.try(wire.array_field(raw, "content"))
      use state <- result.try(restore_parts(parts, content))
      Ok(#(put(raw, "content", json.Array(state.0)), state.1))
    }
    "reasoning",
      [message.AssistantThinking(thinking_signature: signature, ..), ..]
    -> {
      use summary <- result.try(wire.array_field(raw, "summary"))
      let parts = result.unwrap(wire.array_field(raw, "content"), [])
      let remaining = case summary, parts, content {
        [], [], [message.AssistantThinking(thinking: "", ..), ..rest] -> rest
        _, _, _ -> content
      }
      use summary_state <- result.try(restore_parts(summary, remaining))
      use content_state <- result.try(restore_parts(parts, summary_state.1))
      let raw = put(raw, "summary", json.Array(summary_state.0))
      let raw = case parts {
        [] -> raw
        _ -> put(raw, "content", json.Array(content_state.0))
      }
      let raw = case signature {
        None -> raw
        Some(text) -> put(raw, "encrypted_content", json.String(text))
      }
      Ok(#(raw, content_state.1))
    }
    _, _ -> Error(Nil)
  }
}

fn restore_parts(
  parts: List(JsonValue),
  content: List(message.AssistantBlock),
) -> Result(#(List(JsonValue), List(message.AssistantBlock)), Nil) {
  use state <- result.try(
    list.try_fold(parts, #([], content), fn(state, raw) {
      let #(parts, remaining) = state
      use kind <- result.try(wire.string_field(raw, "type"))
      use block <- result.try(case kind, remaining {
        "output_text", [message.AssistantText(text, _), ..rest] ->
          Ok(#("text", text, rest))
        "refusal", [message.AssistantText(text, _), ..rest] ->
          Ok(#("refusal", text, rest))
        "summary_text", [message.AssistantThinking(thinking: text, ..), ..rest]
        -> Ok(#("text", text, rest))
        "reasoning_text",
          [message.AssistantThinking(thinking: text, ..), ..rest]
        -> Ok(#("text", text, rest))
        _, _ -> Error(Nil)
      })
      Ok(#([put(raw, block.0, json.String(block.1)), ..parts], block.2))
    }),
  )
  Ok(#(list.reverse(state.0), state.1))
}

/// Decodes one complete supported output item into canonical field order.
/// Unknown fields never cross into replay metadata.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.item(json.Null) == Error(Nil)
/// ```
pub fn item(value: JsonValue) -> Result(JsonValue, Nil) {
  use id <- result.try(nonempty(value, "id"))
  use kind <- result.try(wire.string_field(value, "type"))
  use status <- result.try(optional_status(value))
  let head = [#("id", json.String(id)), #("type", json.String(kind))]
  let status = case status {
    None -> []
    Some(status) -> [#("status", json.String(status))]
  }
  use fields <- result.try(case kind {
    "message" -> {
      use role <- result.try(wire.string_field(value, "role"))
      use <- bool.guard(role != "assistant", Error(Nil))
      use phase <- result.try(message_phase(value))
      use parts <- result.try(wire.array_field(value, "content"))
      use parts <- result.try(list.try_map(parts, part))
      use <- bool.guard(
        list.any(parts, fn(part) {
          wire.string_field(part, "type") == Ok("summary_text")
        }),
        Error(Nil),
      )
      let phase = case phase {
        None -> []
        Some(phase) -> [#("phase", json.String(phase))]
      }
      Ok(list.append(
        [#("role", json.String(role)), #("content", json.Array(parts))],
        phase,
      ))
    }
    "function_call" -> {
      use call_id <- result.try(nonempty(value, "call_id"))
      use name <- result.try(nonempty(value, "name"))
      use arguments <- result.try(wire.string_field(value, "arguments"))
      Ok([
        #("call_id", json.String(call_id)),
        #("name", json.String(name)),
        #("arguments", json.String(arguments)),
      ])
    }
    "reasoning" -> {
      use summary <- result.try(wire.array_field(value, "summary"))
      use summary <- result.try(list.try_map(summary, summary_part))
      use encrypted <- result.try(optional_string(value, "encrypted_content"))
      let encrypted = case encrypted {
        None -> []
        Some(text) -> [#("encrypted_content", json.String(text))]
      }
      use content <- result.try(optional_content(value))
      Ok(
        list.flatten([[#("summary", json.Array(summary))], encrypted, content]),
      )
    }
    _ -> Error(Nil)
  })
  Ok(json.Object(list.flatten([head, status, fields])))
}

/// Validates the optional assistant message phase. A phase changes follow-up
/// interpretation, so unknown values are semantic errors rather than metadata
/// to discard. Missing or null phase makes no assertion about message intent.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.message_phase(json.Object([])) == Ok(None)
/// ```
pub fn message_phase(value: JsonValue) -> Result(Option(String), Nil) {
  use phase <- result.try(optional_string(value, "phase"))
  case phase {
    None | Some("commentary") | Some("final_answer") -> Ok(phase)
    Some(_) -> Error(Nil)
  }
}

fn optional_content(
  value: JsonValue,
) -> Result(List(#(String, JsonValue)), Nil) {
  case wire.field(value, "content") {
    Error(Nil) -> Ok([])
    Ok(json.Array(parts)) -> {
      use parts <- result.try(
        list.try_map(parts, fn(part) {
          use kind <- result.try(wire.string_field(part, "type"))
          use <- bool.guard(kind != "reasoning_text", Error(Nil))
          use text <- result.try(wire.string_field(part, "text"))
          Ok(
            json.Object([
              #("type", json.String(kind)),
              #("text", json.String(text)),
            ]),
          )
        }),
      )
      Ok([#("content", json.Array(parts))])
    }
    Ok(_) -> Error(Nil)
  }
}

fn optional_status(value: JsonValue) -> Result(Option(String), Nil) {
  use status <- result.try(optional_string(value, "status"))
  case status {
    None | Some("completed") | Some("incomplete") -> Ok(status)
    Some(_) -> Error(Nil)
  }
}

/// Reads a missing or null optional string without accepting another type.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.optional_string(json.Object([]), "id") == Ok(None)
/// ```
pub fn optional_string(
  value: JsonValue,
  name: String,
) -> Result(Option(String), Nil) {
  case wire.field(value, name) {
    Error(Nil) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(Nil)
  }
}

/// Requires a nonempty identity rather than inventing a routing key.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.nonempty(json.Object([]), "id") == Error(Nil)
/// ```
pub fn nonempty(value: JsonValue, name: String) -> Result(String, Nil) {
  use text <- result.try(wire.string_field(value, name))
  case text {
    "" -> Error(Nil)
    _ -> Ok(text)
  }
}

/// Canonicalizes a supported text, summary, or refusal content part.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.part(json.Null) == Error(Nil)
/// ```
pub fn part(value: JsonValue) -> Result(JsonValue, Nil) {
  use kind <- result.try(wire.string_field(value, "type"))
  case kind {
    "output_text" -> {
      use text <- result.try(wire.string_field(value, "text"))
      use annotations <- result.try(annotations(value))
      Ok(
        json.Object([
          #("type", json.String(kind)),
          #("text", json.String(text)),
          #("annotations", json.Array(annotations)),
        ]),
      )
    }
    "refusal" -> {
      use text <- result.try(wire.string_field(value, "refusal"))
      Ok(
        json.Object([
          #("type", json.String(kind)),
          #("refusal", json.String(text)),
        ]),
      )
    }
    "summary_text" | "reasoning_text" -> {
      use text <- result.try(wire.string_field(value, "text"))
      Ok(
        json.Object([#("type", json.String(kind)), #("text", json.String(text))]),
      )
    }
    _ -> Error(Nil)
  }
}

fn summary_part(value: JsonValue) -> Result(JsonValue, Nil) {
  use <- bool.guard(
    wire.string_field(value, "type") != Ok("summary_text"),
    Error(Nil),
  )
  part(value)
}

fn annotations(value: JsonValue) -> Result(List(JsonValue), Nil) {
  case wire.field(value, "annotations") {
    Error(Nil) -> Ok([])
    Ok(json.Array(values)) -> list.try_map(values, annotation)
    Ok(_) -> Error(Nil)
  }
}

/// Retains citation metadata only, never an arbitrary provider object.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.annotation(json.Null) == Error(Nil)
/// ```
pub fn annotation(value: JsonValue) -> Result(JsonValue, Nil) {
  use kind <- result.try(wire.string_field(value, "type"))
  use fields <- result.try(case kind {
    "url_citation" -> {
      use start <- result.try(wire.int_field(value, "start_index"))
      use end <- result.try(wire.int_field(value, "end_index"))
      use <- bool.guard(start < 0 || end < start, Error(Nil))
      use url <- result.try(wire.string_field(value, "url"))
      use title <- result.try(wire.string_field(value, "title"))
      Ok([
        #("start_index", json.Int(start)),
        #("end_index", json.Int(end)),
        #("url", json.String(url)),
        #("title", json.String(title)),
      ])
    }
    "file_citation" -> {
      use file_id <- result.try(nonempty(value, "file_id"))
      use filename <- result.try(wire.string_field(value, "filename"))
      use index <- result.try(wire.int_field(value, "index"))
      use <- bool.guard(index < 0, Error(Nil))
      Ok([
        #("file_id", json.String(file_id)),
        #("filename", json.String(filename)),
        #("index", json.Int(index)),
      ])
    }
    _ -> Error(Nil)
  })
  Ok(json.Object([#("type", json.String(kind)), ..fields]))
}

/// Projects validated output items to durable assistant blocks.
///
/// ## Examples
///
/// ```gleam
/// assert responses_items.blocks([]) == []
/// ```
pub fn blocks(items: List(JsonValue)) -> List(message.AssistantBlock) {
  list.flat_map(items, fn(item) {
    case wire.string_field(item, "type") {
      Ok("function_call") -> [
        message.AssistantToolCall(message.ToolCall(
          id: wire.string_field_or(item, "call_id", ""),
          name: wire.string_field_or(item, "name", ""),
          arguments: wire.tool_arguments(wire.string_field_or(
            item,
            "arguments",
            "",
          )),
          thought_signature: None,
          namespace: None,
        )),
      ]
      Ok("reasoning") -> {
        let summary = result.unwrap(wire.array_field(item, "summary"), [])
        let content = result.unwrap(wire.array_field(item, "content"), [])
        let signature = option_string(item, "encrypted_content")
        let parts = list.append(summary, content)

        // Ciphertext belongs to the item, not each summary part. Storing it
        // once prevents a large cipher multiplied by many tiny parts from
        // expanding a bounded stream into an enormous durable payload.
        case parts {
          [] -> [message.AssistantThinking("", signature, False)]
          _ ->
            list.index_map(parts, fn(part, index) {
              message.AssistantThinking(
                wire.string_field_or(part, "text", ""),
                case index {
                  0 -> signature
                  _ -> None
                },
                False,
              )
            })
        }
      }
      Ok("message") ->
        list.map(result.unwrap(wire.array_field(item, "content"), []), fn(part) {
          let text = case wire.string_field(part, "type") {
            Ok("refusal") -> wire.string_field_or(part, "refusal", "")
            _ -> wire.string_field_or(part, "text", "")
          }
          message.AssistantText(text, None)
        })
      _ -> []
    }
  })
}

fn option_string(value: JsonValue, name: String) -> Option(String) {
  case wire.string_field(value, name) {
    Ok(text) -> Some(text)
    Error(Nil) -> None
  }
}
