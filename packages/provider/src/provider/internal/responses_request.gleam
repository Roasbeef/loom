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

type RequestMode {
  PublicApi
  Subscription
}

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
  body_with_access(resolved, request, None)
}

/// Builds the subscription body without a caller-supplied output ceiling.
/// ChatGPT plan inference requires streamed, stateless requests and namespaced
/// tools. The fixed namespace preserves Loom's existing local tool policy.
///
/// ## Examples
///
/// ```gleam
/// // responses_request.subscription_body(resolved, request)
/// ```
pub fn subscription_body(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
) -> String {
  subscription_body_with_access(resolved, request, None)
}

/// Builds an API-key body with the operator's explicit access program.
///
/// ## Examples
///
/// ```gleam
/// // body_with_access(resolved, request, Some(model.DaybreakBlue))
/// ```
pub fn body_with_access(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
  access: option.Option(model.CyberAccessProgram),
) -> String {
  encode_body(resolved, request, PublicApi, access)
}

/// Builds a subscription body with the operator's explicit access program.
///
/// ## Examples
///
/// ```gleam
/// // subscription_body_with_access(resolved, request, Some(model.DaybreakBlue))
/// ```
pub fn subscription_body_with_access(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
  access: option.Option(model.CyberAccessProgram),
) -> String {
  encode_body(resolved, request, Subscription, access)
}

fn encode_body(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
  mode: RequestMode,
  access: option.Option(model.CyberAccessProgram),
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
  let output_options = case mode {
    PublicApi -> [
      #("tool_choice", json.String("auto")),
      #("parallel_tool_calls", json.Bool(True)),
      #("max_output_tokens", json.Int(max_tokens)),
    ]
    Subscription -> []
  }
  json.Object(
    list.flatten([
      [#("model", json.String(resolved.model_id))],
      system,
      [
        #(
          "input",
          json.Array(
            list.flat_map(request.messages, fn(value) {
              encode_message(value, mode, request.tools)
            }),
          ),
        ),
        #("tools", json.Array(encode_tools(request.tools, mode))),
      ],
      output_options,
      cyber_access(access),
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

// An omitted selection retains the server's entitlement-aware default. An
// explicit selection is never inferred from a model name or replay metadata.
fn cyber_access(
  access: option.Option(model.CyberAccessProgram),
) -> List(#(String, JsonValue)) {
  case access {
    None -> []
    Some(program) -> {
      let value = case program {
        model.StandardCyberAccess -> "standard"
        model.DaybreakBlue -> "daybreak_blue"
        model.DaybreakRed -> "daybreak_red"
      }
      [#("access_programs", json.Object([#("cyber", json.String(value))]))]
    }
  }
}

// Subscription inference exposes one namespace of local functions. No provider
// hosted tool or deferred tool discovery can expand the broker's authority.
fn encode_tools(
  tools: List(model.ToolSpec),
  mode: RequestMode,
) -> List(JsonValue) {
  let functions =
    list.map(tools, fn(tool) {
      json.Object([
        #("type", json.String("function")),
        #("name", json.String(tool.name)),
        #("description", json.String(tool.description)),
        #("parameters", tool.input_schema),
      ])
    })
  case mode, functions {
    PublicApi, _ -> functions
    Subscription, [] -> []
    Subscription, _ -> [
      json.Object([
        #("type", json.String("namespace")),
        #("name", json.String("loom")),
        #(
          "description",
          json.String("Tools executed by Loom under its local policy."),
        ),
        #("tools", json.Array(functions)),
      ]),
    ]
  }
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

fn encode_message(
  value: message.AgentMessage,
  mode: RequestMode,
  tools: List(model.ToolSpec),
) -> List(JsonValue) {
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
        "codex-subscription", Some(diagnostics) -> replay(diagnostics, content)
        _, _ -> Error(Nil)
      }
      case replay {
        Ok(values) -> list.map(values, replay_namespace(_, mode, tools))
        Error(Nil) -> list.flat_map(content, assistant_block(_, mode, tools))
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
        json.Null
        | json.Bool(_)
        | json.Float(_)
        | json.String(_)
        | json.Array(_)
        | json.Object(_) -> Error(Nil)
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

fn assistant_block(
  value: message.AssistantBlock,
  mode: RequestMode,
  tools: List(model.ToolSpec),
) -> List(JsonValue) {
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
      replay_namespace(
        json.Object(
          list.append(
            [
              #("type", json.String("function_call")),
              #("call_id", json.String(call.id)),
              #("name", json.String(call.name)),
              #("arguments", json.String(json.to_string(call.arguments))),
            ],
            case call.namespace {
              None -> []
              Some(namespace) -> [#("namespace", json.String(namespace))]
            },
          ),
        ),
        mode,
        tools,
      ),
    ]
  }
}

// A namespace on a function_call input item is a subscription transport shape,
// and a recorded call carries it from whichever route produced the turn. The
// public API request never sends it, so a session that switches from the
// subscription route to an API-key route cannot leak "loom" onto its input
// items. The subscription request does the opposite and fills in the namespace
// that older records predate.
fn replay_namespace(
  value: JsonValue,
  mode: RequestMode,
  tools: List(model.ToolSpec),
) -> JsonValue {
  case mode {
    PublicApi -> without_namespace(value)
    Subscription -> with_legacy_namespace(value, tools)
  }
}

fn without_namespace(value: JsonValue) -> JsonValue {
  case value {
    json.Object(fields) ->
      case wire.string_field(value, "type") == Ok("function_call") {
        True ->
          json.Object(list.filter(fields, fn(field) { field.0 != "namespace" }))
        False -> value
      }
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> value
  }
}

// Older assistant records predate namespaces. Only a function explicitly
// offered by this request receives Loom's namespace; foreign namespaces remain
// opaque history and can never be relabelled as a local call.
fn with_legacy_namespace(
  value: JsonValue,
  tools: List(model.ToolSpec),
) -> JsonValue {
  case value {
    json.Object(fields) -> {
      let name = wire.string_field(value, "name")
      case
        wire.string_field(value, "type") == Ok("function_call")
        && wire.field(value, "namespace") == Error(Nil)
        && list.any(tools, fn(tool) { name == Ok(tool.name) })
      {
        True ->
          json.Object(
            list.append(fields, [#("namespace", json.String("loom"))]),
          )
        False -> value
      }
    }
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> value
  }
}
