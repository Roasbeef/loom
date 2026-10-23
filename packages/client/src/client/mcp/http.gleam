//// Streamable HTTP adapter for the `gleam_mcp/transport.Transport` seam.
////
//// `gleam_mcp/client` speaks newline-delimited JSON-RPC over a `Transport`.
//// This module implements a `ChannelTransport` coordinator that translates
//// each outbound JSON-RPC message into an HTTP `POST` over
//// `provider/http.Transport`, bounded at `max_response_bytes` (eight MiB per
//// JSON body or SSE event), and feeds the correlated response back to the
//// client actor as `TransportData`.
////
//// Both streamable-HTTP protocol profiles in the field are supported:
////
//// - **Initialized sessions (`2025-06-18`, `2025-03-26`, `2024-11-05`)**:
////   `initialize` is sent as a `POST`, any `Mcp-Session-Id` response header
////   and negotiated `protocolVersion` are retained for subsequent requests,
////   `notifications/initialized` is sent as a `POST` accepting `202 Accepted`,
////   and `Close` sends a bounded `DELETE` when a session ID is held.
//// - **Stateless modern HTTP (`2026-07-28`, `gleam_mcp/server_http`)**: when
////   the server rejects `initialize` with `-32020`, `-32022`, `-32600` or
////   `-32601`, the coordinator probes `tools/list` with `2026-07-28`
////   request-scoped `_meta` and `Mcp-*` headers, answers `gleam_mcp/client`'s
////   `initialize` locally, and attaches `2026-07-28` metadata and custom
////   `x-mcp-header` mirrors to every subsequent `tools/list` and `tools/call`.
////
//// Local HTTP framing and oversized-response faults are authenticated with an
//// in-VM HMAC (`tag_fault` / `classify_fault`) so `client/mcp` maps an 8 MiB
//// response overrun or malformed body to `mcp_malformed` and a transport or
//// OAuth failure to `mcp_unavailable`, without latching the client dead across
//// independent HTTP requests.
////
//// ## Flow
////
//// `seam` → `open_connection` → `handle` → `handle_send` → `post_exchange` →
//// `execute_http`
////
//// 1. `seam` builds a `ChannelTransport` that calls `open_connection` in the
////    client actor's process.
//// 2. `handle` and `handle_send` dispatch initialization (`run_initialize`,
////    `probe_stateless_modern`), `notifications/initialized`
////    (`run_initialized_notification`), and requests (`run_request`).
//// 3. `post_exchange` resolves headers (`resolve_auth_headers`,
////    `build_request_headers`), runs `execute_http` (`await_status`,
////    `collect_sse`, `collect_body`, `finish_body`, `decode_json_body`), and
////    retries once on HTTP 401 with `retry_after_unauthorized`.
//// 4. `tag_fault` and `classify_fault` authenticate local HTTP faults across
////    the `gleam_mcp/client` boundary.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/http as mcp_http_meta
import gleam_mcp/http_headers
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc.{type Id}
import gleam_mcp/metadata
import gleam_mcp/protocol
import gleam_mcp/sse
import gleam_mcp/stdio
import gleam_mcp/transport
import gleam_mcp/version
import host/bootstrap
import provider/http
import weft
import weft/state_machine as sm

/// The byte ceiling for retained accumulation of one HTTP JSON response body or
/// one SSE event (8 MiB), matching `gleam_mcp/client_http`. Checked before
/// appending each delivered `provider/http` fragment.
pub const max_response_bytes = 8_388_608

/// How outbound HTTP requests authenticate to the remote MCP endpoint.
pub type Auth {
  /// No `Authorization` header is sent.
  NoAuth

  /// Static `Authorization: Bearer <token>`.
  Bearer(token: String)

  /// Static `Authorization: Macaroon <token>`.
  Macaroon(token: String)

  /// OAuth 2.1 bearer token resolved per request, with one refresh attempt on
  /// HTTP 401.
  OAuth(
    authorize: fn(weft.Ledger) -> Result(String, String),
    refresh_unauthorized: fn(String, weft.Ledger) -> Result(String, String),
  )
}

/// Configuration for one remote Streamable HTTP MCP server.
pub type Config {
  Config(
    /// The `[mcp.<name>]` server key.
    server: String,
    /// Validated absolute `http://` or `https://` endpoint URL.
    url: String,
    /// Authentication source for outbound requests.
    auth: Auth,
    /// Streaming HTTP transport (`http.httpc_transport()` in production).
    http_transport: http.Transport,
    /// Version advertised in `clientInfo`.
    client_version: String,
    /// Per-request exchange deadline in milliseconds.
    request_timeout_ms: Int,
  )
}

