//// The Agent Client Protocol's vocabulary, decoded and encoded as closed types.
////
//// `tui/acp/rpc` settles that a line is a JSON-RPC frame; this module settles
//// that a frame's method and params mean something ACP defines. Requests the
//// client sends decode here into the `Request` variants the server matches
//// on; everything the server says (results, `session/update` payloads and
//// the permission request) is built here from typed values, so the shape of
//// the wire is written once and the server never assembles JSON by hand.
////
//// Decoding is total and refuses precisely. An unknown method is
//// `method_not_found`, a known method whose params are wrong is
//// `invalid_params` with a sentence naming the member, and neither can crash
//// the server, because the params are walked with plain list lookups on the
//// core JSON value and every miss is an `Error`.
////
//// Two ACP members are deliberately not offered, and a request that needs
//// them is refused rather than half honoured. Audio prompt content is not
//// advertised in `promptCapabilities`, so an audio block is `invalid_params`.
//// Per-session MCP servers and the guidance opt-out are `Loom` extensions the
//// daemon cannot yet apply to one session, so `session/new` names them in a
//// refusal instead of silently ignoring a request whose purpose is isolation.
//// `docs/architecture/acp.md` lists the whole mapping.
////
//// ## Flow
////
//// `request` → `decode_new_session` / `decode_prompt` → `blocks`
////
//// 1. `request` picks the decoder by method name.
//// 2. The per-method decoders read their members with `text` and friends.
//// 3. `blocks` turns prompt content into the user blocks the daemon's
////    rich-content prompt command carries.

import core/json.{type JsonValue}
import core/message
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/acp/rpc

/// The one ACP protocol version this server speaks.
pub const protocol_version = 1

/// Whether project guidance (`AGENTS.md`, `CLAUDE.md`) is loaded for a session.
pub type Guidance {
  /// The default: the daemon loads guidance as it does for any session.
  GuidanceLoaded

  /// The client asked, with `_meta.loom.project_instructions = false`, for
  /// guidance to be skipped. The server refuses it today; see the module doc.
  GuidanceOmitted
}

/// The Loom extension members of `_meta.loom` on a session request.
pub type Meta {
  Meta(
    /// A workspace registered on an executor, by name. Never a path.
    workspace: Option(String),
    /// The `[executors.<name>]` the workspace is registered on.
    executor: Option(String),
    /// The `[pools.<name>]` the daemon picks an executor from.
    pool: Option(String),
    /// A model profile name, as `--model-profile` takes.
    profile: Option(String),
    /// A catalogue model name to switch the main strand to.
    model: Option(String),
    /// Whether to load project guidance.
    guidance: Guidance,
  )
}

/// A request from the client that the server answers.
pub type Request {
  /// The opening exchange: version negotiation and capabilities.
  Initialize(
    /// The newest ACP version the client speaks.
    protocol_version: Int,
  )

  /// A credential exchange. Loom advertises no methods, so this is refused.
  Authenticate(method_id: String)

  /// Starts a session.
  NewSession(
    /// The client's working directory, resolved against the operator's roots.
    cwd: String,
    /// The names of MCP servers the client offered; any is refused today.
    mcp_servers: List(String),
    /// The Loom extension members.
    meta: Meta,
  )

  /// Reattaches a saved session and replays its transcript.
  LoadSession(
    /// The Loom session id.
    session_id: String,
    /// The client's working directory.
    cwd: String,
    /// The names of MCP servers the client offered; any is refused today.
    mcp_servers: List(String),
    /// The Loom extension members.
    meta: Meta,
  )

  /// One user turn.
  Prompt(
    /// The session the turn belongs to.
    session_id: String,
    /// The turn's content as the daemon's user blocks.
    content: List(message.UserBlock),
  )

  /// Switches the session's model by catalogue name, the original ACP form
  /// that clients such as Zed still send.
  SetModel(session_id: String, model_id: String)

  /// Sets a session configuration option, the form current ACP SDKs (and so
  /// Harbor's runner) use to choose a model. Loom offers one select option,
  /// `model`, so a boolean value is refused when the server dispatches it.
  SetConfigOption(session_id: String, config_id: String, value: ConfigValue)
}

/// The value a `session/set_config_option` request carries.
pub type ConfigValue {
  /// A choice among a select option's values.
  Choice(value: String)

  /// A switch, which Loom offers no option for.
  Switch
}

