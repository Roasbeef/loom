//// Browser PKCE and rotating public-client credentials.
////
//// A login owns one loopback listener and one fresh nonce/state/verifier.
//// The displayed start URL contains no retained ID token; only the browser
//// redirect to the fixed issuer carries id_token_hint. A callback-supplied
//// registration is bound only by a verified exchange; the profile owner saves
//// it with the grant, so an unverified callback never persists a client ID.
//// Token responses establish identity through oidc, and granted scopes alone
//// decide whether the saved identity may invoke the public Responses API.

import client/codex/credentials.{type Binding, type Grant, Grant}
import client/codex/network
import client/codex/oidc
import client/daemon/listener
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

/// Injected boundary facts for deterministic credential lifecycle tests.
pub type Services {
  Services(
    /// Performs fixed-origin, redirect-refusing, bounded HTTP.
    fetch: fn(http.HttpRequest, Int) -> Result(network.Response, String),
    /// Verifies signature and claims before returning a subject.
    verify: fn(String, String, oidc.Verification, Int) -> Result(String, String),
    /// Supplies the current wall-clock milliseconds.
    now: fn() -> Int,
    /// Supplies cryptographic random bytes for host and attempt identity.
    entropy: fn(Int) -> BitArray,
  )
}

/// The transaction values retained only by the pending browser attempt.
pub type Attempt {
  Attempt(
    /// Secret PKCE verifier, never placed in an authorization URL.
    verifier: String,
    /// One-use state checked before either code or error is accepted.
    state: String,
    /// Nonce validated against the signed ID token.
    nonce: String,
    /// Issued registration selected for returning login, or a new registration.
    client_id: Option(String),
  )
}

/// A state-checked callback ready for the token exchange.
pub type Callback {
  Callback(
    /// The one-use authorization code.
    code: String,
    /// The issued client identifier rather than dynamic_agent_client.
    client_id: String,
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
    id_token: Option(String),
    token_type: String,
    expires_in: Int,
    scopes: String,
  )
}

/// Keeps every native owner in the enclosing transport operation's ledger.
///
/// ## Examples
///
/// ```gleam
/// // oauth.services_on(ledger)
/// ```
pub fn services_on(ledger: weft.Ledger) -> Services {
  let fetch = fn(request, limit) { network.fetch(ledger, request, limit) }
  Services(
    fetch,
    fn(token, client, verification, now) {
      oidc.verify(fetch, token, client, verification, now)
    },
    bootstrap.system_time_ms,
    crypto.strong_random_bytes,
  )
}

/// Mints a stable UUID URI from cryptographic entropy.
///
/// ## Examples
///
/// ```gleam
/// // oauth.host_id(crypto.strong_random_bytes)
/// ```
pub fn host_id(entropy: fn(Int) -> BitArray) -> String {
  let hex = bit_array.base16_encode(entropy(16)) |> string.lowercase
  "urn:uuid:"
  <> string.slice(hex, 0, 8)
  <> "-"
  <> string.slice(hex, 8, 4)
  <> "-4"
  <> string.slice(hex, 13, 3)
  <> "-8"
  <> string.slice(hex, 17, 3)
  <> "-"
  <> string.slice(hex, 20, 12)
}

/// The literal loopback URL an operator opens to begin the attempt on `port`.
///
/// The route redirects to the issuer, so this address never carries the
/// returning identity hint.
///
/// ## Examples
///
/// ```gleam
/// oauth.start_url(1455) == "http://127.0.0.1:1455/auth/start"
/// ```
pub fn start_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/auth/start"
}