/// Classification of a local HTTP fault carried through `gleam_mcp/client`.
pub type FaultKind {
  /// The HTTP response violated framing, content-type, UTF-8, JSON, or the
  /// 8 MiB byte ceiling (`mcp_malformed`).
  MalformedFault(reason: String)

  /// The HTTP connection, TLS handshake, status, or OAuth token failed
  /// (`mcp_unavailable`).
  UnavailableFault(reason: String)
}

type WireMode {
  Negotiating
  InitializedSession(
    session_id: Option(String),
    protocol_version: Option(String),
  )
  StatelessModern
}

type Phase {
  Running
}

type State {
  State(
    config: Config,
    inbound: Subject(transport.TransportEvent),
    commands: Subject(Msg),
    mode: WireMode,
    tool_schemas: Dict(String, JsonValue),
    next_key: Int,
    inflight: Dict(Int, weft.Detached(Nil, Nil)),
  )
}

type Msg {
  Send(line: String)
  InitializeDone(
    key: Int,
    outcome: Result(
      #(WireMode, JsonValue, Dict(String, JsonValue)),
      #(Id, FaultKind),
    ),
  )
  RequestDone(key: Int, reply: JsonValue, schemas: Dict(String, JsonValue))
  NotificationDone(key: Int)
  Close
  ClientGone
}

type ParsedResponse {
  ParsedResponse(
    session_id: Option(String),
    value: JsonValue,
    outcome: Result(JsonValue, jsonrpc.RpcError),
  )
}

type RawHttpOutcome {
  RawParsed(ParsedResponse)
  RawEmptyAccepted(session_id: Option(String))
  RawUnauthorized(status: Int)
  RawFault(FaultKind)
}