/// Which request form a model switch answers, because the two replies differ.
pub type ModelAnswer {
  /// `session/set_model` answers with an empty object.
  LegacyAnswer

  /// `session/set_config_option` answers with every option's current state.
  ConfigAnswer
}

/// A notification from the client.
pub type Notification {
  /// Stop the running turn of a session.
  Cancel(session_id: String)
}

/// How a prompt turn ended, as ACP names it.
pub type StopReason {
  /// The model finished.
  EndTurn

  /// The turn hit its token limit.
  MaxTokens

  /// The client cancelled it.
  Cancelled
}

/// Token counts for one turn, which Harbor and Zed both read.
pub type TurnUsage {
  TurnUsage(
    /// Uncached input tokens.
    input: Int,
    /// Output tokens.
    output: Int,
    /// Input, output and cache tokens together.
    total: Int,
    /// The reasoning subset of output, when reported.
    thought: Option(Int),
    /// Tokens read from the provider cache.
    cached_read: Int,
    /// Tokens written to the provider cache.
    cached_write: Int,
  )
}

/// One model the client may select.
pub type ModelChoice {
  ModelChoice(
    /// The catalogue name, which is what `session/set_model` sends back.
    id: String,
    /// The model's provider identifier, shown to a person.
    name: String,
  )
}

/// The selectable models and which one is current.
pub type ModelState {
  ModelState(
    /// The catalogue name of the current model.
    current: String,
    /// Every model the catalogue offers this session.
    available: List(ModelChoice),
  )
}

/// What kind of work a tool call does, which clients use to pick an icon.
pub type ToolKind {
  /// Reads a file.
  Read

  /// Changes a file.
  Edit

  /// Runs a command or a program.
  Execute

  /// Searches the workspace.
  Search

  /// Fetches from the network.
  Fetch

  /// Anything else.
  Other
}

/// Where a tool call stands.
pub type ToolStatus {
  /// Named by the model and not yet running.
  Pending

  /// Running.
  InProgress

  /// Finished normally.
  Completed

  /// Finished with an error.
  Failed
}

/// One tool call, as `tool_call` announces it.
pub type ToolCall {
  ToolCall(
    /// The provider's call id, stable across every update of the call.
    id: String,
    /// A short line for a person.
    title: String,
    /// What kind of work it does.
    kind: ToolKind,
    /// Where it stands.
    status: ToolStatus,
    /// The model's arguments.
    raw_input: JsonValue,
  )
}

/// What `session/update` can carry.
pub type Update {
  /// A piece of the model's answer.
  AgentText(text: String)

  /// A piece of the model's reasoning.
  AgentThought(text: String)

  /// A piece of the user's turn, sent when replaying a loaded session.
  UserText(text: String)

  /// A tool call has begun.
  ToolStarted(call: ToolCall)

  /// A tool call moved or printed.
  ToolProgress(
    /// The call being updated.
    id: String,
    /// Its new status.
    status: ToolStatus,
    /// Text output so far, or none.
    output: Option(String),
    /// The machine-readable output, when the call finished.
    raw_output: Option(JsonValue),
  )

  /// Context use and cumulative cost.
  Usage(
    /// Tokens currently in context.
    used: Int,
    /// The context window.
    size: Int,
    /// Cumulative cost in US dollars, when priced.
    cost: Option(Float),
  )
}

/// One choice offered on a permission request.
pub type OptionKind {
  /// Allow this once.
  AllowOnce

  /// Allow, and remember for the session.
  AllowAlways

  /// Refuse this once.
  RejectOnce
}

/// One button on a permission request.
pub type PermissionOption {
  PermissionOption(
    /// The id the client answers with.
    id: String,
    /// The label.
    name: String,
    /// The meaning, which clients style by.
    kind: OptionKind,
  )
}

/// The client's answer to a permission request.
pub type PermissionChoice {
  /// The person picked an option.
  Selected(option_id: String)

  /// The request was dismissed, as a cancelled turn does.
  Dismissed
}

// --- decoding ----------------------------------------------------------------

