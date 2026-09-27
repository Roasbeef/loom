//// The shape of a claim token and of the addresses a claim travels to,
//// shared by the daemon that issues claims, the `loomd access` command that
//// prints them, and the `loom claim` command that redeems them
//// (protocol-change/053).
////
//// A claim token is `loomclaim_` followed by 64 lowercase hexadecimal
//// characters. The prefix is what lets each side refuse a claim where a
//// bearer belongs and a bearer where a claim belongs, and what lets a secret
//// scanner recognize one. The daemon stores only the SHA-256 digest of the
//// whole string, and a claim authenticates nothing: it is redeemed once, on
//// `/v2/claim`, for a credential the invitee's own client drew.
////
//// Remote addresses follow one rule for bearers and claims alike: `wss` to
//// any host, and cleartext `ws` only to a literal loopback address, so a
//// secret never crosses an unencrypted network hop.

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// The prefix every claim token carries.
pub const prefix = "loomclaim_"

/// Whether a value is claim-shaped, meaning it begins with the claim prefix.
///
/// A bearer is 64 hexadecimal characters with no prefix, so a claim-shaped
/// value offered as a bearer is refused before any connection: presenting
/// it would fail anyway, and refusing it names the mistake.
///
/// ## Examples
///
/// ```gleam
/// assert claim.is_claim_shaped("loomclaim_00")
/// assert !claim.is_claim_shaped(string.repeat("a", 64))
/// ```
pub fn is_claim_shaped(value: String) -> Bool {
  string.starts_with(value, prefix)
}

/// Whether a value is 64 lowercase hexadecimal characters: the shape of a
/// bearer credential, and of a SHA-256 digest.
///
/// ## Examples
///
/// ```gleam
/// assert claim.is_hex_256(string.repeat("a", 64))
/// assert !claim.is_hex_256("loomclaim_00")
/// ```
pub fn is_hex_256(value: String) -> Bool {
  string.byte_size(value) == 64 && lowercase_hex(value)
}

/// Accepts exactly `loomclaim_` and 64 lowercase hexadecimal characters.
///
/// ## Examples
///
/// ```gleam
/// assert claim.validate_token("loomclaim_" <> string.repeat("0", 64)) == Ok(Nil)
/// ```
pub fn validate_token(value: String) -> Result(Nil, String) {
  case string.split_once(value, prefix) {
    Ok(#("", hex)) ->
      case is_hex_256(hex) {
        True -> Ok(Nil)
        False ->
          Error("a claim token is loomclaim_ and 64 lowercase hex characters")
      }
    Ok(_) | Error(Nil) ->
      Error("a claim token is loomclaim_ and 64 lowercase hex characters")
  }
}

/// Draws a fresh token: the prefix and 32 bytes from the operating system's
/// cryptographic source (`crypto:strong_rand_bytes`), hex-encoded.
///
/// ## Examples
///
/// ```gleam
/// assert claim.validate_token(claim.mint_token(crypto.strong_random_bytes)) == Ok(Nil)
/// ```
pub fn mint_token(entropy: fn(Int) -> BitArray) -> String {
  prefix <> hex(entropy(32))
}

/// Draws a fresh 64-character credential from `crypto:strong_rand_bytes`.
/// `loom claim` and `loom enroll` store this and send only its digest.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(claim.random_credential()) == 64
/// ```
pub fn random_credential() -> String {
  hex(crypto.strong_random_bytes(32))
}

/// The lowercase hexadecimal SHA-256 digest of a text value, the form in which
/// the daemon stores claims and credentials.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(claim.digest("loomclaim_00")) == 64
/// ```
pub fn digest(value: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(value)) |> hex
}

/// Accepts a control address only when its credentials stay off the network:
/// an unqualified `/v2/control` endpoint over `wss` to any host, or over `ws`
/// only to a literal loopback address.
///
/// ## Examples
///
/// ```gleam
/// assert claim.remote_address("ws://[::1]:8080/v2/control") == Ok(Nil)
/// assert claim.remote_address("ws://example.com/v2/control") != Ok(Nil)
/// ```
pub fn remote_address(address: String) -> Result(Nil, String) {
  use endpoint <- result.try(
    uri.parse(address) |> result.replace_error("invalid control address"),
  )
  use Nil <- result.try(case endpoint {
    uri.Uri(
      path: "/v2/control",
      userinfo: None,
      query: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error("expected an unqualified /v2/control endpoint")
  })

  // `uri.parse` keeps an IPv6 literal's brackets in `host`, so the bracketed
  // form is the one a parsed `ws://[::1]:PORT/v2/control` actually presents.
  // The bare form is matched as well because a caller may hand this function
  // a host it assembled itself rather than one it parsed back out of a URI.
  case endpoint.scheme, endpoint.host {
    Some("wss"), Some(host) if host != "" -> Ok(Nil)
    Some("ws"), Some("127.0.0.1")
    | Some("ws"), Some("[::1]")
    | Some("ws"), Some("::1")
    -> Ok(Nil)
    _, _ -> Error("remote control requires TLS")
  }
}

/// The claim endpoint for a control address: the same scheme, host and port,
/// with `/v2/control` replaced by `/v2/claim`. The address must already pass
/// `remote_address`.
///
/// ## Examples
///
/// ```gleam
/// assert claim.endpoint("wss://loom.example.com/v2/control")
///   == Ok("wss://loom.example.com/v2/claim")
/// ```
pub fn endpoint(address: String) -> Result(String, String) {
  use Nil <- result.try(remote_address(address))
  case string.ends_with(address, "/v2/control") {
    True -> Ok(string.drop_end(address, string.length("control")) <> "claim")
    False -> Error("expected an unqualified /v2/control endpoint")
  }
}

fn hex(bytes: BitArray) -> String {
  bytes |> bit_array.base16_encode |> string.lowercase
}

fn lowercase_hex(value: String) -> Bool {
  list.all(string.to_graphemes(value), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}