type PostAttempt {
  PostAttempt(
    session_id: Option(String),
    protocol_version: Option(String),
    extra_headers: List(#(String, String)),
    expected_id: Option(Id),
    body: String,
  )
}

const fault_prefix = "loom-mcp-http-fault:"

/// Builds a `transport.Transport` (`ChannelTransport`) for a remote HTTP MCP
/// server.
///
/// ## Examples
///
/// ```gleam
/// // http.seam(config)
/// ```
pub fn seam(config: Config) -> transport.Transport {
  transport.ChannelTransport(connect: fn(inbound) {
    open_connection(config, inbound, process.self())
  })
}

/// Authenticates a local HTTP fault message so `client/mcp` can distinguish it
/// from a remote JSON-RPC server error.
///
/// ## Examples
///
/// ```gleam
/// let tagged = http.tag_fault(http.MalformedFault("too large"))
/// assert http.classify_fault(tagged) == Some(http.MalformedFault("too large"))
/// ```
pub fn tag_fault(fault: FaultKind) -> String {
  let payload = case fault {
    MalformedFault(reason:) -> "malformed:" <> reason
    UnavailableFault(reason:) -> "unavailable:" <> reason
  }
  let mac =
    crypto.hmac(bit_array.from_string(payload), crypto.Sha256, fault_secret())
    |> bit_array.base16_encode
  fault_prefix <> mac <> ":" <> payload
}

/// Verifies and decodes a tagged local HTTP fault message. Untrusted server
/// error messages without a valid HMAC return `None`.
///
/// ## Examples
///
/// ```gleam
/// assert http.classify_fault("untrusted server error") == None
/// ```
pub fn classify_fault(message: String) -> Option(FaultKind) {
  case string.starts_with(message, fault_prefix) {
    False -> None
    True -> {
      let rest = string.drop_start(message, string.length(fault_prefix))
      case string.split_once(rest, ":") {
        Error(Nil) -> None
        Ok(#(mac, payload)) -> {
          let expected =
            crypto.hmac(
              bit_array.from_string(payload),
              crypto.Sha256,
              fault_secret(),
            )
            |> bit_array.base16_encode
          case
            crypto.secure_compare(
              bit_array.from_string(mac),
              bit_array.from_string(expected),
            )
          {
            False -> None
            True -> decode_fault_payload(payload)
          }
        }
      }
    }
  }
}

fn decode_fault_payload(payload: String) -> Option(FaultKind) {
  case
    string.starts_with(payload, "malformed:"),
    string.starts_with(payload, "unavailable:")
  {
    True, _ ->
      Some(
        MalformedFault(reason: string.drop_start(
          payload,
          string.length("malformed:"),
        )),
      )
    False, True ->
      Some(
        UnavailableFault(reason: string.drop_start(
          payload,
          string.length("unavailable:"),
        )),
      )
    False, False -> None
  }
}

fn fault_secret() -> BitArray {
  let pid = int.to_string(bootstrap.current_process_id())
  let home = bootstrap.getenv("HOME") |> result.unwrap("")
  bootstrap.sha256(bit_array.from_string(
    "loom-mcp-http-key:" <> pid <> ":" <> home,
  ))
}

fn open_connection(
  config: Config,
  inbound: Subject(transport.TransportEvent),
  client_pid: process.Pid,
) -> transport.Connection {
  let started =
    sm.new_with_initialiser(1000, fn(commands) {
      let selector =
        process.new_selector()
        |> process.select(commands)
        |> process.select_specific_monitor(process.monitor(client_pid), fn(_) {
          ClientGone
        })
      let state =
        State(
          config:,
          inbound:,
          commands:,
          mode: Negotiating,
          tool_schemas: dict.new(),
          next_key: 1,
          inflight: dict.new(),
        )
      sm.initialised(Running, state)
      |> sm.selecting(selector)
      |> sm.returning(commands)
      |> Ok
    })
    |> sm.on_event(handle)
    |> sm.unlinked
    |> sm.start
  case started {
    Ok(actor) ->
      transport.Connection(
        send: fn(line) {
          process.send(actor.data, Send(line))
          Ok(Nil)
        },
        close: fn() { process.send(actor.data, Close) },
      )
    Error(_) ->
      transport.Connection(send: fn(_) { Error(Nil) }, close: fn() {
        process.send(
          inbound,
          transport.TransportClosed("mcp http coordinator failed to start"),
        )
      })
  }
}

fn handle(phase: Phase, state: State, msg: Msg) -> sm.Next(Phase, State, Msg) {
  case phase, msg {
    Running, Send(line) -> handle_send(state, line)
    Running, InitializeDone(key, outcome) -> {
      let state = retire_key(state, key)
      case outcome {
        Ok(#(mode, reply, schemas)) -> {
          send_frame(state.inbound, reply)
          sm.keep(
            State(
              ..state,
              mode:,
              tool_schemas: dict.merge(state.tool_schemas, schemas),
            ),
          )
        }
        Error(#(id, fault)) -> {
          send_frame(state.inbound, tagged_error_response(id, fault))
          sm.keep(state)
        }
      }
    }
    Running, RequestDone(key, reply, schemas) -> {
      let state = retire_key(state, key)
      send_frame(state.inbound, reply)
      sm.keep(
        State(..state, tool_schemas: dict.merge(state.tool_schemas, schemas)),
      )
    }
    Running, NotificationDone(key) -> sm.keep(retire_key(state, key))
    Running, Close -> {
      let drained = cancel_all(state.inflight)
      delete_session_if_needed(state.config, state.mode)
      case drained {
        Ok(Nil) -> {
          process.send(
            state.inbound,
            transport.TransportClosed("mcp http transport closed"),
          )
          sm.stop()
        }
        Error(Nil) -> sm.stop_abnormal("mcp http request drain unconfirmed")
      }
    }
    Running, ClientGone -> {
      let _ = cancel_all(state.inflight)
      sm.stop()
    }
  }
}

fn handle_send(state: State, line: String) -> sm.Next(Phase, State, Msg) {
  let trimmed = string.trim_end(line)
  case jsonrpc.decode(trimmed) {
    Ok(jsonrpc.ServerRequest(id:, method: "initialize", params:)) -> {
      let key = state.next_key
      let config = state.config
      let commands = state.commands
      let run =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            let outcome = run_initialize(ledger, config, id, params)
            process.send(commands, InitializeDone(key, outcome))
            Ok(Nil)
          }),
        ])
        |> weft.deadline(config.request_timeout_ms)
        |> weft.start_detached
      sm.keep(
        State(
          ..state,
          next_key: key + 1,
          inflight: dict.insert(state.inflight, key, run),
        ),
      )
    }
    Ok(jsonrpc.Notification(method: "notifications/initialized", ..)) ->
      case state.mode {
        StatelessModern -> sm.keep(state)
        Negotiating | InitializedSession(..) -> {
          let key = state.next_key
          let config = state.config
          let mode = state.mode
          let commands = state.commands
          let run =
            weft.new_prepared([
              weft.managed(fn(ledger) {
                let _ = run_initialized_notification(ledger, config, mode)
                process.send(commands, NotificationDone(key))
                Ok(Nil)
              }),
            ])
            |> weft.deadline(config.request_timeout_ms)
            |> weft.start_detached
          sm.keep(
            State(
              ..state,
              next_key: key + 1,
              inflight: dict.insert(state.inflight, key, run),
            ),
          )
        }
      }
    Ok(jsonrpc.ServerRequest(id:, method:, params:)) -> {
      let key = state.next_key
      let config = state.config
      let mode = state.mode
      let schemas = state.tool_schemas
      let commands = state.commands
      let run =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            let #(reply, discovered) =
              run_request(ledger, config, mode, schemas, id, method, params)
            process.send(commands, RequestDone(key, reply, discovered))
            Ok(Nil)
          }),
        ])
        |> weft.deadline(config.request_timeout_ms)
        |> weft.start_detached
      sm.keep(
        State(
          ..state,
          next_key: key + 1,
          inflight: dict.insert(state.inflight, key, run),
        ),
      )
    }
    Ok(jsonrpc.Notification(..)) | Ok(jsonrpc.Response(..)) | Error(_) ->
      sm.keep(state)
  }
}