/// Decodes the params of a client request by method name.
///
/// ## Examples
///
/// ```gleam
/// let params = json.Object([#("protocolVersion", json.Int(1))])
/// assert schema.request("initialize", params) == Ok(schema.Initialize(1))
/// ```
///
/// ```gleam
/// let assert Error(error) = schema.request("nope", json.Object([]))
/// assert error.code == rpc.method_not_found
/// ```
pub fn request(
  method: String,
  params: JsonValue,
) -> Result(Request, rpc.WireError) {
  use fields <- result.try(object(params))

  // The method name picks the decoder; an unlisted name is not offered.
  case method {
    "initialize" -> {
      use version <- result.map(number(fields, "protocolVersion"))
      Initialize(version)
    }
    "authenticate" -> {
      use method_id <- result.map(text(fields, "methodId"))
      Authenticate(method_id)
    }
    "session/new" -> decode_new_session(fields)
    "session/load" -> decode_load_session(fields)
    "session/prompt" -> decode_prompt(fields)
    "session/set_model" -> {
      use session_id <- result.try(text(fields, "sessionId"))
      use model_id <- result.map(text(fields, "modelId"))
      SetModel(session_id, model_id)
    }
    "session/set_config_option" -> decode_set_config_option(fields)
    _ -> Error(rpc.error(rpc.method_not_found, "method not found: " <> method))
  }
}

/// Decodes a client notification by method name.
///
/// ## Examples
///
/// ```gleam
/// let params = json.Object([#("sessionId", json.String("s"))])
/// assert schema.notification("session/cancel", params)
///   == Ok(schema.Cancel("s"))
/// ```
pub fn notification(
  method: String,
  params: JsonValue,
) -> Result(Notification, rpc.WireError) {
  use fields <- result.try(object(params))

  // Only cancellation is a notification ACP defines for a client to send.
  case method {
    "session/cancel" -> {
      use session_id <- result.map(text(fields, "sessionId"))
      Cancel(session_id)
    }
    _ -> Error(rpc.error(rpc.method_not_found, "method not found: " <> method))
  }
}

/// Decodes the client's reply to a permission request.
///
/// ## Examples
///
/// ```gleam
/// let outcome = json.Object([
///   #("outcome", json.String("selected")),
///   #("optionId", json.String("allow")),
/// ])
/// let reply = json.Object([#("outcome", outcome)])
/// assert schema.permission_choice(reply) == Ok(schema.Selected("allow"))
/// ```
pub fn permission_choice(
  reply: JsonValue,
) -> Result(PermissionChoice, rpc.WireError) {
  use fields <- result.try(object(reply))
  use outcome <- result.try(member(fields, "outcome"))
  use outcome <- result.try(object(outcome))
  use kind <- result.try(text(outcome, "outcome"))

  // A selection names an option; anything else is a dismissal.
  case kind {
    "selected" -> {
      use option_id <- result.map(text(outcome, "optionId"))
      Selected(option_id)
    }
    "cancelled" -> Ok(Dismissed)
    _ -> Error(invalid("outcome must be selected or cancelled"))
  }
}

