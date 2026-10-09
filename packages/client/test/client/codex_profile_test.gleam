//// Durable profile ownership, refresh rotation and revocation regressions.
////
//// Test directories are explicit and never resolve the operator's saved
//// credentials. The real cross-process kernel lock serializes both workers.

import client/codex/credentials
import client/codex/network
import client/codex/oauth
import client/codex/profile
import client/codex/profile_control as control
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import provider/http
import weft

fn directory() -> String {
  "/var/tmp/loom-codex-profile-"
  <> bit_array.base16_encode(crypto.strong_random_bytes(8))
}

fn binding() -> credentials.Binding {
  credentials.Binding(
    "urn:uuid:00000000-0000-4000-8000-000000000000",
    Some("oaiapp_saved"),
    Some("account-one"),
    Some(credentials.Grant(
      "old-access",
      Some("old-refresh"),
      "old-id-token",
      [
        "openid",
        "offline_access",
        "resource.invoke",
        "chatgpt.tokens.use.direct",
      ],
      1000,
    )),
  )
}

fn services(
  fetch: fn(http.HttpRequest, Int) -> Result(network.Response, String),
) {
  oauth.Services(
    fetch,
    fn(_, _, _, _) { Ok("account-one") },
    fn() { 2_000_000 },
    crypto.strong_random_bytes,
  )
}

pub fn codex_concurrent_expired_requests_rotate_once_test() {
  let directory = directory()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let assert Ok(Nil) = credentials.save(directory <> "/work.json", binding())
    as "The old grant is durable before either worker starts."
  let refreshes = process.new_subject()
  let services =
    services(fn(request, _) {
      assert request.url == "https://auth.openai.com/api/accounts/oauth/token"
      assert string.contains(request.body, "refresh_token=old-refresh")
      assert string.contains(request.body, "client_id=oaiapp_saved")
      assert !string.contains(request.body, "scope=")
      process.send(refreshes, Nil)
      process.sleep(50)
      Ok(network.Response(
        200,
        "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"openid offline_access resource.invoke chatgpt.tokens.use.direct\"}",
      ))
    })
  let outcomes =
    weft.new([
      fn() { profile.auth_at(directory, "work", services) },
      fn() { profile.auth_at(directory, "work", services) },
    ])
    |> weft.limit(2)
    |> weft.start
  assert list.all(outcomes, fn(outcome) {
    case outcome {
      weft.Completed(_, "new-access") -> True
      _ -> False
    }
  })
  assert process.receive(refreshes, 1000) == Ok(Nil)
  assert process.receive(refreshes, 0) == Error(Nil)
  let assert Ok(Some(saved)) = credentials.load(directory <> "/work.json")
    as "The rotated grant is durable."
  let assert Some(grant) = saved.grant
    as "A successful refresh retains a grant."
  assert grant.refresh == Some("new-refresh")
}

pub fn codex_terminal_refresh_clears_tokens_but_temporary_failure_preserves_test() {
  let directory = directory()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let old = binding()
  let assert Ok(Nil) = credentials.save(directory <> "/work.json", old)
    as "The previous grant is saved."
  assert profile.auth_at(
      directory,
      "work",
      services(fn(_, _) { Ok(network.Response(503, "unavailable")) }),
    )
    == Error("token_endpoint_unavailable")
  assert credentials.load(directory <> "/work.json") == Ok(Some(old))
  assert profile.auth_at(
      directory,
      "work",
      services(fn(_, _) {
        Ok(network.Response(400, "{\"error\":\"invalid_grant\"}"))
      }),
    )
    == Error("reauthorization_required")
  assert credentials.load(directory <> "/work.json")
    == Ok(Some(credentials.Binding(..old, grant: None)))
}

pub fn codex_logout_unconfirmed_revocation_clears_local_grant_test() {
  let directory = directory()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let old = binding()
  let assert Ok(Nil) = credentials.save(directory <> "/work.json", old)
    as "The previous grant is saved."
  let events = process.new_subject()
  let effects =
    services(fn(request, _) {
      assert request.url == "https://auth.openai.com/api/accounts/oauth/revoke"
      assert string.contains(request.body, "token=old-refresh")
      assert string.contains(request.body, "token_type_hint=refresh_token")
      Ok(network.Response(503, "temporary"))
    })
  assert weft.new_prepared([
      weft.managed(fn(ledger) {
        profile.execute_at(
          directory,
          "work",
          control.Logout,
          events,
          effects,
          ledger,
        )
      }),
    ])
    |> weft.start
    == [weft.Completed(0, Nil)]
  assert process.receive(events, 1000)
    == Ok(control.LogoutRevocationUnconfirmed)
  assert credentials.load(directory <> "/work.json")
    == Ok(Some(credentials.Binding(..old, grant: None)))
  assert profile.auth_at(directory, "work", effects) == Error("not_logged_in")
}

