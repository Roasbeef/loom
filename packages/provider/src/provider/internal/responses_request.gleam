//// Stateless Responses request projection.
////
//// History remains the caller's durable input. Provider diagnostics are only
//// a lossless replay hint after their decoded projection agrees with that
//// input; unknown metadata never becomes an outbound provider instruction.

import core/json.{type JsonValue}
import core/message
import core/origin
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import provider/internal/responses_items as items
import provider/internal/wire
import provider/model

/// Builds the API-key dialect body, without any authentication material.
///
/// ## Examples
///
/// ```gleam
/// // responses_request.body(resolved, request)
/// ```
pub fn body(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
) -> String {
  let system = case request.system {
    None -> []
    Some(text) -> [#("instructions", json.String(text))]
  }
  let reasoning = case resolved.thinking {
    model.ThinkingOff -> []
    model.ThinkingLow -> reasoning("low")
    model.ThinkingMedium -> reasoning("medium")
    model.ThinkingHigh -> reasoning("high")
  }
  let max_tokens = case request.max_output_tokens {
    None -> resolved.max_output_tokens
    Some(count) -> count
  }
  json.Object(
    list.flatten([
      [#("model", json.String(resolved.model_id))],
      system,
      [
        #("input", json.Array(list.flat_map(request.messages, encode_message))),
        #(
          "tools",
          json.Array(
            list.map(request.tools, fn(tool) {
              json.Object([
                #("type", json.String("function")),
                #("name", json.String(tool.name)),
                #("description", json.String(tool.description)),
                #("parameters", tool.input_schema),
              ])
            }),
          ),
        ),
        #("tool_choice", json.String("auto")),
        #("parallel_tool_calls", json.Bool(True)),
        #("max_output_tokens", json.Int(max_tokens)),
      ],
      reasoning,
      [
        #("include", json.Array([json.String("reasoning.encrypted_content")])),
        #("store", json.Bool(False)),
        #("stream", json.Bool(True)),
      ],
    ]),
  )
  |> json.to_string
}

fn reasoning(effort: String) -> List(#(String, JsonValue)) {
  [
    #(
      "reasoning",
      json.Object([
        #("effort", json.String(effort)),
        #("summary", json.String("auto")),
      ]),
    ),
  ]
}

fn encode_message(value: message.AgentMessage) -> List(JsonValue) {
  case value {
    message.UserMessage(content:, origin:, ..) -> [
      json.Object([
        #("role", json.String("user")),
        #(
          "content",
          json.Array(list.map(origin.project(content, origin), user_block)),
        ),
      ]),
    ]
    message.AssistantMessage(content:, api:, diagnostics:, ..) -> {
      let replay = case api, diagnostics {
        "openai-responses", Some(diagnostics) -> replay(diagnostics, content)
        _, _ -> Error(Nil)
      }
      case replay {
        Ok(values) -> values
        Error(Nil) -> list.flat_map(content, assistant_block)
      }
    }
    message.ToolResultMessage(tool_call_id:, content:, is_error:, ..) -> {
      let content = list.map(content, result_block)

      // Responses has no is_error field. A stable JSON envelope on a text
      // block carries that fact without replaying internal tool details.
      let content = case is_error {
        False -> content
        True -> [
          json.Object([
            #("type", json.String("input_text")),
            #(
              "text",
              json.String(
                json.to_string(
                  json.Object([
                    #("is_error", json.Bool(True)),
                    #("content", json.Array(content)),
                  ]),
                ),
              ),
            ),
          ]),
        ]
      }
      [
        json.Object([
          #("type", json.String("function_call_output")),
          #("call_id", json.String(tool_call_id)),
          #("output", json.Array(content)),
        ]),
      ]
    }
    message.CustomMessage(..) -> []
  }
}

fn replay(
  diagnostics: JsonValue,
  content: List(message.AssistantBlock),
) -> Result(List(JsonValue), Nil) {
  use <- bool.guard(
    bit_array.byte_size(bit_array.from_string(json.to_string(diagnostics)))
      > 65_536,
    Error(Nil),
  )
  use metadata <- result.try(wire.field(diagnostics, items.namespace))
  use output <- result.try(wire.array_field(metadata, "output"))
  use order <- result.try(wire.array_field(metadata, "block_order"))
  use order <- result.try(
    list.try_map(order, fn(value) {
      case value {
        json.Int(index) -> Ok(index)
        _ -> Error(Nil)
      }
    }),
  )
  use <- bool.guard(
    list.sort(order, int.compare)
      != list.index_map(content, fn(_, index) { index }),
    Error(Nil),
  )
  use content <- result.try(
    list.try_map(order, fn(index) { list.first(list.drop(content, index)) }),
  )
  items.restore(output, content)
}

fn user_block(value: message.UserBlock) -> JsonValue {
  case value {
    message.UserText(text:, ..) -> text_part("input_text", text)
    message.UserImage(data:, mime_type:) -> image_part(data, mime_type)
  }
}

fn result_block(value: message.ToolResultBlock) -> JsonValue {
  case value {
    message.ToolResultText(text:, ..) -> text_part("input_text", text)
    message.ToolResultImage(data:, mime_type:) -> image_part(data, mime_type)
  }
}

fn text_part(kind: String, text: String) -> JsonValue {
  json.Object([#("type", json.String(kind)), #("text", json.String(text))])
}

fn image_part(data: String, mime: String) -> JsonValue {
  json.Object([
    #("type", json.String("input_image")),
    #("image_url", json.String("data:" <> mime <> ";base64," <> data)),
  ])
}

fn assistant_block(value: message.AssistantBlock) -> List(JsonValue) {
  case value {
    message.AssistantText(text:, ..) -> [
      json.Object([
        #("role", json.String("assistant")),
        #("content", json.Array([text_part("output_text", text)])),
      ]),
    ]

    // A signature without its validated Responses item ID is not a complete
    // reasoning item. Foreign, missing or invalid metadata cannot invent one.
    message.AssistantThinking(..) -> []
    message.AssistantToolCall(call:) -> [
      json.Object([
        #("type", json.String("function_call")),
        #("call_id", json.String(call.id)),
        #("name", json.String(call.name)),
        #("arguments", json.String(json.to_string(call.arguments))),
      ]),
    ]
  }
}