/// Decodes `session/set_config_option`: a select value is text, a boolean is a switch.
fn decode_set_config_option(
  fields: List(#(String, JsonValue)),
) -> Result(Request, rpc.WireError) {
  use session_id <- result.try(text(fields, "sessionId"))
  use config_id <- result.try(text(fields, "configId"))

  use value <- result.map(config_value(fields))
  SetConfigOption(session_id, config_id, value)
}

/// The JSON type of `value` says which kind of option it is for.
fn config_value(
  fields: List(#(String, JsonValue)),
) -> Result(ConfigValue, rpc.WireError) {
  case list.key_find(fields, "value") {
    Ok(json.String(value)) -> Ok(Choice(value))
    Ok(json.Bool(_)) -> Ok(Switch)
    _ -> Error(invalid("value must be a string or a boolean"))
  }
}

/// Decodes `session/new`'s params.
fn decode_new_session(
  fields: List(#(String, JsonValue)),
) -> Result(Request, rpc.WireError) {
  use cwd <- result.try(text(fields, "cwd"))
  use servers <- result.try(mcp_servers(fields))
  use meta <- result.map(meta(fields))
  NewSession(cwd, servers, meta)
}

/// Decodes `session/load`'s params.
fn decode_load_session(
  fields: List(#(String, JsonValue)),
) -> Result(Request, rpc.WireError) {
  use session_id <- result.try(text(fields, "sessionId"))
  use cwd <- result.try(text(fields, "cwd"))
  use servers <- result.try(mcp_servers(fields))
  use meta <- result.map(meta(fields))
  LoadSession(session_id, cwd, servers, meta)
}

/// Decodes `session/prompt`'s params, including every content block.
fn decode_prompt(
  fields: List(#(String, JsonValue)),
) -> Result(Request, rpc.WireError) {
  use session_id <- result.try(text(fields, "sessionId"))
  use items <- result.try(member(fields, "prompt"))

  // A prompt is a non-empty list of content blocks.
  case items {
    json.Array([_, ..] as items) -> {
      use content <- result.map(blocks(items))
      Prompt(session_id, content)
    }
    _ -> Error(invalid("prompt must be a non-empty array of content blocks"))
  }
}

/// Reads the names of the offered MCP servers, requiring each to be an object with a name.
fn mcp_servers(
  fields: List(#(String, JsonValue)),
) -> Result(List(String), rpc.WireError) {
  case list.key_find(fields, "mcpServers") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) {
        use server <- result.try(object(item))
        text(server, "name")
      })
    Ok(_) -> Error(invalid("mcpServers must be an array"))
  }
}

/// Reads `_meta.loom`, answering the default when it is absent.
fn meta(fields: List(#(String, JsonValue))) -> Result(Meta, rpc.WireError) {
  let empty = Meta(None, None, None, None, None, GuidanceLoaded)

  // `_meta` and its `loom` member are both optional objects.
  case list.key_find(fields, "_meta") {
    Error(Nil) | Ok(json.Null) -> Ok(empty)
    Ok(json.Object(meta)) ->
      case list.key_find(meta, "loom") {
        Error(Nil) | Ok(json.Null) -> Ok(empty)
        Ok(json.Object(loom)) -> loom_meta(loom)
        Ok(_) -> Error(invalid("_meta.loom must be an object"))
      }
    Ok(_) -> Error(invalid("_meta must be an object"))
  }
}

/// Reads the members of `_meta.loom`, refusing a wrong type rather than ignoring it.
fn loom_meta(loom: List(#(String, JsonValue))) -> Result(Meta, rpc.WireError) {
  use workspace <- result.try(optional_text(loom, "workspace"))
  use executor <- result.try(optional_text(loom, "executor"))
  use pool <- result.try(optional_text(loom, "pool"))
  use profile <- result.try(optional_text(loom, "profile"))
  use model <- result.try(optional_text(loom, "model"))

  use guidance <- result.map(guidance_of(loom))
  Meta(workspace, executor, pool, profile, model, guidance)
}

/// Reads `project_instructions`, the one `_meta.loom` member that is not text.
fn guidance_of(
  loom: List(#(String, JsonValue)),
) -> Result(Guidance, rpc.WireError) {
  case list.key_find(loom, "project_instructions") {
    Error(Nil) | Ok(json.Bool(True)) -> Ok(GuidanceLoaded)
    Ok(json.Bool(False)) -> Ok(GuidanceOmitted)
    Ok(_) -> Error(invalid("project_instructions must be a boolean"))
  }
}

/// Turns prompt content blocks into the daemon's user blocks.
///
/// ## Examples
///
/// ```gleam
/// let block = json.Object([
///   #("type", json.String("text")),
///   #("text", json.String("hello")),
/// ])
/// assert schema.blocks([block]) == Ok([message.UserText("hello", None)])
/// ```
pub fn blocks(
  items: List(JsonValue),
) -> Result(List(message.UserBlock), rpc.WireError) {
  items |> list.try_map(block) |> result.map(list.flatten)
}

/// Decodes one content block, which may become more than one user block.
fn block(item: JsonValue) -> Result(List(message.UserBlock), rpc.WireError) {
  use fields <- result.try(object(item))
  use kind <- result.try(text(fields, "type"))

  // Each content type ACP defines is either carried, rewritten as text, or refused.
  case kind {
    "text" -> {
      use body <- result.map(text(fields, "text"))
      [message.UserText(body, None)]
    }
    "image" -> {
      use data <- result.try(text(fields, "data"))
      use mime <- result.try(text(fields, "mimeType"))
      image(data, mime)
    }
    "resource_link" -> {
      use uri <- result.try(text(fields, "uri"))
      use name <- result.map(text(fields, "name"))
      [message.UserText("Referenced resource " <> name <> ": " <> uri, None)]
    }
    "resource" -> embedded_resource(fields)
    "audio" -> Error(invalid("audio prompt content is not supported"))
    _ -> Error(invalid("unknown content block type: " <> kind))
  }
}

/// Admits an image only when its media type says it is one.
fn image(
  data: String,
  mime: String,
) -> Result(List(message.UserBlock), rpc.WireError) {
  case string.starts_with(mime, "image/") {
    True -> Ok([message.UserImage(data, mime)])
    False -> Error(invalid("image content needs an image/* mimeType"))
  }
}

/// Reads an embedded resource: text becomes a labelled text block, an image blob an image.
fn embedded_resource(
  fields: List(#(String, JsonValue)),
) -> Result(List(message.UserBlock), rpc.WireError) {
  use resource <- result.try(member(fields, "resource") |> result.try(object))
  use uri <- result.try(text(resource, "uri"))

  // A resource carries either text or a base64 blob; only an image blob is usable.
  case list.key_find(resource, "text"), list.key_find(resource, "blob") {
    Ok(json.String(body)), _ ->
      Ok([message.UserText("Attached " <> uri <> ":\n\n" <> body, None)])
    _, Ok(json.String(data)) -> {
      use mime <- result.try(text(resource, "mimeType"))
      image(data, mime)
    }
    _, _ -> Error(invalid("resource needs text or an image blob"))
  }
}

/// Requires a JSON object, answering its members.
fn object(
  value: JsonValue,
) -> Result(List(#(String, JsonValue)), rpc.WireError) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(invalid("expected an object"))
  }
}

/// Requires a member to be present.
fn member(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, rpc.WireError) {
  list.key_find(fields, name)
  |> result.map_error(fn(_) { invalid("missing member " <> name) })
}

/// Requires a member to be text.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, rpc.WireError) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error(invalid(name <> " must be a string"))
  }
}

/// Reads an optional text member, refusing a present member of another type.
fn optional_text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Option(String), rpc.WireError) {
  case list.key_find(fields, name) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(value)) -> Ok(Some(value))
    Ok(_) -> Error(invalid(name <> " must be a string"))
  }
}

/// Requires a member to be an integer.
fn number(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, rpc.WireError) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error(invalid(name <> " must be an integer"))
  }
}