fn retire_key(state: State, key: Int) -> State {
  case dict.get(state.inflight, key) {
    Error(Nil) -> state
    Ok(run) -> {
      weft.cancel_detached(run)
      let _ = drain_detached(run, bootstrap.monotonic_time_ms() + 5000)
      State(..state, inflight: dict.delete(state.inflight, key))
    }
  }
}

fn cancel_all(
  inflight: Dict(Int, weft.Detached(Nil, Nil)),
) -> Result(Nil, Nil) {
  let runs = dict.values(inflight)
  let deadline = bootstrap.monotonic_time_ms() + 5000
  list.each(runs, weft.cancel_detached)
  list.try_each(runs, drain_detached(_, deadline))
}

fn drain_detached(
  run: weft.Detached(Nil, Nil),
  deadline: Int,
) -> Result(Nil, Nil) {
  let remaining = deadline - bootstrap.monotonic_time_ms()
  case remaining > 0 {
    False -> Error(Nil)
    True ->
      case weft.pull(run, int.min(remaining, 1000)) {
        weft.AllDelivered -> Ok(Nil)
        weft.RunLost(_) -> Error(Nil)
        weft.NotYet | weft.PulledOutcome(_) -> drain_detached(run, deadline)
      }
  }
}

fn send_frame(
  inbound: Subject(transport.TransportEvent),
  message: JsonValue,
) -> Nil {
  process.send(
    inbound,
    transport.TransportData(bytes: bit_array.from_string(stdio.frame(message))),
  )
}

fn tagged_error_response(id: Id, fault: FaultKind) -> JsonValue {
  jsonrpc.error_response(
    Some(id),
    jsonrpc.RpcError(code: -32_000, message: tag_fault(fault), data: None),
  )
}

fn run_initialize(
  ledger: weft.Ledger,
  config: Config,
  id: Id,
  params: Option(JsonValue),
) -> Result(#(WireMode, JsonValue, Dict(String, JsonValue)), #(Id, FaultKind)) {
  let envelope = jsonrpc.request(id, "initialize", params)
  case post_exchange(ledger, config, None, None, [], Some(id), envelope) {
    Error(fault) -> Error(#(id, fault))
    Ok(ParsedResponse(session_id:, value:, outcome: Ok(result_obj))) -> {
      let negotiated = extract_protocol_version(result_obj)
      Ok(#(
        InitializedSession(session_id:, protocol_version: negotiated),
        value,
        dict.new(),
      ))
    }
    Ok(ParsedResponse(
      outcome: Error(jsonrpc.RpcError(code:, ..)),
      value: original_error,
      ..,
    ))
      if code == -32_020 || code == -32_022 || code == -32_600 || code == -32_601
    -> probe_stateless_modern(ledger, config, id, original_error)
    Ok(ParsedResponse(session_id:, value:, outcome: Error(_))) ->
      Ok(#(
        InitializedSession(session_id:, protocol_version: None),
        value,
        dict.new(),
      ))
  }
}

fn probe_stateless_modern(
  ledger: weft.Ledger,
  config: Config,
  init_id: Id,
  original_error: JsonValue,
) -> Result(#(WireMode, JsonValue, Dict(String, JsonValue)), #(Id, FaultKind)) {
  let probe_envelope =
    modern_envelope(config.client_version, init_id, "tools/list", None)
  let extra_headers = mcp_http_meta.headers(probe_envelope) |> result.unwrap([])
  case
    post_exchange(
      ledger,
      config,
      None,
      None,
      extra_headers,
      Some(init_id),
      probe_envelope,
    )
  {
    Ok(ParsedResponse(outcome: Ok(result_obj), ..)) -> {
      let schemas = extract_tool_schemas(result_obj)
      let synthesized =
        jsonrpc.response(
          init_id,
          json.Object([
            #("protocolVersion", json.String(protocol.requested_version)),
            #("capabilities", json.Object([#("tools", json.Object([]))])),
          ]),
        )
      Ok(#(StatelessModern, synthesized, schemas))
    }
    Ok(_) | Error(_) ->
      Ok(#(
        InitializedSession(session_id: None, protocol_version: None),
        original_error,
        dict.new(),
      ))
  }
}

fn run_initialized_notification(
  ledger: weft.Ledger,
  config: Config,
  mode: WireMode,
) -> Result(Nil, FaultKind) {
  let #(session_id, protocol_version) = case mode {
    InitializedSession(session_id:, protocol_version:) -> #(
      session_id,
      protocol_version,
    )
    Negotiating | StatelessModern -> #(None, None)
  }
  post_notification(
    ledger,
    config,
    session_id,
    protocol_version,
    protocol.initialized(),
  )
}

