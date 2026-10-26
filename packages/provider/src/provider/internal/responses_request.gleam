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
  body_with_options(resolved, request, access, None)
}

/// Builds a Responses request with explicit access and serving policy.
///
/// ## Examples
///
/// ```gleam
/// // body_with_options(..., None, Some(model.FastServiceTier))
/// ```
pub fn body_with_options(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
  access: option.Option(model.CyberAccessProgram),
  tier: option.Option(model.ResponsesServiceTier),
) -> String {
  encode_body(resolved, request, PublicApi, access, tier)
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
  subscription_body_with_options(resolved, request, access, None)
}

/// Builds a Responses request with explicit access and serving policy.
///
/// ## Examples
///
/// ```gleam
/// // subscription_body_with_options(..., None, Some(model.FastServiceTier))
/// ```
pub fn subscription_body_with_options(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
  access: option.Option(model.CyberAccessProgram),
  tier: option.Option(model.ResponsesServiceTier),
) -> String {
  encode_body(resolved, request, Subscription, access, tier)
}

/// Encodes a complete request payload into a JSON string according to API mode.
fn encode_body(
  resolved: model.ResolvedModel,
  request: model.ProviderRequest,
  mode: RequestMode,
  access: option.Option(model.CyberAccessProgram),
  tier: option.Option(model.ResponsesServiceTier),
) -> String {
  // Encode system instructions if present.
  let system = case request.system {
    None -> []
    Some(text) -> [#("instructions", json.String(text))]
  }

  // Map model thinking configuration into reasoning effort parameters.
  let reasoning = case resolved.thinking {
    model.ThinkingOff -> []
    model.ThinkingLow -> reasoning("low")
    model.ThinkingMedium -> reasoning("medium")
    model.ThinkingHigh -> reasoning("high")
    model.ThinkingXHigh -> reasoning("xhigh")
    model.ThinkingMax -> reasoning("max")
  }

  // Resolve token limits and output mode options.
  let max_tokens = case request.max_output_tokens {
    None -> resolved.max_output_tokens
    Some(count) -> count
  }

  // Configure output mode options depending on PublicApi or Subscription mode.
  let output_options = case mode {
    PublicApi -> [
      #("tool_choice", json.String("auto")),
      #("parallel_tool_calls", json.Bool(True)),
      #("max_output_tokens", json.Int(max_tokens)),
    ]
    Subscription -> []
  }

  // Assemble root JSON payload fields.
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
      service_tier(tier),
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
/// Encodes optional cyber access program settings into payload fields.
fn cyber_access(
  access: option.Option(model.CyberAccessProgram),
) -> List(#(String, JsonValue)) {
  // Map access program option to its wire representation.
  case access {
    None -> []
    Some(program) -> {
      // Translate program enum to access program identifier string.
      let value = case program {
        model.StandardCyberAccess -> "standard"
        model.DaybreakBlue -> "daybreak_blue"
        model.DaybreakRed -> "daybreak_red"
      }

      [#("access_programs", json.Object([#("cyber", json.String(value))]))]
    }
  }
}

// Only the typed operator selection reaches the wire. Omission preserves the
// provider default and explicit default remains distinct from omission. Fast
// uses the documented priority alias shared by public and subscription endpoints.
/// Maps service tier selection to wire payload fields.
fn service_tier(
  tier: option.Option(model.ResponsesServiceTier),
) -> List(#(String, JsonValue)) {
  case tier {
    None -> []
    Some(model.DefaultServiceTier) -> [
      #("service_tier", json.String("default")),
    ]
    Some(model.FastServiceTier) -> [#("service_tier", json.String("priority"))]
  }
}

// Subscription inference exposes one namespace of local functions. No provider
// hosted tool or deferred tool discovery can expand the broker's authority.
/// Encodes tool specifications into Responses function declarations.
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

        // The Responses API defaults function tools to strict mode, where
        // every property must be listed in `required` and unused optional
        // arguments have to be sent as empty values. Loom's schemas mark
        // fields optional and document omission as the way to leave them
        // out, so strict is switched off for every function explicitly
        // rather than left to a server default.
        #("strict", json.Bool(False)),
      ])
    })

  // Return flat functions for PublicApi or wrap in loom namespace for Subscription.
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

/// Builds reasoning effort payload configuration.
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

/// Encodes an agent conversation message into Responses input items.
fn encode_message(
  value: message.AgentMessage,
  mode: RequestMode,
  tools: List(model.ToolSpec),
) -> List(JsonValue) {
  // Dispatch on message role to serialize appropriate wire representations.
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
      // Inspect diagnostics for recorded replay payloads.
      let replay = case api, diagnostics {
        "openai-responses", Some(diagnostics) -> replay(diagnostics, content)
        "codex-subscription", Some(diagnostics) -> replay(diagnostics, content)
        _, _ -> Error(Nil)
      }

      // Replay recorded items with namespace adjustments or reconstruct from blocks.
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

/// Validates and decodes diagnostic replay payload when size is bounded.
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

/// Encodes a single assistant block into Responses wire items.
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
/// Adjusts namespace fields on replayed function calls according to request mode.
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

/// Strips namespace fields from function call objects for public API compatibility.
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
/// Attaches loom namespace to legacy unprefixed function calls.
fn with_legacy_namespace(
  value: JsonValue,
  tools: List(model.ToolSpec),
) -> JsonValue {
  // Match JSON object to check and attach missing loom namespace.
  case value {
    json.Object(fields) -> {
      let name = wire.string_field(value, "name")

      // Verify call is a known function without namespace before injecting loom namespace.
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
