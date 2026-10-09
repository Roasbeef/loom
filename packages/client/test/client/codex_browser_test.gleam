//// A real ephemeral loopback browser flow with an injected token endpoint.
////
//// The driver never contacts OpenAI: redirects remain disabled, and token
//// exchange is a typed fixture. Signature validation is tested separately
//// with real RSA keys; this test covers listener ownership and callback order.

import client/codex/credentials
import client/codex/network
import client/codex/oauth
import client/codex/profile
import client/codex/profile_control as control
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap
import weft

pub fn codex_browser_listener_pkce_callback_and_registration_test() {
  let instructions = process.new_subject()
  let initial =
    credentials.Binding(
      "urn:uuid:00000000-0000-4000-8000-000000000000",
      None,
      None,
      None,
    )
  let task =
    weft.managed(fn(ledger) {
      let effects =
        oauth.Services(
          fetch: fn(request, _) {
            assert request.url
              == "https://auth.openai.com/api/accounts/oauth/token"
            let assert Ok(fields) = uri.parse_query(request.body)
              as "The token request is a form."
            assert list.key_find(fields, "client_id") == Ok("oaiapp_new")
            assert list.key_find(fields, "code") == Ok("one-use-code")
            let assert Ok(verifier) = list.key_find(fields, "code_verifier")
              as "The exchange includes the original PKCE verifier."
            assert string.byte_size(verifier) == 43
            Ok(network.Response(
              200,
              "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"signed-identity-fixture\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"openid offline_access resource.invoke chatgpt.tokens.use.direct\"}",
            ))
          },
          verify: fn(_, client, _, _) {
            assert client == "oaiapp_new"
            Ok("account-one")
          },
          now: fn() { 2_000_000 },
          entropy: crypto.strong_random_bytes,
        )
      oauth.login(
        initial,
        effects,
        fn(url) { process.send(instructions, url) },
        ledger,
      )
      |> result.map(fn(binding) {
        assert binding.subject == Some("account-one")
        assert binding.client_id == Some("oaiapp_new")
        Nil
      })
    })
  let running =
    weft.new_prepared([task]) |> weft.deadline(10_000) |> weft.start_detached
  let assert Ok(port) = process.receive(instructions, 5000)
    as "The listener publishes its bound port."
  let start_url = oauth.start_url(port)
  assert string.starts_with(start_url, "http://127.0.0.1:")
  assert !string.contains(start_url, "id_token_hint")
  assert get_with_host(start_url, "evil.example").status == 400
  assert get_with_host(start_url, "127.0.0.1:1").status == 400
  let redirect = get(start_url)
  assert redirect.status == 302
  let assert Ok(auth_url) = response.get_header(redirect, "location")
    as "Only the browser receives the authorization redirect."
  let assert Ok(parsed) = uri.parse(auth_url)
    as "The issuer URL is well formed."
  assert parsed.host == Some("auth.openai.com")
  let assert Some(query) = parsed.query
    as "Authorization parameters are supplied."
  let assert Ok(fields) = uri.parse_query(query)
    as "Authorization parameters decode."
  let assert Ok(state) = list.key_find(fields, "state")
    as "The browser receives the pending state."
  let assert Ok(callback) = list.key_find(fields, "redirect_uri")
    as "The exact selected callback port is retained."
  assert get(callback <> "?state=wrong&code=untrusted&client_id=oaiapp_new").status
    == 400
  let verified_callback =
    callback
    <> "?"
    <> uri.query_to_string([
      #("state", state),
      #("code", "one-use-code"),
      #("client_id", "oaiapp_new"),
    ])
  assert get_with_host(verified_callback, "evil.example").status == 400
  assert get(verified_callback).status == 200
  let assert weft.PulledOutcome(weft.Completed(_, Nil)) =
    weft.pull(running, 10_000)
    as "The authenticated operation completes."
  assert weft.pull(running, 10_000) == weft.AllDelivered
}

// A callback names its own client ID, and any local process that has read the
// state from the start redirect can forge one. The ID is bound only by a
// verified exchange, so a callback whose exchange fails leaves the profile
// without a registration and the next login starts a fresh one.
pub fn codex_failed_exchange_does_not_persist_callback_client_id_test() {
  let directory = "/var/tmp/loom-codex-browser-" <> random_suffix()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let events = process.new_subject()
  let rejecting =
    oauth.Services(
      fetch: fn(_, _) {
        Ok(network.Response(400, "{\"error\":\"invalid_client\"}"))
      },
      verify: fn(_, _, _, _) { Ok("account-one") },
      now: fn() { 2_000_000 },
      entropy: crypto.strong_random_bytes,
    )
  let task =
    weft.managed(fn(ledger) {
      Ok(profile.execute_at(
        directory,
        "work",
        control.LoginBrowser,
        events,
        rejecting,
        ledger,
      ))
    })
  let running =
    weft.new_prepared([task]) |> weft.deadline(10_000) |> weft.start_detached
  let assert Ok(control.LoginInstructions(port)) = process.receive(events, 5000)
    as "The listener publishes its bound port."
  let start_url = oauth.start_url(port)
  let assert Ok(auth_url) = response.get_header(get(start_url), "location")
    as "The start route redirects to the issuer."
  let assert Ok(parsed) = uri.parse(auth_url)
    as "The issuer URL is well formed."
  let assert Some(query) = parsed.query as "Authorization parameters exist."
  let assert Ok(fields) = uri.parse_query(query)
    as "Authorization parameters decode."
  let assert Ok(state) = list.key_find(fields, "state")
    as "The browser receives the pending state."
  let assert Ok(callback) = list.key_find(fields, "redirect_uri")
    as "The callback address is retained."
  let forged =
    callback
    <> "?"
    <> uri.query_to_string([
      #("state", state),
      #("code", "forged-code"),
      #("client_id", "oaiapp_attacker"),
    ])
  assert get(forged).status == 200
  let assert weft.PulledOutcome(weft.Completed(_, Error(_))) =
    weft.pull(running, 10_000)
    as "The rejected exchange fails the login."
  let assert Ok(Some(stored)) = credentials.load(directory <> "/work.json")
    as "Login creates the profile record before the browser attempt."
  assert stored.client_id == None
  assert stored.subject == None
  assert stored.grant == None
}

fn random_suffix() -> String {
  bit_array.base16_encode(crypto.strong_random_bytes(8))
}

fn get(url: String) -> response.Response(String) {
  let assert Ok(request) = request.to(url)
    as "The local test request has a valid URL."
  let assert Ok(response) = httpc.send(request)
    as "The local callback listener answers."
  response
}

fn get_with_host(url: String, host: String) -> response.Response(String) {
  let assert Ok(request) = request.to(url)
    as "The local test request has a valid URL."
  let assert Ok(response) =
    request |> request.set_header("host", host) |> httpc.send
    as "The local listener answers the hostile authority."
  response
}
