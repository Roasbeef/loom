//// Loom adapter for `gleam_mcp/streamable_http` over `provider/http.Transport`.
////
//// The protocol state machine — `2025-06-18` / `2025-03-26` / `2024-11-05`
//// initialized Streamable HTTP sessions (`Mcp-Session-Id`, `202 Accepted`,
//// session `DELETE`), `2026-07-28` stateless modern HTTP fallback
//// (`discovery/discover`, request-scoped `_meta`, `Mcp-*` and `x-mcp-header`
//// mirrors), 8 MiB JSON/SSE bounds, OAuth 401 refresh retry, and HMAC fault
//// authentication — lives in `gleam_mcp/streamable_http`. This module bridges
//// Loom's `provider/http.Transport` into `streamable_http.HttpTransport`.
////
//// ## Flow
////
//// `seam` → `to_streamable_config` → `adapt_transport` → `sh.seam`

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/result
import gleam_mcp/streamable_http as sh
import gleam_mcp/transport
import provider/http
import weft

/// The byte ceiling for retained accumulation of one HTTP JSON response body or
/// one SSE event (8 MiB), matching `gleam_mcp/streamable_http`.
pub const max_response_bytes = sh.max_response_bytes

/// How outbound HTTP requests authenticate to the remote MCP endpoint.
pub type Auth {
  /// No `Authorization` header is sent.
  NoAuth

  /// Static `Authorization: Bearer <token>`.
  Bearer(token: String)

  /// Static `Authorization: Macaroon <token>`.
  Macaroon(token: String)

  /// OAuth 2.1 bearer token resolved per request, with one refresh attempt on
  /// HTTP 401/403.
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

/// Builds a `transport.Transport` (`ChannelTransport`) for a remote HTTP MCP
/// server by delegating to `gleam_mcp/streamable_http.seam`.
///
/// ## Examples
///
/// ```gleam
/// // http.seam(config)
/// ```
pub fn seam(config: Config) -> transport.Transport {
  sh.seam(to_streamable_config(config))
}

/// Authenticates a local HTTP fault message so `client/mcp` can distinguish it
/// from a remote JSON-RPC server error.
///
/// ## Examples
///
/// ```gleam
/// let tagged = http.tag_fault(http.MalformedFault("too large"))
/// assert http.classify_fault(tagged) == option.Some(http.MalformedFault("too large"))
/// ```
pub fn tag_fault(fault: FaultKind) -> String {
  case fault {
    MalformedFault(reason:) -> sh.tag_fault(sh.MalformedFault(reason:))
    UnavailableFault(reason:) -> sh.tag_fault(sh.UnavailableFault(reason:))
  }
}

/// Verifies and decodes a tagged local HTTP fault message. Untrusted server
/// error messages without a valid HMAC return `None`.
///
/// ## Examples
///
/// ```gleam
/// assert http.classify_fault("untrusted server error") == option.None
/// ```
pub fn classify_fault(message: String) -> Option(FaultKind) {
  sh.classify_fault(message)
  |> option.map(fn(fault) {
    case fault {
      sh.MalformedFault(reason:) -> MalformedFault(reason:)
      sh.UnavailableFault(reason:) -> UnavailableFault(reason:)
    }
  })
}

/// Converts client MCP HTTP configuration to streamable HTTP client configuration.
fn to_streamable_config(config: Config) -> sh.Config {
  // Translate authorization strategy to streamable representation.
  let auth = case config.auth {
    NoAuth -> sh.NoAuth
    Bearer(token:) -> sh.Bearer(token:)
    Macaroon(token:) -> sh.Macaroon(token:)
    OAuth(authorize:, refresh_unauthorized:) ->
      sh.OAuth(authorize:, refresh_unauthorized:)
  }

  sh.Config(
    server: config.server,
    url: config.url,
    auth:,
    http_transport: adapt_transport(config.http_transport),
    client_name: "loom",
    client_version: config.client_version,
    login_command: "loomd mcp login",
    request_timeout_ms: config.request_timeout_ms,
  )
}

/// Adapts provider HTTP transport to the streamable HTTP transport interface.
fn adapt_transport(provider_transport: http.Transport) -> sh.HttpTransport {
  let prepare_streaming = provider_transport.prepare_streaming
  sh.HttpTransport(prepare_streaming: fn(req, events) {
    let ready = process.new_subject()
    let provider_req =
      http.HttpRequest(
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: req.body,
      )

    // Spawn asynchronous worker relaying provider events to stream receiver.
    let relay =
      process.spawn_unlinked(fn() {
        let provider_events = process.new_subject()

        // Dispatch streaming request to underlying provider transport.
        case prepare_streaming(provider_req, provider_events) {
          Error(reason) -> process.send(ready, Error(reason))
          Ok(prepared) -> {
            process.send(ready, Ok(prepared))
            relay_events(provider_events, events)
          }
        }
      })

    // Await preparation response from spawned streaming worker.
    use prepared <- result.try(case process.receive(ready, 5000) {
      Ok(outcome) -> outcome
      Error(Nil) -> {
        process.kill(relay)
        Error("mcp http relay timed out preparing request")
      }
    })

    let running = prepared.running
    let begin = prepared.begin
    Ok(sh.PreparedHttp(
      running: sh.RunningHttp(owner: running.owner, cancel: fn() {
        http.cancel(running)
        process.kill(relay)
      }),
      begin:,
    ))
  })
}

/// Forwards events from provider event subject to streamable event subject.
fn relay_events(
  source: Subject(http.HttpEvent),
  target: Subject(sh.HttpEvent),
) -> Nil {
  // Receive and translate each provider stream event until stream terminates.
  case process.receive(source, 60_000) {
    Error(Nil) -> Nil
    Ok(http.ResponseStatus(status:, headers:)) -> {
      process.send(target, sh.ResponseStatus(status:, headers:))
      relay_events(source, target)
    }
    Ok(http.ResponseChunk(chunk:)) -> {
      process.send(target, sh.ResponseChunk(chunk:))
      relay_events(source, target)
    }
    Ok(http.ResponseEnd) -> process.send(target, sh.ResponseEnd)
    Ok(http.RequestRefused(status:, body: _)) ->
      process.send(target, sh.RequestRefused(status:, headers: [], body: ""))
    Ok(http.RequestFailed(reason:)) ->
      process.send(target, sh.RequestFailed(reason:))
  }
}
