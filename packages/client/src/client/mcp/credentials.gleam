//// Private, versioned OAuth 2.1 registration and grant records for remote
//// MCP servers.
////
//// Each `[mcp.<name>]` server configured with `auth = "oauth"` owns one
//// record at `<config_home>/loom/mcp-oauth/<name>.json`, guarded by the
//// kernel launch lock `<name>.lock`. A registration (`server`, `resource`,
//// `issuer`, `token_endpoint`, `client_id`) outlives its `grant`: logging out
//// clears the access and refresh tokens while preserving an issued dynamic
//// client registration for the next login against the same `resource` and
//// `issuer`. Every disk read is bounded, checked for private `0600`
//// ownership, and decoded totally before any token reaches HTTP.

import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap
import weft/poll

/// The tokens issued by an authorization server for one MCP server binding.
pub type Grant {
  Grant(
    /// The opaque bearer token sent only in outbound MCP `Authorization` headers.
    access: String,
    /// Optional refresh token used to rotate `access` when it expires.
    refresh: Option(String),
    /// Granted scopes returned by the token endpoint.
    scopes: List(String),
    /// Absolute access-token expiry in Unix milliseconds.
    expires: Int,
  )
}

/// The saved OAuth binding and optional active grant for one `[mcp.<name>]` server.
pub type Binding {
  Binding(
    /// The `[mcp.<name>]` catalogue key.
    server: String,
    /// The exact configured MCP server URL (`resource` indicator, RFC 8707).
    resource: String,
    /// The authorization server's canonical issuer URL.
    issuer: String,
    /// The authorization server's token endpoint URL.
    token_endpoint: String,
    /// The pre-registered or dynamically registered OAuth `client_id`.
    client_id: String,
    /// The active token grant, or `None` after logout or expiry without refresh.
    grant: Option(Grant),
  )
}

/// Resolves the private directory holding MCP OAuth credential files.
///
/// ## Examples
///
/// ```gleam
/// // credentials.directory()
/// ```
pub fn directory() -> Result(String, String) {
  // Resolve base configuration directory from XDG_CONFIG_HOME or fallback to HOME/.config.
  let root = case bootstrap.getenv("XDG_CONFIG_HOME") {
    Ok(value) if value != "" -> Ok(value)
    Ok(_) | Error(Nil) ->
      bootstrap.getenv("HOME")
      |> result.map(fn(home) { home <> "/.config" })
      |> result.replace_error("credential_unavailable")
  }

  result.map(root, fn(path) { path <> "/loom/mcp-oauth" })
}

/// Validates an MCP server name before using it as a lock or credential filename.
///
/// ## Examples
///
/// ```gleam
/// assert credentials.valid_server("linear_1") == Ok(Nil)
/// ```
pub fn valid_server(server: String) -> Result(Nil, String) {
  let lower = "abcdefghijklmnopqrstuvwxyz"
  let allowed = lower <> "0123456789_"

  // Verify server identifier characters and length bounds.
  let valid = case string.to_graphemes(server) {
    [first, ..rest] ->
      server != "internal"
      && string.contains(lower, first)
      && string.byte_size(server) <= 32
      && !string.ends_with(server, "_")
      && !string.contains(server, "__")
      && list.all(rest, fn(char) { string.contains(allowed, char) })
    [] -> False
  }

  // Reject invalid server identifiers.
  case valid {
    True -> Ok(Nil)
    False -> Error("invalid_server_name")
  }
}

/// Decodes a versioned MCP OAuth credential record from JSON text.
///
/// ## Examples
///
/// ```gleam
/// assert credentials.decode_record("{}") == Error("credential_unavailable")
/// ```
pub fn decode_record(document: String) -> Result(Binding, String) {
  use record <- result.try(
    json.parse(document, record_decoder())
    |> result.replace_error("credential_unavailable"),
  )
  use Nil <- result.try(validate(record))
  Ok(record)
}