pub fn codex_identity_only_never_posts_or_refreshes_test() {
  let directory = directory()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let old = binding()
  let assert Some(grant) = old.grant as "The fixture carries a grant."
  let identity =
    credentials.Binding(
      ..old,
      grant: Some(credentials.Grant(..grant, scopes: ["openid", "email"])),
    )
  let assert Ok(Nil) = credentials.save(directory <> "/work.json", identity)
    as "Identity-only sign-in is saved."
  assert profile.auth_at(
      directory,
      "work",
      services(fn(_, _) {
        panic as "Identity-only grants must never contact inference or refresh."
      }),
    )
    == Error("plan_permission_required")
}

pub fn codex_status_reports_signed_out_identity_only_and_plan_enabled_test() {
  let directory = directory()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let path = directory <> "/work.json"
  let old = binding()
  let assert Some(grant) = old.grant as "The fixture carries a grant."
  let identity =
    credentials.Binding(
      ..old,
      grant: Some(credentials.Grant(..grant, scopes: ["openid", "email"])),
    )
  let never =
    services(fn(_, _) { panic as "Status must not contact the network." })
  let status = fn() {
    let events = process.new_subject()
    assert weft.new_prepared([
        weft.managed(fn(ledger) {
          profile.execute_at(
            directory,
            "work",
            control.Status,
            events,
            never,
            ledger,
          )
        }),
      ])
      |> weft.start
      == [weft.Completed(0, Nil)]
    process.receive(events, 1000)
  }

  assert status() == Ok(control.LoginStatus(control.SignedOut))
  let assert Ok(Nil) =
    credentials.save(path, credentials.Binding(..old, grant: None))
    as "A signed-out record is saved."
  assert status() == Ok(control.LoginStatus(control.SignedOut))
  let assert Ok(Nil) = credentials.save(path, identity)
    as "An identity-only grant is saved."
  assert status()
    == Ok(control.LoginStatus(control.SignedIn(control.IdentityOnly)))
  let assert Ok(Nil) = credentials.save(path, old) as "A plan grant is saved."
  assert status()
    == Ok(control.LoginStatus(control.SignedIn(control.PlanEnabled)))
}

pub fn codex_public_catalogue_drops_unknown_fields_and_refuses_malformed_test() {
  assert profile.model_catalogue(
      "{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"visibility\":\"list\",\"base_instructions\":\"private instructions\",\"access_token\":\"secret\"},{\"slug\":\"hidden-model\",\"visibility\":\"hide\"},{\"slug\":\"gpt-6-luna\",\"visibility\":\"list\"}]}",
    )
    == Ok("[{\"id\":\"gpt-6.1-sol\"},{\"id\":\"gpt-6-luna\"}]")
  assert profile.model_catalogue("{\"models\":[]}") == Ok("[]")

  list.each(
    [
      "{\"data\":[{\"id\":\"gpt-6-sol\"}]}",
      "{\"models\":[{}]}",
      "{\"models\":[{\"slug\":\"gpt-6-sol\"}]}",
      "{\"models\":[{\"slug\":\"forged\\nrow\",\"visibility\":\"list\"}]}",
      "{\"models\":[{\"slug\":\"\",\"visibility\":\"hide\"}]}",
    ],
    fn(document) {
      assert profile.model_catalogue(document)
        == Error("invalid_model_catalogue")
    },
  )
}

pub fn codex_catalogue_bounds_include_unlisted_models_test() {
  let row =
    json.object([
      #("slug", json.string("hidden-model")),
      #("visibility", json.string("hide")),
    ])
  let document = fn(count) {
    json.object([
      #("models", json.array(list.repeat(row, count), fn(row) { row })),
    ])
    |> json.to_string
  }
  assert profile.model_catalogue(document(512)) == Ok("[]")
  assert profile.model_catalogue(document(513))
    == Error("invalid_model_catalogue")
}

pub fn codex_models_command_projects_subscription_catalogue_test() {
  let directory = directory()
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "The test owns its private directory."
  let old = binding()
  let assert Some(grant) = old.grant as "The fixture carries a grant."
  let current =
    credentials.Binding(
      ..old,
      grant: Some(credentials.Grant(..grant, expires: 4_000_000)),
    )
  let assert Ok(Nil) = credentials.save(directory <> "/work.json", current)
    as "The authorized grant is durable before discovery."

  let events = process.new_subject()
  let effects =
    services(fn(request, limit) {
      assert request.url == "https://api.openai.com/v1/models"
      assert request.method == "GET"
      assert request.body == ""
      assert limit == 1_048_576
      assert list.contains(request.headers, #(
        "authorization",
        "Bearer old-access",
      ))
      Ok(network.Response(
        200,
        "{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"visibility\":\"list\",\"display_name\":\"Sol\"}]}",
      ))
    })
  assert weft.new_prepared([
      weft.managed(fn(ledger) {
        profile.execute_at(
          directory,
          "work",
          control.Models,
          events,
          effects,
          ledger,
        )
      }),
    ])
    |> weft.start
    == [weft.Completed(0, Nil)]
  assert process.receive(events, 1000)
    == Ok(control.ModelCatalogue("[{\"id\":\"gpt-6.1-sol\"}]"))
}