/// Constructs the exact issuer URL from a pending transaction, a registration,
/// and the loopback callback URI the listener bound.
///
/// ## Examples
///
/// ```gleam
/// // oauth.authorization_url(binding, attempt, "http://127.0.0.1:1455/auth/callback")
/// ```
@internal
pub fn authorization_url(
  binding: Binding,
  attempt: Attempt,
  redirect_uri: String,
) -> String {
  let registration = case attempt.client_id {
    None -> [
      #("client_id", "dynamic_agent_client"),
      #("agent_name_hint", "Loom"),
    ]
    Some(client_id) -> [#("client_id", client_id)]
  }
  let hint = case binding.grant {
    None -> []
    Some(grant) -> [#("id_token_hint", grant.id_token)]
  }
  let challenge =
    crypto.hash(crypto.Sha256, bit_array.from_string(attempt.verifier))
    |> base64url
  let params =
    list.append(
      registration,
      list.append(hint, [
        #("ext_agent_host_id", binding.host_id),
        #("response_type", "code"),
        #("redirect_uri", redirect_uri),
        #("resource", "https://api.openai.com/v1"),
        #(
          "scope",
          "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
        ),
        #("state", attempt.state),
        #("nonce", attempt.nonce),
        #("code_challenge", challenge),
        #("code_challenge_method", "S256"),
      ]),
    )
  "https://auth.openai.com/api/accounts/authorize?"
  <> uri.query_to_string(params)
}

fn base64url(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, False)
  |> string.replace("+", "-")
  |> string.replace("/", "_")
  |> string.replace("=", "")
}

