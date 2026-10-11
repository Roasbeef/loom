//// OpenAI identity verification over maintained JOSE primitives.
////
//// Untrusted ID tokens never establish profile identity. Gose pins RS256,
//// requires a matching published key ID, and verifies issuer, audience and
//// expiry before this module inspects subject and attempt nonce. The network
//// path loads keys from the fixed issuer, never a token-controlled URL.
////
//// A token that names a key the published set does not hold is refused as
//// `unknown_signing_key` rather than `invalid_identity`, and the network path
//// fetches the set once more before refusing. The issuer rotates and reshapes
//// its keys without notice, and on 2026-10-08 a change in how it published
//// them read here as a bad signature; the distinct code says which of the two
//// happened, and the second fetch absorbs a rotation that reached the token
//// before the copy of the set this request was served.

import client/codex/network
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gose
import gose/jose/jwt
import gose/jose/key_set
import provider/http

/// Whether identity verification belongs to a browser attempt or refresh.
pub type Verification {
  /// The browser result must carry the nonce minted for this attempt.
  Browser(nonce: String)

  /// A refreshed identity must remain the same verified subject.
  Refresh(subject: String)
}

type Identity {
  Identity(
    subject: String,
    nonce: Option(String),
    audience: List(String),
    authorized_party: Option(String),
  )
}

/// Uses the enclosing operation's published HTTP owner for key discovery.
///
/// ## Examples
///
/// ```gleam
/// // oidc.verify(fetch, token, client, verification, now)
/// ```
pub fn verify(
  fetch: fn(http.HttpRequest, Int) -> Result(network.Response, String),
  token: String,
  client_id: String,
  verification: Verification,
  now_ms: Int,
) -> Result(String, String) {
  let check = fn(jwks) {
    verify_with_keys(token, client_id, verification, now_ms, jwks)
  }
  use jwks <- result.try(published_keys(fetch))

  // A key the set did not hold earns exactly one more fetch, so a rotation
  // that reached the token first costs one request rather than a login, and
  // a key that never appears costs no more than that.
  case check(jwks) {
    Error(reason) if reason == unknown_signing_key ->
      published_keys(fetch) |> result.try(check)
    answer -> answer
  }
}

/// The refusal for a token whose key ID the published set does not hold.
const unknown_signing_key = "unknown_signing_key"