/// An `invalid_params` error with a sentence naming the problem.
fn invalid(message: String) -> rpc.WireError {
  rpc.error(rpc.invalid_params, message)
}

// --- encoding ----------------------------------------------------------------

/// The `initialize` result.
///
/// `version` is the Loom build, shown to the client as the agent's version.
/// `loadSession` is advertised because `session/load` replays the retained
/// transcript, and images and embedded context because the daemon's
/// `prompt_content` carries both; audio is not.
///
/// ## Examples
///
/// ```gleam
/// let result = schema.initialize_result("0.3.2")
/// let assert json.Object(fields) = result
/// assert list.key_find(fields, "protocolVersion") == Ok(json.Int(1))
/// ```
pub fn initialize_result(version: String) -> JsonValue {
  json.Object([
    #("protocolVersion", json.Int(protocol_version)),
    #(
      "agentCapabilities",
      json.Object([
        #("loadSession", json.Bool(True)),
        #(
          "promptCapabilities",
          json.Object([
            #("image", json.Bool(True)),
            #("audio", json.Bool(False)),
            #("embeddedContext", json.Bool(True)),
          ]),
        ),
        #(
          "mcpCapabilities",
          json.Object([#("http", json.Bool(False)), #("sse", json.Bool(False))]),
        ),
      ]),
    ),
    #("authMethods", json.Array([])),
    #(
      "agentInfo",
      json.Object([
        #("name", json.String("loom")),
        #("title", json.String("Loom")),
        #("version", json.String(version)),
      ]),
    ),
  ])
}

