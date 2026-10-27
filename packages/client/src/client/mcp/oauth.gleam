//// Loom OAuth 2.1 browser sign-in, loopback callback listener, and locked
//// credential persistence over `gleam_mcp/oauth`.
////
//// Protocol discovery (RFC 9728 Protected Resource Metadata and RFC 8414
//// Authorization Server Metadata), Dynamic Client Registration (RFC 7591),
//// PKCE `S256` challenge construction, constant-time state verification, code
//// exchange, and refresh token rotation live in `gleam_mcp/oauth`. This module
//// wires those pure protocol steps to Loom's redirect-refusing
//// `client/codex/network.fetch`, the Mist loopback callback listener, and
//// `client/mcp/credentials`'s locked private storage.
////
//// ## Flow
////
//// `discover` → `login` → `browser_flow` → `authorize` → `renew`

import client/codex/network
import client/daemon/listener
import client/mcp/credentials.{type Binding, type Grant, Binding, Grant}
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/http as gleam_http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/oauth as mcp_oauth
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

/// Builds production OAuth services bound to the enclosing `weft.Ledger`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.services_on(ledger)
/// ```
pub fn services_on(ledger: weft.Ledger) -> Services {
  Services(
    fetch: fn(req, limit) { network.fetch(ledger, req, limit) },
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
  mcp_oauth.start_url(port)
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
  mcp_oauth.authorization_url(
    to_mcp_metadata(metadata),
    to_mcp_attempt(attempt),
    redirect_uri,
  )
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
  mcp_oauth.callback(to_mcp_attempt(attempt), query)
  |> result.map(from_mcp_callback)
}

/// Discovers OAuth 2.1 endpoints for a remote MCP server URL.
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
  mcp_oauth.discover(server_url, to_mcp_services(services))
  |> result.map(from_mcp_metadata)
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

/// Runs the loopback authorization flow and exchanges its verified callback.
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
  let entropy = services.entropy
  let verifier = mcp_oauth.secret_token(entropy(32))
  let state = mcp_oauth.secret_token(entropy(32))
  let builder =
    mist.new(fn(req) { handle_browser(req, messages, verifier, state) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
  use owner <- result.try(
    listener.prepare(process.self(), builder)
    |> result.replace_error("callback_unavailable"),
  )

  // Adopt listener custody into the caller's ledger before accepting requests.
  use Nil <- result.try(adopt_listener(ledger, owner))
  listener.begin(owner)
  use bound <- result.try(listener.ready(owner, within: 5000))
  let authority = "127.0.0.1:" <> int.to_string(bound.port)
  let redirect_uri = "http://" <> authority <> "/auth/callback"
  let mcp_services = to_mcp_services(services)
  let resolved_client =
    mcp_oauth.resolve_client_id(
      option.map(stored, to_mcp_binding),
      to_mcp_metadata(metadata),
      configured_client_id,
      redirect_uri,
      "Loom",
      mcp_services,
    )

  // A client-resolution failure closes the listener; success proceeds to callback exchange.
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
      mcp_oauth.exchange_code(
        server,
        to_mcp_metadata(metadata),
        to_mcp_attempt(attempt),
        redirect_uri,
        mcp_oauth.Callback(code: received.code),
        mcp_services,
      )
      |> result.map(from_mcp_binding)
    }
  }
}

/// Transfers listener shutdown responsibility to the operation ledger.
fn adopt_listener(
  ledger: weft.Ledger,
  owner: listener.Listener,
) -> Result(Nil, String) {
  case
    weft.adopt(ledger, owner: listener.pid(owner), cancel: fn() {
      listener.close(owner)
    })
  {
    weft.Adopted -> Ok(Nil)
    weft.Refused -> Error("request_cancelled")
  }
}

/// Verifies the callback host before dispatching a browser request.
fn handle_browser(
  req: request.Request(mist.Connection),
  messages: Subject(BrowserMessage),
  verifier: String,
  state: String,
) -> response.Response(mist.ResponseData) {
  let authority = process.new_subject()
  process.send(messages, CheckAuthority(req.headers, authority))

  // A verified authority is the prerequisite for handling any route.
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

/// Serves only the start and callback routes after host verification.
fn handle_verified_browser(
  req: request.Request(mist.Connection),
  messages: Subject(BrowserMessage),
  attempt: Attempt,
) -> response.Response(mist.ResponseData) {
  // Route only the two OAuth endpoints; reject every other path.
  case req.method, req.path {
    gleam_http.Get, "/auth/start" -> {
      let reply = process.new_subject()
      process.send(messages, Start(reply))

      // The start request redirects only while the flow is alive.
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

      // Return only a verified callback or explicit authorization denial.
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

/// Waits for browser messages until callback, cancellation, or deadline.
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

  // Browser messages advance the same flow without changing its deadline.
  case message {
    CheckAuthority(headers, reply) -> {
      // Accept exactly one Host header matching the bound loopback authority.
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
    use Nil <- result.try(mcp_oauth.check_binding_config(
      to_mcp_binding(binding),
      server_url,
      configured_client_id,
    ))
    use grant <- result.try(option.to_result(binding.grant, "not_logged_in"))
    let now = services.now

    // Keep a grant with a safety margin; otherwise refresh under the lock.
    case now() < grant.expires - 60_000 {
      True -> Ok(grant.access)
      False -> renew(path, binding, services)
    }
  })
}

/// Forces a token refresh after an outbound MCP request was rejected with HTTP 401.
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
    use Nil <- result.try(mcp_oauth.check_binding_config(
      to_mcp_binding(binding),
      server_url,
      configured_client_id,
    ))
    use grant <- result.try(option.to_result(
      binding.grant,
      "reauthorization_required",
    ))
    let now = services.now

    // Reuse a valid token only when it is not the rejected credential.
    case grant.access != rejected_token && now() < grant.expires - 60_000 {
      True -> Ok(grant.access)
      False -> renew(path, binding, services)
    }
  })
}