fn run_request(
  ledger: weft.Ledger,
  config: Config,
  mode: WireMode,
  schemas: Dict(String, JsonValue),
  id: Id,
  method: String,
  params: Option(JsonValue),
) -> #(JsonValue, Dict(String, JsonValue)) {
  let #(session_id, protocol_version, extra_headers, envelope) = case mode {
    StatelessModern -> {
      let env = modern_envelope(config.client_version, id, method, params)
      let base_headers = mcp_http_meta.headers(env) |> result.unwrap([])
      let param_headers = modern_param_headers(schemas, method, env)
      #(None, None, list.append(base_headers, param_headers), env)
    }
    InitializedSession(session_id:, protocol_version:) -> #(
      session_id,
      protocol_version,
      [],
      jsonrpc.request(id, method, params),
    )
    Negotiating -> #(None, None, [], jsonrpc.request(id, method, params))
  }
  case
    post_exchange(
      ledger,
      config,
      session_id,
      protocol_version,
      extra_headers,
      Some(id),
      envelope,
    )
  {
    Error(fault) -> #(tagged_error_response(id, fault), dict.new())
    Ok(ParsedResponse(value:, outcome: Ok(result_obj), ..)) -> {
      let discovered = case method {
        "tools/list" -> extract_tool_schemas(result_obj)
        _ -> dict.new()
      }
      #(value, discovered)
    }
    Ok(ParsedResponse(value:, outcome: Error(_), ..)) -> #(value, dict.new())
  }
}

