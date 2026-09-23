//// Operator commands for a dedicated Codex subscription profile.
////
//// Login, status, logout, and model discovery use the same profile helper as
//// inference. This module receives redacted control events and presents them
//// to the operator. It never reads an OAuth token, account ID, or credential
//// file. A timed-out command is cancelled through its request owner.

import client/codex_bridge.{type Command, type ControlEvent}
import client/internal/ffi_os
import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/http

/// Usage for the Codex subscription control commands.
pub const usage = "usage: loomd codex <command> [--profile NAME]\n  login [--device]    Sign in with a browser or device code.\n  status              Show whether the profile is signed in.\n  models              Show models available to this profile as JSON.\n  logout              Remove this profile's saved credential.\n\nThe default profile is `default`. A profile is 1-64 ASCII letters, digits,\nunderscores, or hyphens, starting with a letter or digit."

/// A parsed request contains only a command and a portable profile name.
@internal
pub type Request {
  /// A command whose flags have already been checked.
  Request(profile: String, command: Command)
}

/// Runs one operator command without starting the daemon.
///
/// ## Examples
///
/// ```gleam
/// // cli.main(["status", "--profile", "default"])
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case parse(arguments) {
    Error(reason) -> fail(reason)
    Ok(request) -> {
      case execute(request, io.println) {
        Ok(Nil) -> Nil
        Error(reason) -> fail(reason)
      }
    }
  }
}

fn fail(reason: String) -> Nil {
  io.println_error("loom codex: " <> reason)
  ffi_os.halt(1)
}

/// Parses the operator's exact verb and flag shape before opening a helper.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Request("default", codex_bridge.Status)) = parse(["status"])
/// ```
@internal
pub fn parse(arguments: List(String)) -> Result(Request, String) {
  case arguments {
    ["login", ..flags] -> parse_flags(flags, codex_bridge.LoginBrowser, None)
    ["status", ..flags] -> parse_flags(flags, codex_bridge.Status, None)
    ["models", ..flags] -> parse_flags(flags, codex_bridge.Models, None)
    ["logout", ..flags] -> parse_flags(flags, codex_bridge.Logout, None)
    [] -> Error("a command is required\n" <> usage)
    [other, ..] -> Error("unknown command `" <> other <> "`\n" <> usage)
  }
}

fn parse_flags(
  flags: List(String),
  command: Command,
  profile: Option(String),
) -> Result(Request, String) {
  case flags {
    [] -> {
      let profile = case profile {
        Some(name) -> name
        None -> "default"
      }
      use Nil <- result.try(valid_profile(profile))
      Ok(Request(profile:, command:))
    }
    ["--profile", name, ..rest] ->
      case profile {
        None -> parse_flags(rest, command, Some(name))
        Some(_) -> Error("--profile may be passed only once\n" <> usage)
      }
    ["--device", ..rest] ->
      case command {
        codex_bridge.LoginBrowser ->
          parse_flags(rest, codex_bridge.LoginDevice, profile)
        _ -> Error("--device is valid only for login\n" <> usage)
      }
    [other, ..] -> Error("unknown argument `" <> other <> "`\n" <> usage)
  }
}

fn valid_profile(name: String) -> Result(Nil, String) {
  let chars = string.to_graphemes(name)
  let permitted =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
  let initial = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  case chars {
    [first, ..rest] ->
      case
        string.byte_size(name) <= 64
        && string.contains(initial, first)
        && all_permitted(rest, permitted)
      {
        True -> Ok(Nil)
        False -> Error("invalid profile name\n" <> usage)
      }
    _ -> Error("invalid profile name\n" <> usage)
  }
}

fn all_permitted(chars: List(String), permitted: String) -> Bool {
  case chars {
    [] -> True
    [first, ..rest] ->
      string.contains(permitted, first) && all_permitted(rest, permitted)
  }
}

fn execute(request: Request, emit: fn(String) -> Nil) -> Result(Nil, String) {
  let events = process.new_subject()
  use prepared <- result.try(codex_bridge.command(
    request.profile,
    request.command,
    events,
  ))
  let running = prepared.running
  let monitor = process.monitor(http.owner(running))
  let selector =
    process.new_selector()
    |> process.select_map(events, Observed)
    |> process.select_specific_monitor(monitor, fn(down) {
      OwnerGone(down.reason)
    })
  prepared.begin()
  let answer = await_event(selector, request.command, emit)
  case answer {
    Error("subscription command timed out") -> http.cancel(running)
    _ -> Nil
  }
  process.demonitor_process(monitor)
  answer
}

type Observation {
  Observed(ControlEvent)
  OwnerGone(process.ExitReason)
}

// OAuth can involve a human leaving the terminal for several minutes. The
// command still has a finite wait so its owner can cancel a stranded helper.
const login_wait_ms = 600_000

const control_wait_ms = 30_000

const drain_wait_ms = 30_000

