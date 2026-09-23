//// The Codex control CLI checks syntax before it starts a helper and renders
//// only the credential-free observations offered by the bridge.

import client/codex/cli
import client/codex_bridge
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn codex_cli_selects_browser_device_and_profile_test() {
  assert cli.parse(["login"])
    == Ok(cli.Request("default", codex_bridge.LoginBrowser))
  assert cli.parse(["login", "--profile", "work_1", "--device"])
    == Ok(cli.Request("work_1", codex_bridge.LoginDevice))
  assert cli.parse(["models", "--profile", "work-2"])
    == Ok(cli.Request("work-2", codex_bridge.Models))
  assert cli.parse(["logout"])
    == Ok(cli.Request("default", codex_bridge.Logout))
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
  assert cli.presentation(codex_bridge.LoginInstructions(
      "https://auth.openai.com/device",
      Some("ABCD-EFGH"),
    ))
    == cli.Continue([
      "Open https://auth.openai.com/device",
      "Enter code: ABCD-EFGH",
    ])
  assert cli.presentation(codex_bridge.LoginInstructions(
      "https://auth.openai.com/authorize",
      None,
    ))
    == cli.Continue(["Open https://auth.openai.com/authorize"])
  assert cli.presentation(codex_bridge.LoginStatus("logged_out", ""))
    == cli.Complete(["Not signed in to Codex."])
  assert cli.presentation(codex_bridge.LoginStatus("logged_in", "pro"))
    == cli.Complete(["Signed in to Codex (pro)."])
  assert cli.presentation(codex_bridge.ControlFailed("account_mismatch"))
    == cli.Refused("account_mismatch")
}

pub fn codex_cli_models_are_passed_through_without_secret_fields_test() {
  let models = "[{\"id\":\"gpt-6-sol\",\"context_window\":200000}]"
  assert cli.presentation(codex_bridge.ModelCatalogue(models))
    == cli.Complete([models])
}

pub fn codex_cli_refuses_terminal_escape_in_auth_observations_test() {
  assert cli.presentation(codex_bridge.LoginInstructions(
      "https://auth.openai.com/codex/device\nforged",
      Some("ABCD"),
    ))
    == cli.Refused("invalid_login_instructions")
  assert cli.presentation(codex_bridge.LoginInstructions(
      "https://auth.openai.com/codex/device",
      Some("ABCD\nforged"),
    ))
    == cli.Refused("invalid_login_instructions")
  assert cli.presentation(codex_bridge.LoginComplete("pro\nforged"))
    == cli.Complete(["Signed in to Codex (plan unavailable)."])
}

pub fn codex_cli_requires_normal_owner_drain_after_success_test() {
  let success = cli.Complete(["Signed in to Codex (pro)."])
  assert cli.drained_result(process.Normal, success)
    == Ok(["Signed in to Codex (pro)."])
  assert cli.drained_result(
      process.Abnormal(dynamic.string("helper exited")),
      success,
    )
    == Error("subscription helper drain proof lost")
  assert cli.drained_result(process.Killed, success)
    == Error("subscription helper drain proof lost")
}
