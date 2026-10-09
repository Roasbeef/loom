//// The subscription CLI checks syntax before it admits an operation and renders
//// only the credential-free observations reported by a control command.

import client/codex/cli
import client/codex/profile_control as control
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/string

pub fn codex_cli_selects_browser_and_profile_test() {
  assert cli.parse(["login"])
    == Ok(cli.Request("default", control.LoginBrowser))
  assert cli.parse(["login", "--profile", "work_1"])
    == Ok(cli.Request("work_1", control.LoginBrowser))
  assert cli.parse(["models", "--profile", "work-2"])
    == Ok(cli.Request("work-2", control.Models))
  assert cli.parse(["logout"]) == Ok(cli.Request("default", control.Logout))
}

pub fn codex_cli_refuses_ambiguous_or_unsafe_arguments_test() {
  let invalid = [
    ["login", "--device", "--device"],
    ["status", "--device"],
    ["models", "--profile"],
    ["logout", "--profile", "good", "--profile", "other"],
    ["login", "--profile", "-bad"],
    ["login", "--profile", "bad/relative"],
    ["login", "--profile", "bad\nline"],
    ["login", "--profile", "é"],
    ["login", "--profile", string.repeat("a", 65)],
    ["login", "--secret", "token"],
  ]
  assert invalid
    |> list.all(fn(arguments) {
      case cli.parse(arguments) {
        Error(_) -> True
        Ok(_) -> False
      }
    })
}

pub fn codex_cli_renders_redacted_status_and_login_instructions_test() {
  assert cli.presentation(control.LoginInstructions(1455))
    == cli.Continue(["Open http://127.0.0.1:1455/auth/start"])
  assert cli.presentation(control.LoginStatus(control.SignedOut))
    == cli.Complete(["Not signed in with ChatGPT."])
  assert cli.presentation(
      control.LoginStatus(control.SignedIn(control.PlanEnabled)),
    )
    == cli.Complete(["Signed in with ChatGPT (plan_enabled)."])
  assert cli.presentation(
      control.LoginStatus(control.SignedIn(control.IdentityOnly)),
    )
    == cli.Complete(["Signed in with ChatGPT (identity_only)."])
  assert cli.presentation(control.LoginComplete(control.IdentityOnly))
    == cli.Complete(["Signed in with ChatGPT (identity_only)."])
  assert cli.presentation(control.ControlFailed("account_mismatch"))
    == cli.Refused("account_mismatch")
}

pub fn codex_cli_renders_logout_outcomes_test() {
  assert cli.presentation(control.LogoutComplete)
    == cli.Complete(["Signed out of ChatGPT."])
  assert cli.presentation(control.LogoutRevocationUnconfirmed)
    == cli.Complete([
      "Signed out locally. Remote revocation was not confirmed; disconnect Loom in ChatGPT Settings.",
    ])
}

pub fn codex_cli_models_are_passed_through_without_secret_fields_test() {
  let models = "[{\"id\":\"gpt-6-sol\",\"context_window\":200000}]"
  assert cli.presentation(control.ModelCatalogue(models))
    == cli.Complete([models])
}

pub fn codex_cli_requires_normal_owner_drain_after_success_test() {
  let success = cli.Complete(["Signed in with ChatGPT (plan_enabled)."])
  assert cli.drained_result(process.Normal, success)
    == Ok(["Signed in with ChatGPT (plan_enabled)."])
  assert cli.drained_result(
      process.Abnormal(dynamic.string("operation exited")),
      success,
    )
    == Error("subscription operation drain proof lost")
  assert cli.drained_result(process.Killed, success)
    == Error("subscription operation drain proof lost")
}