/// Refreshes and saves the grant, clearing it when reauthorization is required.
fn renew(
  path: String,
  binding: Binding,
  services: Services,
) -> Result(String, String) {
  // Invalid-client responses invalidate the grant; other failures preserve it.
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
  mcp_oauth.refresh(to_mcp_binding(binding), to_mcp_services(services))
  |> result.map(from_mcp_binding)
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

    // Logout removes only the grant and preserves client registration.
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

    // A saved binding must still match server configuration to report its grant.
    case stored {
      None -> Ok(None)
      Some(binding) ->
        // Return a grant only when its binding still matches configuration.
        case
          mcp_oauth.check_binding_config(
            to_mcp_binding(binding),
            server_url,
            configured_client_id,
          )
        {
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
  mcp_oauth.describe_auth_error(server, "loomd mcp login", code)
}

/// Adapts client service callbacks to the MCP OAuth service contract.
fn to_mcp_services(services: Services) -> mcp_oauth.Services {
  let fetch = services.fetch
  let now = services.now
  let entropy = services.entropy
  mcp_oauth.Services(
    fetch: fn(req, limit) {
      let provider_req =
        http.HttpRequest(
          method: req.method,
          url: req.url,
          headers: req.headers,
          body: req.body,
        )
      use resp <- result.map(fetch(provider_req, limit))
      mcp_oauth.HttpResponse(status: resp.status, headers: [], body: resp.body)
    },
    now:,
    entropy:,
  )
}

/// Converts the client-owned binding to the MCP OAuth representation.
fn to_mcp_binding(binding: Binding) -> mcp_oauth.Binding {
  mcp_oauth.Binding(
    server: binding.server,
    resource: binding.resource,
    issuer: binding.issuer,
    token_endpoint: binding.token_endpoint,
    client_id: binding.client_id,
    grant: option.map(binding.grant, fn(grant) {
      mcp_oauth.Grant(
        access: grant.access,
        refresh: grant.refresh,
        scopes: grant.scopes,
        expires: grant.expires,
      )
    }),
  )
}

/// Converts an MCP OAuth binding into the client-owned representation.
fn from_mcp_binding(binding: mcp_oauth.Binding) -> Binding {
  Binding(
    server: binding.server,
    resource: binding.resource,
    issuer: binding.issuer,
    token_endpoint: binding.token_endpoint,
    client_id: binding.client_id,
    grant: option.map(binding.grant, fn(grant) {
      Grant(
        access: grant.access,
        refresh: grant.refresh,
        scopes: grant.scopes,
        expires: grant.expires,
      )
    }),
  )
}

/// Converts discovered metadata to the MCP OAuth representation.
fn to_mcp_metadata(metadata: Metadata) -> mcp_oauth.Metadata {
  mcp_oauth.Metadata(
    resource: metadata.resource,
    issuer: metadata.issuer,
    authorization_endpoint: metadata.authorization_endpoint,
    token_endpoint: metadata.token_endpoint,
    registration_endpoint: metadata.registration_endpoint,
    scopes: metadata.scopes,
  )
}

/// Converts MCP OAuth metadata to the client-owned representation.
fn from_mcp_metadata(metadata: mcp_oauth.Metadata) -> Metadata {
  Metadata(
    resource: metadata.resource,
    issuer: metadata.issuer,
    authorization_endpoint: metadata.authorization_endpoint,
    token_endpoint: metadata.token_endpoint,
    registration_endpoint: metadata.registration_endpoint,
    scopes: metadata.scopes,
  )
}

/// Converts callback verification state to the MCP OAuth representation.
fn to_mcp_attempt(attempt: Attempt) -> mcp_oauth.Attempt {
  mcp_oauth.Attempt(
    verifier: attempt.verifier,
    state: attempt.state,
    client_id: attempt.client_id,
  )
}

/// Converts a verified MCP callback into the client-owned callback.
fn from_mcp_callback(cb: mcp_oauth.Callback) -> Callback {
  Callback(code: cb.code)
}