/// Decodes a versioned credential binding record from json.
/// Builds the total decoder for the persisted binding fields and supported version.
fn record_decoder() -> decode.Decoder(Binding) {
  use version <- decode.field("version", decode.int)
  use server <- decode.field("server", decode.string)
  use resource <- decode.field("resource", decode.string)
  use issuer <- decode.field("issuer", decode.string)
  use token_endpoint <- decode.field("token_endpoint", decode.string)
  use client_id <- decode.field("client_id", decode.string)
  use grant <- decode.field("grant", decode.optional(grant_decoder()))

  // Ensure format version is supported.
  case version {
    1 ->
      decode.success(Binding(
        server:,
        resource:,
        issuer:,
        token_endpoint:,
        client_id:,
        grant:,
      ))
    _other ->
      decode.failure(
        Binding(
          server:,
          resource:,
          issuer:,
          token_endpoint:,
          client_id:,
          grant:,
        ),
        "MCP OAuth credential version 1",
      )
  }
}

/// Decodes an OAuth grant record containing tokens and expiration.
/// Requires all token grant fields before a grant can enter a credential binding.
fn grant_decoder() -> decode.Decoder(Grant) {
  use access <- decode.field("access_token", decode.string)
  use refresh <- decode.field("refresh_token", decode.optional(decode.string))
  use scopes <- decode.field("scopes", decode.list(decode.string))
  use expires <- decode.field("expires_ms", decode.int)
  decode.success(Grant(access:, refresh:, scopes:, expires:))
}

/// Encodes a validated MCP OAuth credential record for atomic replacement.
///
/// ## Examples
///
/// ```gleam
/// // credentials.encode_record(binding)
/// ```
pub fn encode_record(record: Binding) -> String {
  json.object([
    #("version", json.int(1)),
    #("server", json.string(record.server)),
    #("resource", json.string(record.resource)),
    #("issuer", json.string(record.issuer)),
    #("token_endpoint", json.string(record.token_endpoint)),
    #("client_id", json.string(record.client_id)),
    #("grant", json.nullable(record.grant, encode_grant)),
  ])
  |> json.to_string
}

/// Serializes an OAuth token grant to JSON value.
/// Encodes token and expiry fields using the versioned on-disk schema.
fn encode_grant(grant: Grant) -> json.Json {
  json.object([
    #("access_token", json.string(grant.access)),
    #("refresh_token", json.nullable(grant.refresh, json.string)),
    #("scopes", json.array(grant.scopes, json.string)),
    #("expires_ms", json.int(grant.expires)),
  ])
}

/// Reads a private MCP OAuth record, returning `Ok(None)` when absent.
///
/// ## Examples
///
/// ```gleam
/// // credentials.load("/private/mcp-oauth/linear.json")
/// ```
pub fn load(path: String) -> Result(Option(Binding), String) {
  // Check if credential file exists on disk.
  case bootstrap.path_exists(path) {
    False -> Ok(None)
    True -> {
      use bytes <- result.try(
        bootstrap.read_private_bounded(path, 65_536)
        |> result.replace_error("credential_unavailable"),
      )
      use text <- result.try(
        bit_array.to_string(bytes)
        |> result.replace_error("credential_unavailable"),
      )
      decode_record(text) |> result.map(Some)
    }
  }
}

/// Validates and atomically writes a private MCP OAuth record (`0600`).
///
/// ## Examples
///
/// ```gleam
/// // credentials.save(path, binding)
/// ```
pub fn save(path: String, record: Binding) -> Result(Nil, String) {
  use Nil <- result.try(validate(record))
  bootstrap.atomic_write_private(path, encode_record(record))
  |> result.replace_error("credential_unavailable")
}

