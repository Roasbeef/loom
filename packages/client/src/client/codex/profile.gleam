//// Durable per-profile credential ownership without a token cache.
////
//// Each operation acquires the existing kernel launch lock, rereads a bounded
//// private record, and atomically replaces rotating credentials before release.
//// Inference receives only its current bearer after the lock is released, so
//// management commands can run while an HTTP stream is active. Logout cannot
//// retract an already-admitted request; later requests reread the cleared grant.
//// Login holds the lock through the browser attempt, and another operation
//// receives profile_busy after its bounded acquisition wait. `permission`
//// maps a grant's scopes onto the `control.Permission` a status or login
//// event reports, and `require_plan` refuses a grant without plan permission
//// both before and after a refresh, since a refresh may narrow its scopes.

import client/codex/credentials.{type Binding, type Grant, Binding}
import client/codex/oauth
import client/codex/profile_control as control
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/http
import weft
import weft/poll

/// Resolves the dedicated native profile directory without consulting Codex's files.
///
/// ## Examples
///
/// ```gleam
/// // profile.directory()
/// ```
pub fn directory() -> Result(String, String) {
  let root = case bootstrap.getenv("XDG_CONFIG_HOME") {
    Ok(value) if value != "" -> Ok(value)
    Ok(_) | Error(Nil) ->
      bootstrap.getenv("HOME")
      |> result.map(fn(home) { home <> "/.config" })
      |> result.replace_error("credential_unavailable")
  }
  result.map(root, fn(path) { path <> "/loom/chatgpt-subscription" })
}

/// Reads or refreshes one authorized bearer under the profile's native lock.
///
/// ## Examples
///
/// ```gleam
/// // profile.auth("default", ledger)
/// ```
pub fn auth(profile: String, ledger: weft.Ledger) -> Result(String, String) {
  use directory <- result.try(directory())
  auth_at(directory, profile, oauth.services_on(ledger))
}

/// Uses a private test directory and injected token exchange facts.
///
/// ## Examples
///
/// ```gleam
/// // profile.auth_at(test_directory, "work", services)
/// ```
@internal
pub fn auth_at(
  directory: String,
  profile: String,
  services: oauth.Services,
) -> Result(String, String) {
  with_lock(directory, profile, fn(path) {
    use binding <- result.try(current(path))
    authorize(path, binding, services)
  })
}

fn authorize(
  path: String,
  binding: Binding,
  services: oauth.Services,
) -> Result(String, String) {
  use grant <- result.try(option.to_result(binding.grant, "not_logged_in"))

  // An identity-only grant is refused before any refresh, so it never reaches
  // the token endpoint. A grant with no plan permission cannot become usable
  // by renewing it.
  use grant <- result.try(require_plan(grant))
  use grant <- result.try(case services.now() < grant.expires - 60_000 {
    True -> Ok(grant)
    False -> renew(path, binding, services)
  })

  // The issuer may narrow scopes when it rotates a grant, so the renewed grant
  // is checked again. A grant that was still fresh passes this check unchanged.
  use grant <- result.try(require_plan(grant))
  Ok(grant.access)
}

fn require_plan(grant: Grant) -> Result(Grant, String) {
  case credentials.plan_enabled(grant) {
    True -> Ok(grant)
    False -> Error("plan_permission_required")
  }
}

// A rotated grant replaces the stored one before it is used. A terminal
// refusal clears the stored grant but keeps the registration and subject, and
// any other failure leaves the record untouched for a later attempt.
fn renew(
  path: String,
  binding: Binding,
  services: oauth.Services,
) -> Result(Grant, String) {
  case oauth.refresh(binding, services) {
    Ok(refreshed) -> {
      use Nil <- result.try(credentials.save(path, refreshed))
      option.to_result(refreshed.grant, "not_logged_in")
    }
    Error("reauthorization_required") -> {
      use Nil <- result.try(credentials.save(
        path,
        Binding(..binding, grant: None),
      ))
      Error("reauthorization_required")
    }
    Error(reason) -> Error(reason)
  }
}

/// Runs a redacted operator operation inside the transport's prepared worker.
///
/// ## Examples
///
/// ```gleam
/// // profile.execute("default", control.Status, events, ledger)
/// ```
pub fn execute(
  profile: String,
  command: control.Command,
  events: Subject(control.ControlEvent),
  ledger: weft.Ledger,
) -> Result(Nil, String) {
  use directory <- result.try(directory())
  execute_at(
    directory,
    profile,
    command,
    events,
    oauth.services_on(ledger),
    ledger,
  )
}

