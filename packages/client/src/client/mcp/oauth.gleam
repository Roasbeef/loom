//// OAuth 2.1 authorization-code + PKCE discovery, registration, login, and
//// token refresh for remote HTTP MCP servers.
////
//// An operator authorizes a remote `[mcp.<name>]` server (`auth = "oauth"`)
//// from the terminal with `loomd mcp login <name>`. Login discovers Protected
//// Resource Metadata (RFC 9728) and Authorization Server Metadata (RFC 8414),
//// uses a pre-registered `client_id` or Dynamic Client Registration
//// (RFC 7591), opens one loopback `127.0.0.1` listener with a fresh PKCE
//// `S256` verifier and state, and exchanges the authorization code with the
//// MCP server's canonical `resource` indicator (RFC 8707).
////
//// At session boot and on each outbound HTTP request, `authorize` reads or
//// refreshes the bearer token under the server's kernel file lock. When a
//// token expires mid-session and cannot be refreshed, the stored grant is
//// cleared and the capability call fails in-band with instructions to run
//// `loomd mcp login <name>`.
////
//// ## Flow
////
//// `discover` → `login` → `browser_flow` → `exchange_code` → `authorize` →
//// `refresh`
////
//// 1. `discover` probes Protected Resource Metadata (`discover_protected_resource`,
////    `find_protected_resource`) and Authorization Server Metadata
////    (`discover_auth_server`, `find_auth_server`, `decode_auth_server`).
//// 2. `login` and `login_at` enter `browser_flow`, resolving the client ID with
////    `resolve_client_id` and `register_client`, serving `/auth/start` and
////    `/auth/callback` with `handle_browser`, `handle_verified_browser`,
////    `await_browser` and `callback`, and redeeming the code with
////    `exchange_code` and `token_request`.
//// 3. `authorize`, `authorize_at` and `refresh_unauthorized_at` check the
////    saved record with `check_binding_config` and rotate expired tokens
////    through `renew` and `refresh`.

import client/codex/network
import client/daemon/listener
import client/mcp/credentials.{type Binding, type Grant, Binding, Grant}
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http as gleam_http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap
import mist
import provider/http
import weft

/// Injected boundary facts for deterministic MCP OAuth tests.
pub type Services {
  Services(
    /// Performs redirect-refusing, bounded HTTP requests.
    fetch: fn(http.HttpRequest, Int) -> Result(network.Response, String),
    /// Supplies the current wall-clock time in Unix milliseconds.
    now: fn() -> Int,
    /// Supplies cryptographic random bytes for PKCE verifiers and state.
    entropy: fn(Int) -> BitArray,
  )
}

/// Discovered OAuth 2.1 endpoints for one remote MCP server.
pub type Metadata {
  Metadata(
    /// The MCP server's canonical resource URL (RFC 8707).
    resource: String,
    /// The authorization server's canonical issuer URL.
    issuer: String,
    /// The browser authorization endpoint URL.
    authorization_endpoint: String,
    /// The token exchange and refresh endpoint URL.
    token_endpoint: String,
    /// Optional dynamic client registration endpoint URL (RFC 7591).
    registration_endpoint: Option(String),
    /// Scopes to request during authorization.
    scopes: List(String),
  )
}

/// The transaction values retained only by the pending browser attempt.
pub type Attempt {
  Attempt(
    /// Secret PKCE verifier, never placed in an authorization URL.
    verifier: String,
    /// One-use state checked before either code or error is accepted.
    state: String,
    /// Resolved OAuth client identifier for this attempt.
    client_id: String,
  )
}

/// A state-checked browser callback ready for the token exchange.
pub type Callback {
  Callback(
    /// The one-use authorization code.
    code: String,
  )
}