/// Validates a callback's state before interpreting an OAuth error or code.
///
/// ## Examples
///
/// ```gleam
/// // oauth.callback(attempt, "state=...&code=...&client_id=oaiapp_...")
/// ```
@internal
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
  use client_id <- result.try(
    case
      attempt.client_id,
      list.filter(fields, fn(field) { field.0 == "client_id" })
    {
      None, [#(_, issued)] -> valid_client(issued)
      Some(selected), [] -> Ok(selected)
      Some(selected), [#(_, supplied)] ->
        case selected == supplied {
          True -> Ok(selected)
          False -> Error("registration_mismatch")
        }
      None, [] | None, [_, _, ..] | Some(_), [_, _, ..] ->
        Error("invalid_callback")
    },
  )
  Ok(Callback(code, client_id))
}

fn unique(
  fields: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  case list.filter(fields, fn(field) { field.0 == name }) {
    [#(_, value)] ->
      case value {
        "" -> Error("invalid_callback")
        _ -> Ok(value)
      }
    [] | [_, _, ..] -> Error("invalid_callback")
  }
}

fn valid_client(value: String) -> Result(String, String) {
  case
    value != "dynamic_agent_client"
    && value != ""
    && string.byte_size(value) <= 256
  {
    True -> Ok(value)
    False -> Error("invalid_callback")
  }
}

/// Runs browser login with an adopted listener and returns the bound binding.
/// `notify` receives the listener's bound port once it accepts connections.
///
/// The callback's client ID is trusted only after the token exchange and
/// identity verification succeed, so this function persists nothing. The caller
/// saves the returned binding, which is the single place a registration is
/// stored.
///
/// ## Examples
///
/// ```gleam
/// // oauth.login(binding, services, notify, ledger)
/// ```
pub fn login(
  binding: Binding,
  services: Services,
  notify: fn(Int) -> Nil,
  ledger: weft.Ledger,
) -> Result(Binding, String) {
  let messages = process.new_subject()
  let attempt =
    Attempt(
      base64url(services.entropy(32)),
      base64url(services.entropy(32)),
      base64url(services.entropy(32)),
      binding.client_id,
    )

  // The request handler exists before the listener binds, so it holds only
  // what the attempt fixes in advance. The callback address is known after
  // the bind and travels separately.
  let builder =
    mist.new(fn(request) { handle_browser(request, messages, attempt) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
  use owner <- result.try(
    listener.prepare(process.self(), builder)
    |> result.replace_error("callback_unavailable"),
  )

  // The listener joins the operation's ledger before it accepts a connection,
  // so cancellation or worker loss still closes the socket.
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
  notify(bound.port)

  // The listener closes when the browser attempt ends, before the one-use code
  // is redeemed, so no later request can reach the callback route.
  let answer =
    await_browser(
      messages,
      authorization_url(binding, attempt, redirect_uri),
      authority,
      bootstrap.monotonic_time_ms() + 600_000,
    )
  listener.close(owner)
  use received <- result.try(answer)
  exchange(binding, attempt, redirect_uri, received, services)
}

fn handle_browser(
  request: request.Request(mist.Connection),
  messages: Subject(BrowserMessage),
  attempt: Attempt,
) -> response.Response(mist.ResponseData) {
  let authority = process.new_subject()
  process.send(messages, CheckAuthority(request.headers, authority))
  case process.receive(authority, 1000) {
    Ok(Ok(Nil)) -> handle_verified_browser(request, messages, attempt)
    Ok(Error(Nil)) -> page(400, "This sign-in host could not be verified.")
    Error(Nil) -> page(410, "This sign-in attempt has ended.")
  }
}

// The attempt owner validates the exact bound authority before the listener
// exposes the private issuer redirect or consumes a callback.
fn handle_verified_browser(
  request: request.Request(mist.Connection),
  messages: Subject(BrowserMessage),
  attempt: Attempt,
) -> response.Response(mist.ResponseData) {
  case request.method, request.path {
    gleam_http.Get, "/auth/start" -> {
      let reply = process.new_subject()
      process.send(messages, Start(reply))
      case process.receive(reply, 1000) {
        Ok(url) ->
          response.new(302)
          |> response.set_header("location", url)
          |> response.set_header("cache-control", "no-store")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("Continue to OpenAI.")),
          )
        Error(Nil) -> page(410, "This sign-in attempt has ended.")
      }
    }
    gleam_http.Get, "/auth/callback" -> {
      let result = callback(attempt, option.unwrap(request.query, ""))
      case result {
        Ok(_) | Error("authorization_denied") -> {
          process.send(messages, Returned(result))
          page(
            200,
            "Sign-in received. Return to Loom to see the verified result.",
          )
        }
        Error(_) -> page(400, "This sign-in callback could not be verified.")
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
  authorization_url: String,
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
      await_browser(messages, authorization_url, authority, deadline)
    }
    Start(reply) -> {
      process.send(reply, authorization_url)
      await_browser(messages, authorization_url, authority, deadline)
    }
    Returned(result) -> result
  }
}

fn exchange(
  binding: Binding,
  attempt: Attempt,
  redirect_uri: String,
  callback: Callback,
  services: Services,
) -> Result(Binding, String) {
  use token <- result.try(token_request(
    [
      #("grant_type", "authorization_code"),
      #("client_id", callback.client_id),
      #("code", callback.code),
      #("code_verifier", attempt.verifier),
      #("redirect_uri", redirect_uri),
      #("resource", "https://api.openai.com/v1"),
    ],
    services,
  ))
  use id_token <- result.try(option.to_result(
    token.id_token,
    "invalid_identity",
  ))
  use subject <- result.try(services.verify(
    id_token,
    callback.client_id,
    oidc.Browser(attempt.nonce),
    services.now(),
  ))
  credentials.accept(
    binding,
    callback.client_id,
    subject,
    grant(token, id_token, services.now()),
  )
}

/// Refreshes only this issued registration and verifies any refreshed identity.
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
  use #(client_id, subject, previous) <- result.try(
    case binding.client_id, binding.subject, binding.grant {
      Some(client_id), Some(subject), Some(grant) ->
        Ok(#(client_id, subject, grant))
      _, _, _ -> Error("not_logged_in")
    },
  )
  use refresh <- result.try(option.to_result(
    previous.refresh,
    "reauthorization_required",
  ))
  use token <- result.try(token_request(
    [
      #("grant_type", "refresh_token"),
      #("client_id", client_id),
      #("refresh_token", refresh),
      #("resource", "https://api.openai.com/v1"),
    ],
    services,
  ))
  use id_token <- result.try(case token.id_token {
    None -> Ok(previous.id_token)
    Some(value) -> {
      use _ <- result.try(services.verify(
        value,
        client_id,
        oidc.Refresh(subject),
        services.now(),
      ))
      Ok(value)
    }
  })
  credentials.accept(
    binding,
    client_id,
    subject,
    grant(token, id_token, services.now()),
  )
}

fn token_request(
  fields: List(#(String, String)),
  services: Services,
) -> Result(Token, String) {
  use response <- result.try(services.fetch(
    form_request("https://auth.openai.com/api/accounts/oauth/token", fields),
    65_536,
  ))
  use Nil <- result.try(case response.status {
    200 -> Ok(Nil)
    _ -> Error(token_error(response.body))
  })
  use token <- result.try(
    json.parse(response.body, token_decoder())
    |> result.replace_error("invalid_token_response"),
  )
  use <- bool.guard(
    when: token.access == ""
      || token.refresh == Some("")
      || token.token_type != "Bearer"
      || token.expires_in <= 0
      || token.expires_in > 86_400,
    return: Error("invalid_token_response"),
  )
  Ok(token)
}

fn token_error(body: String) -> String {
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
  case json.parse(body, decoder) {
    Ok("invalid_grant")
    | Ok("invalid_refresh_token")
    | Ok("token_expired")
    | Ok("refresh_token_expired")
    | Ok("refresh_token_invalidated")
    | Ok("refresh_token_reused") -> "reauthorization_required"
    Ok("invalid_client") -> "invalid_client"
    Ok(_) | Error(_) -> "token_endpoint_unavailable"
  }
}

fn token_decoder() -> decode.Decoder(Token) {
  use access <- decode.field("access_token", decode.string)
  use refresh <- decode.optional_field(
    "refresh_token",
    None,
    decode.optional(decode.string),
  )
  use id_token <- decode.optional_field(
    "id_token",
    None,
    decode.optional(decode.string),
  )
  use token_type <- decode.field("token_type", decode.string)
  use expires_in <- decode.field("expires_in", decode.int)
  use scopes <- decode.field("scope", decode.string)
  decode.success(Token(
    access:,
    refresh:,
    id_token:,
    token_type:,
    expires_in:,
    scopes:,
  ))
}

fn grant(token: Token, id_token: String, now: Int) -> Grant {
  Grant(
    token.access,
    token.refresh,
    id_token,
    string.split(token.scopes, " ") |> list.filter(fn(scope) { scope != "" }),
    now + token.expires_in * 1000,
  )
}

/// Attempts renewable-session revocation without exposing response diagnostics.
///
/// ## Examples
///
/// ```gleam
/// // oauth.revoke(binding, services)
/// ```
pub fn revoke(binding: Binding, services: Services) -> Result(Nil, String) {
  let refresh = option.then(binding.grant, fn(grant) { grant.refresh })
  case binding.client_id, refresh {
    Some(client_id), Some(refresh) -> {
      use response <- result.try(services.fetch(
        form_request("https://auth.openai.com/api/accounts/oauth/revoke", [
          #("client_id", client_id),
          #("token", refresh),
          #("token_type_hint", "refresh_token"),
        ]),
        4096,
      ))
      case response.status {
        200 -> Ok(Nil)
        _ -> Error("revocation_unconfirmed")
      }
    }
    None, Some(_) | Some(_), None | None, None -> Ok(Nil)
  }
}

fn form_request(
  url: String,
  fields: List(#(String, String)),
) -> http.HttpRequest {
  http.HttpRequest(
    "POST",
    url,
    [
      #("content-type", "application/x-www-form-urlencoded"),
      #("accept", "application/json"),
    ],
    uri.query_to_string(fields),
  )
}
