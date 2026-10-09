//// Signed identity and registration regressions for the native SIWC boundary.
////
//// The verifier checks real RSA signatures rather than mocked JWT payloads.
//// Callback cases independently prove the selected issued client cannot drift.

import client/codex/credentials
import client/codex/oauth
import client/codex/oidc
import gleam/bit_array
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gose
import gose/jose/jwt
import gose/jose/key_set

pub fn codex_signed_identity_pins_key_issuer_audience_expiry_nonce_test() {
  let assert Ok(key) = gose.generate_rsa(2048)
    as "RSA fixture generation succeeds."
  let key = gose.with_kid(key, "fixture-key")
  let assert Ok(public) = gose.public_key(key)
    as "The public verification key exists."
  let jwks = key_set.from_list([public]) |> key_set.to_json |> json.to_string
  let assert Ok(claims) =
    jwt.claims()
    |> jwt.with_issuer("https://auth.openai.com")
    |> jwt.with_audience("oaiapp_loom")
    |> jwt.with_subject("account-one")
    |> jwt.with_expiration(timestamp.from_unix_seconds(2000))
    |> jwt.with_claim("nonce", json.string("attempt-nonce"))
    as "Nonce is a valid custom claim."
  let token = signed(claims, key)
  assert oidc.verify_with_keys(
      token,
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Ok("account-one")
  assert oidc.verify_with_keys(
      token,
      "oaiapp_other",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")
  assert oidc.verify_with_keys(
      token,
      "oaiapp_loom",
      oidc.Browser("other-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")
  assert oidc.verify_with_keys(
      token,
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      2_001_000,
      jwks,
    )
    == Error("invalid_identity")
  assert oidc.verify_with_keys(
      token,
      "oaiapp_loom",
      oidc.Refresh("account-two"),
      1_000_000,
      jwks,
    )
    == Error("account_mismatch")
  assert oidc.verify_with_keys(
      signed(jwt.with_issuer(claims, "https://evil.example"), key),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")
  assert oidc.verify_with_keys(
      signed(jwt.with_subject(claims, ""), key),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")
  let unknown_key = gose.with_kid(key, "unknown-key")
  assert oidc.verify_with_keys(
      signed(claims, unknown_key),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")

  // Expiry is mandatory even when the issuer, audience and signature agree.
  let assert Ok(no_expiry) =
    jwt.claims()
    |> jwt.with_issuer("https://auth.openai.com")
    |> jwt.with_audience("oaiapp_loom")
    |> jwt.with_subject("account-one")
    |> jwt.with_claim("nonce", json.string("attempt-nonce"))
    as "A missing-expiry fixture remains a syntactically valid JWT."
  assert oidc.verify_with_keys(
      signed(no_expiry, key),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")

  // Multiple audiences require the authorized party to identify this client.
  let assert Ok(many_audiences) =
    jwt.with_audiences(claims, ["oaiapp_loom", "oaiapp_other"])
    as "The multiple audience fixture is valid."
  assert oidc.verify_with_keys(
      signed(many_audiences, key),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")
  let assert Ok(bound_audiences) =
    jwt.with_claim(many_audiences, "azp", json.string("oaiapp_loom"))
    as "The authorized party identifies the issued client."
  assert oidc.verify_with_keys(
      signed(bound_audiences, key),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Ok("account-one")

  // A correctly shaped token signed with another RSA key fails the signature.
  let assert Ok(other) = gose.generate_rsa(2048)
    as "The attacker fixture has its own signing key."
  assert oidc.verify_with_keys(
      signed(claims, gose.with_kid(other, "fixture-key")),
      "oaiapp_loom",
      oidc.Browser("attempt-nonce"),
      1_000_000,
      jwks,
    )
    == Error("invalid_identity")
}

fn signed(claims: jwt.Claims, key: gose.Key(String)) -> String {
  let assert Ok(token) =
    jwt.sign(
      gose.DigitalSignature(gose.RsaPkcs1(gose.RsaPkcs1Sha256)),
      claims: claims,
      key: key,
    )
    as "The fixture claims can be signed."
  jwt.serialize(token)
}

pub fn codex_callback_checks_state_and_registration_before_code_test() {
  let fresh = oauth.Attempt("verifier", "state", "nonce", None)
  assert oauth.callback(fresh, "state=state&code=code&client_id=oaiapp_new")
    == Ok(oauth.Callback("code", "oaiapp_new"))
  assert oauth.callback(fresh, "state=wrong&code=code&client_id=oaiapp_new")
    == Error("invalid_callback")
  assert oauth.callback(fresh, "state=state&code=code")
    == Error("invalid_callback")
  assert oauth.callback(
      fresh,
      "state=state&code=code&client_id=dynamic_agent_client",
    )
    == Error("invalid_callback")
  assert oauth.callback(
      fresh,
      "state=state&state=state&code=code&client_id=oaiapp_new",
    )
    == Error("invalid_callback")
  assert oauth.callback(fresh, "state=wrong&error=access_denied")
    == Error("invalid_callback")
  assert oauth.callback(fresh, "state=state&error=access_denied")
    == Error("authorization_denied")
  let returning = oauth.Attempt(..fresh, client_id: Some("oaiapp_saved"))
  assert oauth.callback(returning, "state=state&code=code")
    == Ok(oauth.Callback("code", "oaiapp_saved"))
  assert oauth.callback(
      returning,
      "state=state&code=code&client_id=oaiapp_other",
    )
    == Error("registration_mismatch")
}

pub fn codex_record_preserves_identity_only_and_logout_binding_test() {
  let binding =
    credentials.Binding(
      "urn:uuid:00000000-0000-4000-8000-000000000000",
      Some("oaiapp_saved"),
      Some("account-one"),
      None,
    )
  let identity =
    credentials.Grant(
      "access",
      None,
      "id-token",
      ["openid", "profile", "email"],
      10_000,
    )
  let assert Ok(saved) =
    credentials.accept(binding, "oaiapp_saved", "account-one", identity)
    as "Identity-only grants are durable sign-ins."
  assert !credentials.plan_enabled(identity)
  assert credentials.decode_record(credentials.encode_record(saved))
    == Ok(saved)
  assert credentials.accept(saved, "oaiapp_saved", "account-two", identity)
    == Error("account_mismatch")
  assert credentials.accept(saved, "oaiapp_other", "account-one", identity)
    == Error("registration_mismatch")
  let cleared = credentials.Binding(..saved, grant: None)
  assert credentials.decode_record(credentials.encode_record(cleared))
    == Ok(binding)
  assert credentials.decode_record(
      "{\"access\":\"legacy\",\"refresh\":\"legacy\"}",
    )
    == Error("credential_unavailable")
}

pub fn codex_authorize_pkce_and_returning_client_are_bound_test() {
  let host =
    oauth.host_id(fn(size) { bit_array.from_string(string.repeat("a", size)) })
  let binding = credentials.Binding(host, None, None, None)
  let attempt = oauth.Attempt("verifier", "state", "nonce", None)
  let redirect = "http://127.0.0.1:1234/auth/callback"
  let url = oauth.authorization_url(binding, attempt, redirect)
  assert string.contains(
    url,
    "redirect_uri=http%3A%2F%2F127.0.0.1%3A1234%2Fauth%2Fcallback",
  )
  assert string.contains(url, "client_id=dynamic_agent_client")
  assert string.contains(url, "agent_name_hint=Loom")
  assert string.contains(url, "code_challenge_method=S256")
  assert string.contains(url, "resource=https%3A%2F%2Fapi.openai.com%2Fv1")
  assert !string.contains(url, "code_verifier=")
  let returning =
    oauth.authorization_url(
      binding,
      oauth.Attempt(..attempt, client_id: Some("oaiapp_saved")),
      redirect,
    )
  assert string.contains(returning, "client_id=oaiapp_saved")
  assert !string.contains(returning, "agent_name_hint")
}