/// The `session/new` result.
///
/// The model catalogue is offered twice because ACP clients disagree about
/// how to learn it: `models` is the original (unstable) member that Zed and
/// older SDKs read with `session/set_model`, and `configOptions` is the
/// current one, a select option of category `model`, which current SDKs (and
/// so Harbor's runner) pair with `session/set_config_option`.
///
/// ## Examples
///
/// ```gleam
/// let result = schema.session_result("s1", None)
/// assert result == json.Object([#("sessionId", json.String("s1"))])
/// ```
pub fn session_result(
  session_id: String,
  models: Option(ModelState),
) -> JsonValue {
  json.Object([#("sessionId", json.String(session_id)), ..model_members(models)])
}

/// The `session/load` result, which names no session because the request did.
///
/// ## Examples
///
/// ```gleam
/// assert schema.load_result(None) == json.Object([])
/// ```
pub fn load_result(models: Option(ModelState)) -> JsonValue {
  json.Object(model_members(models))
}

/// The reply to a model switch, in the shape of the request that asked.
///
/// ## Examples
///
/// ```gleam
/// assert schema.model_answer(schema.LegacyAnswer, None) == json.Object([])
/// ```
pub fn model_answer(
  shape: ModelAnswer,
  models: Option(ModelState),
) -> JsonValue {
  case shape {
    LegacyAnswer -> json.Object([])
    ConfigAnswer ->
      json.Object([
        #(
          "configOptions",
          option.map(models, encode_config_options)
            |> option.unwrap(json.Array([])),
        ),
      ])
  }
}

/// Both model encodings, or nothing when the catalogue is empty.
fn model_members(models: Option(ModelState)) -> List(#(String, JsonValue)) {
  list.flatten([
    present("models", option.map(models, encode_models)),
    present("configOptions", option.map(models, encode_config_options)),
  ])
}

/// The model catalogue as a select option of category `model`.
fn encode_config_options(state: ModelState) -> JsonValue {
  json.Array([
    json.Object([
      #("id", json.String("model")),
      #("name", json.String("Model")),
      #("category", json.String("model")),
      #("type", json.String("select")),
      #("currentValue", json.String(state.current)),
      #(
        "options",
        json.Array(
          list.map(state.available, fn(choice) {
            json.Object([
              #("value", json.String(choice.id)),
              #("name", json.String(choice.name)),
            ])
          }),
        ),
      ),
    ]),
  ])
}

/// The members to add to an object for an optional value: none when absent.
///
/// ACP clients decode with schemas in which an optional member is *absent*,
/// not `null`, so an unset value must leave no key behind.
fn present(
  name: String,
  value: Option(JsonValue),
) -> List(#(String, JsonValue)) {
  case value {
    Some(value) -> [#(name, value)]
    None -> []
  }
}

/// The `models` member of a session result, which is how Harbor and Zed learn
/// that `session/set_model` is offered.
fn encode_models(state: ModelState) -> JsonValue {
  json.Object([
    #("currentModelId", json.String(state.current)),
    #(
      "availableModels",
      json.Array(
        list.map(state.available, fn(choice) {
          json.Object([
            #("modelId", json.String(choice.id)),
            #("name", json.String(choice.name)),
          ])
        }),
      ),
    ),
  ])
}

/// The `session/prompt` result.
///
/// ## Examples
///
/// ```gleam
/// let result = schema.prompt_result(schema.EndTurn, None)
/// assert result == json.Object([#("stopReason", json.String("end_turn"))])
/// ```
pub fn prompt_result(stop: StopReason, usage: Option(TurnUsage)) -> JsonValue {
  json.Object([
    #("stopReason", json.String(stop_word(stop))),
    ..present("usage", option.map(usage, encode_turn_usage))
  ])
}

/// The wire word for a stop reason.
fn stop_word(stop: StopReason) -> String {
  case stop {
    EndTurn -> "end_turn"
    MaxTokens -> "max_tokens"
    Cancelled -> "cancelled"
  }
}

/// The per-turn token counts, in ACP's camelCase.
fn encode_turn_usage(usage: TurnUsage) -> JsonValue {
  json.Object(list.append(
    [
      #("inputTokens", json.Int(usage.input)),
      #("outputTokens", json.Int(usage.output)),
      #("totalTokens", json.Int(usage.total)),
      #("cachedReadTokens", json.Int(usage.cached_read)),
      #("cachedWriteTokens", json.Int(usage.cached_write)),
    ],
    present("thoughtTokens", option.map(usage.thought, json.Int)),
  ))
}

/// The params of one `session/update` notification.
///
/// ## Examples
///
/// ```gleam
/// let params = schema.update_params("s1", schema.AgentText("hi"))
/// assert json.to_string(params)
///   == "{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}"
/// ```
pub fn update_params(session_id: String, update: Update) -> JsonValue {
  json.Object([
    #("sessionId", json.String(session_id)),
    #("update", encode_update(update)),
  ])
}

/// The `update` member for each kind of update.
fn encode_update(update: Update) -> JsonValue {
  case update {
    AgentText(text) -> chunk("agent_message_chunk", text)
    AgentThought(text) -> chunk("agent_thought_chunk", text)
    UserText(text) -> chunk("user_message_chunk", text)
    ToolStarted(call) -> encode_tool_call(call)
    ToolProgress(id:, status:, output:, raw_output:) ->
      encode_tool_progress(id, status, output, raw_output)
    Usage(used:, size:, cost:) -> encode_usage(used, size, cost)
  }
}