fn published_keys(
  fetch: fn(http.HttpRequest, Int) -> Result(network.Response, String),
) -> Result(String, String) {
  use response <- result.try(fetch(
    http.HttpRequest(
      "GET",
      "https://auth.openai.com/.well-known/jwks.json",
      [#("accept", "application/json")],
      "",
    ),
    65_536,
  ))
  use <- bool.guard(
    when: response.status != 200,
    return: Error("identity_unavailable"),
  )
  Ok(response.body)
}

/// Validates a signed token against an injected published key set.
///
/// ## Examples
///
/// ```gleam
/// // oidc.verify_with_keys(token, issued_id, oidc.Browser(nonce), now_ms, jwks)
/// ```
@internal
pub fn verify_with_keys(
  token: String,
  client_id: String,
  verification: Verification,
  now_ms: Int,
  jwks: String,
) -> Result(String, String) {
  use <- bool.guard(
    when: string.byte_size(token) > 16_384 || string.byte_size(jwks) > 65_536,
    return: Error("invalid_identity"),
  )
  use keys <- result.try(
    key_set.from_json(without_certificates(jwks))
    |> result.replace_error("invalid_identity"),
  )

  // Asked before the verifier, whose own refusal of a missing key ID is the
  // same `invalid_identity` a forged signature earns.
  use <- bool.guard(
    when: names_unpublished_key(token, keys),
    return: Error(unknown_signing_key),
  )
  let options =
    jwt.JwtValidationOptions(
      ..jwt.default_validation(),
      issuer: Some("https://auth.openai.com"),
      audience: Some(client_id),
      clock_skew: 0,
      kid_policy: jwt.RequireKidMatch,
    )
  use verifier <- result.try(
    jwt.verifier(
      gose.DigitalSignature(gose.RsaPkcs1(gose.RsaPkcs1Sha256)),
      keys: key_set.to_list(keys),
      options: options,
    )
    |> result.replace_error("invalid_identity"),
  )
  use verified <- result.try(
    jwt.verify_and_validate(
      verifier,
      token: token,
      now: timestamp.from_unix_seconds(now_ms / 1000),
    )
    |> result.replace_error("invalid_identity"),
  )
  use claims <- result.try(
    jwt.decode(verified, identity_decoder())
    |> result.replace_error("invalid_identity"),
  )
  use <- bool.guard(
    when: claims.subject == "" || string.byte_size(claims.subject) > 512,
    return: Error("invalid_identity"),
  )

  // Multiple audiences require the authorized party to identify this client.
  use <- bool.guard(
    when: list.drop(claims.audience, 1) != []
      && claims.authorized_party != Some(client_id),
    return: Error("invalid_identity"),
  )
  use Nil <- result.try(case verification {
    Browser(expected) ->
      case claims.nonce {
        Some(actual) ->
          case
            crypto.secure_compare(
              bit_array.from_string(actual),
              bit_array.from_string(expected),
            )
          {
            True -> Ok(Nil)
            False -> Error("invalid_identity")
          }
        None -> Error("invalid_identity")
      }
    Refresh(expected) ->
      case claims.subject == expected {
        True -> Ok(Nil)
        False -> Error("account_mismatch")
      }
  })
  Ok(claims.subject)
}

/// Drops the X.509 members from every key of a published key set.
///
/// Gose refuses any JWK that carries `x5u`, `x5c`, `x5t` or `x5t#S256`, and
/// `key_set.from_json` skips a refused key without saying so. The issuer began
/// publishing `x5c` on its signing keys on 2026-10-08, so every key a new token
/// names vanished from the set and verification failed as an unknown key ID.
/// The certificate chain adds nothing here: trust comes from the fixed issuer
/// URL and the key's own `n` and `e`, never from the chain. A body that is not
/// a key set is returned unchanged, so the caller's parse reports it.
///
/// ## Examples
///
/// ```gleam
/// // oidc.without_certificates("{\"keys\":[{\"kid\":\"a\",\"x5c\":[\"AA\"]}]}")
/// ```
@internal
pub fn without_certificates(jwks: String) -> String {
  // A member that is not a string is dropped; every member an RSA signing
  // key needs is a string, and the arrays are the certificate chain.
  let member =
    decode.one_of(decode.map(decode.string, Some), [decode.success(None)])
  let keys_decoder = {
    use keys <- decode.field(
      "keys",
      decode.list(decode.dict(decode.string, member)),
    )
    decode.success(keys)
  }

  case json.parse(jwks, keys_decoder) {
    Ok(keys) ->
      json.object([#("keys", json.array(keys, certificate_free_key))])
      |> json.to_string
    Error(_) -> jwks
  }
}

fn certificate_free_key(key: dict.Dict(String, Option(String))) -> json.Json {
  dict.to_list(key)
  |> list.filter_map(fn(entry) {
    case entry {
      #("x5u", _) | #("x5c", _) | #("x5t", _) | #("x5t#S256", _) -> Error(Nil)
      #(name, Some(value)) -> Ok(#(name, json.string(value)))
      #(_, None) -> Error(Nil)
    }
  })
  |> json.object
}

/// Whether the token names a key ID that the published set does not hold.
///
/// A token that will not parse, or names no key, is left to the verifier,
/// which refuses it as `invalid_identity`; only a readable key ID absent from
/// the set is the issuer's change rather than the token's fault.
fn names_unpublished_key(token: String, keys: key_set.JwkSet) -> Bool {
  let named =
    jwt.parse(token)
    |> result.replace_error(Nil)
    |> result.try(jwt.kid)

  case named {
    Ok(kid) ->
      !list.any(key_set.to_list(keys), fn(key) { gose.kid(key) == Ok(kid) })
    Error(Nil) -> False
  }
}

fn identity_decoder() -> decode.Decoder(Identity) {
  use subject <- decode.field("sub", decode.string)
  use nonce <- decode.optional_field(
    "nonce",
    None,
    decode.optional(decode.string),
  )
  use audience <- decode.field(
    "aud",
    decode.one_of(decode.list(decode.string), [
      decode.map(decode.string, fn(value) { [value] }),
    ]),
  )
  use authorized_party <- decode.optional_field(
    "azp",
    None,
    decode.optional(decode.string),
  )
  decode.success(Identity(subject:, nonce:, audience:, authorized_party:))
}