/// Runs `operation` under the per-server kernel file lock `<server>.lock`.
///
/// ## Examples
///
/// ```gleam
/// // credentials.with_lock(dir, "linear", fn(path) { credentials.load(path) })
/// ```
pub fn with_lock(
  directory: String,
  server: String,
  operation: fn(String) -> Result(value, String),
) -> Result(value, String) {
  use Nil <- result.try(valid_server(server))
  use Nil <- result.try(
    bootstrap.ensure_private_directory(directory)
    |> result.replace_error("credential_unavailable"),
  )
  let lock_path = directory <> "/" <> server <> ".lock"
  use lock <- result.try(acquire(lock_path))
  let answer = operation(directory <> "/" <> server <> ".json")
  bootstrap.release_launch_lock(lock)
  answer
}

/// Acquires an exclusive filesystem launch lock with polling retry.
/// Retries a busy launch lock until acquisition or the bounded wait expires.
fn acquire(path: String) -> Result(bootstrap.LaunchLock, String) {
  case
    poll.until(within: 5000, every: 50, attempt: fn() {
      case bootstrap.try_launch_lock(path) {
        Ok(lock) -> poll.Done(lock)
        Error("busy") -> poll.Retry
        Error(_) -> poll.Fail("credential_unavailable")
      }
    })
  {
    poll.Answered(lock) -> Ok(lock)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("server_auth_busy")
  }
}

/// Validates field invariants and URL structures of a credential binding.
/// Enforces server, HTTPS endpoint, client identifier, and optional grant invariants.
fn validate(record: Binding) -> Result(Nil, String) {
  use Nil <- result.try(valid_server(record.server))
  let ok =
    valid_oauth_url(record.resource)
    && valid_oauth_url(record.issuer)
    && valid_oauth_url(record.token_endpoint)
    && is_label(record.client_id, 256)
    && valid_grant(record.grant)
  use <- bool.guard(when: !ok, return: Error("credential_unavailable"))
  Ok(Nil)
}

/// Checks if an optional token grant adheres to credential character rules.
/// Rejects unsafe token characters, oversized scopes, and nonpositive expiries.
fn valid_grant(grant: Option(Grant)) -> Bool {
  case grant {
    None -> True
    Some(grant) ->
      is_secret(grant.access)
      && case grant.refresh {
        None -> True
        Some(refresh) -> is_secret(refresh)
      }
      && grant.expires > 0
      && list.drop(grant.scopes, 32) == []
      && list.all(grant.scopes, fn(scope) { is_label(scope, 128) })
  }
}

/// Checks whether a URL is a valid HTTPS (or loopback HTTP) OAuth endpoint
/// without userinfo or fragment.
///
/// ## Examples
///
/// ```gleam
/// assert credentials.valid_oauth_url("https://auth.example.com/token")
/// ```
pub fn valid_oauth_url(raw: String) -> Bool {
  case is_label(raw, 2048), uri.parse(raw) {
    True, Ok(parsed) ->
      case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
        Some("https"), Some(host), None, None if host != "" ->
          valid_port(parsed.port)
        Some("http"), Some(host), None, None ->
          is_loopback(host) && valid_port(parsed.port)
        _, _, _, _ -> False
      }
    _, _ -> False
  }
}

fn valid_port(port: Option(Int)) -> Bool {
  case port {
    None -> True
    Some(port) -> port > 0 && port <= 65_535
  }
}

fn is_loopback(host: String) -> Bool {
  case string.lowercase(host) {
    "127.0.0.1" | "localhost" | "::1" | "[::1]" -> True
    _other -> False
  }
}

fn is_label(value: String, limit: Int) -> Bool {
  value != ""
  && string.byte_size(value) <= limit
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

/// Verifies that a secret token string contains only allowed base64/URL characters.
/// Restricts token bytes to the accepted bearer-token alphabet and size bound.
fn is_secret(value: String) -> Bool {
  let permitted =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="
  is_label(value, 16_384)
  && list.all(string.to_graphemes(value), fn(char) {
    string.byte_size(char) == 1 && string.contains(permitted, char)
  })
}