fn modern_envelope(
  client_version: String,
  id: Id,
  method: String,
  params: Option(JsonValue),
) -> JsonValue {
  let meta =
    metadata.new(version.V20260728)
    |> metadata.with_client("loom", client_version)
    |> metadata.value
  let fields = case params {
    Some(json.Object(existing)) -> existing
    _ -> []
  }
  jsonrpc.request(id, method, Some(json.Object([#("_meta", meta), ..fields])))
}

fn modern_param_headers(
  schemas: Dict(String, JsonValue),
  method: String,
  envelope: JsonValue,
) -> List(#(String, String)) {
  case method {
    "tools/call" -> {
      let rendered = {
        use meta <- result.try(mcp_http_meta.metadata(envelope))
        use tool_name <- result.try(option.to_result(meta.name, "no name"))
        use schema_json <- result.try(
          dict.get(schemas, tool_name) |> result.replace_error("no schema"),
        )
        use plan <- result.try(http_headers.compile(schema_json))
        use args <- result.try(mcp_http_meta.arguments(envelope))
        http_headers.headers(plan, args)
      }
      result.unwrap(rendered, [])
    }
    _ -> []
  }
}

fn extract_protocol_version(value: JsonValue) -> Option(String) {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "protocolVersion") {
        Ok(json.String(ver)) if ver != "" -> Some(ver)
        _ -> None
      }
    _ -> None
  }
}

fn extract_tool_schemas(value: JsonValue) -> Dict(String, JsonValue) {
  case protocol.decode_tools_page(value) {
    Error(_) -> dict.new()
    Ok(page) ->
      list.fold(page.tools, dict.new(), fn(acc, tool) {
        dict.insert(acc, tool.name, tool.input_schema)
      })
  }
}

fn post_exchange(
  ledger: weft.Ledger,
  config: Config,
  session_id: Option(String),
  protocol_version: Option(String),
  extra_headers: List(#(String, String)),
  expected_id: Option(Id),
  envelope: JsonValue,
) -> Result(ParsedResponse, FaultKind) {
  use #(auth_headers, used_oauth_token) <- result.try(resolve_auth_headers(
    ledger,
    config.auth,
  ))
  let headers =
    build_request_headers(
      session_id,
      protocol_version,
      extra_headers,
      auth_headers,
    )
  let body = json.to_string(envelope)
  case
    execute_http(
      ledger,
      config.http_transport,
      "POST",
      config.url,
      headers,
      body,
      expected_id,
      config.request_timeout_ms,
    )
  {
    RawParsed(parsed) -> Ok(parsed)
    RawEmptyAccepted(session_id:) -> empty_accepted(expected_id, session_id)
    RawFault(fault) -> Error(fault)
    RawUnauthorized(status) ->
      retry_after_unauthorized(
        ledger,
        config,
        PostAttempt(
          session_id:,
          protocol_version:,
          extra_headers:,
          expected_id:,
          body:,
        ),
        used_oauth_token,
        status,
      )
  }
}

fn empty_accepted(
  expected_id: Option(Id),
  session_id: Option(String),
) -> Result(ParsedResponse, FaultKind) {
  case expected_id {
    None ->
      Ok(ParsedResponse(
        session_id:,
        value: json.Object([]),
        outcome: Ok(json.Object([])),
      ))
    Some(_) ->
      Error(MalformedFault(
        "the server answered an empty body to a JSON-RPC request",
      ))
  }
}

fn retry_after_unauthorized(
  ledger: weft.Ledger,
  config: Config,
  attempt: PostAttempt,
  used_oauth_token: Option(String),
  status: Int,
) -> Result(ParsedResponse, FaultKind) {
  case config.auth, used_oauth_token {
    OAuth(refresh_unauthorized:, ..), Some(rejected) -> {
      use refreshed_token <- result.try(
        refresh_unauthorized(rejected, ledger)
        |> result.map_error(UnavailableFault),
      )
      let headers =
        build_request_headers(
          attempt.session_id,
          attempt.protocol_version,
          attempt.extra_headers,
          [#("authorization", "Bearer " <> refreshed_token)],
        )
      case
        execute_http(
          ledger,
          config.http_transport,
          "POST",
          config.url,
          headers,
          attempt.body,
          attempt.expected_id,
          config.request_timeout_ms,
        )
      {
        RawParsed(parsed) -> Ok(parsed)
        RawEmptyAccepted(session_id:) ->
          empty_accepted(attempt.expected_id, session_id)
        RawUnauthorized(code) ->
          Error(UnavailableFault(
            "the OAuth token for mcp."
            <> config.server
            <> " was rejected (HTTP "
            <> int.to_string(code)
            <> "); run `loomd mcp login "
            <> config.server
            <> "`",
          ))
        RawFault(fault) -> Error(fault)
      }
    }
    _, _ ->
      Error(UnavailableFault(
        "the server rejected authentication with HTTP " <> int.to_string(status),
      ))
  }
}

fn post_notification(
  ledger: weft.Ledger,
  config: Config,
  session_id: Option(String),
  protocol_version: Option(String),
  envelope: JsonValue,
) -> Result(Nil, FaultKind) {
  use _ <- result.try(post_exchange(
    ledger,
    config,
    session_id,
    protocol_version,
    [],
    None,
    envelope,
  ))
  Ok(Nil)
}

fn delete_session_if_needed(config: Config, mode: WireMode) -> Nil {
  case mode {
    InitializedSession(session_id: Some(sid), protocol_version:) -> {
      let _ =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            case resolve_auth_headers(ledger, config.auth) {
              Error(_) -> Ok(Nil)
              Ok(#(auth_headers, _)) -> {
                let headers =
                  build_request_headers(
                    Some(sid),
                    protocol_version,
                    [],
                    auth_headers,
                  )
                let _ =
                  execute_http(
                    ledger,
                    config.http_transport,
                    "DELETE",
                    config.url,
                    headers,
                    "",
                    None,
                    1000,
                  )
                Ok(Nil)
              }
            }
          }),
        ])
        |> weft.deadline(1000)
        |> weft.start
      Nil
    }
    InitializedSession(session_id: None, ..) | Negotiating | StatelessModern ->
      Nil
  }
}