/// A text chunk update of the given `sessionUpdate` kind.
fn chunk(kind: String, text: String) -> JsonValue {
  json.Object([
    #("sessionUpdate", json.String(kind)),
    #("content", text_content(text)),
  ])
}

/// An ACP text content block.
fn text_content(text: String) -> JsonValue {
  json.Object([#("type", json.String("text")), #("text", json.String(text))])
}

/// The `tool_call` announcement.
fn encode_tool_call(call: ToolCall) -> JsonValue {
  json.Object([
    #("sessionUpdate", json.String("tool_call")),
    #("toolCallId", json.String(call.id)),
    #("title", json.String(call.title)),
    #("kind", json.String(kind_word(call.kind))),
    #("status", json.String(status_word(call.status))),
    #("rawInput", call.raw_input),
  ])
}

/// A `tool_call_update`, carrying only the members that changed.
fn encode_tool_progress(
  id: String,
  status: ToolStatus,
  output: Option(String),
  raw_output: Option(JsonValue),
) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("sessionUpdate", json.String("tool_call_update")),
        #("toolCallId", json.String(id)),
        #("status", json.String(status_word(status))),
      ],
      present("content", option.map(output, text_blocks)),
      present("rawOutput", raw_output),
    ]),
  )
}

/// A tool call's content list holding one text block.
fn text_blocks(text: String) -> JsonValue {
  json.Array([
    json.Object([
      #("type", json.String("content")),
      #("content", text_content(text)),
    ]),
  ])
}

/// The `usage_update`, with cost in US dollars when it is priced.
fn encode_usage(used: Int, size: Int, cost: Option(Float)) -> JsonValue {
  json.Object(list.append(
    [
      #("sessionUpdate", json.String("usage_update")),
      #("used", json.Int(used)),
      #("size", json.Int(size)),
    ],
    present("cost", option.map(cost, encode_cost)),
  ))
}

/// Cumulative cost in US dollars, ACP's `cost` object.
fn encode_cost(amount: Float) -> JsonValue {
  json.Object([
    #("amount", json.Float(amount)),
    #("currency", json.String("USD")),
  ])
}

/// The wire word for a tool kind.
fn kind_word(kind: ToolKind) -> String {
  case kind {
    Read -> "read"
    Edit -> "edit"
    Execute -> "execute"
    Search -> "search"
    Fetch -> "fetch"
    Other -> "other"
  }
}

/// The wire word for a tool status.
fn status_word(status: ToolStatus) -> String {
  case status {
    Pending -> "pending"
    InProgress -> "in_progress"
    Completed -> "completed"
    Failed -> "failed"
  }
}

/// The params of a `session/request_permission` request.
///
/// ## Examples
///
/// ```gleam
/// let call = schema.ToolCall("e1", "run a command", schema.Execute,
///   schema.Pending, json.Null)
/// let options = [schema.PermissionOption("allow", "Allow", schema.AllowOnce)]
/// let params = schema.permission_params("s1", call, options)
/// let assert json.Object(fields) = params
/// assert list.key_find(fields, "sessionId") == Ok(json.String("s1"))
/// ```
pub fn permission_params(
  session_id: String,
  call: ToolCall,
  options: List(PermissionOption),
) -> JsonValue {
  json.Object([
    #("sessionId", json.String(session_id)),
    #(
      "toolCall",
      json.Object([
        #("toolCallId", json.String(call.id)),
        #("title", json.String(call.title)),
        #("kind", json.String(kind_word(call.kind))),
        #("status", json.String(status_word(call.status))),
        #("rawInput", call.raw_input),
      ]),
    ),
    #(
      "options",
      json.Array(
        list.map(options, fn(option) {
          json.Object([
            #("optionId", json.String(option.id)),
            #("name", json.String(option.name)),
            #("kind", json.String(option_kind_word(option.kind))),
          ])
        }),
      ),
    ),
  ])
}

/// The wire word for a permission option kind.
fn option_kind_word(kind: OptionKind) -> String {
  case kind {
    AllowOnce -> "allow_once"
    AllowAlways -> "allow_always"
    RejectOnce -> "reject_once"
  }
}