type BrowserMessage {
  CheckAuthority(List(#(String, String)), Subject(Result(Nil, Nil)))
  Start(Subject(String))
  Returned(Result(Callback, String))
}

type Token {
  Token(
    access: String,
    refresh: Option(String),
    token_type: String,
    expires_in: Int,
    scopes: List(String),
  )
}

type ProtectedResource {
  ProtectedResource(
    resource: Option(String),
    authorization_servers: List(String),
    scopes_supported: List(String),
  )
}

type AuthServer {
  AuthServer(
    issuer: Option(String),
    authorization_endpoint: String,
    token_endpoint: String,
    registration_endpoint: Option(String),
    scopes_supported: List(String),
    code_challenge_methods_supported: Option(List(String)),
  )
}

/// Builds production OAuth services bound to the enclosing `weft.Ledger`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.services_on(ledger)
/// ```
pub fn services_on(ledger: weft.Ledger) -> Services {
  Services(
    fetch: fn(request, limit) { network.fetch(ledger, request, limit) },
    now: bootstrap.system_time_ms,
    entropy: crypto.strong_random_bytes,
  )
}

/// The literal loopback URL an operator opens to begin the browser attempt.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.start_url(1455) == "http://127.0.0.1:1455/auth/start"
/// ```
pub fn start_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/auth/start"
}

/// Constructs the authorization server redirect URL with PKCE `S256` and
/// RFC 8707 `resource` binding.
///
/// ## Examples
///
/// ```gleam
/// // oauth.authorization_url(metadata, attempt, "http://127.0.0.1:1455/auth/callback")
/// ```
pub fn authorization_url(
  metadata: Metadata,
  attempt: Attempt,
  redirect_uri: String,
) -> String {
  let challenge =
    crypto.hash(crypto.Sha256, bit_array.from_string(attempt.verifier))
    |> base64url
  let scope_param = case metadata.scopes {
    [] -> []
    scopes -> [#("scope", string.join(scopes, " "))]
  }
  let params =
    list.append(
      [
        #("response_type", "code"),
        #("client_id", attempt.client_id),
        #("redirect_uri", redirect_uri),
        #("resource", metadata.resource),
      ],
      list.append(scope_param, [
        #("state", attempt.state),
        #("code_challenge", challenge),
        #("code_challenge_method", "S256"),
      ]),
    )
  let sep = case string.contains(metadata.authorization_endpoint, "?") {
    True -> "&"
    False -> "?"
  }
  metadata.authorization_endpoint <> sep <> uri.query_to_string(params)
}

/// Validates a loopback callback's state in constant time before reading `code`.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.callback(oauth.Attempt("v", "s", "c"), "state=s&code=abc")
///   == Ok(oauth.Callback("abc"))
/// ```
pub fn callback(attempt: Attempt, query: String) -> Result(Callback, String) {
  use <- bool.guard(
    when: string.byte_size(query) > 8192,
    return: Error("invalid_callback"),
  )
  use fields <- result.try(
    uri.parse_query(query) |> result.replace_error("invalid_callback"),
  )
  use state <- result.try(unique(fields, "state"))
  use <- bool.guard(
    when: !crypto.secure_compare(
      bit_array.from_string(state),
      bit_array.from_string(attempt.state),
    ),
    return: Error("invalid_callback"),
  )
  use <- bool.guard(
    when: list.key_find(fields, "error") != Error(Nil),
    return: Error("authorization_denied"),
  )
  use code <- result.try(unique(fields, "code"))
  Ok(Callback(code:))
}

fn unique(
  fields: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  case list.filter(fields, fn(field) { field.0 == name }) {
    [#(_, value)] if value != "" -> Ok(value)
    [] | [_] | [_, _, ..] -> Error("invalid_callback")
  }
}

/// Discovers OAuth 2.1 endpoints for a remote MCP server URL.
///
/// Checks Protected Resource Metadata (RFC 9728) at the path-suffixed and root
/// `.well-known/oauth-protected-resource` endpoints, then Authorization Server
/// Metadata (RFC 8414) at `.well-known/oauth-authorization-server` and
/// `.well-known/openid-configuration`, falling back to standard `/authorize`,
/// `/token`, and `/register` routes at the authorization server origin when
/// discovery documents return 404.
///
/// ## Examples
///
/// ```gleam
/// // oauth.discover("https://mcp.example.com/mcp", services)
/// ```
pub fn discover(
  server_url: String,
  services: Services,
) -> Result(Metadata, String) {
  use <- bool.guard(
    when: !credentials.valid_oauth_url(server_url),
    return: Error("invalid_server_url"),
  )
  use #(origin, path) <- result.try(split_origin_and_path(server_url))
  use #(auth_server_url, prm_scopes) <- result.try(discover_protected_resource(
    server_url,
    origin,
    path,
    services,
  ))
  discover_auth_server(server_url, auth_server_url, prm_scopes, services)
}

fn discover_protected_resource(
  server_url: String,
  origin: String,
  path: String,
  services: Services,
) -> Result(#(String, List(String)), String) {
  let candidates = case path {
    "" | "/" -> [origin <> "/.well-known/oauth-protected-resource"]
    _ -> [
      origin <> "/.well-known/oauth-protected-resource" <> path,
      origin <> "/.well-known/oauth-protected-resource",
    ]
  }
  find_protected_resource(candidates, server_url, origin, services)
}

fn find_protected_resource(
  candidates: List(String),
  server_url: String,
  origin: String,
  services: Services,
) -> Result(#(String, List(String)), String) {
  case candidates {
    [] -> Ok(#(origin, []))
    [url, ..rest] ->
      case fetch_json(url, services) {
        Error("not_found") ->
          find_protected_resource(rest, server_url, origin, services)
        Error(reason) -> Error(reason)
        Ok(body) -> decode_protected_resource(body, server_url, origin)
      }
  }
}

fn decode_protected_resource(
  body: String,
  server_url: String,
  origin: String,
) -> Result(#(String, List(String)), String) {
  use prm <- result.try(
    json.parse(body, protected_resource_decoder())
    |> result.replace_error("invalid_protected_resource_metadata"),
  )
  use Nil <- result.try(validate_prm_resource(prm.resource, server_url, origin))
  case prm.authorization_servers {
    [first, ..] ->
      case credentials.valid_oauth_url(first) {
        True -> Ok(#(strip_trailing_slash(first), prm.scopes_supported))
        False -> Error("invalid_protected_resource_metadata")
      }
    [] -> Error("invalid_protected_resource_metadata")
  }
}

fn validate_prm_resource(
  reported: Option(String),
  server_url: String,
  origin: String,
) -> Result(Nil, String) {
  case reported {
    None -> Ok(Nil)
    Some(value) -> {
      let trimmed = strip_trailing_slash(value)
      case
        trimmed == strip_trailing_slash(server_url)
        || trimmed == strip_trailing_slash(origin)
      {
        True -> Ok(Nil)
        False -> Error("protected_resource_mismatch")
      }
    }
  }
}

fn discover_auth_server(
  server_url: String,
  auth_server_url: String,
  prm_scopes: List(String),
  services: Services,
) -> Result(Metadata, String) {
  use #(as_origin, as_path) <- result.try(split_origin_and_path(auth_server_url))
  let candidates = case as_path {
    "" | "/" -> [
      as_origin <> "/.well-known/oauth-authorization-server",
      as_origin <> "/.well-known/openid-configuration",
    ]
    _ -> [
      as_origin <> "/.well-known/oauth-authorization-server" <> as_path,
      as_origin <> "/.well-known/openid-configuration" <> as_path,
      as_origin <> as_path <> "/.well-known/openid-configuration",
    ]
  }
  find_auth_server(
    candidates,
    server_url,
    auth_server_url,
    as_origin,
    prm_scopes,
    services,
  )
}

fn find_auth_server(
  candidates: List(String),
  server_url: String,
  auth_server_url: String,
  as_origin: String,
  prm_scopes: List(String),
  services: Services,
) -> Result(Metadata, String) {
  case candidates {
    [] ->
      Ok(Metadata(
        resource: server_url,
        issuer: auth_server_url,
        authorization_endpoint: as_origin <> "/authorize",
        token_endpoint: as_origin <> "/token",
        registration_endpoint: Some(as_origin <> "/register"),
        scopes: prm_scopes,
      ))
    [url, ..rest] ->
      case fetch_json(url, services) {
        Error("not_found") ->
          find_auth_server(
            rest,
            server_url,
            auth_server_url,
            as_origin,
            prm_scopes,
            services,
          )
        Error(reason) -> Error(reason)
        Ok(body) ->
          decode_auth_server(body, server_url, auth_server_url, prm_scopes)
      }
  }
}

fn decode_auth_server(
  body: String,
  server_url: String,
  auth_server_url: String,
  prm_scopes: List(String),
) -> Result(Metadata, String) {
  use parsed <- result.try(
    json.parse(body, auth_server_decoder())
    |> result.replace_error("invalid_auth_server_metadata"),
  )
  use Nil <- result.try(case parsed.code_challenge_methods_supported {
    None -> Ok(Nil)
    Some(methods) ->
      case list.contains(methods, "S256") {
        True -> Ok(Nil)
        False -> Error("pkce_s256_unsupported")
      }
  })
  let issuer =
    option.unwrap(parsed.issuer, auth_server_url) |> strip_trailing_slash
  use Nil <- result.try(
    case
      credentials.valid_oauth_url(issuer)
      && credentials.valid_oauth_url(parsed.authorization_endpoint)
      && credentials.valid_oauth_url(parsed.token_endpoint)
      && case parsed.registration_endpoint {
        None -> True
        Some(reg) -> credentials.valid_oauth_url(reg)
      }
    {
      True -> Ok(Nil)
      False -> Error("invalid_auth_server_metadata")
    },
  )
  let base_scopes = case prm_scopes {
    [] -> parsed.scopes_supported
    _ -> prm_scopes
  }
  let scopes = case
    list.contains(parsed.scopes_supported, "offline_access")
    && !list.contains(base_scopes, "offline_access")
  {
    True -> list.append(base_scopes, ["offline_access"])
    False -> base_scopes
  }
  Ok(Metadata(
    resource: server_url,
    issuer:,
    authorization_endpoint: parsed.authorization_endpoint,
    token_endpoint: parsed.token_endpoint,
    registration_endpoint: parsed.registration_endpoint,
    scopes:,
  ))
}

fn protected_resource_decoder() -> decode.Decoder(ProtectedResource) {
  use resource <- decode.optional_field(
    "resource",
    None,
    decode.optional(decode.string),
  )
  use authorization_servers <- decode.optional_field(
    "authorization_servers",
    [],
    decode.list(decode.string),
  )
  use scopes_supported <- decode.optional_field(
    "scopes_supported",
    [],
    decode.list(decode.string),
  )
  decode.success(ProtectedResource(
    resource:,
    authorization_servers:,
    scopes_supported:,
  ))
}

fn auth_server_decoder() -> decode.Decoder(AuthServer) {
  use issuer <- decode.optional_field(
    "issuer",
    None,
    decode.optional(decode.string),
  )
  use authorization_endpoint <- decode.field(
    "authorization_endpoint",
    decode.string,
  )
  use token_endpoint <- decode.field("token_endpoint", decode.string)
  use registration_endpoint <- decode.optional_field(
    "registration_endpoint",
    None,
    decode.optional(decode.string),
  )
  use scopes_supported <- decode.optional_field(
    "scopes_supported",
    [],
    decode.list(decode.string),
  )
  use code_challenge_methods_supported <- decode.optional_field(
    "code_challenge_methods_supported",
    None,
    decode.optional(decode.list(decode.string)),
  )
  decode.success(AuthServer(
    issuer:,
    authorization_endpoint:,
    token_endpoint:,
    registration_endpoint:,
    scopes_supported:,
    code_challenge_methods_supported:,
  ))
}

/// Runs browser OAuth 2.1 login for `server` and saves the resulting binding.
///
/// ## Examples
///
/// ```gleam
/// // oauth.login("linear", "https://mcp.linear.app/mcp", None, notify, ledger)
/// ```
pub fn login(
  server: String,
  server_url: String,
  configured_client_id: Option(String),
  notify: fn(Int) -> Nil,
  ledger: weft.Ledger,
) -> Result(Binding, String) {
  use directory <- result.try(credentials.directory())
  login_at(
    directory,
    server,
    server_url,
    configured_client_id,
    services_on(ledger),
    notify,
    ledger,
  )
}

/// Runs browser OAuth 2.1 login against an explicit credential directory and
/// injected `Services`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.login_at(dir, "linear", url, None, services, notify, ledger)
/// ```
@internal
pub fn login_at(
  directory: String,
  server: String,
  server_url: String,
  configured_client_id: Option(String),
  services: Services,
  notify: fn(Int) -> Nil,
  ledger: weft.Ledger,
) -> Result(Binding, String) {
  credentials.with_lock(directory, server, fn(path) {
    use stored <- result.try(credentials.load(path))
    use metadata <- result.try(discover(server_url, services))
    use binding <- result.try(browser_flow(
      server,
      stored,
      metadata,
      configured_client_id,
      services,
      notify,
      ledger,
    ))
    use Nil <- result.try(credentials.save(path, binding))
    Ok(binding)
  })
}

fn browser_flow(
  server: String,
  stored: Option(Binding),
  metadata: Metadata,
  configured_client_id: Option(String),
  services: Services,
  notify: fn(Int) -> Nil,
  ledger: weft.Ledger,
) -> Result(Binding, String) {
  let messages = process.new_subject()
  let verifier = base64url(services.entropy(32))
  let state = base64url(services.entropy(32))

  let builder =
    mist.new(fn(req) { handle_browser(req, messages, verifier, state) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
  use owner <- result.try(
    listener.prepare(process.self(), builder)
    |> result.replace_error("callback_unavailable"),
  )
  use Nil <- result.try(
    case
      weft.adopt(ledger, owner: listener.pid(owner), cancel: fn() {
        listener.close(owner)
      })
    {
      weft.Adopted -> Ok(Nil)
      weft.Refused -> Error("request_cancelled")
    },
  )
  listener.begin(owner)
  use bound <- result.try(listener.ready(owner, within: 5000))
  let authority = "127.0.0.1:" <> int.to_string(bound.port)
  let redirect_uri = "http://" <> authority <> "/auth/callback"
  let resolved_client =
    resolve_client_id(
      stored,
      metadata,
      configured_client_id,
      redirect_uri,
      services,
    )
  case resolved_client {
    Error(reason) -> {
      listener.close(owner)
      Error(reason)
    }
    Ok(client_id) -> {
      let attempt = Attempt(verifier:, state:, client_id:)
      notify(bound.port)
      let answer =
        await_browser(
          messages,
          authorization_url(metadata, attempt, redirect_uri),
          authority,
          bootstrap.monotonic_time_ms() + 600_000,
        )
      listener.close(owner)
      use received <- result.try(answer)
      exchange_code(server, metadata, attempt, redirect_uri, received, services)
    }
  }
}

fn resolve_client_id(
  stored: Option(Binding),
  metadata: Metadata,
  configured_client_id: Option(String),
  redirect_uri: String,
  services: Services,
) -> Result(String, String) {
  case configured_client_id {
    Some(client_id) -> Ok(client_id)
    None ->
      case stored {
        Some(existing)
          if existing.resource == metadata.resource
          && existing.issuer == metadata.issuer
        -> Ok(existing.client_id)
        _ ->
          register_client(
            metadata.registration_endpoint,
            redirect_uri,
            services,
          )
      }
  }
}

/// Dynamically registers a public loopback OAuth client (RFC 7591).
fn register_client(
  registration_endpoint: Option(String),
  redirect_uri: String,
  services: Services,
) -> Result(String, String) {
  use endpoint <- result.try(option.to_result(
    registration_endpoint,
    "client_id_required",
  ))
  let body =
    json.object([
      #("client_name", json.string("Loom")),
      #("redirect_uris", json.array([redirect_uri], json.string)),
      #(
        "grant_types",
        json.array(["authorization_code", "refresh_token"], json.string),
      ),
      #("response_types", json.array(["code"], json.string)),
      #("token_endpoint_auth_method", json.string("none")),
    ])
    |> json.to_string
  use resp <- result.try(services.fetch(
    http.HttpRequest(
      "POST",
      endpoint,
      [
        #("content-type", "application/json"),
        #("accept", "application/json"),
      ],
      body,
    ),
    65_536,
  ))
  use <- bool.guard(
    when: resp.status != 200 && resp.status != 201,
    return: Error("client_registration_failed"),
  )
  let decoder = {
    use client_id <- decode.field("client_id", decode.string)
    decode.success(client_id)
  }
  use client_id <- result.try(
    json.parse(resp.body, decoder)
    |> result.replace_error("invalid_client_registration"),
  )
  use <- bool.guard(
    when: client_id == ""
      || string.byte_size(client_id) > 256
      || string.contains(client_id, "\n")
      || string.contains(client_id, "\r"),
    return: Error("invalid_client_registration"),
  )
  Ok(client_id)
}

fn handle_browser(
  req: request.Request(mist.Connection),
  messages: Subject(BrowserMessage),
  verifier: String,
  state: String,
) -> response.Response(mist.ResponseData) {
  let authority = process.new_subject()
  process.send(messages, CheckAuthority(req.headers, authority))
  case process.receive(authority, 1000) {
    Ok(Ok(Nil)) ->
      handle_verified_browser(
        req,
        messages,
        Attempt(verifier:, state:, client_id: "pending"),
      )
    Ok(Error(Nil)) -> page(400, "This sign-in host could not be verified.")
    Error(Nil) -> page(410, "This sign-in attempt has ended.")
  }
}

fn handle_verified_browser(
  req: request.Request(mist.Connection),
  messages: Subject(BrowserMessage),
  attempt: Attempt,
) -> response.Response(mist.ResponseData) {
  case req.method, req.path {
    gleam_http.Get, "/auth/start" -> {
      let reply = process.new_subject()
      process.send(messages, Start(reply))
      case process.receive(reply, 1000) {
        Ok(url) ->
          response.new(302)
          |> response.set_header("location", url)
          |> response.set_header("cache-control", "no-store")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("Continue to MCP authorization.")),
          )
        Error(Nil) -> page(410, "This sign-in attempt has ended.")
      }
    }
    gleam_http.Get, "/auth/callback" -> {
      let result = callback(attempt, option.unwrap(req.query, ""))
      case result {
        Ok(_) | Error("authorization_denied") -> {
          process.send(messages, Returned(result))
          page(
            200,
            "Authorization received. Return to Loom to see the verified result.",
          )
        }
        Error(_) ->
          page(400, "This authorization callback could not be verified.")
      }
    }
    _, _ -> page(404, "Unknown sign-in route.")
  }
}

fn page(status: Int, text: String) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

fn await_browser(
  messages: Subject(BrowserMessage),
  auth_url: String,
  authority: String,
  deadline: Int,
) -> Result(Callback, String) {
  use message <- result.try(
    process.receive(
      messages,
      int.max(deadline - bootstrap.monotonic_time_ms(), 0),
    )
    |> result.replace_error("login_cancelled"),
  )
  case message {
    CheckAuthority(headers, reply) -> {
      let checked = case
        list.filter(headers, fn(header) { string.lowercase(header.0) == "host" })
      {
        [#(_, received)] if received == authority -> Ok(Nil)
        _ -> Error(Nil)
      }
      process.send(reply, checked)
      await_browser(messages, auth_url, authority, deadline)
    }
    Start(reply) -> {
      process.send(reply, auth_url)
      await_browser(messages, auth_url, authority, deadline)
    }
    Returned(result) -> result
  }
}

fn exchange_code(
  server: String,
  metadata: Metadata,
  attempt: Attempt,
  redirect_uri: String,
  received: Callback,
  services: Services,
) -> Result(Binding, String) {
  use token <- result.try(token_request(
    metadata.token_endpoint,
    [
      #("grant_type", "authorization_code"),
      #("client_id", attempt.client_id),
      #("code", received.code),
      #("code_verifier", attempt.verifier),
      #("redirect_uri", redirect_uri),
      #("resource", metadata.resource),
    ],
    services,
  ))
  let scopes = case token.scopes {
    [] -> metadata.scopes
    granted -> granted
  }
  Ok(Binding(
    server:,
    resource: metadata.resource,
    issuer: metadata.issuer,
    token_endpoint: metadata.token_endpoint,
    client_id: attempt.client_id,
    grant: Some(Grant(
      access: token.access,
      refresh: token.refresh,
      scopes:,
      expires: services.now() + token.expires_in * 1000,
    )),
  ))
}

/// Resolves or refreshes the current bearer token for `server` in a managed scope.
///
/// ## Examples
///
/// ```gleam
/// // oauth.authorize("linear", "https://mcp.linear.app/mcp", None, ledger)
/// ```
pub fn authorize(
  server: String,
  server_url: String,
  configured_client_id: Option(String),
  ledger: weft.Ledger,
) -> Result(String, String) {
  use directory <- result.try(credentials.directory())
  authorize_at(
    directory,
    server,
    server_url,
    configured_client_id,
    services_on(ledger),
  )
}

/// Resolves or refreshes a bearer token using an explicit directory and `Services`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.authorize_at(dir, "linear", url, None, services)
/// ```
@internal
pub fn authorize_at(
  directory: String,
  server: String,
  server_url: String,
  configured_client_id: Option(String),
  services: Services,
) -> Result(String, String) {
  credentials.with_lock(directory, server, fn(path) {
    use stored <- result.try(credentials.load(path))
    use binding <- result.try(option.to_result(stored, "not_logged_in"))
    use Nil <- result.try(check_binding_config(
      binding,
      server_url,
      configured_client_id,
    ))
    use grant <- result.try(option.to_result(binding.grant, "not_logged_in"))
    case services.now() < grant.expires - 60_000 {
      True -> Ok(grant.access)
      False -> renew(path, binding, services)
    }
  })
}

/// Forces a token refresh after an outbound MCP request was rejected with HTTP 401.
///
/// If a concurrent request has already rotated the stored token to a fresh
/// value, returns that value without a second refresh call. If no refresh token
/// is available or the authorization server rejects the refresh, clears the
/// saved grant and returns `Error("reauthorization_required")`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.refresh_unauthorized_at(dir, "linear", url, None, old_token, services)
/// ```
@internal
pub fn refresh_unauthorized_at(
  directory: String,
  server: String,
  server_url: String,
  configured_client_id: Option(String),
  rejected_token: String,
  services: Services,
) -> Result(String, String) {
  credentials.with_lock(directory, server, fn(path) {
    use stored <- result.try(credentials.load(path))
    use binding <- result.try(option.to_result(stored, "not_logged_in"))
    use Nil <- result.try(check_binding_config(
      binding,
      server_url,
      configured_client_id,
    ))
    use grant <- result.try(option.to_result(
      binding.grant,
      "reauthorization_required",
    ))
    case
      grant.access != rejected_token && services.now() < grant.expires - 60_000
    {
      True -> Ok(grant.access)
      False -> renew(path, binding, services)
    }
  })
}

fn check_binding_config(
  binding: Binding,
  server_url: String,
  configured_client_id: Option(String),
) -> Result(Nil, String) {
  use <- bool.guard(
    when: binding.resource != server_url,
    return: Error("resource_mismatch"),
  )
  case configured_client_id {
    None -> Ok(Nil)
    Some(expected) ->
      case binding.client_id == expected {
        True -> Ok(Nil)
        False -> Error("client_id_mismatch")
      }
  }
}

fn renew(
  path: String,
  binding: Binding,
  services: Services,
) -> Result(String, String) {
  case refresh(binding, services) {
    Ok(refreshed) -> {
      use Nil <- result.try(credentials.save(path, refreshed))
      use grant <- result.try(option.to_result(
        refreshed.grant,
        "reauthorization_required",
      ))
      Ok(grant.access)
    }
    Error("reauthorization_required") | Error("invalid_client") -> {
      use Nil <- result.try(credentials.save(
        path,
        Binding(..binding, grant: None),
      ))
      Error("reauthorization_required")
    }
    Error(reason) -> Error(reason)
  }
}

/// Refreshes an expired grant at the authorization server's token endpoint.
///
/// ## Examples
///
/// ```gleam
/// // oauth.refresh(binding, services)
/// ```
pub fn refresh(
  binding: Binding,
  services: Services,
) -> Result(Binding, String) {
  use previous <- result.try(option.to_result(binding.grant, "not_logged_in"))
  use refresh_token <- result.try(option.to_result(
    previous.refresh,
    "reauthorization_required",
  ))
  use token <- result.try(token_request(
    binding.token_endpoint,
    [
      #("grant_type", "refresh_token"),
      #("client_id", binding.client_id),
      #("refresh_token", refresh_token),
      #("resource", binding.resource),
    ],
    services,
  ))
  let next_refresh = case token.refresh {
    Some(_) -> token.refresh
    None -> previous.refresh
  }
  let next_scopes = case token.scopes {
    [] -> previous.scopes
    scopes -> scopes
  }
  Ok(
    Binding(
      ..binding,
      grant: Some(Grant(
        access: token.access,
        refresh: next_refresh,
        scopes: next_scopes,
        expires: services.now() + token.expires_in * 1000,
      )),
    ),
  )
}

/// Clears the saved grant for `server` while preserving its client registration.
///
/// ## Examples
///
/// ```gleam
/// // oauth.logout_at(dir, "linear")
/// ```
@internal
pub fn logout_at(directory: String, server: String) -> Result(Nil, String) {
  credentials.with_lock(directory, server, fn(path) {
    use stored <- result.try(credentials.load(path))
    case stored {
      None -> Ok(Nil)
      Some(binding) -> credentials.save(path, Binding(..binding, grant: None))
    }
  })
}

/// Reports whether `server` currently holds a saved grant for `server_url`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.status_at(dir, "linear", url, None)
/// ```
@internal
pub fn status_at(
  directory: String,
  server: String,
  server_url: String,
  configured_client_id: Option(String),
) -> Result(Option(Grant), String) {
  credentials.with_lock(directory, server, fn(path) {
    use stored <- result.try(credentials.load(path))
    case stored {
      None -> Ok(None)
      Some(binding) ->
        case check_binding_config(binding, server_url, configured_client_id) {
          Ok(Nil) -> Ok(binding.grant)
          Error(_) -> Ok(None)
        }
    }
  })
}

/// Words an OAuth error code for an operator log line or in-band refusal,
/// never quoting a token value.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(
///   oauth.describe_auth_error("linear", "not_logged_in"),
///   "loomd mcp login linear",
/// )
/// ```
pub fn describe_auth_error(server: String, code: String) -> String {
  case code {
    "not_logged_in" ->
      "its OAuth credential is not signed in; run `loomd mcp login "
      <> server
      <> "`"
    "reauthorization_required" ->
      "the OAuth token for mcp."
      <> server
      <> " expired and requires reauthorization; run `loomd mcp login "
      <> server
      <> "`"
    "resource_mismatch" | "client_id_mismatch" ->
      "its saved OAuth registration does not match the current configuration; run `loomd mcp login "
      <> server
      <> "`"
    other ->
      "its OAuth credential could not be resolved ("
      <> other
      <> "); run `loomd mcp login "
      <> server
      <> "`"
  }
}

fn token_request(
  token_endpoint: String,
  fields: List(#(String, String)),
  services: Services,
) -> Result(Token, String) {
  use resp <- result.try(services.fetch(
    http.HttpRequest(
      "POST",
      token_endpoint,
      [
        #("content-type", "application/x-www-form-urlencoded"),
        #("accept", "application/json"),
      ],
      uri.query_to_string(fields),
    ),
    65_536,
  ))
  use Nil <- result.try(case resp.status {
    200 -> Ok(Nil)
    status -> Error(token_error(status, resp.body))
  })
  use token <- result.try(
    json.parse(resp.body, token_decoder())
    |> result.replace_error("invalid_token_response"),
  )
  use <- bool.guard(
    when: token.access == ""
      || token.refresh == Some("")
      || string.lowercase(token.token_type) != "bearer"
      || token.expires_in <= 0
      || token.expires_in > 31_536_000,
    return: Error("invalid_token_response"),
  )
  Ok(token)
}

fn token_error(status: Int, body: String) -> String {
  let decoder = {
    use error <- decode.field(
      "error",
      decode.one_of(decode.string, [
        {
          use code <- decode.field("code", decode.string)
          decode.success(code)
        },
      ]),
    )
    decode.success(error)
  }
  case json.parse(body, decoder), status {
    Ok("invalid_client"), _ -> "invalid_client"
    Ok("invalid_grant"), _
    | Ok("invalid_refresh_token"), _
    | Ok("token_expired"), _
    | Ok("refresh_token_expired"), _
    | Ok("refresh_token_invalidated"), _
    | Ok("refresh_token_reused"), _
    | Ok("unauthorized_client"), _
    | _, 400
    | _, 401
    | _, 403
    -> "reauthorization_required"
    _, _ -> "token_endpoint_unavailable"
  }
}

fn token_decoder() -> decode.Decoder(Token) {
  use access <- decode.field("access_token", decode.string)
  use refresh <- decode.optional_field(
    "refresh_token",
    None,
    decode.optional(decode.string),
  )
  use token_type <- decode.field("token_type", decode.string)
  use expires_in <- decode.optional_field("expires_in", 3600, decode.int)
  use scope_str <- decode.optional_field("scope", "", decode.string)
  let scopes =
    string.split(scope_str, " ")
    |> list.filter(fn(scope) { scope != "" })
  decode.success(Token(access:, refresh:, token_type:, expires_in:, scopes:))
}

fn fetch_json(url: String, services: Services) -> Result(String, String) {
  use resp <- result.try(services.fetch(
    http.HttpRequest("GET", url, [#("accept", "application/json")], ""),
    65_536,
  ))
  case resp.status {
    200 -> Ok(resp.body)
    404 -> Error("not_found")
    _ -> Error("discovery_unavailable")
  }
}

fn split_origin_and_path(raw: String) -> Result(#(String, String), String) {
  use parsed <- result.try(
    uri.parse(raw) |> result.replace_error("invalid_server_url"),
  )
  use #(scheme, host) <- result.try(case parsed.scheme, parsed.host {
    Some(scheme), Some(host) if host != "" -> Ok(#(scheme, host))
    _, _ -> Error("invalid_server_url")
  })
  let port_suffix = case parsed.port {
    None -> ""
    Some(port) -> ":" <> int.to_string(port)
  }
  let origin = scheme <> "://" <> host <> port_suffix
  let path = strip_trailing_slash(parsed.path)
  Ok(#(origin, path))
}

fn strip_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") && value != "/" {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn base64url(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, False)
  |> string.replace("+", "-")
  |> string.replace("/", "_")
  |> string.replace("=", "")
}