fn await_event(
  selector,
  command: Command,
  emit: fn(String) -> Nil,
) -> Result(Nil, String) {
  let within = case command {
    codex_bridge.LoginBrowser | codex_bridge.LoginDevice -> login_wait_ms
    _ -> control_wait_ms
  }
  case process.selector_receive(selector, within) {
    Error(Nil) -> Error("subscription command timed out")
    Ok(OwnerGone(_)) -> Error("subscription helper stopped before completion")
    Ok(Observed(event)) ->
      case presentation(event) {
        Continue(lines) -> {
          print_lines(lines, emit)
          await_event(selector, command, emit)
        }
        Complete(_) as terminal -> await_owner(selector, terminal, emit)
        Refused(_) as terminal -> await_owner(selector, terminal, emit)
      }
  }
}

// A control result is not complete until the request owner has observed the
// helper's `end` frame and exited. The helper sends that frame only after its
// login or discovery worker has released its credential and HTTP resources.
fn await_owner(
  selector,
  terminal: Presentation,
  emit: fn(String) -> Nil,
) -> Result(Nil, String) {
  case process.selector_receive(selector, drain_wait_ms) {
    Error(Nil) -> Error("subscription command timed out")
    Ok(OwnerGone(reason)) -> {
      use lines <- result.try(drained_result(reason, terminal))
      print_lines(lines, emit)
      Ok(Nil)
    }
    Ok(Observed(_)) ->
      Error("subscription helper sent duplicate terminal result")
  }
}

/// Accepts a control result only when its request owner exited normally.
///
/// ## Examples
///
/// ```gleam
/// // drained_result(process.Normal, Complete(["done"])) == Ok(["done"])
/// ```
@internal
pub fn drained_result(
  reason: process.ExitReason,
  terminal: Presentation,
) -> Result(List(String), String) {
  case reason, terminal {
    process.Normal, Complete(lines) -> Ok(lines)
    process.Normal, Refused(code) ->
      Error("subscription helper refused " <> code)
    process.Normal, Continue(_) ->
      Error("subscription helper ended before completion")
    process.Killed, _ | process.Abnormal(_), _ ->
      Error("subscription helper drain proof lost")
  }
}

fn print_lines(lines: List(String), emit: fn(String) -> Nil) -> Nil {
  case lines {
    [] -> Nil
    [line, ..rest] -> {
      emit(line)
      print_lines(rest, emit)
    }
  }
}

/// The only rendering path for helper control events. Model JSON is already
/// reduced to a validated, non-secret list at the helper boundary.
@internal
pub type Presentation {
  /// Instructions precede a login's terminal completion.
  Continue(lines: List(String))

  /// A terminal success.
  Complete(lines: List(String))

  /// A terminal helper refusal identified only by a code.
  Refused(code: String)
}

/// Projects one redacted bridge event onto terminal text.
///
/// ## Examples
///
/// ```gleam
/// // presentation(codex_bridge.LoginStatus("logged_out", ""))
/// ```
@internal
pub fn presentation(event: ControlEvent) -> Presentation {
  case event {
    codex_bridge.LoginInstructions(url, Some(code)) ->
      case safe_login_url(url) && safe_device_code(code) {
        True -> Continue(["Open " <> url, "Enter code: " <> code])
        False -> Refused("invalid_login_instructions")
      }
    codex_bridge.LoginInstructions(url, None) ->
      case safe_login_url(url) {
        True -> Continue(["Open " <> url])
        False -> Refused("invalid_login_instructions")
      }
    codex_bridge.LoginComplete(plan) ->
      Complete(["Signed in to Codex (" <> display_plan(plan) <> ")."])
    codex_bridge.LoginStatus("logged_in", plan) ->
      Complete(["Signed in to Codex (" <> display_plan(plan) <> ")."])
    codex_bridge.LoginStatus("logged_out", _) ->
      Complete(["Not signed in to Codex."])
    codex_bridge.LoginStatus(_, _) -> Refused("invalid_status")
    codex_bridge.LogoutComplete -> Complete(["Signed out of Codex."])
    codex_bridge.ModelCatalogue(json) -> Complete([json])
    codex_bridge.ControlFailed(code) -> Refused(code)
  }
}

fn display_plan(plan: String) -> String {
  case
    safe_label(
      plan,
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    )
  {
    True -> plan
    False -> "plan unavailable"
  }
}

fn safe_login_url(url: String) -> Bool {
  string.starts_with(url, "https://auth.openai.com/")
  && string.byte_size(url) <= 4096
  && safe_label(
    url,
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~:/?&=%+",
  )
}

fn safe_device_code(code: String) -> Bool {
  string.byte_size(code) <= 64
  && safe_label(
    code,
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-",
  )
}

fn safe_label(value: String, permitted: String) -> Bool {
  case string.to_graphemes(value) {
    [] -> False
    chars -> all_permitted(chars, permitted)
  }
}
