//// Private, versioned registration and grant records.
////
//// A registration outlives its grant: logout clears tokens while retaining
//// the host URI, issued client ID and verified subject. Replacement cannot
//// silently bind that registration to another account. Every disk read is
//// bounded and decoded totally before any credential reaches HTTP.

import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap

/// A validated identity and the tokens issued for its registration.
pub type Grant {
  Grant(
    /// The opaque bearer used only in outgoing HTTP authorization.
    access: String,
    /// The rotating refresh credential, absent when offline access was not granted.
    refresh: Option(String),
    /// The original signed identity token, retained for returning sign-in.
    id_token: String,
    /// Granted scopes from the token endpoint, rather than callback hints.
    scopes: List(String),
    /// The access token's absolute expiry in Unix milliseconds.
    expires: Int,
  )
}

/// The registration retained when an operator signs out.
pub type Binding {
  Binding(
    /// Stable installation URI supplied as ext_agent_host_id.
    host_id: String,
    /// None until dynamic registration returns an issued client identifier.
    client_id: Option(String),
    /// The verified subject bound to this issued registration.
    subject: Option(String),
    /// The signed-in grant is absent before authorization or after logout.
    grant: Option(Grant),
  )
}

/// Validates the path selector without creating arbitrary atoms or subpaths.
///
/// ## Examples
///
/// ```gleam
/// credentials.valid_profile("work-1") == Ok(Nil)
/// ```
pub fn valid_profile(profile: String) -> Result(Nil, String) {
  let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  let valid = case string.to_graphemes(profile) {
    [first, ..rest] ->
      string.contains(letters, first)
      && string.byte_size(profile) <= 64
      && list.all(rest, fn(char) { string.contains(letters <> "_-", char) })
    [] -> False
  }
  case valid {
    True -> Ok(Nil)
    False -> Error("invalid_profile")
  }
}

/// Decodes only the native SIWC record version, refusing legacy Codex grants.
///
/// ## Examples
///
/// ```gleam
/// credentials.decode_record("{}") == Error("credential_unavailable")
/// ```
pub fn decode_record(document: String) -> Result(Binding, String) {
  use record <- result.try(
    json.parse(document, record_decoder())
    |> result.replace_error("credential_unavailable"),
  )
  use Nil <- result.try(validate(record))
  Ok(record)
}

fn record_decoder() -> decode.Decoder(Binding) {
  use version <- decode.field("version", decode.int)
  use host_id <- decode.field("ext_agent_host_id", decode.string)
  use client_id <- decode.field("client_id", decode.optional(decode.string))
  use subject <- decode.field("subject", decode.optional(decode.string))
  use grant <- decode.field("grant", decode.optional(grant_decoder()))
  case version {
    2 -> decode.success(Binding(host_id:, client_id:, subject:, grant:))
    _ ->
      decode.failure(
        Binding(host_id:, client_id:, subject:, grant:),
        "SIWC version 2",
      )
  }
}

fn grant_decoder() -> decode.Decoder(Grant) {
  use access <- decode.field("access_token", decode.string)
  use refresh <- decode.field("refresh_token", decode.optional(decode.string))
  use id_token <- decode.field("id_token", decode.string)
  use scopes <- decode.field("scopes", decode.list(decode.string))
  use expires <- decode.field("expires_ms", decode.int)
  decode.success(Grant(access:, refresh:, id_token:, scopes:, expires:))
}

/// Encodes the complete registration and optional grant for atomic replacement.
///
/// ## Examples
///
/// ```gleam
/// // credentials.encode_record(binding)
/// ```
pub fn encode_record(record: Binding) -> String {
  json.object([
    #("version", json.int(2)),
    #("ext_agent_host_id", json.string(record.host_id)),
    #("client_id", json.nullable(record.client_id, json.string)),
    #("subject", json.nullable(record.subject, json.string)),
    #("grant", json.nullable(record.grant, encode_grant)),
  ])
  |> json.to_string
}

fn encode_grant(grant: Grant) -> json.Json {
  json.object([
    #("access_token", json.string(grant.access)),
    #("refresh_token", json.nullable(grant.refresh, json.string)),
    #("id_token", json.string(grant.id_token)),
    #("scopes", json.array(grant.scopes, json.string)),
    #("expires_ms", json.int(grant.expires)),
  ])
}

fn validate(record: Binding) -> Result(Nil, String) {
  let host_ok =
    string.starts_with(record.host_id, "urn:uuid:")
    && string.byte_size(record.host_id) == 45
  let client_ok = case record.client_id {
    None -> record.subject == None && record.grant == None
    Some(client_id) ->
      is_label(client_id, 256) && client_id != "dynamic_agent_client"
  }
  let grant_ok = case record.grant, record.subject {
    None, None -> True
    None, Some(subject) -> is_label(subject, 512)
    Some(grant), Some(subject) ->
      is_label(subject, 512)
      && is_secret(grant.access)
      && case grant.refresh {
        Some(token) -> is_secret(token)
        None -> !list.contains(grant.scopes, "offline_access")
      }
      && is_secret(grant.id_token)
      && grant.expires > 0
      && list.drop(grant.scopes, 32) == []
      && list.all(grant.scopes, fn(scope) { is_label(scope, 128) })
    Some(_), None -> False
  }
  case host_ok && client_ok && grant_ok {
    True -> Ok(Nil)
    False -> Error("credential_unavailable")
  }
}

fn is_label(value: String, limit: Int) -> Bool {
  value != ""
  && string.byte_size(value) <= limit
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn is_secret(value: String) -> Bool {
  let permitted =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="
  is_label(value, 16_384)
  && list.all(string.to_graphemes(value), fn(char) {
    string.byte_size(char) == 1 && string.contains(permitted, char)
  })
}

/// Reads a protected record, distinguishing a fresh profile from corruption.
///
/// ## Examples
///
/// ```gleam
/// // credentials.load("/private/state/work.json")
/// ```
pub fn load(path: String) -> Result(Option(Binding), String) {
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

/// Writes one complete validated record with existing private-file durability.
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

/// Binds a verified login without replacing a different account's identity.
///
/// ## Examples
///
/// ```gleam
/// // credentials.accept(binding, issued_client, verified_subject, grant)
/// ```
pub fn accept(
  record: Binding,
  client_id: String,
  subject: String,
  grant: Grant,
) -> Result(Binding, String) {
  use <- bool.guard(
    when: record.client_id != None && record.client_id != Some(client_id),
    return: Error("registration_mismatch"),
  )
  use <- bool.guard(
    when: record.subject != None && record.subject != Some(subject),
    return: Error("account_mismatch"),
  )
  let next =
    Binding(
      ..record,
      client_id: Some(client_id),
      subject: Some(subject),
      grant: Some(grant),
    )
  use Nil <- result.try(validate(next))
  Ok(next)
}

/// Separates valid identity from permission to spend ChatGPT plan tokens.
///
/// ## Examples
///
/// ```gleam
/// // credentials.plan_enabled(grant)
/// ```
pub fn plan_enabled(grant: Grant) -> Bool {
  list.contains(grant.scopes, "chatgpt.tokens.use.direct")
  && list.contains(grant.scopes, "resource.invoke")
}