/// Injects the profile location and effects for durable lifecycle regressions.
///
/// ## Examples
///
/// ```gleam
/// // profile.execute_at(directory, "work", control.Logout, events, services)
/// ```
@internal
pub fn execute_at(
  directory: String,
  profile: String,
  command: control.Command,
  events: Subject(control.ControlEvent),
  services: oauth.Services,
  ledger: weft.Ledger,
) -> Result(Nil, String) {
  with_lock(directory, profile, fn(path) {
    case command {
      control.Status -> {
        use stored <- result.try(credentials.load(path))
        let sign_in = case stored {
          Some(Binding(grant: Some(grant), ..)) ->
            control.SignedIn(permission(grant))
          Some(Binding(grant: None, ..)) | None -> control.SignedOut
        }
        process.send(events, control.LoginStatus(sign_in))
        Ok(Nil)
      }
      control.LoginBrowser -> {
        use binding <- result.try(load_or_create(path, services))
        use logged_in <- result.try(oauth.login(
          binding,
          services,
          fn(port) { process.send(events, control.LoginInstructions(port)) },
          ledger,
        ))
        use Nil <- result.try(credentials.save(path, logged_in))
        use grant <- result.try(option.to_result(
          logged_in.grant,
          "not_logged_in",
        ))
        process.send(events, control.LoginComplete(permission(grant)))
        Ok(Nil)
      }
      control.Logout -> {
        use stored <- result.try(credentials.load(path))
        logout(path, stored, events, services)
      }
      control.Models -> {
        use binding <- result.try(current(path))
        use bearer <- result.try(authorize(path, binding, services))
        use response <- result.try(services.fetch(
          http.HttpRequest(
            "GET",
            "https://api.openai.com/v1/models",
            [
              #("authorization", "Bearer " <> bearer),
              #("accept", "application/json"),
            ],
            "",
          ),
          1_048_576,
        ))
        use <- bool.guard(
          when: response.status != 200,
          return: Error("model_catalogue_unavailable"),
        )
        use catalogue <- result.try(model_catalogue(response.body))
        process.send(events, control.ModelCatalogue(catalogue))
        Ok(Nil)
      }
    }
  })
}

fn permission(grant: Grant) -> control.Permission {
  case credentials.plan_enabled(grant) {
    True -> control.PlanEnabled
    False -> control.IdentityOnly
  }
}

fn logout(
  path: String,
  stored,
  events: Subject(control.ControlEvent),
  services: oauth.Services,
) -> Result(Nil, String) {
  case stored {
    None -> {
      process.send(events, control.LogoutComplete)
      Ok(Nil)
    }
    Some(binding) -> {
      let revoked = oauth.revoke(binding, services)
      use Nil <- result.try(credentials.save(
        path,
        Binding(..binding, grant: None),
      ))
      let event = case revoked {
        Ok(Nil) -> control.LogoutComplete
        Error(_) -> control.LogoutRevocationUnconfirmed
      }
      process.send(events, event)
      Ok(Nil)
    }
  }
}

fn current(path: String) -> Result(Binding, String) {
  use binding <- result.try(credentials.load(path))
  option.to_result(binding, "not_logged_in")
}

fn load_or_create(
  path: String,
  services: oauth.Services,
) -> Result(Binding, String) {
  use stored <- result.try(credentials.load(path))
  case stored {
    Some(binding) -> Ok(binding)
    None -> {
      let binding = Binding(oauth.host_id(services.entropy), None, None, None)
      use Nil <- result.try(credentials.save(path, binding))
      Ok(binding)
    }
  }
}

fn with_lock(
  directory: String,
  profile: String,
  operation: fn(String) -> Result(value, String),
) -> Result(value, String) {
  use Nil <- result.try(credentials.valid_profile(profile))
  use Nil <- result.try(
    bootstrap.ensure_private_directory(directory)
    |> result.replace_error("credential_unavailable"),
  )
  let lock_path = directory <> "/" <> profile <> ".lock"
  use lock <- result.try(acquire(lock_path))
  let answer = operation(directory <> "/" <> profile <> ".json")
  bootstrap.release_launch_lock(lock)
  answer
}

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
    poll.Expired -> Error("profile_busy")
  }
}

/// Projects only bounded public identifiers from an authenticated model list.
///
/// The subscription endpoint returns models identified by slug, rather than the
/// Platform API's data/id shape. Only listed entries reach the operator, in the
/// server's order; instructions and other model metadata never leave this seam.
///
/// ## Examples
///
/// ```gleam
/// assert profile.model_catalogue("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"visibility\":\"list\"}]}") == Ok("[{\"id\":\"gpt-6.1-sol\"}]")
/// ```
@internal
pub fn model_catalogue(document: String) -> Result(String, String) {
  let decoder = {
    use models <- decode.field(
      "models",
      decode.list({
        use slug <- decode.field("slug", decode.string)
        use visibility <- decode.field("visibility", decode.string)
        decode.success(#(slug, visibility))
      }),
    )
    decode.success(models)
  }
  use models <- result.try(
    json.parse(document, decoder)
    |> result.replace_error("invalid_model_catalogue"),
  )
  use <- bool.guard(
    when: list.drop(models, 512) != []
      || !list.all(models, fn(model) { valid_model(model.0) }),
    return: Error("invalid_model_catalogue"),
  )

  // Bounds apply to the whole response before visibility removes hidden rows.
  // Otherwise hidden entries could evade the catalogue's count and ID checks.
  let listed = list.filter(models, fn(model) { model.1 == "list" })
  Ok(
    json.array(listed, fn(model) {
      json.object([#("id", json.string(model.0))])
    })
    |> json.to_string,
  )
}

fn valid_model(id: String) -> Bool {
  let permitted =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.:/"
  id != ""
  && string.byte_size(id) <= 128
  && list.all(string.to_graphemes(id), fn(char) {
    string.contains(permitted, char)
  })
}