fn resolve_auth_headers(
  ledger: weft.Ledger,
  auth: Auth,
) -> Result(#(List(#(String, String)), Option(String)), FaultKind) {
  case auth {
    NoAuth -> Ok(#([], None))
    Bearer(token:) -> Ok(#([#("authorization", "Bearer " <> token)], None))
    Macaroon(token:) -> Ok(#([#("authorization", "Macaroon " <> token)], None))
    OAuth(authorize:, ..) ->
      case authorize(ledger) {
        Ok(token) ->
          Ok(#([#("authorization", "Bearer " <> token)], Some(token)))
        Error(reason) -> Error(UnavailableFault(reason))
      }
  }
}

fn build_request_headers(
  session_id: Option(String),
  protocol_version: Option(String),
  extra_headers: List(#(String, String)),
  auth_headers: List(#(String, String)),
) -> List(#(String, String)) {
  let base = case extra_headers {
    [] -> [
      #("accept", "application/json, text/event-stream"),
      #("content-type", "application/json"),
    ]
    _ -> extra_headers
  }
  let with_session = case session_id {
    None -> base
    Some(sid) -> list.append(base, [#("mcp-session-id", sid)])
  }
  let with_version = case
    protocol_version,
    list.any(with_session, fn(h) {
      string.lowercase(h.0) == "mcp-protocol-version"
    })
  {
    Some(ver), False ->
      list.append(with_session, [#("mcp-protocol-version", ver)])
    _, _ -> with_session
  }
  list.append(with_version, auth_headers)
}

fn execute_http(
  ledger: weft.Ledger,
  http_transport: http.Transport,
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  expected_id: Option(Id),
  timeout_ms: Int,
) -> RawHttpOutcome {
  let events = process.new_subject()
  let req = http.HttpRequest(method:, url:, headers:, body:)
  case http_transport.prepare_streaming(req, events) {
    Error(reason) -> RawFault(UnavailableFault(reason))
    Ok(prepared) ->
      case
        weft.adopt(
          ledger,
          owner: prepared.running.owner,
          cancel: prepared.running.cancel,
        )
      {
        weft.Refused ->
          RawFault(UnavailableFault("mcp http request was cancelled"))
        weft.Adopted -> {
          prepared.begin()
          let deadline = bootstrap.monotonic_time_ms() + int.max(timeout_ms, 1)
          let outcome = await_status(events, expected_id, deadline)
          http.cancel(prepared.running)
          outcome
        }
      }
  }
}

fn await_status(
  events: Subject(http.HttpEvent),
  expected_id: Option(Id),
  deadline: Int,
) -> RawHttpOutcome {
  let remaining = int.max(deadline - bootstrap.monotonic_time_ms(), 0)
  case process.receive(events, remaining) {
    Error(Nil) ->
      RawFault(UnavailableFault("timed out waiting for HTTP response headers"))
    Ok(http.RequestFailed(reason:)) -> RawFault(UnavailableFault(reason))
    Ok(http.RequestRefused(status:, ..)) ->
      RawFault(UnavailableFault(
        "HTTP request refused with status " <> int.to_string(status),
      ))
    Ok(http.ResponseChunk(_)) | Ok(http.ResponseEnd) ->
      RawFault(MalformedFault("HTTP response body preceded headers"))
    Ok(http.ResponseStatus(status:, headers:)) -> {
      let session_id =
        option.from_result(http_headers.get(headers, "mcp-session-id"))
      let content_type = media_type(headers)
      case status, content_type, expected_id {
        401, _, _ | 403, _, _ -> RawUnauthorized(status)
        s, "text/event-stream", Some(id) if s >= 200 && s < 300 ->
          case sse.new(max_response_bytes) {
            Ok(decoder) ->
              collect_sse(events, session_id, id, decoder, deadline)
            Error(reason) -> RawFault(MalformedFault(reason))
          }
        _, _, _ ->
          collect_body(
            events,
            status,
            session_id,
            content_type,
            expected_id,
            <<>>,
            deadline,
          )
      }
    }
  }
}

fn collect_sse(
  events: Subject(http.HttpEvent),
  session_id: Option(String),
  expected_id: Id,
  decoder: sse.Decoder,
  deadline: Int,
) -> RawHttpOutcome {
  let remaining = int.max(deadline - bootstrap.monotonic_time_ms(), 0)
  case process.receive(events, remaining) {
    Error(Nil) ->
      RawFault(UnavailableFault("timed out waiting for SSE response event"))
    Ok(http.RequestFailed(reason:)) -> RawFault(UnavailableFault(reason))
    Ok(http.RequestRefused(status:, ..)) ->
      RawFault(UnavailableFault(
        "SSE stream refused with status " <> int.to_string(status),
      ))
    Ok(http.ResponseStatus(..)) ->
      RawFault(MalformedFault("duplicate HTTP status in SSE stream"))
    Ok(http.ResponseEnd) ->
      case sse.finish(decoder) {
        Error(reason) ->
          RawFault(MalformedFault(
            "the server's SSE stream ended mid-event: " <> reason,
          ))
        Ok(Nil) ->
          RawFault(UnavailableFault(
            "SSE stream closed before a correlated JSON-RPC response arrived",
          ))
      }
    Ok(http.ResponseChunk(chunk:)) ->
      case sse.feed(decoder, chunk) {
        Error(reason) ->
          RawFault(MalformedFault(
            "the server's SSE response exceeded the "
            <> int.to_string(max_response_bytes)
            <> "-byte limit or was malformed: "
            <> reason,
          ))
        Ok(#(next_decoder, sse_events)) ->
          case inspect_sse_events(sse_events, session_id, expected_id) {
            Ok(Some(parsed)) -> RawParsed(parsed)
            Ok(None) ->
              collect_sse(
                events,
                session_id,
                expected_id,
                next_decoder,
                deadline,
              )
            Error(fault) -> RawFault(fault)
          }
      }
  }
}

fn inspect_sse_events(
  sse_events: List(String),
  session_id: Option(String),
  expected_id: Id,
) -> Result(Option(ParsedResponse), FaultKind) {
  case sse_events {
    [] -> Ok(None)
    [event, ..rest] -> {
      use value <- result.try(
        json.parse(event)
        |> result.replace_error(MalformedFault(
          "the server sent malformed JSON in an SSE event",
        )),
      )
      case jsonrpc.decode_modern(event) {
        Ok(jsonrpc.Correlated(jsonrpc.Response(response_id, outcome)))
          if response_id == expected_id
        -> Ok(Some(ParsedResponse(session_id:, value:, outcome:)))
        Ok(jsonrpc.Correlated(jsonrpc.Notification(..))) ->
          inspect_sse_events(rest, session_id, expected_id)
        Ok(jsonrpc.UncorrelatedError(error)) ->
          Ok(
            Some(ParsedResponse(
              session_id:,
              value: jsonrpc.error_response(Some(expected_id), error),
              outcome: Error(error),
            )),
          )
        _ ->
          Error(MalformedFault(
            "the server sent an uncorrelated or invalid JSON-RPC event on the SSE stream",
          ))
      }
    }
  }
}

fn collect_body(
  events: Subject(http.HttpEvent),
  status: Int,
  session_id: Option(String),
  content_type: String,
  expected_id: Option(Id),
  bytes: BitArray,
  deadline: Int,
) -> RawHttpOutcome {
  let remaining = int.max(deadline - bootstrap.monotonic_time_ms(), 0)
  case process.receive(events, remaining) {
    Error(Nil) ->
      RawFault(UnavailableFault("timed out reading HTTP response body"))
    Ok(http.RequestFailed(reason:)) -> RawFault(UnavailableFault(reason))
    Ok(http.RequestRefused(status: code, ..)) ->
      RawFault(UnavailableFault(
        "HTTP request refused with status " <> int.to_string(code),
      ))
    Ok(http.ResponseStatus(..)) ->
      RawFault(MalformedFault("duplicate HTTP status before response end"))
    Ok(http.ResponseChunk(chunk:)) -> {
      let next_size = bit_array.byte_size(bytes) + bit_array.byte_size(chunk)
      case next_size <= max_response_bytes {
        False ->
          RawFault(MalformedFault(
            "the server's HTTP response exceeded the "
            <> int.to_string(max_response_bytes)
            <> "-byte limit",
          ))
        True ->
          collect_body(
            events,
            status,
            session_id,
            content_type,
            expected_id,
            <<bytes:bits, chunk:bits>>,
            deadline,
          )
      }
    }
    Ok(http.ResponseEnd) ->
      finish_body(status, session_id, content_type, expected_id, bytes)
  }
}

fn finish_body(
  status: Int,
  session_id: Option(String),
  content_type: String,
  expected_id: Option(Id),
  bytes: BitArray,
) -> RawHttpOutcome {
  case expected_id, status == 202 || status == 204 || status == 200, bytes {
    None, True, _ -> RawEmptyAccepted(session_id:)
    _, _, _ ->
      case content_type == "application/json" {
        True -> decode_json_body(status, session_id, expected_id, bytes)
        False ->
          case status >= 200 && status < 300 {
            True ->
              RawFault(MalformedFault(
                "unsupported HTTP content-type `" <> content_type <> "`",
              ))
            False ->
              RawFault(UnavailableFault(
                "the server answered HTTP " <> int.to_string(status),
              ))
          }
      }
  }
}

fn decode_json_body(
  status: Int,
  session_id: Option(String),
  expected_id: Option(Id),
  bytes: BitArray,
) -> RawHttpOutcome {
  use <- bool.guard(
    when: bytes == <<>> && status >= 200 && status < 300,
    return: RawFault(MalformedFault("the server returned an empty JSON body")),
  )
  case bit_array.to_string(bytes) {
    Error(Nil) ->
      RawFault(MalformedFault("the server's JSON response is not valid UTF-8"))
    Ok(text) ->
      case json.parse(text), jsonrpc.decode_modern(text), expected_id {
        Ok(value),
          Ok(jsonrpc.Correlated(jsonrpc.Response(response_id, outcome))),
          Some(id)
          if response_id == id
        -> RawParsed(ParsedResponse(session_id:, value:, outcome:))
        Ok(_), Ok(jsonrpc.UncorrelatedError(error)), Some(id) ->
          RawParsed(ParsedResponse(
            session_id:,
            value: jsonrpc.error_response(Some(id), error),
            outcome: Error(error),
          ))
        _, _, _ ->
          case status >= 200 && status < 300 {
            True ->
              RawFault(MalformedFault(
                "the server's JSON response is not a correlated JSON-RPC response",
              ))
            False ->
              RawFault(UnavailableFault(
                "the server answered HTTP " <> int.to_string(status),
              ))
          }
      }
  }
}

fn media_type(headers: List(#(String, String))) -> String {
  case http_headers.get(headers, "content-type") {
    Error(_) -> ""
    Ok(raw) ->
      raw
      |> string.split(";")
      |> list.first
      |> result.unwrap("")
      |> string.trim
      |> string.lowercase
  }
}
